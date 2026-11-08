import Foundation

/// Sends one HTTP request. Swappable so tests run without the network.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GVError.network("no HTTP response") }
        return (data, http)
    }
}

public enum Google {
    public static let origin = "https://voice.google.com"
    public static let apiKey = "AIzaSyDTYc1N4xiODyrQYK0Kl6g_y279LjYkrBg"      // the Voice web app's public key
    public static let waaKey = "AIzaSyBGb5fGAyC-pRcRU6MUHb__b_vKha71HRE"
    public static let waaRequestKey = "/JR8jsAkqotcKsEKhXic"
    public static let clientVersion = "665865172"
    public static let voiceAPI = "https://clients6.google.com/voice/v1/voiceclient"
    public static let peopleAPI = "https://peoplestack-pa.clients6.google.com/$rpc/peoplestack.PeopleStackAutocompleteService"
    public static let waaAPI = "https://waa-pa.clients6.google.com/$rpc/google.internal.waa.v1.Waa"
    public static let rotateURL = "https://accounts.google.com/RotateCookies"

    /// Safari's user agent on this Mac. The sign-in window, the send stamp and every request use the same one.
    public static var safariUserAgent: String {
        let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = (plist?["CFBundleShortVersionString"] as? String) ?? "26.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }
}

public struct WaaProgram {
    public var scriptURL: String
    public var program: String
    public var globalName: String
}

public struct SendReceipt {
    public var threadID: String
    public var messageID: String
    public var timestamp: Int64
}

/// Talks to the same private web endpoints voice.google.com uses, with the tool's own signed-in session.
public actor VoiceClient {
    public private(set) var session: Session
    let store: SessionStore?
    let transport: Transport
    var lastFileCheck = Date.distantPast
    public static let rotateEvery: TimeInterval = 10 * 60

    public init(session: Session, store: SessionStore?, transport: Transport = URLSessionTransport()) {
        self.session = session
        self.store = store
        self.transport = transport
    }

    /// Loads the saved sign-in. Throws SIGNED_OUT when there is none.
    public static func open(store: SessionStore = SessionStore(), transport: Transport = URLSessionTransport()) throws -> VoiceClient {
        guard let session = try store.load() else { throw GVError.signedOut }
        return VoiceClient(session: session, store: store, transport: transport)
    }

    // MARK: - Voice API

    public func account() async throws -> (number: String, raw: Any) {
        let resp = try await voice("account/get", [nil, 1])
        guard let number = PB.str(PB.at(resp, 1), 1), !number.isEmpty else {
            throw GVError("NO_VOICE_NUMBER", "This Google account has no Google Voice number.",
                          hint: "Run `gvoice login` and pick the account that owns the number.")
        }
        return (number, resp)
    }

    public func listThreads(_ folder: Folder, pageSize: Int, messagesPerThread: Int = 15,
                            pageToken: String? = nil) async throws -> (threads: [VoiceThread], next: String?) {
        let resp = try await voice("api2thread/list", [folder.code, pageSize, messagesPerThread, pageToken, nil, [nil, 1, 1]])
        let threads = PB.list(resp, 1).compactMap(VoiceThread.init(pb:))
        let next = PB.str(resp, 2).flatMap { $0.isEmpty ? nil : $0 }
        return (threads, next)
    }

    public func thread(_ id: String, count: Int, pageToken: String? = nil) async throws -> VoiceThread {
        let resp: Any
        do {
            resp = try await voice("api2thread/get", [id, count, pageToken, [nil, 1, 1]])
        } catch let e as GVError where e.code == "NOT_FOUND" || e.code == "GOOGLE_ERROR" && e.message.contains("HTTP 400") {
            throw GVError.notFound("Conversation \(id)")
        }
        guard let t = VoiceThread(pb: PB.at(resp, 1) as Any) else { throw GVError.notFound("Conversation \(id)") }
        return t
    }

    /// Marks a conversation read or unread (the second message is the field mask).
    public func setRead(_ id: String, read: Bool) async throws {
        _ = try await voice("thread/updateattributes", [[id, nil, nil, read ? 1 : 0], [nil, nil, nil, 1], 1])
    }

    /// Names saved in the account's Google Contacts, keyed by E.164 number. Missing names are left out.
    public func names(for phones: [String]) async throws -> [String: String] {
        let wanted = phones.filter { $0.hasPrefix("+") }.uniqued()
        guard !wanted.isEmpty else { return [:] }
        let url = URL(string: "\(Google.peopleAPI)/Lookup?key=\(Google.apiKey)")!
        let resp = try await call(url, body: PB.encode([243, [1, 2], wanted.map { [nil, $0] as [Any?] }]),
                                  extra: ["X-Goog-Api-Key": Google.apiKey])
        var out: [String: String] = [:]
        for match in PB.list(resp, 1) {
            guard let phone = PB.str(PB.at(match, 1), 2) else { continue }
            let methods = PB.list(PB.at(PB.at(match, 2), 1), 1)
            for m in methods {
                if let name = PB.str(PB.at(PB.at(m, 1), 2), 1), !name.isEmpty, name != phone {
                    out[phone] = name
                    break
                }
            }
        }
        return out
    }

    // MARK: - Sending

    public func createWaa() async throws -> WaaProgram {
        let url = URL(string: "\(Google.waaAPI)/Create")!
        let resp = try await call(url, body: PB.encode([Google.waaRequestKey]),
                                  extra: ["X-Goog-Api-Key": Google.waaKey, "X-User-Agent": "grpc-web-javascript/0.1"])
        let waa = PB.at(resp, 1)
        guard var script = PB.str(PB.at(waa, 3), 4), let program = PB.str(waa, 5), let global = PB.str(waa, 6) else {
            throw GVError("STAMP_FAILED", "Google did not hand out the send check program.")
        }
        if script.hasPrefix("//") { script = "https:" + script }
        return WaaProgram(scriptURL: script, program: program, globalName: global)
    }

    public func pingWaa(_ token: String) async throws {
        let url = URL(string: "\(Google.waaAPI)/Ping")!
        _ = try await call(url, body: PB.encode([Google.waaRequestKey, token, 72, Int64.random(in: 0..<2_000_000_000)]),
                           extra: ["X-Goog-Api-Key": Google.waaKey, "X-User-Agent": "grpc-web-javascript/0.1"])
    }

    /// One send attempt. Never retried here: a timeout after Google received it could mean a double text.
    public func sendSMS(text: String, threadID: String, recipients: [String], transactionID: Int64,
                        stamp: String?) async throws -> SendReceipt {
        let body: [Any?] = [nil, nil, nil, nil, text, threadID, threadID.isEmpty ? recipients : nil, nil,
                            [transactionID], nil, stamp.map { [$0] } ?? ["!"]]
        let resp = try await voice("api2thread/sendsms", body, retry: false)
        return SendReceipt(threadID: PB.str(resp, 2) ?? threadID, messageID: PB.str(resp, 3) ?? "",
                           timestamp: PB.int(resp, 4) ?? Int64(Date().timeIntervalSince1970 * 1000))
    }

    // MARK: - Session upkeep

    /// Saves the account email and Voice number onto the stored sign-in once they are known.
    public func remember(email: String?, number: String?) {
        let email = email ?? session.email
        let number = number ?? session.number
        guard email != session.email || number != session.number else { return }
        session.email = email
        session.number = number
        guard let store else { return }
        let signedInAt = session.signedInAt
        _ = try? store.locked {
            guard var onDisk = try store.load(), abs(onDisk.signedInAt.timeIntervalSince(signedInAt)) < 1 else { return }
            onDisk.email = email
            onDisk.number = number
            try store.save(onDisk)
        }
        lastFileCheck = Date()
    }

    /// Refreshes the short-lived sign-in cookie the way Google's web apps do (about every 10 minutes of use).
    /// Never throws for a failed refresh: the real call that follows reports the actual problem.
    @discardableResult
    public func refreshIfDue(force: Bool = false) async -> Bool {
        try? reloadIfChanged()
        let due = force || session.rotatedAt.map { Date().timeIntervalSince($0) > VoiceClient.rotateEvery } ?? true
        guard due else { return true }
        if let store, !force {
            // Another gvoice process may have just refreshed; re-read under the lock before deciding.
            if let fresh = try? store.locked({ try store.load() }) {
                session = fresh
                if let at = fresh.rotatedAt, Date().timeIntervalSince(at) <= VoiceClient.rotateEvery { return true }
            }
        }
        var req = URLRequest(url: URL(string: Google.rotateURL)!)
        req.httpMethod = "POST"
        req.httpBody = Data("[000,\"-0000000000000000000\"]".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://accounts.google.com", forHTTPHeaderField: "Origin")
        req.setValue(session.userAgent, forHTTPHeaderField: "User-Agent")
        if let c = session.jar.header(for: req.url!) { req.setValue(c, forHTTPHeaderField: "Cookie") }
        guard let (_, http) = try? await transport.send(req) else { return false }
        let changed = session.jar.absorb(http)
        guard (200..<300).contains(http.statusCode) else { return false }
        session.rotatedAt = Date()
        try? persist(changed, markRotated: true)
        return true
    }

    /// The Google account email for this sign-in, when Google shares it. Best effort.
    public func accountEmail() async -> String? {
        var req = URLRequest(url: URL(string: "https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard")!)
        req.httpMethod = "POST"
        req.httpBody = Data()
        req.setValue(session.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://accounts.google.com", forHTTPHeaderField: "Origin")
        if let c = session.jar.header(for: req.url!) { req.setValue(c, forHTTPHeaderField: "Cookie") }
        guard let (data, http) = try? await transport.send(req), http.statusCode == 200,
              let parsed = try? PB.parse(data) else { return nil }
        let accounts = PB.list(parsed, 2)
        let index = Int(session.authUser) ?? 0
        let row: Any? = accounts.indices.contains(index) ? accounts[index] : accounts.first
        return PB.str(row, 4).flatMap { $0.contains("@") ? $0 : nil }
    }

    func reloadIfChanged() throws {
        guard let store else { return }
        guard let mod = store.modified else { throw GVError.signedOut }   // `gvoice logout` ran
        guard mod > lastFileCheck else { return }
        lastFileCheck = Date()
        if let fresh = try store.load() { session = fresh }
    }

    func persist(_ changed: [Cookie], markRotated: Bool = false) throws {
        guard let store, !changed.isEmpty || markRotated else { return }
        let rotatedAt = session.rotatedAt
        try store.locked {
            var onDisk = try store.load() ?? session
            for c in changed { onDisk.jar.set(c) }
            if markRotated { onDisk.rotatedAt = rotatedAt }
            onDisk.jar.dropExpired()
            try store.save(onDisk)
        }
        lastFileCheck = Date()
    }

    // MARK: - HTTP

    func voice(_ path: String, _ body: [Any?], retry: Bool = true) async throws -> Any {
        let url = URL(string: "\(Google.voiceAPI)/\(path)?alt=protojson&key=\(Google.apiKey)")!
        return try await call(url, body: PB.encode(body), retry: retry)
    }

    func request(_ url: URL, body: Data, extra: [String: String]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = body
        let h: [String: String] = [
            "Content-Type": "application/json+protobuf",
            "User-Agent": session.userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": Google.origin,
            "Referer": Google.origin + "/",
            "Sec-Fetch-Site": "same-site",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "X-Goog-AuthUser": session.authUser,
        ]
        for (k, v) in h { r.setValue(v, forHTTPHeaderField: k) }
        if url.host == "clients6.google.com" {
            r.setValue(Google.clientVersion, forHTTPHeaderField: "X-Client-Version")
            r.setValue("google-api-javascript-client/1.1.0", forHTTPHeaderField: "X-JavaScript-User-Agent")
            r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            let details = "appVersion=\(session.userAgent.dropFirst(8))&platform=MacIntel&userAgent=\(session.userAgent)"
            r.setValue(details.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? details,
                       forHTTPHeaderField: "X-ClientDetails")
        }
        if let sapisid = session.jar.value("SAPISID") {
            r.setValue(GoogleAuth.sapisidHash(sapisid, origin: Google.origin), forHTTPHeaderField: "Authorization")
        }
        if let c = session.jar.header(for: url) { r.setValue(c, forHTTPHeaderField: "Cookie") }
        for (k, v) in extra { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Calls one endpoint with retries for flaky networks and one automatic sign-in refresh on 401.
    func call(_ url: URL, body: Data, extra: [String: String] = [:], retry: Bool = true) async throws -> Any {
        try reloadIfChanged()
        await refreshIfDue()
        guard session.jar.value("SAPISID") != nil else { throw GVError.signedOut }
        var attempt = 0
        var refreshed = false
        while true {
            attempt += 1
            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await transport.send(request(url, body: body, extra: extra))
            } catch let e as GVError {
                throw e
            } catch {
                let failedBeforeSending = (error as? URLError).map { [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                                                                      .notConnectedToInternet].contains($0.code) } ?? false
                if (retry || failedBeforeSending) && attempt < 4 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                    continue
                }
                if !retry && !failedBeforeSending {
                    throw GVError("SEND_UNCERTAIN", "The connection dropped while sending, so it is not known whether the text went out.",
                                  hint: "Read the conversation before trying again.")
                }
                throw GVError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)
            }
            try persist(session.jar.absorb(http))
            switch http.statusCode {
            case 200..<300:
                return try PB.parse(data)
            case 401, 403:
                if !refreshed {
                    refreshed = true
                    await refreshIfDue(force: true)
                    continue
                }
                throw GVError.sessionExpired
            case 404:
                throw GVError.notFound("That item")
            case 429:
                if retry && attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
                if !retry {
                    throw GVError("SEND_REJECTED", "Google Voice turned the text away (too many requests). Nothing was sent.",
                                  hint: "Wait a few minutes before trying again.")
                }
                throw GVError.rateLimited
            case 500..<600:
                if retry && attempt < 4 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
                if !retry {
                    throw GVError("SEND_UNCERTAIN", "Google Voice had a server error mid-send, so it is not known whether the text went out.",
                                  hint: "Read the conversation before trying again.")
                }
                throw GVError.google(http.statusCode, VoiceClient.errorText(data))
            default:
                throw GVError.google(http.statusCode, VoiceClient.errorText(data))
            }
        }
    }

    static func errorText(_ data: Data) -> String {
        guard let parsed = try? PB.parse(data) else { return "" }
        if let dict = parsed as? [String: Any], let err = dict["error"] as? [String: Any] {
            return (err["message"] as? String) ?? ""
        }
        return PB.str(parsed, 2) ?? ""
    }
}
