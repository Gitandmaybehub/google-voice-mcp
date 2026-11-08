import Foundation

public enum Phone {
    /// Normalizes a typed number to E.164 ("+12125550142"). US numbers may be written any common way.
    /// Short codes (3 to 6 digits) come back as plain digits, which is how Voice names their threads.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("t.") { return normalize(String(trimmed.dropFirst(2))) }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty, trimmed.allSatisfy({ $0.isNumber || " +-().".contains($0) }) else { return nil }
        if trimmed.hasPrefix("+") {
            return (8...15).contains(digits.count) ? "+" + digits : nil
        }
        switch digits.count {
        case 3...6: return digits
        case 10: return digits.first == "0" || digits.first == "1" ? nil : "+1" + digits
        case 11 where digits.hasPrefix("1"): return "+" + digits
        default: return nil
        }
    }

    /// The Voice thread id for a one-to-one text conversation.
    public static func threadID(_ e164: String) -> String { "t." + e164 }

    /// The phone number behind a one-to-one thread id, if it is one.
    public static func fromThreadID(_ id: String) -> String? {
        guard id.hasPrefix("t.") else { return nil }
        return normalize(String(id.dropFirst(2)))
    }

    /// "(212) 555-0142" for US numbers, the number unchanged otherwise.
    public static func pretty(_ number: String) -> String {
        guard number.hasPrefix("+1"), number.count == 12 else { return number }
        let d = Array(number.dropFirst(2))
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }

    /// Ten-digit US form used by the send door ("2125550142").
    public static func tenDigits(_ e164: String) -> String {
        let digits = e164.filter(\.isNumber)
        return digits.count == 11 && digits.hasPrefix("1") ? String(digits.dropFirst()) : digits
    }
}
