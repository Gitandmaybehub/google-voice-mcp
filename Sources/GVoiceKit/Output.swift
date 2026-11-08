import Foundation

public enum Output {
    public static func json(_ value: Any) -> String {
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: opts) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The stable shape agents parse: {"ok":true,"data":...} or {"ok":false,"error":{code,message,hint}}.
    public static func success(_ data: Any) -> String { json(["ok": true, "data": data]) }
    public static func failure(_ error: GVError) -> String { json(["ok": false, "error": error.json]) }
}

/// Friendly terminal output for people. Agents get JSON instead (any time output is not a terminal).
public struct Pretty {
    public var color: Bool
    public var width: Int

    public init(color: Bool, width: Int) {
        self.color = color
        self.width = max(50, min(width, 140))
    }

    public func paint(_ s: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    public func dim(_ s: String) -> String { paint(s, "2") }
    public func bold(_ s: String) -> String { paint(s, "1") }
    public func blue(_ s: String) -> String { paint(s, "38;5;74") }
    public func green(_ s: String) -> String { paint(s, "32") }
    public func red(_ s: String) -> String { paint(s, "31") }
    public func yellow(_ s: String) -> String { paint(s, "33") }

    static func date(_ iso: Any?) -> Date? {
        guard let s = iso as? String, !s.isEmpty else { return nil }
        return Render.iso.date(from: s)
    }

    /// Fixed patterns with plain spaces: 12-hour time everywhere, whatever the Mac's region settings.
    static func format(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f
    }

    static let clock = format("h:mm a")
    static let weekday = format("EEE")
    static let monthDay = format("MMM d")
    static let full = format("EEE, MMM d, h:mm a")
    static let fullYear = format("MMM d, yyyy, h:mm a")
    static let dayName = format("EEEE, MMMM d")
    static let dayNameYear = format("EEEE, MMMM d, yyyy")
    static let monthDayYear = format("MMM d, yyyy")

    /// "2:32 PM" today, "Tue" this week, "Oct 3" this year, "Oct 3, 2025" before. Always 12-hour time.
    static func short(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return clock.string(from: d) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day,
           days < 7, days > 0 { return weekday.string(from: d) }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) { return monthDay.string(from: d) }
        return monthDayYear.string(from: d)
    }

    static func long(_ d: Date?) -> String {
        guard let d else { return "" }
        if Calendar.current.isDateInToday(d) { return "Today " + clock.string(from: d) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday " + clock.string(from: d) }
        if Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date()) {
            return full.string(from: d)
        }
        return fullYear.string(from: d)
    }

    static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return cal.component(.year, from: d) == cal.component(.year, from: Date())
            ? dayName.string(from: d) : dayNameYear.string(from: d)
    }

    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    public static func clip(_ s: String, _ n: Int) -> String {
        guard n > 1 else { return "" }
        return s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    public static func pad(_ s: String, _ n: Int) -> String {
        let c = clip(s, n)
        return c + String(repeating: " ", count: max(0, n - c.count))
    }

    func wrap(_ text: String, indent: Int) -> [String] {
        let room = max(20, width - indent)
        var lines: [String] = []
        for para in text.components(separatedBy: "\n") {
            var line = ""
            for word in para.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                if line.isEmpty {
                    line = word
                } else if line.count + 1 + word.count <= room {
                    line += " " + word
                } else {
                    lines.append(line)
                    line = word
                }
                while line.count > room {
                    lines.append(String(line.prefix(room)))
                    line = String(line.dropFirst(room))
                }
            }
            lines.append(line)
        }
        return lines
    }

    // MARK: - Commands

    public func render(_ command: String, _ data: Any) -> String {
        guard let d = data as? [String: Any] else { return Output.json(data) }
        switch command {
        case "status", "login": return status(d)
        case "logout": return green("✓") + " Signed out. Run " + bold("gvoice login") + " to sign in again."
        case "list", "search": return conversations(d, search: command == "search")
        case "read": return thread(d)
        case "voicemail": return voicemails(d)
        case "send", "reply": return sent(d)
        case "shot":
            return green("✓") + " Saved a picture of \(d["conversationId"] ?? "") to " + bold("\(d["path"] ?? "")")
        case "mark-read":
            let unread = d["isUnread"] as? Bool ?? false
            return green("✓") + " Marked " + (unread ? "unread" : "read") + ": " + "\(d["conversationId"] ?? "")"
        default: return Output.json(d)
        }
    }

    func status(_ d: [String: Any]) -> String {
        var out = green("✓") + " Signed in to Google Voice\n"
        if let a = d["account"] as? String { out += "  " + dim("Account ") + a + "\n" }
        if let n = d["number"] as? String { out += "  " + dim("Number  ") + Phone.pretty(n) + "\n" }
        if let at = Pretty.date(d["signedInAt"]) { out += "  " + dim("Since   ") + Pretty.long(at) + "\n" }
        return out.trimmingCharacters(in: .newlines)
    }

    func conversations(_ d: [String: Any], search: Bool) -> String {
        let rows = d["conversations"] as? [[String: Any]] ?? []
        if rows.isEmpty {
            return dim(search ? "No conversations match \"\(d["query"] ?? "")\"." : "No conversations here.")
        }
        let nameW = min(24, max(12, rows.map { ($0["contact"] as? String ?? "").count }.max() ?? 12))
        let timeW = 9
        let msgW = max(10, width - nameW - timeW - 6)
        var lines: [String] = []
        for r in rows {
            let unread = r["isUnread"] as? Bool ?? false
            let dot = unread ? yellow("●") : " "
            let name = Pretty.pad(r["contact"] as? String ?? "", nameW)
            var text = Pretty.oneLine((search ? r["match"] as? String : nil) ?? r["lastMessage"] as? String ?? "")
            if !search, r["lastDirection"] as? String == "out" { text = "You: " + text }
            let when = Pretty.short(Pretty.date(search ? r["matchTimestamp"] ?? r["lastTimestamp"] : r["lastTimestamp"]))
            let nameText = unread ? bold(name) : blue(name)
            lines.append("\(dot) \(nameText)  \(dim(Pretty.pad(when, timeW)))  \(Pretty.clip(text, msgW))")
        }
        var footer = "\(rows.count) conversation\(rows.count == 1 ? "" : "s")"
        if let scanned = d["scanned"] as? Int { footer += " · checked the newest \(scanned)" }
        if d["nextPage"] != nil { footer += " · more with --page \(d["nextPage"]!)" }
        if let s = d["searched"] as? String { footer += " · searched \(s)" }
        lines.append(dim(footer))
        return lines.joined(separator: "\n")
    }

    func thread(_ d: [String: Any]) -> String {
        var lines: [String] = []
        let title = d["contact"] as? String ?? ""
        let phone = d["phone"] as? String
        var header = bold(title)
        if let phone, title != Phone.pretty(phone) { header += "  " + dim(Phone.pretty(phone)) }
        lines.append(header)
        if let note = d["note"] as? String { lines.append(dim(note)) }
        var lastDay: String?
        for m in d["messages"] as? [[String: Any]] ?? [] {
            let date = Pretty.date(m["timestamp"])
            let day = date.map(Pretty.dayLabel) ?? ""
            if day != lastDay {
                lines.append("")
                lines.append(dim("── \(day) ──"))
                lastDay = day
            }
            let inbound = m["isInbound"] as? Bool ?? false
            let who = inbound ? blue(m["senderName"] as? String ?? Phone.pretty(m["sender"] as? String ?? "")) : green("You")
            let time = date.map { Pretty.clock.string(from: $0) } ?? ""
            lines.append("\(who) \(dim(time))")
            var text = m["text"] as? String ?? ""
            if m["hasPicture"] as? Bool == true && text.isEmpty { text = "[picture]" }
            for l in wrap(text, indent: 2) { lines.append("  " + l) }
        }
        if (d["messages"] as? [Any])?.isEmpty ?? true, d["note"] == nil { lines.append(dim("No messages.")) }
        if d["hasMore"] as? Bool == true { lines.append(""); lines.append(dim("Older messages: raise --limit.")) }
        return lines.joined(separator: "\n")
    }

    func voicemails(_ d: [String: Any]) -> String {
        let rows = d["voicemails"] as? [[String: Any]] ?? []
        if rows.isEmpty { return dim("No voicemails.") }
        var lines: [String] = []
        for (i, v) in rows.enumerated() {
            if i > 0 { lines.append("") }
            var head = blue(v["name"] as? String ?? "")
            if let p = v["phone"] as? String, v["name"] as? String != Phone.pretty(p) { head += "  " + dim(Phone.pretty(p)) }
            head += "  " + dim(Pretty.long(Pretty.date(v["date"])))
            if let s = v["durationSeconds"] as? Double { head += dim(" · \(Int(s.rounded()))s") }
            if v["isUnread"] as? Bool == true { head = yellow("● ") + head }
            lines.append(head)
            let t = v["transcript"] as? String ?? ""
            for l in wrap(t.isEmpty ? "(no transcript)" : t, indent: 2) { lines.append("  " + l) }
        }
        return lines.joined(separator: "\n")
    }

    func sent(_ d: [String: Any]) -> String {
        if let results = d["results"] as? [[String: Any]] {
            return results.map { r in
                let ok = r["decision"] as? String == "sent"
                let who = Phone.pretty(r["to"] as? String ?? "")
                let reason = r["reason"] as? String ?? ""
                return ok ? green("✓") + " Sent to \(who) through the send door"
                          : red("✗") + " Not sent to \(who). The send door blocked it" + (reason.isEmpty ? "." : ": \(reason).")
            }.joined(separator: "\n")
        }
        let to = (d["to"] as? [String] ?? []).map(Phone.pretty).joined(separator: ", ")
        if d["duplicate"] as? Bool == true { return yellow("•") + " Already sent to \(to) with this key, so not sent again." }
        let when = Pretty.date(d["timestamp"]).map { " at " + Pretty.clock.string(from: $0) } ?? ""
        return green("✓") + " Sent to \(to)\(when)"
    }

    public func error(_ e: GVError) -> String {
        var out = red("✗") + " " + e.message
        if let hint = e.hint { out += "\n  " + dim(hint) }
        return out
    }
}
