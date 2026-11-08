import Foundation

/// Google's "pblite" wire format: a protobuf message written as a JSON array where
/// field number N sits at index N-1. Very high field numbers can spill into a trailing
/// object keyed by the field number. Defaults are often left out or written as null.
public enum PB {
    public static func at(_ value: Any?, _ field: Int) -> Any? {
        guard let arr = value as? [Any], field >= 1 else { return nil }
        if let tail = arr.last as? [String: Any], let v = tail[String(field)] {
            return v is NSNull ? nil : v
        }
        guard field <= arr.count else { return nil }
        let v = arr[field - 1]
        return v is NSNull ? nil : v
    }

    public static func str(_ value: Any?, _ field: Int) -> String? {
        switch at(value, field) {
        case let s as String: return s
        case let n as NSNumber where !isBool(n): return n.stringValue
        default: return nil
        }
    }

    public static func int(_ value: Any?, _ field: Int) -> Int64? {
        switch at(value, field) {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    public static func double(_ value: Any?, _ field: Int) -> Double? {
        switch at(value, field) {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    public static func bool(_ value: Any?, _ field: Int) -> Bool {
        switch at(value, field) {
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "1" || s == "true"
        default: return false
        }
    }

    public static func list(_ value: Any?, _ field: Int) -> [Any] {
        at(value, field) as? [Any] ?? []
    }

    public static func strings(_ value: Any?, _ field: Int) -> [String] {
        list(value, field).compactMap { $0 as? String }
    }

    public static func ints(_ value: Any?, _ field: Int) -> [Int] {
        list(value, field).compactMap { ($0 as? NSNumber)?.intValue }
    }

    static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Parses a pblite response body, dropping the anti-JSON-hijacking prefix if present.
    public static func parse(_ data: Data) throws -> Any {
        var body = data
        let prefix = Data(")]}'".utf8)
        if body.starts(with: prefix) {
            body = body.dropFirst(prefix.count)
            while let first = body.first, first == 0x0A || first == 0x0D || first == 0x20 { body = body.dropFirst() }
        }
        if body.isEmpty { return [Any]() }
        return try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    }

    /// Encodes a request message. `nil` becomes JSON null at any depth.
    public static func encode(_ message: [Any?]) -> Data {
        let body = clean(message)
        precondition(JSONSerialization.isValidJSONObject(body), "pblite request is not JSON: \(message)")
        return (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
    }

    /// Unwraps optionals (Swift nests them inside arrays) so JSONSerialization accepts the value.
    static func clean(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first else { return NSNull() }
            return clean(inner.value)
        }
        if let list = value as? [Any?] { return list.map { clean($0) } }
        return value
    }
}
