import AppKit
import GVoiceKit
import WebKit

/// `gvoice shot`: a real picture of one conversation, the way voice.google.com shows it. It opens the real
/// website in a hidden window with gvoice's own sign-in, waits for the messages, and saves a PNG.
/// The website marks a thread read when it opens it, so an unread conversation is marked unread again after.
@MainActor
final class ThreadShot: NSObject {
    static let size = NSSize(width: 1280, height: 860)
    let store = SessionStore()
    var window: NSWindow?

    static func take(_ args: Args, service: Service) async throws -> [String: Any] {
        try await ThreadShot().take(args, service: service)
    }

    func take(_ args: Args, service: Service) async throws -> [String: Any] {
        let out = URL(fileURLWithPath: ((args.string("out") ?? "") as NSString).expandingTildeInPath)
        // A normal read first: it checks the sign-in, refreshes it when due, and gives the exact id and unread state.
        let read = try await service.run("read", Args(["id": args.string("id") ?? "", "limit": 1, "filter": "all"]))
        guard let thread = read as? [String: Any], let id = thread["conversationId"] as? String else {
            throw GVError.notFound("Conversation \(args.string("id") ?? "")")
        }
        let wasUnread = thread["unreadWas"] as? Bool ?? false
        guard let session = try store.load() else { throw GVError.signedOut }

        let png: NSBitmapImageRep
        do {
            png = try await picture(of: id, session: session)
        } catch {
            if wasUnread { _ = try? await service.run("mark-read", Args(["id": id, "unread": true])) }
            throw error
        }
        if wasUnread { _ = try await service.run("mark-read", Args(["id": id, "unread": true])) }
        guard let data = png.representation(using: .png, properties: [:]) else {
            throw GVError("SHOT_FAILED", "Could not turn the picture into a PNG.")
        }
        do {
            try data.write(to: out, options: .atomic)
        } catch {
            throw GVError("WRITE_FAILED", "Could not save the picture to \(out.path).")
        }
        return ["path": out.path, "conversationId": id, "width": png.pixelsWide, "height": png.pixelsHigh,
                "keptUnread": wasUnread]
    }

    func picture(of id: String, session: Session) async throws -> NSBitmapImageRep {
        let (web, injected) = await open(session)
        defer { close(web) }
        let base = "https://voice.google.com/u/\(session.authUser)/messages"
        let query = id.replacingOccurrences(of: "+", with: "%2B")
        // The link form opens threads the website already has in its list; the path form opens older ones.
        var shown = false
        for (link, wait) in [("\(base)?itemId=\(query)", 20.0), ("\(base)/\(id)", 15.0)] where !shown {
            guard let url = URL(string: link) else { continue }
            web.load(URLRequest(url: url))
            shown = try await waitForMessages(web, id: id, timeout: wait)
        }
        await keepRefreshedCookies(web, injected: injected)
        guard shown else {
            throw GVError("SHOT_FAILED", "The conversation did not open on the Google Voice website.",
                          hint: "Try again in a minute.")
        }
        try await Task.sleep(nanoseconds: 700_000_000)   // let pictures in the thread finish drawing
        let image = try await web.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            throw GVError("SHOT_FAILED", "The Google Voice page could not be captured.")
        }
        return bitmap
    }

    func open(_ session: Session) async -> (WKWebView, [Cookie]) {
        _ = NSApplication.shared
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.accessory) }   // no Dock icon
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // nothing is kept by WebKit; the sign-in stays in session.json
        config.preferences.inactiveSchedulingPolicy = .none
        let injected = session.jar.cookies.filter { $0.expires.map { $0 > Date() } ?? true }
        for cookie in injected {
            if let http = cookie.httpCookie { await config.websiteDataStore.httpCookieStore.setCookie(http) }
        }
        let web = WKWebView(frame: NSRect(origin: .zero, size: ThreadShot.size), configuration: config)
        web.customUserAgent = session.userAgent
        // WebKit only paints a view that sits in a window, so it gets one placed off every screen.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: ThreadShot.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        self.window = window
        return (web, injected)
    }

    func close(_ web: WKWebView) {
        web.stopLoading()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    /// Waits until the thread's messages are on screen and have stopped changing.
    func waitForMessages(_ web: WKWebView, id: String, timeout: TimeInterval) async throws -> Bool {
        let digits = id.filter(\.isNumber)
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        var steady = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            let state = try? await web.evaluateJavaScript("""
                ({n: document.querySelectorAll('gv-message-item').length, host: location.host,
                  href: decodeURIComponent(location.href)})
                """) as? [String: Any]
            if let host = state?["host"] as? String, host == "accounts.google.com" { throw GVError.sessionExpired }
            let n = state?["n"] as? Int ?? 0
            let href = state?["href"] as? String ?? ""
            guard n > 0, href.filter(\.isNumber).contains(digits) else {
                last = -1
                steady = 0
                continue
            }
            steady = n == last ? steady + 1 : 0
            last = n
            if steady >= 3 { return true }
        }
        return false
    }

    /// The website may refresh the sign-in cookies while it runs. Keep any it changed, so the saved
    /// sign-in never falls behind the one Google now expects.
    func keepRefreshedCookies(_ web: WKWebView, injected: [Cookie]) async {
        let key = { (c: Cookie) in "\(c.name)|\(c.domain)|\(c.path)" }
        let before = Dictionary(injected.map { (key($0), $0.value) }, uniquingKeysWith: { first, _ in first })
        let all = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        let changed = all.map(Cookie.init).filter { c in
            (c.domain == "google.com" || c.domain.hasSuffix(".google.com")) && before[key(c)] != c.value
        }
        guard !changed.isEmpty else { return }
        _ = try? store.locked {
            guard var saved = try store.load() else { return }
            for c in changed { saved.jar.set(c) }
            try store.save(saved)
        }
    }
}

extension Cookie {
    var httpCookie: HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .path: path,
                                               .domain: hostOnly ? domain : "." + domain]
        if secure { p[.secure] = "TRUE" }
        if let expires { p[.expires] = expires }
        return HTTPCookie(properties: p)
    }
}
