import Foundation
import XCTest
@testable import GVoiceKit

/// Plays Google's part: answers each request from a routing closure and records what was sent.
final class FakeGoogle: Transport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body: Any = [Any]()
        var headers: [String: String] = [:]
        var fail: URLError.Code?
    }

    let lock = NSLock()
    var requests: [URLRequest] = []
    var route: (URLRequest, Int) -> Reply

    init(_ route: @escaping (URLRequest, Int) -> Reply) { self.route = route }

    func count(_ suffix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.url!.path.hasSuffix(suffix) }.count
    }

    func bodies(_ suffix: String) -> [Any] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.url!.path.hasSuffix(suffix) }.compactMap {
            $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n = lock.withLock {
            requests.append(request)
            return requests.filter { $0.url!.path == request.url!.path }.count
        }
        let r = route(request, n)
        if let fail = r.fail { throw URLError(fail) }
        let data = r.body is Data ? r.body as! Data
            : try JSONSerialization.data(withJSONObject: r.body, options: .fragmentsAllowed)
        return (data, HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: r.headers)!)
    }
}

final class FakeStamper: Stamper {
    var calls: [(String, [String], Int64)] = []
    var fail = false

    func stamp(client: VoiceClient, threadID: String, recipients: [String], transactionID: Int64) async throws -> String {
        if fail { throw GVError("X", "no stamp") }
        calls.append((threadID, recipients, transactionID))
        return "stamp-ok"
    }
}

enum Fixture {
    static let jane = "+15551230001"
    static let bob = "+15551230002"
    static let me = "+15550000000"

    static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    static func message(_ id: String, _ ts: Int64, _ type: Int, _ text: String?, from: String) -> [Any] {
        [id, ts, me, [NSNull(), from], type, 0, NSNull(), NSNull(), NSNull(), text as Any? ?? NSNull()]
    }

    static let picture: [Any] = ["m5", Int64(1_700_000_300_000), me, [NSNull(), jane], 10, 0, NSNull(), NSNull(), NSNull(),
                                 NSNull(), NSNull(), NSNull(), NSNull(), NSNull(),
                                 [NSNull(), NSNull(), [["image/jpeg", "att-1"]], NSNull(), jane]]

    static func thread(_ id: String, read: Bool, _ messages: [[Any]], next: String? = nil, phones: [String]) -> [Any] {
        [id, read ? 1 : 0, messages, next as Any? ?? NSNull(), phones.map { [$0, $0] }, [2], NSNull(), 1, phones]
    }

    static let janeThread = thread("t.\(jane)", read: false, [
        picture,
        message("m2", 1_700_000_060_000, 11, "On my way", from: jane),
        message("m1", 1_700_000_000_000, 10, "Hi there, are you free Friday?", from: jane),
    ], next: "older-1", phones: [jane])

    static let bobThread = thread("t.\(bob)", read: true, [
        message("m3", 1_699_999_000_000, 10, "Ceramic coating price?", from: bob),
    ], phones: [bob])

    static let voicemail: [Any] = ["c.VM1", 0, [["v1", Int64(1_700_000_500_000), me, [NSNull(), bob], 2, 0,
                                                 [NSNull(), [[b64("Call")], [b64("me")], [b64("back")]]], NSNull(), 12.0]],
                                   NSNull(), [[bob, bob]], [4], NSNull(), 0, [bob]]

    static func names(_ pairs: [String: String]) -> [Any] {
        [pairs.map { phone, name -> [Any] in
            [[NSNull(), phone], [[[[[NSNull(), [name]]]]]]]
        }]
    }

    static func session(_ store: SessionStore) throws {
        var s = Session(jar: CookieJar([Cookie(name: "SAPISID", value: "abc", domain: "google.com"),
                                        Cookie(name: "SID", value: "sid", domain: "google.com")]),
                        authUser: "0", email: "test@example.com", number: me, userAgent: "UA")
        s.rotatedAt = Date()
        try store.save(s)
    }
}

final class ServiceTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = SessionStore(dir: dir)
        try Fixture.session(store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func google(_ extra: ((URLRequest, Int) -> FakeGoogle.Reply?)? = nil) -> FakeGoogle {
        FakeGoogle { req, n in
            if let r = extra?(req, n) { return r }
            let path = req.url!.path
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
            if path.hasSuffix("api2thread/list") {
                let folder = PB.int(body, 1)
                if folder == 4 { return .init(body: [[Fixture.voicemail]]) }
                return .init(body: [[Fixture.janeThread, Fixture.bobThread], NSNull(), "v1-x"])
            }
            if path.hasSuffix("api2thread/get") {
                let id = PB.str(body, 1)
                if id == "t.\(Fixture.jane)" {
                    if PB.str(body, 3) == "older-1" {
                        return .init(body: [Fixture.thread("t.\(Fixture.jane)", read: false,
                                                           [Fixture.message("m0", 1_699_000_000_000, 10, "First text", from: Fixture.jane)],
                                                           phones: [Fixture.jane])])
                    }
                    return .init(body: [Fixture.janeThread])
                }
                if id == "t.\(Fixture.bob)" { return .init(body: [Fixture.bobThread]) }
                return .init(status: 404, body: ["error": ["message": "not found"]])
            }
            if path.hasSuffix("/Lookup") { return .init(body: Fixture.names([Fixture.jane: "Jane Doe"])) }
            if path.hasSuffix("account/get") { return .init(body: [[Fixture.me]]) }
            if path.hasSuffix("api2thread/sendsms") { return .init(body: [NSNull(), "t.\(Fixture.jane)", "new-msg", 1_700_000_900_000]) }
            if path.hasSuffix("thread/updateattributes") { return .init(body: [Any]()) }
            if path.hasSuffix("RotateCookies") {
                return .init(headers: ["Set-Cookie": "__Secure-1PSIDTS=rotated; Domain=.google.com; Path=/; Secure"])
            }
            return .init(status: 418)
        }
    }

    func testListRendersNamesAndUnread() async throws {
        let g = google()
        let s = Service(store: store, transport: g)
        let out = try await s.list(Validator.check([:], Commands.named("list")!))
        let rows = out["conversations"] as! [[String: Any]]
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["conversationId"] as? String, "t.\(Fixture.jane)")
        XCTAssertEqual(rows[0]["contact"] as? String, "Jane Doe")
        XCTAssertEqual(rows[0]["isUnread"] as? Bool, true)
        XCTAssertEqual(rows[0]["lastMessage"] as? String, "Picture")
        XCTAssertEqual(rows[1]["contact"] as? String, "(555) 123-0002")
        XCTAssertNil(out["nextPage"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(out))
        // Every Voice call carries the sign-in headers the web app sends.
        let req = g.requests.first { $0.url!.path.hasSuffix("api2thread/list") }!
        XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")!.hasPrefix("SAPISIDHASH "))
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
        XCTAssertTrue(req.value(forHTTPHeaderField: "Cookie")!.contains("SAPISID=abc"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json+protobuf")
        XCTAssertEqual(g.count("RotateCookies"), 0)   // fresh sign-in: no refresh needed yet

        let unread = try await s.list(Validator.check(["filter": "unread"], Commands.named("list")!))
        XCTAssertEqual(unread["count"] as? Int, 1)
    }

    func testReadIsOldestFirstAndPages() async throws {
        let s = Service(store: store, transport: google())
        let out = try await s.read(Validator.check(["id": "(555) 123-0001", "limit": 10], Commands.named("read")!))
        let msgs = out["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs.map { $0["messageId"] as! String }, ["m0", "m1", "m2", "m5"])
        XCTAssertEqual(msgs[1]["senderName"] as? String, "Jane Doe")
        XCTAssertEqual(msgs[2]["sender"] as? String, "me")
        XCTAssertEqual(msgs[2]["isInbound"] as? Bool, false)
        XCTAssertEqual(msgs[3]["hasPicture"] as? Bool, true)
        XCTAssertEqual(out["unreadWas"] as? Bool, true)
        XCTAssertEqual(out["skipped"] as? Bool, false)

        let skipped = try await s.read(Validator.check(["id": "t.\(Fixture.jane)", "skip_unconfirmed_read": true],
                                                       Commands.named("read")!))
        XCTAssertEqual(skipped["skipped"] as? Bool, true)
        XCTAssertEqual((skipped["messages"] as! [Any]).count, 0)

        do {
            _ = try await s.read(Validator.check(["id": "+15559999999"], Commands.named("read")!))
            XCTFail("expected NOT_FOUND")
        } catch let e as GVError {
            XCTAssertEqual(e.code, "NOT_FOUND")
        }
    }

    func testSearchAndVoicemail() async throws {
        let s = Service(store: store, transport: google())
        let byWords = try await s.search(Validator.check(["query": "ceramic"], Commands.named("search")!))
        XCTAssertEqual((byWords["conversations"] as! [[String: Any]]).first?["matchedOn"] as? String, "message")
        let byName = try await s.search(Validator.check(["query": "jane"], Commands.named("search")!))
        XCTAssertEqual((byName["conversations"] as! [[String: Any]]).first?["matchedOn"] as? String, "name")
        let byNumber = try await s.search(Validator.check(["query": "123-0002"], Commands.named("search")!))
        XCTAssertEqual((byNumber["conversations"] as! [[String: Any]]).first?["matchedOn"] as? String, "number")
        let none = try await s.search(Validator.check(["query": "zzz"], Commands.named("search")!))
        XCTAssertEqual(none["count"] as? Int, 0)

        let vm = try await s.voicemail(Validator.check([:], Commands.named("voicemail")!))
        let first = (vm["voicemails"] as! [[String: Any]])[0]
        XCTAssertEqual(first["transcript"] as? String, "Call me back")
        XCTAssertEqual(first["phone"] as? String, Fixture.bob)
        XCTAssertEqual(first["durationSeconds"] as? Double, 12)
    }

    func testDirectSendNewThreadAndKeyedRetry() async throws {
        let g = google()
        let stamper = FakeStamper()
        let s = Service(store: store, transport: g, stamper: stamper)
        let args = try Validator.check(["to": "555-123-9999", "text": "  Hello!  ", "key": "k1"], Commands.named("send")!)
        let out = try await s.send(args, direct: true)
        XCTAssertEqual(out["sent"] as? Bool, true)
        XCTAssertEqual(out["messageId"] as? String, "new-msg")
        // No conversation with that number yet, so the send names the recipient and leaves the thread blank.
        let body = g.bodies("api2thread/sendsms").first!
        XCTAssertEqual(PB.str(body, 5), "Hello!")
        XCTAssertEqual(PB.str(body, 6), "")
        XCTAssertEqual(PB.strings(body, 7), ["+15551239999"])
        XCTAssertEqual(PB.strings(body, 11), ["stamp-ok"])
        XCTAssertEqual(stamper.calls.first?.0, "")
        XCTAssertEqual(stamper.calls.first?.1, ["+15551239999"])
        XCTAssertEqual(PB.int(PB.at(body, 9), 1), stamper.calls.first?.2)

        let again = try await s.send(args, direct: true)
        XCTAssertEqual(again["duplicate"] as? Bool, true)
        XCTAssertEqual(g.count("api2thread/sendsms"), 1)   // the retry did not text twice
    }

    func testDirectReplyUsesExistingThread() async throws {
        let g = google()
        let stamper = FakeStamper()
        let s = Service(store: store, transport: g, stamper: stamper)
        _ = try await s.reply(Validator.check(["id": "t.\(Fixture.jane)", "text": "Yes!"], Commands.named("reply")!), direct: true)
        let body = g.bodies("api2thread/sendsms").first!
        XCTAssertEqual(PB.str(body, 6), "t.\(Fixture.jane)")
        XCTAssertNil(PB.at(body, 7))
        XCTAssertEqual(stamper.calls.first?.1, [Fixture.jane])
    }

    func testSendFailuresAreNeverRetried() async throws {
        for (status, code) in [(429, "SEND_REJECTED"), (503, "SEND_UNCERTAIN")] {
            let g = google { req, _ in req.url!.path.hasSuffix("sendsms") ? .init(status: status) : nil }
            let s = Service(store: store, transport: g, stamper: FakeStamper())
            let args = try Validator.check(["to": Fixture.jane, "text": "hi", "key": "x\(status)"], Commands.named("send")!)
            do {
                _ = try await s.send(args, direct: true)
                XCTFail("expected \(code)")
            } catch let e as GVError {
                XCTAssertEqual(e.code, code)
            }
            XCTAssertEqual(g.count("api2thread/sendsms"), 1)
        }
        let g = google { req, _ in req.url!.path.hasSuffix("sendsms") ? .init(fail: .timedOut) : nil }
        let s = Service(store: store, transport: g, stamper: FakeStamper())
        let args = try Validator.check(["to": Fixture.jane, "text": "hi", "key": "t1"], Commands.named("send")!)
        do {
            _ = try await s.send(args, direct: true)
            XCTFail("expected SEND_UNCERTAIN")
        } catch let e as GVError {
            XCTAssertEqual(e.code, "SEND_UNCERTAIN")
        }
        XCTAssertEqual(g.count("api2thread/sendsms"), 1)
        do {   // same key again: refuses until someone checks the conversation
            _ = try await s.send(args, direct: true)
            XCTFail("expected SEND_UNCERTAIN")
        } catch let e as GVError {
            XCTAssertEqual(e.code, "SEND_UNCERTAIN")
        }
        XCTAssertEqual(g.count("api2thread/sendsms"), 1)
    }

    func testStampFailureSendsNothing() async throws {
        let g = google()
        let stamper = FakeStamper()
        stamper.fail = true
        let s = Service(store: store, transport: g, stamper: stamper)
        do {
            _ = try await s.send(Validator.check(["to": Fixture.jane, "text": "hi"], Commands.named("send")!), direct: true)
            XCTFail("expected STAMP_FAILED")
        } catch let e as GVError {
            XCTAssertEqual(e.code, "STAMP_FAILED")
        }
        XCTAssertEqual(g.count("api2thread/sendsms"), 0)
    }

    func testSendDoor() async throws {
        let door = dir.appendingPathComponent("gv-bridge/send_door.py")
        try FileManager.default.createDirectory(at: door.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import json, sys
        a = sys.argv
        phone = a[a.index("--phone") + 1]
        print("noise")
        print(json.dumps({"decision": "sent" if phone == "5551230001" else "blocked", "reason_code": "ok" if phone == "5551230001" else "opted_out"}))
        """.write(to: door, atomically: true, encoding: .utf8)
        setenv("GVOICE_SEND_DOOR", door.path, 1)
        defer { unsetenv("GVOICE_SEND_DOOR") }
        let g = google()
        let s = Service(store: store, transport: g, stamper: FakeStamper())
        let out = try await s.send(Validator.check(["to": [Fixture.jane, Fixture.bob], "text": "hi"], Commands.named("send")!),
                                   direct: false)
        let results = out["results"] as! [[String: Any]]
        XCTAssertEqual(results.map { $0["decision"] as! String }, ["sent", "blocked"])
        XCTAssertEqual(results[1]["reason"] as? String, "opted_out")
        XCTAssertEqual(out["sent"] as? Bool, false)
        XCTAssertEqual(g.count("api2thread/sendsms"), 0)   // the door, not gvoice, does the sending

        do {
            _ = try await s.reply(Validator.check(["id": "c.GROUP1", "text": "hi"], Commands.named("reply")!), direct: false)
            XCTFail("expected DOOR_ONE_TO_ONE_ONLY")
        } catch let e as GVError {
            XCTAssertEqual(e.code, "DOOR_ONE_TO_ONE_ONLY")
        }
        setenv("GVOICE_SEND_DOOR", dir.appendingPathComponent("missing.py").path, 1)
        do {
            _ = try await s.send(Validator.check(["to": Fixture.jane, "text": "hi"], Commands.named("send")!), direct: false)
            XCTFail("expected NO_SEND_DOOR")
        } catch let e as GVError {
            XCTAssertEqual(e.code, "NO_SEND_DOOR")
        }
    }

    func testExpiredSignInRefreshesOnceThenReports() async throws {
        // 401 first, then fine: one refresh and a retry fix it.
        let g = google { req, n in req.url!.path.hasSuffix("account/get") && n == 1 ? .init(status: 401) : nil }
        let s = Service(store: store, transport: g)
        let st = try await s.status()
        XCTAssertEqual(st["number"] as? String, Fixture.me)
        XCTAssertEqual(g.count("RotateCookies"), 1)
        XCTAssertEqual(try store.load()?.jar.value("__Secure-1PSIDTS"), "rotated")   // refreshed cookie was saved

        // Always 401: Google really ended the sign-in.
        let dead = google { req, _ in req.url!.path.hasSuffix("account/get") ? .init(status: 401) : nil }
        do {
            _ = try await Service(store: store, transport: dead).status()
            XCTFail("expected SIGNED_OUT")
        } catch let e as GVError {
            XCTAssertEqual(e.code, "SIGNED_OUT")
            XCTAssertEqual(e.exitCode, 3)
        }
    }

    func testReadsRetryServerHiccups() async throws {
        let g = google { req, n in req.url!.path.hasSuffix("api2thread/list") && n < 3 ? .init(status: 503) : nil }
        let s = Service(store: store, transport: g)
        let out = try await s.list(Validator.check(["limit": 1], Commands.named("list")!))
        XCTAssertEqual(out["count"] as? Int, 1)
        XCTAssertEqual(g.count("api2thread/list"), 3)
    }

    func testLogoutAndSignedOut() async throws {
        let s = Service(store: store, transport: google())
        _ = try await s.status()
        _ = await s.logout()
        do {
            _ = try await s.list(Validator.check([:], Commands.named("list")!))
            XCTFail("expected SIGNED_OUT")
        } catch let e as GVError {
            XCTAssertEqual(e.code, "SIGNED_OUT")
        }
    }

    func testMarkRead() async throws {
        let g = google()
        let s = Service(store: store, transport: g)
        let out = try await s.markRead(Validator.check(["id": "t.\(Fixture.jane)", "unread": true], Commands.named("mark-read")!))
        XCTAssertEqual(out["isUnread"] as? Bool, true)
        let body = g.bodies("thread/updateattributes").first!
        XCTAssertEqual(String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self),
                       "[[\"t.+15551230001\",null,null,0],[null,null,null,1],1]")
    }

    func testMCPTools() async throws {
        let server = MCPServer(service: Service(store: store, transport: google()), version: "test", openLogin: {})
        let names = server.tools.map { $0["name"] as! String }
        XCTAssertEqual(Set(names), ["gv_login", "gv_check_login", "gv_list_sms", "gv_search_sms", "gv_read_sms",
                                    "gv_list_voicemail", "gv_send_sms", "gv_reply_sms", "gv_mark_read"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(server.tools))

        func payload(_ r: [String: Any]) -> [String: Any] {
            let text = ((r["content"] as! [[String: Any]])[0]["text"] as! String)
            return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        }
        let list = await server.call("gv_list_sms", ["limit": 1])
        XCTAssertNil(list["isError"])
        XCTAssertEqual(payload(list)["count"] as? Int, 1)
        let bad = await server.call("gv_read_sms", [:])
        XCTAssertEqual(bad["isError"] as? Bool, true)
        XCTAssertEqual((payload(bad)["error"] as? [String: Any])?["code"] as? String, "INVALID_ARGUMENT")
        let unknown = await server.call("gv_nope", [:])
        XCTAssertEqual(unknown["isError"] as? Bool, true)

        store.delete()
        let status = await server.call("gv_check_login", [:])
        XCTAssertNil(status["isError"])
        XCTAssertEqual(payload(status)["signedIn"] as? Bool, false)
        let signedOut = await server.call("gv_list_sms", [:])
        XCTAssertEqual((payload(signedOut)["error"] as? [String: Any])?["code"] as? String, "SIGNED_OUT")
    }

    func testPrettyOutputUsesTwelveHourTime() async throws {
        let s = Service(store: store, transport: google())
        let out = try await s.read(Validator.check(["id": "t.\(Fixture.jane)"], Commands.named("read")!))
        let text = Pretty(color: false, width: 80).render("read", out)
        XCTAssertTrue(text.contains("Jane Doe"))
        XCTAssertTrue(text.range(of: #"\d{1,2}:\d{2} (AM|PM)"#, options: .regularExpression) != nil)
        XCTAssertNil(text.range(of: #"\b(1[3-9]|2[0-3]):\d{2}\b"#, options: .regularExpression))
        let list = try await s.list(Validator.check([:], Commands.named("list")!))
        XCTAssertTrue(Pretty(color: false, width: 80).render("list", list).contains("2 conversations"))
    }
}
