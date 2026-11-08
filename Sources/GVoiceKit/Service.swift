import Foundation

/// Every gvoice action, shared by the command line and the MCP server. Each returns plain JSON-ready data.
public actor Service {
    public let store: SessionStore
    let transport: Transport
    let stamper: Stamper?
    var client: VoiceClient?
    let sendLock = AsyncLock()
    lazy var ledger = Ledger(store: store)

    public init(store: SessionStore = SessionStore(), transport: Transport = URLSessionTransport(), stamper: Stamper? = nil) {
        self.store = store
        self.transport = transport
        self.stamper = stamper
    }

    func voice() throws -> VoiceClient {
        if let client { return client }
        let c = try VoiceClient.open(store: store, transport: transport)
        client = c
        return c
    }

    /// Runs one command by name with checked arguments.
    public func run(_ command: String, _ args: Args, direct: Bool = false) async throws -> Any {
        switch command {
        case "status": return try await status()
        case "logout": return logout()
        case "list": return try await list(args)
        case "search": return try await search(args)
        case "read": return try await read(args)
        case "voicemail": return try await voicemail(args)
        case "mark-read": return try await markRead(args)
        case "send": return try await send(args, direct: direct)
        case "reply": return try await reply(args, direct: direct)
        default: throw GVError.invalid("Unknown command '\(command)'.")
        }
    }

    // MARK: - Account

    public func status() async throws -> [String: Any] {
        let c = try voice()
        let number = try await c.account().number
        var email = await c.session.email
        if email == nil { email = await c.accountEmail() }
        await c.remember(email: email, number: number)
        let s = await c.session
        var out: [String: Any] = ["signedIn": true, "number": number, "signedInAt": Render.iso.string(from: s.signedInAt)]
        if let email { out["account"] = email }
        return out
    }

    /// Refreshes the sign-in cookie when due. The MCP server calls this every 20 minutes while idle.
    public func keepAlive() async {
        guard let c = try? voice() else { return }
        await c.refreshIfDue()
    }

    public func logout() -> [String: Any] {
        let had = (try? store.load()) != nil
        store.delete()
        client = nil
        return ["signedOut": true, "hadSession": had]
    }

    // MARK: - Reading

    func names(_ c: VoiceClient, _ phones: [String]) async -> [String: String] {
        var out: [String: String] = [:]
        let unique = phones.uniqued()
        for start in stride(from: 0, to: unique.count, by: 100) {
            let chunk = Array(unique[start..<min(start + 100, unique.count)])
            if let found = try? await c.names(for: chunk) { out.merge(found) { a, _ in a } }
        }
        return out
    }

    func me(_ c: VoiceClient) async -> String? { await c.session.number }

    public func list(_ args: Args) async throws -> [String: Any] {
        let c = try voice()
        let folderName = args.string("folder") ?? "inbox"
        let folder = Folder(rawValue: folderName) ?? .inbox
        let unreadOnly = args.string("filter") == "unread"
        let limit = args.int("limit")
        var token = args.string("page")
        var picked: [VoiceThread] = []
        var scanned = 0
        let scanCap = unreadOnly ? 1000 : limit
        repeat {
            let size = unreadOnly ? 100 : min(100, limit - picked.count)
            let page = try await c.listThreads(folder, pageSize: size, messagesPerThread: 1, pageToken: token)
            scanned += page.threads.count
            picked += unreadOnly ? page.threads.filter { !$0.read } : page.threads
            token = page.next
            if page.threads.isEmpty { token = nil }
        } while token != nil && picked.count < limit && scanned < scanCap
        picked = Array(picked.prefix(limit))
        let render = Render(names: await names(c, picked.flatMap(\.participants)), me: await me(c))
        var out: [String: Any] = [
            "folder": folderName,
            "count": picked.count,
            "conversations": picked.map { render.conversation($0, folder: folderName) },
        ]
        if let token { out["nextPage"] = token }
        if unreadOnly { out["scanned"] = scanned }
        return out
    }

    public func search(_ args: Args) async throws -> [String: Any] {
        let c = try voice()
        let query = (args.string("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = args.string("folder") ?? "inbox"
        let folder = Folder(rawValue: folderName) ?? .inbox
        let limit = args.int("limit")
        var threads: [VoiceThread] = []
        var token: String?
        repeat {
            let page = try await c.listThreads(folder, pageSize: 100, messagesPerThread: 15, pageToken: token)
            threads += page.threads
            token = page.threads.isEmpty ? nil : page.next
        } while token != nil && threads.count < 500
        let known = await names(c, threads.flatMap(\.participants))
        let render = Render(names: known, me: await me(c))
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let digits = query.filter(\.isNumber)
        let numberSearch = digits.count >= 3 && digits.count * 2 >= query.filter { !$0.isWhitespace }.count
        var hits: [[String: Any]] = []
        for t in threads where hits.count < limit {
            var why: String?
            if numberSearch, t.participants.contains(where: { $0.filter(\.isNumber).contains(digits) }) {
                why = "number"
            } else if t.participants.contains(where: { fold(known[$0]).contains(needle) }) {
                why = "name"
            } else if let m = t.messages.first(where: { fold($0.text).contains(needle) }) {
                var row = render.conversation(t, folder: folderName)
                row["match"] = m.text
                row["matchTimestamp"] = Render.iso.string(from: m.date)
                row["matchedOn"] = "message"
                hits.append(row)
                continue
            }
            if let why {
                var row = render.conversation(t, folder: folderName)
                row["matchedOn"] = why
                hits.append(row)
            }
        }
        return [
            "query": query,
            "count": hits.count,
            "conversations": hits,
            "searched": "\(threads.count) newest conversations in \(folderName), up to 15 recent messages each",
        ]
    }

    nonisolated func fold(_ s: String?) -> String {
        (s ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Accepts a conversation id from list ("t.+1...", "c....") or a plain phone number.
    nonisolated func threadID(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("t."), let p = Phone.fromThreadID(id) { return Phone.threadID(p) }
        if id.count > 2, id.dropFirst().hasPrefix("."), id.first?.isLetter == true { return id }
        if let p = Phone.normalize(id) { return Phone.threadID(p) }
        throw GVError.invalid("'\(raw)' is not a conversation id or phone number.")
    }

    public func read(_ args: Args) async throws -> [String: Any] {
        let c = try voice()
        let id = try threadID(args.string("id") ?? "")
        let limit = args.int("limit")
        var t = try await c.thread(id, count: min(limit, 100))
        var skipNote: String?
        if args.string("filter") == "unread" && t.read { skipNote = "Conversation is already read, so it was skipped." }
        if args.bool("skip_unconfirmed_read") && !t.read { skipNote = "Conversation is unread, so it was skipped." }
        var messages = t.messages
        var token = t.nextPage
        if skipNote == nil {
            while messages.count < limit, let tok = token {
                let more = try await c.thread(id, count: min(limit - messages.count, 100), pageToken: tok)
                if more.messages.isEmpty { break }
                messages += more.messages
                token = more.nextPage
            }
        } else {
            messages = []
        }
        t.messages = Array(messages.prefix(limit))
        let senders = t.messages.compactMap(\.sender)
        let render = Render(names: await names(c, t.participants + senders), me: await me(c))
        var out = render.conversation(t)
        out.removeValue(forKey: "lastMessage")
        out.removeValue(forKey: "lastTimestamp")
        out.removeValue(forKey: "lastDirection")
        out["unreadWas"] = !t.read
        out["skipped"] = skipNote != nil
        if let skipNote { out["note"] = skipNote }
        out["messages"] = t.messages.reversed().map { render.message($0, in: t) }
        out["hasMore"] = skipNote == nil && token != nil && messages.count >= limit
        return out
    }

    public func voicemail(_ args: Args) async throws -> [String: Any] {
        let c = try voice()
        let limit = args.int("limit")
        var found: [(Message, VoiceThread)] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try await c.listThreads(.voicemail, pageSize: 50, messagesPerThread: 5, pageToken: token)
            for t in page.threads {
                for m in t.messages where m.kind == .voicemail { found.append((m, t)) }
            }
            token = page.threads.isEmpty ? nil : page.next
            pages += 1
        } while token != nil && found.count < limit && pages < 20
        found.sort { $0.0.timestamp > $1.0.timestamp }
        found = Array(found.prefix(limit))
        let phones = found.flatMap { [$0.0.sender].compactMap { $0 } + $0.1.participants }
        let render = Render(names: await names(c, phones), me: await me(c))
        return ["count": found.count, "voicemails": found.map { render.voicemail($0.0, in: $0.1) }]
    }

    public func markRead(_ args: Args) async throws -> [String: Any] {
        let c = try voice()
        let id = try threadID(args.string("id") ?? "")
        let unread = args.bool("unread")
        _ = try await c.thread(id, count: 1)   // a clear NOT_FOUND beats a silent no-op
        try await c.setRead(id, read: !unread)
        return ["conversationId": id, "isUnread": unread]
    }

    // MARK: - Sending

    nonisolated func cleanText(_ args: Args) throws -> String {
        let text = (args.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GVError.invalid("'text' cannot be empty.") }
        return text
    }

    public func send(_ args: Args, direct: Bool) async throws -> [String: Any] {
        let text = try cleanText(args)
        var numbers: [String] = []
        for raw in args.strings("to") {
            guard let n = Phone.normalize(raw) else { throw GVError.invalid("'\(raw)' is not a phone number.") }
            numbers.append(n)
        }
        numbers = numbers.uniqued()
        guard !numbers.isEmpty else { throw GVError.invalid("`send` needs at least one phone number in 'to'.") }
        let key = args.string("key").flatMap { $0.isEmpty ? nil : $0 }
        if direct {
            return try await sendDirect(threadID: nil, recipients: numbers, text: text, key: key)
        }
        return try await throughDoor(numbers, text: text, key: key)
    }

    public func reply(_ args: Args, direct: Bool) async throws -> [String: Any] {
        let text = try cleanText(args)
        let id = try threadID(args.string("id") ?? "")
        let key = args.string("key").flatMap { $0.isEmpty ? nil : $0 }
        if direct {
            return try await sendDirect(threadID: id, recipients: [], text: text, key: key)
        }
        guard let phone = Phone.fromThreadID(id) else {
            throw GVError("DOOR_ONE_TO_ONE_ONLY", "The send door only handles one-to-one text conversations.",
                          hint: "Group texts and call threads cannot be replied to through the door.", exitCode: 2)
        }
        var out = try await throughDoor([phone], text: text, key: key)
        out["conversationId"] = id
        return out
    }

    func throughDoor(_ numbers: [String], text: String, key: String?) async throws -> [String: Any] {
        guard let door = SendDoor.locate() else {
            throw GVError("NO_SEND_DOOR", "No send door was found, so nothing was sent.",
                          hint: "Put your door at ~/.config/gvoice/send_door or set GVOICE_SEND_DOOR. Start from examples/send_door.py.")
        }
        var results: [[String: Any]] = []
        for n in numbers {
            let outcome = await door.send(phone: Phone.tenDigits(n), text: text, key: key)
            results.append(["to": n, "decision": outcome.decision, "reason": outcome.reason])
        }
        let allSent = results.allSatisfy { $0["decision"] as? String == "sent" }
        var out: [String: Any] = ["via": "send door", "sent": allSent, "results": results]
        out["note"] = numbers.count > 1
            ? "The door texts each number on its own. Only \"sent\" means a text went out."
            : "Only \"sent\" means the text went out."
        return out
    }

    /// Sends straight from Google Voice with the anti-abuse stamp. One attempt, never blind-retried.
    func sendDirect(threadID: String?, recipients: [String], text: String, key: String?) async throws -> [String: Any] {
        guard let stamper else {
            throw GVError("STAMP_UNAVAILABLE", "This build cannot make the send stamp, so nothing was sent.")
        }
        await sendLock.lock()
        do {
            let out = try await sendDirectLocked(stamper, threadID: threadID, recipients: recipients, text: text, key: key)
            await sendLock.unlock()
            return out
        } catch {
            await sendLock.unlock()
            throw error
        }
    }

    func sendDirectLocked(_ stamper: Stamper, threadID: String?, recipients: [String], text: String,
                          key: String?) async throws -> [String: Any] {
        let c = try voice()
        // Find the conversation. A first text to a number has no conversation yet: the send creates it.
        var thread = threadID ?? (recipients.count == 1 ? Phone.threadID(recipients[0]) : nil)
        var participants = recipients
        if let t = thread {
            do {
                let existing = try await c.thread(t, count: 1)
                if !existing.participants.isEmpty { participants = existing.participants }
            } catch let e as GVError where e.code == "NOT_FOUND" && threadID == nil {
                thread = nil
            }
        }
        guard !participants.isEmpty else { throw GVError.notFound("Conversation \(threadID ?? "")") }
        let ledgerTo = threadID.map { [$0] } ?? participants
        if let key, let earlier = try ledger.begin(key: key, to: ledgerTo, text: text) { return earlier }

        let sendThread = thread ?? ""
        let txn = Int64.random(in: 1..<100_000_000_000_000)
        let stamp: String
        do {
            stamp = try await stamper.stamp(client: c, threadID: sendThread, recipients: participants, transactionID: txn)
        } catch {
            if let key { ledger.finish(key: key, status: "failed") }
            let detail = (error as? GVError)?.message ?? error.localizedDescription
            throw GVError("STAMP_FAILED", "Could not make Google's send check, so nothing was sent (\(detail)).",
                          hint: "Try again in a minute.")
        }
        let receipt: SendReceipt
        do {
            receipt = try await c.sendSMS(text: text, threadID: sendThread, recipients: participants,
                                          transactionID: txn, stamp: stamp)
        } catch let e as GVError {
            if let key { ledger.finish(key: key, status: e.code == "SEND_UNCERTAIN" ? "uncertain" : "failed") }
            throw e
        } catch {
            if let key { ledger.finish(key: key, status: "uncertain") }
            throw GVError("SEND_UNCERTAIN", "Something went wrong mid-send, so it is not known whether the text went out.",
                          hint: "Read the conversation before trying again.")
        }
        if let key { ledger.finish(key: key, status: "sent", receipt: receipt) }
        return [
            "sent": true,
            "via": "direct",
            "to": participants,
            "conversationId": receipt.threadID,
            "messageId": receipt.messageID,
            "timestamp": Render.iso.string(from: Date(timeIntervalSince1970: Double(receipt.timestamp) / 1000)),
        ]
    }
}
