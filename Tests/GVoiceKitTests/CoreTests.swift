import Foundation
import XCTest
@testable import GVoiceKit

final class PBTests: XCTestCase {
    func testFieldAccess() throws {
        let msg = try PB.parse(Data(")]}'\n[\"id\",1,null,[\"a\",\"b\"],{\"20\":\"far\"}]".utf8))
        XCTAssertEqual(PB.str(msg, 1), "id")
        XCTAssertEqual(PB.int(msg, 2), 1)
        XCTAssertTrue(PB.bool(msg, 2))
        XCTAssertNil(PB.at(msg, 3))
        XCTAssertEqual(PB.strings(msg, 4), ["a", "b"])
        XCTAssertEqual(PB.str(msg, 20), "far")
        XCTAssertNil(PB.str(msg, 99))
        XCTAssertNil(PB.str(true as Any, 1))
    }

    func testEncodeNestedNulls() {
        let body = PB.encode([2, 50, 1, nil, nil, [nil, 1, 1]])
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "[2,50,1,null,null,[null,1,1]]")
        let lookup = PB.encode([243, [1, 2], ["+15551230001"].map { [nil, $0] as [Any?] }])
        XCTAssertEqual(String(decoding: lookup, as: UTF8.self), "[243,[1,2],[[null,\"+15551230001\"]]]")
        let recipients: [String]? = nil
        let send = PB.encode([nil, "hi", recipients, [Int64(42)], ["stamp"]])
        XCTAssertEqual(String(decoding: send, as: UTF8.self), "[null,\"hi\",null,[42],[\"stamp\"]]")
    }
}

final class PhoneTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(Phone.normalize("(212) 555-0142"), "+12125550142")
        XCTAssertEqual(Phone.normalize("212.555.0142"), "+12125550142")
        XCTAssertEqual(Phone.normalize("+1 212 555 0142"), "+12125550142")
        XCTAssertEqual(Phone.normalize("12125550142"), "+12125550142")
        XCTAssertEqual(Phone.normalize("t.+12125550142"), "+12125550142")
        XCTAssertEqual(Phone.normalize("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(Phone.normalize("22395"), "22395")
        XCTAssertNil(Phone.normalize("0622047568"))
        XCTAssertNil(Phone.normalize("call me"))
        XCTAssertNil(Phone.normalize("212555014"))
        XCTAssertNil(Phone.normalize(""))
    }

    func testFormats() {
        XCTAssertEqual(Phone.pretty("+12125550142"), "(212) 555-0142")
        XCTAssertEqual(Phone.pretty("+442079460958"), "+442079460958")
        XCTAssertEqual(Phone.tenDigits("+12125550142"), "2125550142")
        XCTAssertEqual(Phone.threadID("+12125550142"), "t.+12125550142")
        XCTAssertEqual(Phone.fromThreadID("t.+12125550142"), "+12125550142")
        XCTAssertNil(Phone.fromThreadID("c.ABC123"))
    }
}

final class CookieTests: XCTestCase {
    func testMatching() {
        let url = URL(string: "https://clients6.google.com/voice/v1/voiceclient/api2thread/list")!
        XCTAssertTrue(Cookie(name: "SID", value: "1", domain: "google.com").applies(to: url))
        XCTAssertFalse(Cookie(name: "A", value: "1", domain: "google.com", hostOnly: true).applies(to: url))
        XCTAssertFalse(Cookie(name: "B", value: "1", domain: "accounts.google.com").applies(to: url))
        XCTAssertTrue(Cookie(name: "C", value: "1", domain: "google.com", path: "/voice").applies(to: url))
        XCTAssertFalse(Cookie(name: "D", value: "1", domain: "google.com", path: "/voicex").applies(to: url))
        XCTAssertFalse(Cookie(name: "E", value: "1", domain: "google.com", expires: Date(timeIntervalSinceNow: -5)).applies(to: url))
        XCTAssertFalse(Cookie(name: "F", value: "1", domain: "google.com").applies(to: URL(string: "http://google.com/")!))
        XCTAssertFalse(Cookie(name: "G", value: "1", domain: "google.com").applies(to: URL(string: "https://evilgoogle.com/")!))
    }

    func testJarAbsorbAndHeader() {
        var jar = CookieJar([Cookie(name: "SAPISID", value: "old", domain: "google.com"),
                             Cookie(name: "SIDCC", value: "x", domain: "google.com")])
        let url = URL(string: "https://accounts.google.com/RotateCookies")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Set-Cookie": "__Secure-1PSIDTS=new; Domain=.google.com; Path=/; Secure, SIDCC=y; Domain=.google.com; Path=/; Secure",
        ])!
        let changed = jar.absorb(resp)
        XCTAssertEqual(changed.map(\.name), ["__Secure-1PSIDTS"])   // SIDCC changes too, but is not worth saving
        XCTAssertEqual(jar.value("__Secure-1PSIDTS"), "new")
        XCTAssertEqual(jar.value("SIDCC"), "y")
        let header = jar.header(for: URL(string: "https://clients6.google.com/x")!) ?? ""
        XCTAssertTrue(header.contains("SAPISID=old"))
        XCTAssertTrue(header.contains("__Secure-1PSIDTS=new"))
    }

    func testSapisidHash() {
        let h = GoogleAuth.sapisidHash("abc123", origin: "https://voice.google.com", at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(h, "SAPISIDHASH 1700000000_0af60f2c8319974dffd04c264464cd61b24a1ffd")
    }
}

final class WaaPayloadTests: XCTestCase {
    func testHashes() {
        let p = WaaPayload.forMessage(threadID: "", recipients: ["+15551230001", "+15551230002"], transactionID: 42)
        XCTAssertEqual(p["thread_id"], "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
        XCTAssertEqual(p["destinations"], "dO8MMnIVzMNCTpV8gx2USsPRbVP61OfzaLfpXps3a74=")
        XCTAssertEqual(p["message_ids"], "c0dctApWjo2ooEXO0RATfhWfiQrE2og7axfcZRs6gEk=")
        let q = WaaPayload.forMessage(threadID: "t.+15551230001", recipients: ["+15551230001"], transactionID: 42)
        XCTAssertEqual(q["thread_id"], "+/Tqo5hkbTVqTqFmH9qBYie1q91LzmoNi3vTe+R6SCI=")
        XCTAssertEqual(q["destinations"], "s1lRAd59PMisFYukrs3dFXUHpZzxR2sT0M/j32d6Y30=")
    }
}

final class SchemaTests: XCTestCase {
    func spec(_ n: String) -> CommandSpec { Commands.named(n)! }

    func testDefaultsAndCoercion() throws {
        let a = try Validator.check(["limit": "7"], spec("list"))
        XCTAssertEqual(a.int("limit"), 7)
        XCTAssertEqual(a.string("folder"), "inbox")
        XCTAssertEqual(a.string("filter"), "all")
        let b = try Validator.check(["limit": 20.0, "filter": "unread"], spec("list"), mcp: true)
        XCTAssertEqual(b.int("limit"), 20)
        let c = try Validator.check(["phone_number": "+15551230001", "text": "hi"], spec("send"), mcp: true)
        XCTAssertEqual(c.strings("to"), ["+15551230001"])
        let d = try Validator.check(["to": ["+15551230001", "5551230002"], "text": "hi"], spec("send"))
        XCTAssertEqual(d.strings("to").count, 2)
        let e = try Validator.check(["conversation_id": "t.+15551230001"], spec("read"), mcp: true)
        XCTAssertEqual(e.string("id"), "t.+15551230001")
        XCTAssertEqual(e.int("limit"), 50)
    }

    func testRejections() {
        func code(_ raw: [String: Any], _ name: String, mcp: Bool = false) -> String? {
            do { _ = try Validator.check(raw, spec(name), mcp: mcp); return nil } catch { return (error as? GVError)?.code }
        }
        XCTAssertEqual(code(["nope": 1], "list"), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["limit": 0], "list"), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["limit": 501], "list"), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["limit": 2.5], "list"), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["limit": true], "list"), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["folder": "trash"], "list"), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["text": "hi"], "send"), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["to": "+15551230001", "text": "   "], "send"), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["phone_number": "+15551230001", "text": "hi", "direct": true], "send", mcp: true), "INVALID_ARGUMENT")
        XCTAssertEqual(code(["to": "+15551230001", "text": "hi", "direct": true], "send"), "INVALID_ARGUMENT")
        XCTAssertNil(code(["to": "+15551230001", "text": "hi"], "send"))
    }

    func testCommandLine() throws {
        let raw = try Validator.parseCLI(["--to", "5551230001", "--to=5551230002,5551230003", "--text", "hey there",
                                          "--key", "k1"], spec("send"))
        XCTAssertEqual(raw["to"] as? [String], ["5551230001", "5551230002", "5551230003"])
        XCTAssertEqual(try Validator.check(raw, spec("send")).string("key"), "k1")
        XCTAssertThrowsError(try Validator.parseCLI(["--to", "5551230001", "--direct"], spec("send")))
        let read = try Validator.parseCLI(["t.+15551230001", "--limit", "5", "--skip-unconfirmed-read", "false"], spec("read"))
        XCTAssertEqual(read["id"] as? String, "t.+15551230001")
        XCTAssertEqual(read["skip_unconfirmed_read"] as? String, "false")
        XCTAssertThrowsError(try Validator.parseCLI(["--bogus"], spec("list")))
        XCTAssertThrowsError(try Validator.parseCLI(["--limit"], spec("list")))
        XCTAssertThrowsError(try Validator.parseCLI(["a", "b"], spec("read")))
        XCTAssertThrowsError(try Validator.parseCLI(["--text", "a", "--text", "b"], spec("send")))
    }

    func testJSONSchema() {
        let s = Validator.jsonSchema(spec("send"), mcp: true)
        let props = s["properties"] as! [String: Any]
        XCTAssertNotNil(props["phone_number"])
        XCTAssertNil(props["direct"])
        XCTAssertEqual(s["required"] as? [String], ["phone_number", "text"])
        XCTAssertEqual(s["additionalProperties"] as? Bool, false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(s))
    }
}

final class LedgerTests: XCTestCase {
    func testKeyLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = Ledger(store: SessionStore(dir: dir))
        XCTAssertNil(try ledger.begin(key: "k", to: ["+15551230001"], text: "hi"))
        XCTAssertThrowsError(try ledger.begin(key: "k", to: ["+15551230001"], text: "hi")) {
            XCTAssertEqual(($0 as? GVError)?.code, "SEND_UNCERTAIN")
        }
        XCTAssertThrowsError(try ledger.begin(key: "k", to: ["+15551230001"], text: "other")) {
            XCTAssertEqual(($0 as? GVError)?.code, "KEY_CONFLICT")
        }
        ledger.finish(key: "k", status: "sent", receipt: SendReceipt(threadID: "t.+15551230001", messageID: "m9", timestamp: 1_700_000_000_000))
        let again = try ledger.begin(key: "k", to: ["+15551230001"], text: "hi")
        XCTAssertEqual(again?["duplicate"] as? Bool, true)
        XCTAssertEqual(again?["messageId"] as? String, "m9")

        XCTAssertNil(try ledger.begin(key: "f", to: ["+15551230001"], text: "hi"))
        ledger.finish(key: "f", status: "failed")
        XCTAssertNil(try ledger.begin(key: "f", to: ["+15551230001"], text: "hi"))   // a known failure may be retried
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("sends.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
