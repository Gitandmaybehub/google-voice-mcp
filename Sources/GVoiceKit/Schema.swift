import Foundation

public enum ParamType {
    case string, integer, boolean, strings
}

public struct Param {
    public let name: String            // JSON field and --flag (underscores become dashes on the command line)
    public var mcpName: String?        // field name in MCP tools when it differs (kept from the earlier hub tools)
    public let type: ParamType
    public let help: String
    public var required = false
    public var choices: [String]?
    public var range: ClosedRange<Int>?
    public var defaultValue: Any?
    public var positional = false

    public var flag: String { "--" + name.replacingOccurrences(of: "_", with: "-") }
    func key(mcp: Bool) -> String { mcp ? (mcpName ?? name) : name }
}

public struct CommandSpec {
    public let name: String
    public let mcpName: String?
    public let summary: String
    public let params: [Param]
    public let example: String

    public func param(_ name: String) -> Param? { params.first { $0.name == name } }
}

public enum Commands {
    static let folder = Param(name: "folder", type: .string,
                              help: "Which folder: inbox, archived, spam, calls, or voicemail.",
                              choices: ["inbox", "archived", "spam", "calls", "voicemail"], defaultValue: "inbox")
    static let threadID = Param(name: "id", mcpName: "conversation_id", type: .string,
                                help: "Conversation id from list (like t.+12125550142) or a phone number.",
                                required: true, positional: true)
    static func limit(_ fallback: Int, _ help: String) -> Param {
        Param(name: "limit", type: .integer, help: help, range: 1...500, defaultValue: fallback)
    }
    static let key = Param(name: "key", type: .string,
                           help: "A label unique to this one message. Reusing it on a retry never sends twice.")

    public static let all: [CommandSpec] = [
        CommandSpec(name: "login", mcpName: "gv_login",
                    summary: "Open a Google sign-in window on this Mac and save the sign-in for gvoice.",
                    params: [], example: "gvoice login"),
        CommandSpec(name: "logout", mcpName: nil, summary: "Forget the saved Google sign-in.",
                    params: [], example: "gvoice logout"),
        CommandSpec(name: "status", mcpName: "gv_check_login",
                    summary: "Check the sign-in and show the Google account and Voice number.",
                    params: [], example: "gvoice status"),
        CommandSpec(name: "list", mcpName: "gv_list_sms",
                    summary: "List text conversations, newest first, with names from Google Contacts.",
                    params: [
                        folder,
                        Param(name: "filter", type: .string, help: "all, or unread to show only unread conversations.",
                              choices: ["all", "unread"], defaultValue: "all"),
                        limit(50, "Most conversations to return (1 to 500)."),
                        Param(name: "page", type: .string, help: "nextPage value from an earlier list, to keep going."),
                    ], example: "gvoice list --filter unread --limit 20"),
        CommandSpec(name: "search", mcpName: "gv_search_sms",
                    summary: "Find conversations by name, phone number, or words in their recent messages.",
                    params: [
                        Param(name: "query", type: .string, help: "A name, number, or words to look for.",
                              required: true, positional: true),
                        folder,
                        limit(20, "Most conversations to return (1 to 500)."),
                    ], example: "gvoice search \"ceramic coating\""),
        CommandSpec(name: "read", mcpName: "gv_read_sms",
                    summary: "Read one conversation, oldest to newest. Reading never marks it read.",
                    params: [
                        threadID,
                        limit(50, "Most recent messages to return (1 to 500)."),
                        Param(name: "filter", type: .string,
                              help: "all, or unread to return messages only if the conversation is unread.",
                              choices: ["all", "unread"], defaultValue: "all"),
                        Param(name: "skip_unconfirmed_read", type: .boolean,
                              help: "Skip the conversation if it is unread (for inbox sweeps).",
                              defaultValue: false),
                    ], example: "gvoice read +12125550142 --limit 20"),
        CommandSpec(name: "voicemail", mcpName: "gv_list_voicemail",
                    summary: "List voicemails with who called, when, and the transcript.",
                    params: [limit(20, "Most voicemails to return (1 to 500).")],
                    example: "gvoice voicemail --limit 5"),
        CommandSpec(name: "send", mcpName: "gv_send_sms",
                    summary: "Text one or more phone numbers. Goes through the send door.",
                    params: [
                        Param(name: "to", mcpName: "phone_number", type: .strings,
                              help: "Phone number, or a list of numbers. US numbers can be written any common way.",
                              required: true),
                        Param(name: "text", type: .string, help: "The message to send.", required: true),
                        key,
                    ], example: "gvoice send --to \"(212) 555-0142\" --text \"On my way!\" --key eta-1"),
        CommandSpec(name: "reply", mcpName: "gv_reply_sms",
                    summary: "Reply in an existing conversation. Goes through the send door.",
                    params: [
                        Param(name: "id", mcpName: "conversation_id", type: .string,
                              help: "Conversation id from list or read.", required: true),
                        Param(name: "text", type: .string, help: "The reply to send.", required: true),
                        key,
                    ], example: "gvoice reply --id t.+12125550142 --text \"Sounds good!\" --key reply-1"),
        CommandSpec(name: "mark-read", mcpName: "gv_mark_read",
                    summary: "Mark a conversation read, or unread with --unread.",
                    params: [
                        threadID,
                        Param(name: "unread", type: .boolean, help: "Mark it unread instead.", defaultValue: false),
                    ], example: "gvoice mark-read t.+12125550142"),
        CommandSpec(name: "shot", mcpName: nil,
                    summary: "Save a real picture of one conversation as voice.google.com shows it. Unread stays unread.",
                    params: [
                        threadID,
                        Param(name: "out", type: .string, help: "Where to save the PNG picture.", required: true),
                    ], example: "gvoice shot t.+12125550142 --out thread.png"),
        CommandSpec(name: "schema", mcpName: nil, summary: "Show the input fields every command accepts.",
                    params: [Param(name: "command", type: .string, help: "One command to show.", positional: true)],
                    example: "gvoice schema send"),
        CommandSpec(name: "mcp", mcpName: nil,
                    summary: "Run as an MCP server (the standard way AI agents call tools) over stdin and stdout.",
                    params: [], example: "gvoice mcp"),
    ]

    public static func named(_ name: String) -> CommandSpec? { all.first { $0.name == name } }
    public static func tool(_ mcpName: String) -> CommandSpec? { all.first { $0.mcpName == mcpName } }
}

/// Checked, defaulted arguments for one command.
public struct Args {
    public var values: [String: Any]

    public init(_ values: [String: Any] = [:]) { self.values = values }

    public func string(_ key: String) -> String? { values[key] as? String }
    public func int(_ key: String) -> Int { values[key] as? Int ?? 0 }
    public func bool(_ key: String) -> Bool { values[key] as? Bool ?? false }
    public func strings(_ key: String) -> [String] { values[key] as? [String] ?? [] }
}

public enum Validator {
    /// Checks fields against the command's schema: no unknown fields, right types, allowed values, required present.
    public static func check(_ raw: [String: Any], _ spec: CommandSpec, mcp: Bool = false) throws -> Args {
        let params = spec.params
        let byKey = Dictionary(uniqueKeysWithValues: params.map { ($0.key(mcp: mcp), $0) })
        var out: [String: Any] = [:]
        for (key, value) in raw {
            guard let p = byKey[key] else {
                let allowed = params.map { $0.key(mcp: mcp) }
                throw GVError.invalid("`\(spec.name)` has no field '\(key)'."
                    + (allowed.isEmpty ? " It takes no fields." : " Fields: \(allowed.joined(separator: ", ")).")
                    + (mcp ? "" : " See `gvoice schema \(spec.name)`."))
            }
            if value is NSNull { continue }
            out[p.name] = try coerce(value, p, field: key)
        }
        for p in params {
            if out[p.name] == nil, let d = p.defaultValue { out[p.name] = d }
            if p.required && out[p.name] == nil {
                throw GVError.invalid("`\(spec.name)` needs '\(p.key(mcp: mcp))': \(p.help)")
            }
        }
        return Args(out)
    }

    static func coerce(_ value: Any, _ p: Param, field: String) throws -> Any {
        switch p.type {
        case .string:
            guard let s = value as? String else { throw GVError.invalid("'\(field)' must be text.") }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.required && trimmed.isEmpty { throw GVError.invalid("'\(field)' cannot be empty.") }
            if let choices = p.choices, !choices.contains(trimmed) {
                throw GVError.invalid("'\(field)' must be one of: \(choices.joined(separator: ", ")).")
            }
            return p.choices == nil ? s : trimmed
        case .integer:
            var n: Int?
            if let num = value as? NSNumber, !PB.isBool(num), num.doubleValue.rounded() == num.doubleValue {
                n = num.intValue
            } else if let s = value as? String {
                n = Int(s.trimmingCharacters(in: .whitespaces))
            }
            guard let n else { throw GVError.invalid("'\(field)' must be a whole number.") }
            if let r = p.range, !r.contains(n) {
                throw GVError.invalid("'\(field)' must be from \(r.lowerBound) to \(r.upperBound).")
            }
            return n
        case .boolean:
            if let num = value as? NSNumber, PB.isBool(num) { return num.boolValue }
            if let s = value as? String, ["true", "false"].contains(s.lowercased()) { return s.lowercased() == "true" }
            throw GVError.invalid("'\(field)' must be true or false.")
        case .strings:
            let list: [String]
            if let s = value as? String {
                list = s.split(separator: ",").map(String.init)
            } else if let arr = value as? [Any], arr.allSatisfy({ $0 is String }) {
                list = arr.compactMap { $0 as? String }
            } else {
                throw GVError.invalid("'\(field)' must be text or a list of text.")
            }
            let clean = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if p.required && clean.isEmpty { throw GVError.invalid("'\(field)' cannot be empty.") }
            return clean
        }
    }

    /// Reads `--flag value` style arguments into raw fields for `check`.
    public static func parseCLI(_ argv: [String], _ spec: CommandSpec) throws -> [String: Any] {
        var raw: [String: Any] = [:]
        var i = 0
        func param(forFlag flag: String) throws -> Param {
            guard let p = spec.params.first(where: { $0.flag == flag }) else {
                let flags = spec.params.map(\.flag)
                throw GVError.invalid("`\(spec.name)` has no option \(flag)."
                    + (flags.isEmpty ? "" : " Options: \(flags.joined(separator: ", ")).")
                    + " See `gvoice help`.")
            }
            return p
        }
        while i < argv.count {
            let token = argv[i]
            i += 1
            if token.hasPrefix("--") && token.count > 2 {
                var flag = token
                var value: String?
                if let eq = token.firstIndex(of: "=") {
                    flag = String(token[..<eq])
                    value = String(token[token.index(after: eq)...])
                }
                let p = try param(forFlag: flag)
                if p.type == .boolean && value == nil {
                    if i < argv.count, ["true", "false"].contains(argv[i].lowercased()) {
                        value = argv[i]
                        i += 1
                    } else {
                        value = "true"
                    }
                }
                if value == nil {
                    guard i < argv.count else { throw GVError.invalid("\(flag) needs a value.") }
                    value = argv[i]
                    i += 1
                }
                if p.type == .strings {
                    raw[p.name] = (raw[p.name] as? [String] ?? []) + value!.split(separator: ",").map(String.init)
                } else {
                    if raw[p.name] != nil { throw GVError.invalid("\(flag) was given twice.") }
                    raw[p.name] = value!
                }
            } else {
                guard let p = spec.params.first(where: \.positional), raw[p.name] == nil else {
                    throw GVError.invalid("Unexpected '\(token)'. See `gvoice help`.")
                }
                raw[p.name] = token
            }
        }
        return raw
    }

    /// JSON Schema for a command, used by `gvoice schema` and the MCP tool list.
    public static func jsonSchema(_ spec: CommandSpec, mcp: Bool = false) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in spec.params {
            var s: [String: Any] = ["description": p.help]
            switch p.type {
            case .string: s["type"] = "string"
            case .integer: s["type"] = "integer"
            case .boolean: s["type"] = "boolean"
            case .strings:
                s["type"] = "array"
                s["items"] = ["type": "string"]
            }
            if let c = p.choices { s["enum"] = c }
            if let r = p.range {
                s["minimum"] = r.lowerBound
                s["maximum"] = r.upperBound
            }
            if let d = p.defaultValue { s["default"] = d }
            props[p.key(mcp: mcp)] = s
            if p.required { required.append(p.key(mcp: mcp)) }
        }
        return ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
}
