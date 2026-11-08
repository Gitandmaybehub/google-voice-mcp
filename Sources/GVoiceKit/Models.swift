import Foundation

public enum Folder: String, CaseIterable {
    case inbox, all, calls, voicemail, spam, archived

    /// Voice's own folder numbers. "inbox" is the Messages tab (text threads).
    public var code: Int {
        switch self {
        case .all: return 1
        case .inbox: return 2
        case .calls: return 3
        case .voicemail: return 4
        case .spam: return 5
        case .archived: return 6
        }
    }
}

public struct Attachment {
    public var id: String
    public var mimeType: String

    public var json: [String: Any] { ["id": id, "mimeType": mimeType] }
}

public struct Message {
    public enum Kind: String {
        case smsIn = "sms_in", smsOut = "sms_out", voicemail, missedCall = "missed_call"
        case incomingCall = "incoming_call", outgoingCall = "outgoing_call", cancelledCall = "cancelled_call", other
    }

    public var id: String
    public var timestamp: Int64
    public var kind: Kind
    public var text: String
    public var sender: String?
    public var statusRead: Bool?
    public var durationSeconds: Double?
    public var attachments: [Attachment]

    public var isInbound: Bool {
        switch kind {
        case .smsIn, .voicemail, .missedCall, .incomingCall: return true
        default: return false
        }
    }

    public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }

    /// A one-line description, also used for calls and pictures that carry no text.
    public var summary: String {
        if !text.isEmpty { return text }
        switch kind {
        case .missedCall: return "Missed call"
        case .incomingCall: return "Incoming call"
        case .outgoingCall: return "Outgoing call"
        case .cancelledCall: return "Cancelled call"
        case .voicemail: return "Voicemail (no transcript)"
        default: return attachments.isEmpty ? "" : "Picture"
        }
    }

    public init(id: String, timestamp: Int64, kind: Kind, text: String, sender: String?, statusRead: Bool? = nil,
                durationSeconds: Double? = nil, attachments: [Attachment] = []) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.sender = sender
        self.statusRead = statusRead
        self.durationSeconds = durationSeconds
        self.attachments = attachments
    }

    public init?(pb m: Any) {
        guard let id = PB.str(m, 1) else { return nil }
        self.id = id
        timestamp = PB.int(m, 2) ?? 0
        switch PB.int(m, 5) ?? -1 {
        case 0: kind = .missedCall
        case 1: kind = .incomingCall
        case 2: kind = .voicemail
        case 7: kind = .outgoingCall
        case 10: kind = .smsIn
        case 11: kind = .smsOut
        case 14: kind = .cancelledCall
        default: kind = .other
        }
        let mms = PB.at(m, 15)
        var body = PB.str(m, 10) ?? ""
        if body.isEmpty, let mmsText = PB.str(mms, 1) { body = mmsText }
        if body.isEmpty, kind == .voicemail { body = Message.transcript(PB.at(m, 7)) }
        text = body
        sender = PB.str(mms, 5).flatMap { $0.isEmpty ? nil : $0 } ?? PB.str(PB.at(m, 4), 2)
        statusRead = PB.at(m, 6) == nil ? nil : PB.int(m, 6) == 1
        durationSeconds = PB.double(m, 9)
        attachments = PB.list(mms, 3).compactMap { a in
            guard let aid = PB.str(a, 2) else { return nil }
            return Attachment(id: aid, mimeType: PB.str(a, 1) ?? "application/octet-stream")
        }
    }

    /// Voicemail transcripts arrive as word tokens; token text is protobuf bytes (base64 in pblite).
    static func transcript(_ t: Any?) -> String {
        PB.list(t, 2).compactMap { token -> String? in
            guard let raw = PB.str(token, 1) else { return nil }
            if let data = Data(base64Encoded: raw), let s = String(data: data, encoding: .utf8) { return s }
            return raw
        }.joined(separator: " ")
    }
}

public struct Contact {
    public var name: String?
    public var phone: String
}

public struct VoiceThread {
    public var id: String
    public var read: Bool
    public var messages: [Message]   // newest first, as Google sends them
    public var nextPage: String?
    public var contacts: [Contact]
    public var folders: [Int]
    public var phoneNumbers: [String]

    public init(id: String, read: Bool, messages: [Message], nextPage: String? = nil, contacts: [Contact] = [],
                folders: [Int] = [], phoneNumbers: [String] = []) {
        self.id = id
        self.read = read
        self.messages = messages
        self.nextPage = nextPage
        self.contacts = contacts
        self.folders = folders
        self.phoneNumbers = phoneNumbers
    }

    public init?(pb t: Any) {
        guard let id = PB.str(t, 1) else { return nil }
        self.id = id
        read = PB.bool(t, 2)
        messages = PB.list(t, 3).compactMap(Message.init(pb:))
        nextPage = PB.str(t, 4).flatMap { $0.isEmpty ? nil : $0 }
        contacts = PB.list(t, 5).compactMap { c in
            guard let phone = PB.str(c, 2) else { return nil }
            let name = PB.str(c, 1)
            return Contact(name: name == phone || name?.isEmpty == true ? nil : name, phone: phone)
        }
        folders = PB.ints(t, 6)
        phoneNumbers = PB.strings(t, 9)
    }

    public var kind: String {
        if id.hasPrefix("c.") {
            return messages.first?.kind == .voicemail ? "voicemail" : "call"
        }
        return participants.count > 1 ? "group" : "text"
    }

    public var participants: [String] {
        if !phoneNumbers.isEmpty { return phoneNumbers }
        if !contacts.isEmpty { return contacts.map(\.phone) }
        if let p = Phone.fromThreadID(id) { return [p] }
        return messages.compactMap { $0.isInbound ? $0.sender : nil }.uniqued()
    }
}

/// Turns parsed threads into the JSON shapes agents receive. Field names match the earlier
/// browser-based gvoice tool (conversationId, contact, lastMessage, isUnread, ...) and add more detail.
public struct Render {
    public var names: [String: String]
    public var me: String?

    public init(names: [String: String] = [:], me: String? = nil) {
        self.names = names
        self.me = me
    }

    public static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    public func label(_ phone: String) -> String {
        names[phone] ?? Phone.pretty(phone)
    }

    public func conversation(_ t: VoiceThread, folder: String? = nil) -> [String: Any] {
        let people = t.participants
        let last = t.messages.first
        var out: [String: Any] = [
            "conversationId": t.id,
            "contact": people.map(label).joined(separator: ", "),
            "participants": people,
            "kind": t.kind,
            "isUnread": !t.read,
            "lastMessage": last?.summary ?? "",
            "lastTimestamp": last.map { Render.iso.string(from: $0.date) } ?? "",
        ]
        if let phone = people.first { out["phone"] = phone }
        let named = people.compactMap { names[$0] }
        if !named.isEmpty { out["name"] = named.joined(separator: ", ") }
        if let last { out["lastDirection"] = last.isInbound ? "in" : "out" }
        if let folder { out["folder"] = folder }
        return out
    }

    public func message(_ m: Message, in t: VoiceThread) -> [String: Any] {
        let sender = m.isInbound ? (m.sender ?? t.participants.first ?? "") : "me"
        var out: [String: Any] = [
            "conversationId": t.id,
            "messageId": m.id,
            "kind": m.kind.rawValue,
            "sender": sender,
            "text": m.summary,
            "timestamp": Render.iso.string(from: m.date),
            "isInbound": m.isInbound,
            "isUnread": !t.read && m.isInbound && m.statusRead != true,
            "hasPicture": !m.attachments.isEmpty,
        ]
        if m.isInbound, let name = names[sender] { out["senderName"] = name }
        if !m.attachments.isEmpty { out["attachments"] = m.attachments.map(\.json) }
        if let d = m.durationSeconds, d > 0 { out["durationSeconds"] = d }
        return out
    }

    public func voicemail(_ m: Message, in t: VoiceThread) -> [String: Any] {
        let phone = m.sender ?? t.participants.first ?? ""
        var out: [String: Any] = [
            "conversationId": t.id,
            "messageId": m.id,
            "phone": phone,
            "name": names[phone] ?? Phone.pretty(phone),
            "date": Render.iso.string(from: m.date),
            "transcript": m.text,
            "isUnread": !t.read,
        ]
        if let d = m.durationSeconds, d > 0 { out["durationSeconds"] = d }
        return out
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
