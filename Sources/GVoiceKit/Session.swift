import Foundation

public enum Paths {
    /// ~/Library/Application Support/gvoice, or GVOICE_STATE_DIR. Created private (owner only).
    public static var stateDir: URL {
        let env = ProcessInfo.processInfo.environment["GVOICE_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let dir = env.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/gvoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
}

/// The tool's own Google sign-in. Created by `gvoice login`, never copied from another browser.
public struct Session: Codable {
    public var version = 1
    public var jar: CookieJar
    public var authUser: String
    public var email: String?
    public var number: String?
    public var userAgent: String
    public var signedInAt: Date
    public var rotatedAt: Date?

    public init(jar: CookieJar, authUser: String, email: String?, number: String?, userAgent: String,
                signedInAt: Date = Date()) {
        self.jar = jar
        self.authUser = authUser
        self.email = email
        self.number = number
        self.userAgent = userAgent
        self.signedInAt = signedInAt
    }
}

/// Reads and writes session.json (mode 600) under a file lock, so the MCP server and
/// command-line calls running at the same time never overwrite each other's refreshed cookies.
public final class SessionStore {
    public let dir: URL
    public var file: URL { dir.appendingPathComponent("session.json") }
    var lockFile: URL { dir.appendingPathComponent(".session.lock") }

    public init(dir: URL = Paths.stateDir) {
        self.dir = dir
    }

    public func load() throws -> Session? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            return try JSONDecoder.gv.decode(Session.self, from: data)
        } catch {
            throw GVError("SESSION_DAMAGED", "The saved sign-in file could not be read.",
                          hint: "Run `gvoice login` to sign in again.", exitCode: 3)
        }
    }

    public func save(_ session: Session) throws {
        let data = try JSONEncoder.gv.encode(session)
        try writePrivate(data, to: file)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: file)
    }

    public var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Runs `body` while holding an exclusive lock shared by every gvoice process.
    public func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Writes a file readable only by its owner, atomically (temp file + rename).
public func writePrivate(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
    FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: tmp)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    if rename(tmp.path, url.path) != 0 {
        try? FileManager.default.removeItem(at: tmp)
        throw GVError("WRITE_FAILED", "Could not save \(url.lastPathComponent).")
    }
}

extension JSONEncoder {
    static var gv: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var gv: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
