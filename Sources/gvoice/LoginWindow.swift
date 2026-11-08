import AppKit
import GVoiceKit
import WebKit

/// The one-time sign-in: a small window showing Google's real sign-in page. You type your own
/// password and 2-step code there. gvoice keeps only the resulting sign-in, in a file only you can read.
@MainActor
final class LoginController: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static var current: LoginController?
    let store = SessionStore()
    var window: NSWindow!
    var web: WKWebView!
    var capturing = false
    var done = false
    var lockFD: Int32 = -1

    static let start = URL(string: "https://accounts.google.com/ServiceLogin?service=grandcentral&passive=true"
        + "&continue=https%3A%2F%2Fvoice.google.com%2Fu%2F0%2Fmessages")!

    static func run() -> Never {
        let controller = LoginController()
        current = controller
        controller.open()
        NSApplication.shared.run()
        exit(0)
    }

    func open() {
        // Only one sign-in window at a time, even when several agents ask for one.
        lockFD = Darwin.open(store.dir.appendingPathComponent(".login.lock").path, O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            CLI.fail(GVError("LOGIN_OPEN", "A Google Voice sign-in window is already open on this Mac.",
                             hint: "Finish signing in there.", exitCode: 1))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = LoginController.menu()
        app.delegate = self

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // nothing from this window is kept by WebKit
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 700), configuration: config)
        web.customUserAgent = Google.safariUserAgent
        web.navigationDelegate = self
        web.uiDelegate = self

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign in to Google Voice"
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: LoginController.start))

        DispatchQueue.main.asyncAfter(deadline: .now() + 20 * 60) { [weak self] in
            guard let self, !self.done else { return }
            self.end(.failure(GVError("LOGIN_TIMEOUT", "The sign-in window was open for 20 minutes without finishing.",
                                      hint: "Run `gvoice login` again when ready.", exitCode: 3)))
        }
    }

    static func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit gvoice sign-in", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }

    // MARK: - Watching the sign-in

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { check() }

    /// Google's pages sometimes open links in a new window. Keep everything in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func check() {
        guard !capturing, !done, let url = web.url, url.host == "voice.google.com" else { return }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "u", let n = Int(parts[1]) else { return }
        capturing = true
        Task { await capture(authUser: String(n)) }
    }

    func capture(authUser: String) async {
        let all = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        let jar = CookieJar(all.filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return d == "google.com" || d.hasSuffix(".google.com")
        }.map(Cookie.init))
        guard jar.value("SAPISID") != nil else {
            capturing = false   // not fully signed in yet; keep watching
            return
        }
        var session = Session(jar: jar, authUser: authUser, email: nil, number: nil, userAgent: Google.safariUserAgent)
        session.rotatedAt = Date()
        let client = VoiceClient(session: session, store: nil)
        do {
            let number = try await client.account().number
            let email = await client.accountEmail()
            session = await client.session
            session.number = number
            session.email = email
            try store.locked { try store.save(session) }
            var data: [String: Any] = ["signedIn": true, "number": number,
                                       "signedInAt": Render.iso.string(from: session.signedInAt)]
            if let email { data["account"] = email }
            showDone(email: email, number: number)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.end(.success(data)) }
        } catch {
            let e = error as? GVError ?? GVError("LOGIN_FAILED", error.localizedDescription)
            done = true
            web.loadHTMLString(page(icon: "&#9888;", color: "#ff9500", title: "Not signed in",
                                    lines: [e.message, e.hint ?? ""]), baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.end(.failure(e)) }
        }
    }

    func page(icon: String, color: String, title: String, lines: [String]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        let body = lines.filter { !$0.isEmpty }.map { "<p>\(esc($0))</p>" }.joined()
        return """
        <html><body style="font: 15px -apple-system, sans-serif; display:flex; align-items:center; justify-content:center;
        height:90vh; margin:0 32px; color:#1d1d1f; text-align:center"><div>
        <div style="font-size:44px; color:\(color)">\(icon)</div><h2 style="margin:8px 0">\(esc(title))</h2>\(body)
        <p style="color:#86868b">This window closes on its own.</p></div></body></html>
        """
    }

    func showDone(email: String?, number: String) {
        done = true
        web.loadHTMLString(page(icon: "&#10003;", color: "#34c759", title: "Signed in",
                                lines: [email ?? "", "Google Voice \(Phone.pretty(number))"]), baseURL: nil)
    }

    func end(_ result: Result<[String: Any], GVError>) {
        done = true
        window.orderOut(nil)
        switch result {
        case .success(let data): CLI.finish("login", data)
        case .failure(let e): CLI.fail(e)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !done {
            end(.failure(GVError("LOGIN_CANCELLED", "The sign-in window was closed before signing in finished.",
                                 hint: "Run `gvoice login` to try again.", exitCode: 3)))
        }
        return .terminateNow
    }

    func windowWillClose(_ notification: Notification) {
        guard !done else { return }
        end(.failure(GVError("LOGIN_CANCELLED", "The sign-in window was closed before signing in finished.",
                             hint: "Run `gvoice login` to try again.", exitCode: 3)))
    }
}
