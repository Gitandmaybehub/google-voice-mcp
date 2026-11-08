import CryptoKit
import Foundation

/// Makes the anti-abuse stamp Google's own web page attaches to every text it sends.
/// Without it Google turns most sends away. The app target implements this with Apple's built-in web engine.
public protocol Stamper: AnyObject {
    func stamp(client: VoiceClient, threadID: String, recipients: [String], transactionID: Int64) async throws -> String
}

public enum WaaPayload {
    /// What the stamp program signs: SHA-256 hashes of the thread, the recipients, and the message number.
    public static func forMessage(threadID: String, recipients: [String], transactionID: Int64) -> [String: String] {
        func hash(_ s: String) -> String { Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString() }
        return [
            "thread_id": hash(threadID),
            "destinations": hash(recipients.joined(separator: "|")),
            "message_ids": hash(String(transactionID)),
        ]
    }
}

/// Remembers every keyed send, so a retry with the same key can never text twice.
public final class Ledger {
    let store: SessionStore
    var file: URL { store.dir.appendingPathComponent("sends.json") }
    static let keepFor: TimeInterval = 30 * 24 * 3600

    public init(store: SessionStore) { self.store = store }

    struct Entry: Codable {
        var fingerprint: String
        var status: String          // pending, sent, uncertain, failed
        var at: Date
        var threadID: String?
        var messageID: String?
        var sentAt: Date?
    }

    public static func fingerprint(_ to: [String], _ text: String) -> String {
        let digest = SHA256.hash(data: Data((to.sorted().joined(separator: ",") + "\n" + text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder.gv.decode([String: Entry].self, from: data)) ?? [:]
    }

    func save(_ entries: [String: Entry]) throws {
        let cutoff = Date().addingTimeInterval(-Ledger.keepFor)
        try writePrivate(try JSONEncoder.gv.encode(entries.filter { $0.value.at > cutoff }), to: file)
    }

    /// Claims the key before sending. Returns the earlier result when this exact message already went out.
    public func begin(key: String, to: [String], text: String) throws -> [String: Any]? {
        try store.locked {
            var entries = load()
            let fp = Ledger.fingerprint(to, text)
            if let e = entries[key] {
                guard e.fingerprint == fp else {
                    throw GVError("KEY_CONFLICT", "The key '\(key)' was already used for a different message.",
                                  hint: "Use a new key for a new message. Reuse a key only to retry the same message.")
                }
                switch e.status {
                case "sent":
                    var out: [String: Any] = ["sent": true, "duplicate": true, "to": to]
                    if let t = e.threadID { out["conversationId"] = t }
                    if let m = e.messageID { out["messageId"] = m }
                    if let s = e.sentAt { out["timestamp"] = Render.iso.string(from: s) }
                    out["note"] = "Already sent with this key earlier, so it was not sent again."
                    return out
                case "pending", "uncertain":
                    throw GVError("SEND_UNCERTAIN",
                                  "An earlier try with key '\(key)' may or may not have gone out.",
                                  hint: "Read the conversation first. Only send again if the text is not there.")
                default:
                    break  // failed before reaching anyone: safe to try again
                }
            }
            entries[key] = Entry(fingerprint: fp, status: "pending", at: Date())
            try save(entries)
            return nil
        }
    }

    public func finish(key: String, status: String, receipt: SendReceipt? = nil) {
        _ = try? store.locked {
            var entries = load()
            guard var e = entries[key] else { return }
            e.status = status
            e.at = Date()
            if let receipt {
                e.threadID = receipt.threadID
                e.messageID = receipt.messageID
                e.sentAt = Date(timeIntervalSince1970: Double(receipt.timestamp) / 1000)
            }
            entries[key] = e
            try save(entries)
        }
    }
}

/// The send door: a small script the owner controls that every text passes before it goes out
/// (for example opt-outs, quiet hours, or the numbers an agent may text). No door, no send.
public struct SendDoor {
    public let python: String
    public let script: String

    /// Where the door lives when GVOICE_SEND_DOOR is not set. It can be a symlink to the real script.
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gvoice/send_door").path
    }

    public static func locate(environment env: [String: String] = ProcessInfo.processInfo.environment) -> SendDoor? {
        let given = env["GVOICE_SEND_DOOR"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? defaultPath
        // Follow a symlink, so the door runs from its own folder with its own Python.
        let script = URL(fileURLWithPath: given).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: script) else { return nil }
        let venv = URL(fileURLWithPath: script).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".venv/bin/python").path
        let python = FileManager.default.isExecutableFile(atPath: venv) ? venv : "/usr/bin/python3"
        return SendDoor(python: python, script: script)
    }

    public struct Outcome {
        public var decision: String     // sent or blocked
        public var reason: String
    }

    /// Hands one text to the door. Only a "sent" decision means it went out.
    public func send(phone: String, text: String, key: String?) async -> Outcome {
        var args = [script, "--phone", phone, "--text", text, "--source", "gvoice"]
        if let key, !key.isEmpty { args += ["--key", key] }
        let python = self.python
        let cwd = URL(fileURLWithPath: script).deletingLastPathComponent()
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: python)
                p.arguments = args
                p.currentDirectoryURL = cwd
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    done.resume(returning: Outcome(decision: "blocked", reason: "door_error: could not start the send door"))
                    return
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
                if let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
                   let decision = obj["decision"] as? String {
                    done.resume(returning: Outcome(decision: decision, reason: obj["reason_code"] as? String ?? ""))
                } else {
                    done.resume(returning: Outcome(decision: "blocked", reason: "door_error: no answer from the send door"))
                }
            }
        }
    }
}

/// One-at-a-time gate for async code, so two sends in the same process never interleave.
actor AsyncLock {
    var busy = false
    var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
