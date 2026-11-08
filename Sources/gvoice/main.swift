import AppKit
import GVoiceKit

let version = "1.0.0"

enum CLI {
    static var json = isatty(STDOUT_FILENO) == 0
    static var pretty: Pretty {
        var size = winsize()
        let cols = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 100
        let color = ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(STDOUT_FILENO) != 0
        return Pretty(color: color, width: cols)
    }

    static func say(_ text: String, to handle: FileHandle = .standardOutput) {
        handle.write(Data((text + "\n").utf8))
    }

    static func finish(_ command: String, _ data: Any) -> Never {
        if json { say(Output.success(data)) } else { say(pretty.render(command, data)) }
        if ["send", "reply"].contains(command), (data as? [String: Any])?["sent"] as? Bool == false { exit(1) }
        exit(0)
    }

    static func fail(_ error: Error) -> Never {
        let e = error as? GVError ?? GVError("INTERNAL", error.localizedDescription)
        if json { say(Output.failure(e)) } else { say(pretty.error(e), to: .standardError) }
        exit(e.exitCode)
    }

    static func help() -> String {
        let p = pretty
        func row(_ cmd: String, _ text: String) -> String { "  " + p.blue(Pretty.pad(cmd, 35)) + "  " + text }
        return """
        \(p.bold("gvoice \(version)")) \(p.dim("· Google Voice from the command line, no browser needed"))

        \(p.bold("Sign in once"))
        \(row("gvoice login", "Open a Google sign-in window on this Mac"))
        \(row("gvoice status", "Show the account and Voice number"))
        \(row("gvoice logout", "Forget the saved sign-in"))

        \(p.bold("Read"))
        \(row("gvoice list [--filter unread]", "Text conversations, newest first"))
        \(row("gvoice search WORDS", "Find by name, number, or words"))
        \(row("gvoice read ID|NUMBER", "One conversation, oldest to newest"))
        \(row("gvoice voicemail", "Voicemails with transcripts"))
        \(row("gvoice mark-read ID [--unread]", "Mark a conversation read or unread"))
        \(row("gvoice shot ID --out FILE.png", "A real picture of one conversation"))

        \(p.bold("Send")) \(p.dim("(through your send door)"))
        \(row("gvoice send --to NUMBER --text \"…\"", "Text a number. Add --key LABEL"))
        \(row("gvoice reply --id ID --text \"…\"", "Reply in a conversation"))

        \(p.bold("For AI agents"))
        \(row("gvoice mcp", "MCP server: the standard way agents call tools"))
        \(row("gvoice schema [COMMAND]", "Every command's input fields"))
          \(p.dim("Output is JSON whenever it is piped. Add --json to read fields from stdin."))

        \(p.dim("More: gvoice help COMMAND"))
        """
    }

    static func help(for spec: CommandSpec) -> String {
        let p = pretty
        var lines = [p.bold("gvoice \(spec.name)") + "  " + spec.summary, ""]
        if !spec.params.isEmpty {
            lines.append(p.bold("Options"))
            for param in spec.params {
                var name = param.positional ? "[\(param.name.uppercased())] or \(param.flag)" : param.flag
                if param.type != .boolean { name += param.type == .integer ? " N" : " TEXT" }
                var text = param.help
                if let d = param.defaultValue, param.type != .boolean { text += p.dim(" Default: \(d).") }
                if param.required { text += p.dim(" Required.") }
                lines.append("  " + p.blue(Pretty.pad(name, 30)) + " " + text)
            }
            lines.append("")
        }
        lines.append(p.bold("Example"))
        lines.append("  " + spec.example)
        return lines.joined(separator: "\n")
    }

    @MainActor static func start() {
        var argv = Array(CommandLine.arguments.dropFirst())
        var readStdin = false
        var i = 0
        while i < argv.count {   // global options may appear anywhere
            let a = argv[i]
            if a == "--json" {
                readStdin = true
                argv.remove(at: i)
            } else if a == "--output" || a.hasPrefix("--output=") {
                var value = String(a.dropFirst("--output=".count))
                if a == "--output" {
                    value = i + 1 < argv.count ? argv[i + 1] : ""
                    if i + 1 < argv.count { argv.remove(at: i + 1) }
                }
                argv.remove(at: i)
                guard ["json", "pretty"].contains(value) else { fail(GVError.invalid("--output must be json or pretty.")) }
                json = value == "json"
            } else {
                i += 1
            }
        }
        guard let command = argv.first else { say(help()); exit(0) }
        var rest = Array(argv.dropFirst())
        switch command {
        case "help", "--help", "-h":
            if let name = rest.first, let spec = Commands.named(name) { say(help(for: spec)) } else { say(help()) }
            exit(0)
        case "version", "--version", "-v":
            say(json ? Output.success(["version": version]) : "gvoice \(version)")
            exit(0)
        default:
            break
        }
        guard let spec = Commands.named(command) else {
            fail(GVError.invalid("Unknown command '\(command)'. Run `gvoice help` to see them all."))
        }
        if rest.contains("--help") || rest.contains("-h") { say(help(for: spec)); exit(0) }

        // --direct skips the send door. It is for the door alone, so it stays out of help, schema, JSON input,
        // and the MCP tools, and the ~/.local/bin/gvoice wrapper on PATH refuses it.
        let direct = ["send", "reply"].contains(spec.name) && rest.contains("--direct")
        rest.removeAll { direct && $0 == "--direct" }

        let args: Args
        do {
            var raw: [String: Any] = [:]
            if readStdin {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                if !data.isEmpty {
                    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw GVError.invalid("--json expects one JSON object on stdin.")
                    }
                    raw = obj
                }
            }
            raw.merge(try Validator.parseCLI(rest, spec)) { _, flag in flag }
            args = try Validator.check(raw, spec)
        } catch {
            fail(error)
        }

        switch spec.name {
        case "login":
            LoginController.run()
        case "schema":
            if let name = args.string("command") {
                guard let one = Commands.named(name) else { fail(GVError.invalid("Unknown command '\(name)'.")) }
                let data = [name: ["description": one.summary, "inputSchema": Validator.jsonSchema(one)]]
                say(Output.success(data))
            } else {
                var all: [String: Any] = [:]
                for s in Commands.all where s.name != "schema" {
                    all[s.name] = ["description": s.summary, "inputSchema": Validator.jsonSchema(s)]
                }
                say(Output.success(all))
            }
            exit(0)
        case "mcp":
            let server = MCPServer(service: Service(stamper: WaaSigner()), version: version, openLogin: openLoginWindow)
            Thread.detachNewThread { server.serve() }
        case "shot":
            Task {
                do {
                    finish(spec.name, try await ThreadShot.take(args, service: Service()))
                } catch {
                    fail(error)
                }
            }
        default:
            let service = Service(stamper: WaaSigner())
            Task {
                do {
                    let data = try await service.run(spec.name, args, direct: direct)
                    finish(spec.name, data)
                } catch {
                    fail(error)
                }
            }
        }
    }

    /// Starts `gvoice login` as its own process, so an agent can bring up the sign-in window.
    static func openLoginWindow() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["login"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}

signal(SIGPIPE, SIG_IGN)
MainActor.assumeIsolated { CLI.start() }
RunLoop.main.run()
