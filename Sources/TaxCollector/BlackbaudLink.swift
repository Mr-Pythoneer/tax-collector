import AppKit
import WebKit

/// Talks to Blackbaud as you, through web views signed in with your own login.
///
/// You sign in on Blackbaud's own page (or your school's Google/Microsoft page), so your password
/// never passes through Tax Collector. The session cookie stays in this app's web storage, and
/// requests are made from inside a Blackbaud page, exactly like the website makes them.
@MainActor
final class BlackbaudLink: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum CallError: LocalizedError {
        case noHost
        case pageDidNotLoad
        case script(String)

        var errorDescription: String? {
            switch self {
            case .noHost: "Turn on Blackbaud import first, so Tax Collector knows your school's address."
            case .pageDidNotLoad: "Blackbaud's site didn't load. Check your internet connection."
            case let .script(message): "Blackbaud didn't answer: \(message)"
            }
        }
    }

    /// Why something from Blackbaud didn't work, for showing to you.
    struct Failure: Error, Equatable {
        var message: String
        var signedOut = false
    }

    struct Response {
        var status: Int
        var body: String
        var json: Any? { try? JSONSerialization.jsonObject(with: Data(body.utf8)) }
    }

    private(set) var host: String?
    var onSignedInChange: (Bool) -> Void = { _ in }
    /// Where the sign-in is kept between launches (readable only by your user account). Blackbaud's
    /// sign-in is a browser-session cookie, which web storage drops when the app quits; without this
    /// you'd be signed out after every restart.
    var sessionFile: URL?
    private var sessionRestored = false

    private var worker: WKWebView?
    private var workerLoaded = false
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var signInWindow: NSWindow?
    private var signInView: WKWebView?
    private var signInWatch: Task<Void, Never>?
    /// Windows a sign-in page opened itself (Microsoft and Google sometimes use pop-ups).
    private var popups: [WKWebView: NSWindow] = [:]

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

    private func makeWebView(_ size: NSSize, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration ?? self.configuration())
        web.customUserAgent = Self.safariAgent
        web.navigationDelegate = self
        web.uiDelegate = self
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
        // Blackbaud's own sign-in can finish without a full page load, so keep asking while the window is open.
        signInWatch?.cancel()
        signInWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.signInWindow != nil else { return }
                if await self.isSignedIn() {
                    self.signInWindow?.close()
                    return
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let entry = popups.first(where: { $0.value === window }) {
            popups[entry.key] = nil
            return
        }
        guard window === signInWindow else { return }
        signInWatch?.cancel()
        signInWatch = nil
        signInView?.navigationDelegate = nil
        signInView?.uiDelegate = nil
        signInView = nil
        signInWindow = nil
        for (_, popup) in popups { popup.close() }
        Task { self.onSignedInChange(await self.isSignedIn()) }
    }

    // MARK: Pop-ups

    /// A sign-in page asked for a new window. Give it a real one, so the page that opened it can still talk to it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let width = windowFeatures.width.map { CGFloat(truncating: $0) } ?? 520
        let height = windowFeatures.height.map { CGFloat(truncating: $0) } ?? 640
        let popup = makeWebView(NSSize(width: width, height: height), configuration: configuration)
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign in"
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        popups[popup] = window
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups[webView]?.close()
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
        if worker == nil { await restoreSession() }
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

    /// Downloads a file from the school's site with your sign-in. Base64 through the page, since `fetch`
    /// only hands back bytes inside the page.
    func download(_ url: URL) async throws -> (status: Int, data: Data) {
        let web = try await readyWorker()
        let script = """
        const r = await fetch(url, { credentials: 'include' });
        const bytes = new Uint8Array(await r.arrayBuffer());
        let binary = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return { status: r.status, body: btoa(binary) };
        """
        do {
            let result = try await web.callAsyncJavaScript(script, arguments: ["url": url.absoluteString], in: nil, contentWorld: .page)
            guard let dict = result as? [String: Any], let body = dict["body"] as? String,
                  let data = Data(base64Encoded: body) else { throw CallError.script("No file came back.") }
            return ((dict["status"] as? NSNumber)?.intValue ?? 0, data)
        } catch let error as CallError {
            throw error
        } catch {
            throw CallError.script(error.localizedDescription)
        }
    }

    /// Asks Blackbaud who's signed in. Any failure counts as signed out. While signed in, the session is
    /// saved again, since Blackbaud renews it as you use it.
    func isSignedIn() async -> Bool {
        guard host != nil, let r = try? await call("GET", BlackbaudAPI.contextPath) else { return false }
        let signedIn = BlackbaudAPI.isSignedIn(r.status, r.json)
        if signedIn { await saveSession() }
        return signedIn
    }

    // MARK: Keeping the sign-in

    private func isSchoolCookie(_ cookie: HTTPCookie) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix("." + domain)
            || domain.hasSuffix("myschoolapp.com") || domain.hasSuffix("blackbaud.com")
    }

    private func saveSession() async {
        guard let sessionFile else { return }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter(isSchoolCookie)
        let list: [[String: Any]] = cookies.compactMap { cookie in
            guard let properties = cookie.properties else { return nil }
            var plist: [String: Any] = [:]
            for (key, value) in properties {
                switch value {
                case let url as URL: plist[key.rawValue] = url.absoluteString
                case is String, is Date, is NSNumber: plist[key.rawValue] = value
                default: continue
                }
            }
            return plist
        }
        guard !list.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        else { return }
        try? FileManager.default.removeItem(at: sessionFile)
        FileManager.default.createFile(atPath: sessionFile.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Puts the saved sign-in back before the first request of this launch.
    private func restoreSession() async {
        guard !sessionRestored else { return }
        sessionRestored = true
        guard let sessionFile, let data = try? Data(contentsOf: sessionFile),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for item in list {
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in item { properties[HTTPCookiePropertyKey(key)] = value }
            if let cookie = HTTPCookie(properties: properties) { await store.setCookie(cookie) }
        }
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
        if let sessionFile { try? FileManager.default.removeItem(at: sessionFile) }
        worker = nil
        workerLoaded = false
        onSignedInChange(false)
    }
}
