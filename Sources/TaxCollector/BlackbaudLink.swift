import AppKit
import WebKit

/// Talks to Blackbaud as you, through web views signed in with your own login.
///
/// You sign in on Blackbaud's own page (or your school's Google/Microsoft page), so your password
/// never passes through Tax Collector. The session cookie stays in this app's web storage, and
/// requests are made from inside a Blackbaud page, exactly like the website makes them.
@MainActor
final class BlackbaudLink: NSObject, WKNavigationDelegate, NSWindowDelegate {
    enum CallError: Error {
        case noHost
        case pageDidNotLoad
        case script(String)
    }

    struct Response {
        var status: Int
        var body: String
        var json: Any? { try? JSONSerialization.jsonObject(with: Data(body.utf8)) }
    }

    private(set) var host: String?
    var onSignedInChange: (Bool) -> Void = { _ in }

    private var worker: WKWebView?
    private var workerLoaded = false
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var signInWindow: NSWindow?
    private var signInView: WKWebView?

    /// The school's address comes from the feed link (`yourschool.myschoolapp.com`).
    func configure(feedURL: URL?) {
        let newHost = feedURL.flatMap { $0.isFileURL ? nil : $0.host }
        guard newHost != host else { return }
        host = newHost
        worker = nil
        workerLoaded = false
    }

    private func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        return config
    }

    /// Google refuses to sign in inside apps that don't look like a browser, and many schools sign in through Google.
    private static let safariAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private func makeWebView(_ size: NSSize) -> WKWebView {
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration())
        web.customUserAgent = Self.safariAgent
        web.navigationDelegate = self
        return web
    }

    // MARK: Sign-in

    func showSignIn() {
        guard let host, let url = URL(string: "https://\(host)/app/student#login") else { return }
        if let signInWindow {
            NSApp.activate()
            signInWindow.makeKeyAndOrderFront(nil)
            return
        }
        let web = makeWebView(NSSize(width: 900, height: 700))
        web.load(URLRequest(url: url))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign in to Blackbaud"
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        signInWindow = window
        signInView = web
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        signInView?.navigationDelegate = nil
        signInView = nil
        signInWindow = nil
        Task { self.onSignedInChange(await self.isSignedIn()) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === worker {
            workerLoaded = true
            loadWaiters.forEach { $0.resume(returning: true) }
            loadWaiters.removeAll()
            return
        }
        guard webView === signInView else { return }
        // Blackbaud lands on the student pages once you're in. Check, then close the window for you.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if await self.isSignedIn() {
                self.signInWindow?.close()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failWorkerLoad(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failWorkerLoad(webView)
    }

    private func failWorkerLoad(_ webView: WKWebView) {
        guard webView === worker else { return }
        loadWaiters.forEach { $0.resume(returning: false) }
        loadWaiters.removeAll()
    }

    // MARK: Requests

    /// A hidden page on the school's site, so `fetch` runs with the same origin and cookies as the website.
    private func readyWorker() async throws -> WKWebView {
        guard let host, let url = URL(string: "https://\(host)/app/student") else { throw CallError.noHost }
        if let worker, workerLoaded { return worker }
        let web = worker ?? makeWebView(NSSize(width: 800, height: 600))
        if worker == nil {
            worker = web
            web.load(URLRequest(url: url))
        }
        let loaded = await withCheckedContinuation { cont in loadWaiters.append(cont) }
        guard loaded else {
            worker = nil
            throw CallError.pageDidNotLoad
        }
        return web
    }

    /// Runs one request from inside the Blackbaud page. `path` starts with `/`.
    func call(_ method: String, _ path: String, json: Any? = nil, headers: [String: String] = [:]) async throws -> Response {
        let web = try await readyWorker()
        var bodyText = ""
        if let json, let data = try? JSONSerialization.data(withJSONObject: json) {
            bodyText = String(decoding: data, as: UTF8.self)
        }
        let script = """
        const opts = { method: method, credentials: 'include', headers: Object.assign({ 'Accept': 'application/json' }, headers) };
        if (body.length > 0) { opts.body = body; opts.headers['Content-Type'] = 'application/json'; }
        const r = await fetch(path, opts);
        return { status: r.status, body: await r.text() };
        """
        do {
            let result = try await web.callAsyncJavaScript(
                script, arguments: ["method": method, "path": path, "body": bodyText, "headers": headers],
                in: nil, contentWorld: .page)
            guard let dict = result as? [String: Any] else { throw CallError.script("No answer from the page.") }
            let status = (dict["status"] as? NSNumber)?.intValue ?? 0
            return Response(status: status, body: dict["body"] as? String ?? "")
        } catch let error as CallError {
            throw error
        } catch {
            throw CallError.script(error.localizedDescription)
        }
    }

    /// Asks Blackbaud who's signed in. Any failure counts as signed out.
    func isSignedIn() async -> Bool {
        guard host != nil, let r = try? await call("GET", BlackbaudAPI.contextPath) else { return false }
        return BlackbaudAPI.isSignedIn(r.status, r.json)
    }

    /// Forget the session (sign out of Blackbaud inside Tax Collector).
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let school = records.filter { record in
            guard let host else { return false }
            return host.hasSuffix(record.displayName) || record.displayName.contains("blackbaud")
        }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: school)
        worker = nil
        workerLoaded = false
        onSignedInChange(false)
    }
}
