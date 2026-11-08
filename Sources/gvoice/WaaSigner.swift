import AppKit
import GVoiceKit
import WebKit

/// Makes Google's per-text send stamp the same way voice.google.com does: it runs Google's own small
/// check program in Apple's built-in web engine. The hidden web view exists only while a text is sent
/// (about half a second and ~70 MB), then it is thrown away.
@MainActor
final class WaaSigner: NSObject, Stamper, WKNavigationDelegate {
    var loaded: CheckedContinuation<Void, Error>?

    nonisolated override init() { super.init() }

    func stamp(client: VoiceClient, threadID: String, recipients: [String], transactionID: Int64) async throws -> String {
        let waa = try await client.createWaa()
        let userAgent = await client.session.userAgent
        let web = try await page(userAgent: userAgent)
        defer {
            web.navigationDelegate = nil
            web.stopLoading()
        }
        try await loadScript(waa.scriptURL, in: web)
        // The web page announces itself once with a blank stamp, then stamps the message.
        let hello = try await run(waa, payload: nil, in: web)
        try? await client.pingWaa(hello)
        let payload = WaaPayload.forMessage(threadID: threadID, recipients: recipients, transactionID: transactionID)
        return try await run(waa, payload: payload, in: web)
    }

    /// A blank page that counts as voice.google.com, like the real site, without loading the real site.
    func page(userAgent: String) async throws -> WKWebView {
        _ = NSApplication.shared
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.prohibited) }   // no Dock icon
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.inactiveSchedulingPolicy = .none
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        web.customUserAgent = userAgent
        web.navigationDelegate = self
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            web.loadHTMLString("<!doctype html><html><head><title>Google Voice</title></head><body></body></html>",
                               baseURL: URL(string: "https://voice.google.com/about")!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, let waiting = self.loaded else { return }
                self.loaded = nil
                waiting.resume(throwing: GVError("STAMP_FAILED", "Timed out: the page did not load."))
            }
        }
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func loadScript(_ src: String, in web: WKWebView) async throws {
        guard let url = URL(string: src), url.scheme == "https", url.host?.hasSuffix(".google.com") == true
                || url.host == "google.com" || url.host?.hasSuffix(".gstatic.com") == true else {
            throw GVError("STAMP_FAILED", "Google handed out a check program from an unexpected address.")
        }
        _ = try await web.callAsyncJavaScript("""
            await new Promise((resolve, reject) => {
              const s = document.createElement('script');
              s.src = src;
              s.onload = resolve;
              s.onerror = () => reject(new Error('the check program did not load'));
              document.head.appendChild(s);
              setTimeout(() => reject(new Error('the check program took too long to load')), 15000);
            });
            """, arguments: ["src": src], in: nil, contentWorld: .page)
    }

    func run(_ waa: WaaProgram, payload: [String: String]?, in web: WKWebView) async throws -> String {
        let result = try await web.callAsyncJavaScript("""
            return await new Promise((resolve, reject) => {
              setTimeout(() => reject(new Error('the check program did not answer')), 10000);
              const vm = window[globalName];
              if (!vm || typeof vm.a !== 'function') { reject(new Error('the check program is missing')); return; }
              new Promise(done => vm.a(program, (fn1, fn2, fn3, fn4) => done(fn1), true, undefined, () => {}))
                .then(fn1 => fn1(result => resolve(String(result)), [blank ? undefined : payload, undefined, undefined, undefined]),
                      reject);
            });
            """, arguments: ["globalName": waa.globalName, "program": waa.program,
                             "payload": payload ?? [:], "blank": payload == nil],
            in: nil, contentWorld: .page)
        guard let token = result as? String, !token.isEmpty else {
            throw GVError("STAMP_FAILED", "Google's check program returned nothing.")
        }
        return token
    }
}
