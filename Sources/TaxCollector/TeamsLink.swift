import AppKit
import TaxCore
import WebKit

/// Reads your Microsoft Teams assignments as you, through the Teams web app signed in with your own login.
///
/// You sign in on Microsoft's own page, so your password never passes through Tax Collector. Teams opens its
/// Assignments app in a frame and hands that frame its sign-in. A small script added to that frame notes the
/// sign-in token the frame itself sends to its own server and reuses it for read-only requests to that same
/// server. The token stays inside the frame: Tax Collector only gets the answers.
@MainActor
final class TeamsLink: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, WKScriptMessageHandler {
    /// Why something from Teams didn't work, for showing to you.
    struct Failure: Error, Equatable {
        var message: String
        var signedOut = false
        /// What the page looked like when it stalled (hosts and yes/no facts only), for the log.
        var detail: String?
    }

    var onSignedInChange: (Bool) -> Void = { _ in }
    /// Where Microsoft's sign-in cookies are kept between launches (readable only by your user account).
    /// Unless you tick "Stay signed in", they last only until the app quits; without this you'd be signed out
    /// after every restart.
    var sessionFile: URL?
    private var sessionRestored = false

    private var worker: WKWebView?
    /// Teams only runs its apps while it believes it's on screen, so the hidden page lives in a window
    /// that is on screen but invisible and can't be clicked.
    private var workerWindow: NSWindow?
    private var signInWindow: NSWindow?
    private var signInView: WKWebView?
    private var signInWatch: Task<Void, Never>?
    private var popups: [WKWebView: NSWindow] = [:]
    private var busy = false
    /// The Assignments frame inside each Teams page, once it says it has a sign-in.
    private var frames: [ObjectIdentifier: WKFrameInfo] = [:]
    /// Where the hidden page ended up the last time it didn't become ready (host only), for finding out why.
    private(set) var lastStuckHost: String?
    private(set) var lastNavigationError: String?

    private static let startURL = URL(string: "https://teams.cloud.microsoft/")!
    private static let handlerName = "tcTeams"

    /// Runs before the page's own scripts, in every frame, but only does anything on Teams and Assignments.
    private static let pageScript = """
    (() => {
      if (!window.__tcErrors) {
        window.__tcErrors = [];
        const keep = (m) => { if (window.__tcErrors.length < 12) window.__tcErrors.push(String(m).slice(0, 160)); };
        window.addEventListener('error', (e) => keep(e.message));
        window.addEventListener('unhandledrejection', (e) => keep('rejected: ' + (e.reason && e.reason.message || e.reason)));
      }
      const host = location.host;
      const tell = (word) => {
        try { window.webkit.messageHandlers.\(handlerName).postMessage(word); } catch (e) {}
      };

      // Teams itself: open the Assignments app (its rail button has the app's ID), once it's there to click.
      if (window === window.top && host === 'teams.cloud.microsoft') {
        const APP = '\(Teams.appID)';
        let clicks = 0;
        setInterval(() => {
          if (clicks > 40 || document.querySelector('iframe[src*="assignments.edu.cloud.microsoft"]')) return;
          const b = document.getElementById(APP);
          if (b) { clicks++; b.click(); }
        }, 2500);
        return;
      }

      if (window.__taxCollectorTeams || host !== 'assignments.edu.cloud.microsoft') return;
      const AUD = '\(Teams.tokenAudience)';
      const plainFetch = window.fetch.bind(window);
      let token = null, expires = 0;
      const claims = (v) => {
        try {
          let p = v.split(' ')[1].split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
          while (p.length % 4) p += '=';
          return JSON.parse(atob(p));
        } catch (e) { return null; }
      };
      const note = (name, value) => {
        if (!/^authorization$/i.test(String(name)) || !/^bearer /i.test(String(value))) return;
        const c = claims(String(value));
        if (c && c.aud === AUD && (c.exp || 0) * 1000 >= expires) { token = String(value); expires = (c.exp || 0) * 1000; }
      };
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (k, v) { note(k, v); return setHeader.apply(this, arguments); };
      const hSet = Headers.prototype.set, hAppend = Headers.prototype.append;
      Headers.prototype.set = function (k, v) { note(k, v); return hSet.apply(this, arguments); };
      Headers.prototype.append = function (k, v) { note(k, v); return hAppend.apply(this, arguments); };
      window.fetch = function (input, init) {
        try {
          const h = (init && init.headers) || (input instanceof Request ? input.headers : null);
          if (h instanceof Headers) { const v = h.get('Authorization'); if (v) note('Authorization', v); }
          else if (Array.isArray(h)) { h.forEach(([k, v]) => note(k, v)); }
          else if (h) { for (const k in h) note(k, h[k]); }
        } catch (e) {}
        return plainFetch.apply(this, arguments);
      };
      const ready = () => token !== null && expires > Date.now() + 120000;
      Object.defineProperty(window, '__taxCollectorTeams', { value: Object.freeze({
        ready,
        get: async (path) => {
          if (!(token !== null && expires > Date.now() + 30000)) return { status: 0, body: '' };
          const url = new URL(path, location.origin);
          if (url.origin !== location.origin) return { status: 0, body: '' };
          const r = await plainFetch(url.href, { headers: { Accept: 'application/json', Authorization: token }, credentials: 'omit' });
          return { status: r.status, body: await r.text() };
        },
      }) });
      // Tell Tax Collector which frame this is once it has a sign-in. The token itself never leaves.
      const timer = setInterval(() => { if (ready()) { tell('ready'); clearInterval(timer); } }, 1000);
    })();
    """

    private func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let script = WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, contentWorld: .page, name: Self.handlerName)
        return config
    }

    /// Only the Assignments frame counts. Anything else in the page can't say it is.
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let web = message.webView, message.body as? String == "ready",
              message.frameInfo.securityOrigin.host == "assignments.edu.cloud.microsoft",
              message.frameInfo.securityOrigin.protocol == "https" else { return }
        let frame = message.frameInfo
        Task { @MainActor in self.frames[ObjectIdentifier(web)] = frame }
    }

    /// The same Safari look as the Blackbaud window, so Microsoft's sign-in treats it like a browser.
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
        if let signInWindow {
            NSApp.activate()
            signInWindow.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            await restoreSession()
            await clearTeamsPageData()
            let web = makeWebView(NSSize(width: 1000, height: 760))
            web.load(URLRequest(url: Self.startURL))
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Sign in to Microsoft Teams"
            window.contentView = web
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            signInWindow = window
            signInView = web
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // Signed in once Teams has opened Assignments and the page there has a sign-in. Then close the window for you.
            signInWatch?.cancel()
            signInWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, let view = self.signInView else { return }
                    if await self.isReady(view) {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await self.saveSession()
                        // The hidden page starts again from the fresh sign-in.
                        self.dropWorker()
                        self.signInWindow?.close()
                        return
                    }
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
        let view = signInView
        signInWatch?.cancel()
        signInWatch = nil
        signInView?.navigationDelegate = nil
        signInView?.uiDelegate = nil
        signInView = nil
        signInWindow = nil
        for (_, popup) in popups { popup.close() }
        Task {
            let signedIn: Bool
            if let view { signedIn = await self.isReady(view) } else { signedIn = false }
            if let view { self.frames[ObjectIdentifier(view)] = nil }
            self.onSignedInChange(signedIn)
        }
    }

    // MARK: Pop-ups

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Only a window someone is watching can open another.
        guard webView === signInView || popups[webView] != nil else { return nil }
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === worker { lastNavigationError = (error as NSError).domain + " \((error as NSError).code)" }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === worker { lastNavigationError = (error as NSError).domain + " \((error as NSError).code)" }
    }

    // MARK: Reading

    /// Runs a script inside the Assignments frame of `web`. nil when there is no such frame (yet).
    private func inFrame(_ web: WKWebView, _ script: String, _ arguments: [String: Any] = [:]) async -> Any? {
        guard let frame = frames[ObjectIdentifier(web)] else { return nil }
        do {
            return try await web.callAsyncJavaScript(script, arguments: arguments, in: frame, contentWorld: .page)
        } catch {
            // The frame was replaced (Teams reloaded it). Wait for the new one to say it's ready.
            frames[ObjectIdentifier(web)] = nil
            return nil
        }
    }

    private func isReady(_ web: WKWebView) async -> Bool {
        (await inFrame(web, "return !!(window.__taxCollectorTeams && window.__taxCollectorTeams.ready());") as? Bool) ?? false
    }

    /// For finding out why a sign-in stalls: where each window is and what its page says about itself.
    /// Addresses are reduced to host and path. Nothing from the page's content or sign-in is included.
    func debugSnapshot() async -> [String: Any] {
        var views: [(String, WKWebView)] = []
        if let signInView { views.append(("signIn", signInView)) }
        for (i, popup) in popups.keys.enumerated() { views.append(("popup\(i)", popup)) }
        if let worker { views.append(("worker", worker)) }
        let script = """
        return { host: location.host, path: location.pathname.slice(0, 60), state: document.readyState,
                 visible: document.visibilityState, bodyChars: (document.body ? document.body.innerText.length : -1),
                 frames: [...document.querySelectorAll('iframe')].map(f => (f.src || '').split('?')[0].slice(0, 80)),
                 appButton: !!document.getElementById('\(Teams.appID)'), errors: window.__tcErrors || [] };
        """
        var out: [String: Any] = [:]
        for (name, web) in views {
            var info: [String: Any] = [:]
            if let page = try? await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] {
                info = page
            } else {
                info = ["url": web.url?.host ?? "none", "loading": web.isLoading, "script": "no answer"]
            }
            info["assignmentsFrame"] = frames[ObjectIdentifier(web)] != nil
            info["ready"] = await isReady(web)
            out[name] = info
        }
        return out
    }

    /// Whether the hidden page ended up on Microsoft's sign-in page instead of Teams.
    private static func isOnSignInPage(_ web: WKWebView) -> Bool {
        guard let host = web.url?.host?.lowercased() else { return false }
        return host.hasPrefix("login.") || host.contains("microsoftonline") || host.hasSuffix("live.com")
    }

    private func dropWorker() {
        if let worker { frames[ObjectIdentifier(worker)] = nil }
        worker = nil
        workerWindow?.close()
        workerWindow = nil
    }

    /// The hidden Teams page with its Assignments frame signed in. Teams is slow and sometimes flaky to open,
    /// so a page that doesn't get there is dropped and tried once more from scratch.
    private func readyWorker() async -> Result<WKWebView, Failure> {
        if let worker, await isReady(worker) { return .success(worker) }
        await restoreSession()
        var detail = ""
        var onSignIn = false
        for _ in 0..<2 {
            await clearTeamsPageData()
            lastNavigationError = nil
            dropWorker()
            let web = makeWebView(NSSize(width: 1100, height: 800))
            worker = web
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = web
            window.isReleasedWhenClosed = false
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.canHide = false
            window.level = .floating
            window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrameOrigin(NSPoint(x: 0, y: 0))
            window.orderFrontRegardless()
            workerWindow = window
            web.load(URLRequest(url: Self.startURL))
            // Sign-in redirects, then the Teams app, then its Assignments frame.
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await isReady(web) {
                    await saveSession()
                    return .success(web)
                }
                // Microsoft's own sign-in page that waits for someone to type: no point waiting any longer.
                if Self.isOnSignInPage(web), await signInNeedsPerson(web) { break }
            }
            lastStuckHost = web.url?.host
            detail = await stallDetail(web)
            onSignIn = Self.isOnSignInPage(web)
            if onSignIn { break }
        }
        dropWorker()
        // Only Microsoft's sign-in page means signed out. Anything else is Teams being slow or odd, and the next check tries again.
        if onSignIn {
            return .failure(Failure(message: "Signed out of Microsoft Teams. Sign in again to keep importing.", signedOut: true,
                                    detail: detail))
        }
        return .failure(Failure(message: "Teams didn't open properly. Tax Collector will try again soon.", detail: detail))
    }

    /// Whether Microsoft's page is asking for a password or an account choice, rather than passing straight through.
    private func signInNeedsPerson(_ web: WKWebView) async -> Bool {
        let script = "return !!document.querySelector('input[type=password], input[name=loginfmt], #tilesHolder, [data-test-id]');"
        return ((try? await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)) as? Bool) ?? false
    }

    /// One line on where a stalled page got to. Hosts and yes/no facts only; never content or sign-in values.
    private func stallDetail(_ web: WKWebView) async -> String {
        var parts = ["host=\(web.url?.host ?? "none")", "loading=\(web.isLoading)", "nav=\(lastNavigationError ?? "none")"]
        let script = """
        return { path: location.pathname.slice(0, 40), state: document.readyState, visible: document.visibilityState,
                 button: !!document.getElementById('\(Teams.appID)'),
                 frame: !!document.querySelector('iframe[src*="assignments.edu.cloud.microsoft"]'),
                 launcher: /desktop app|use the web app instead/i.test(document.body ? document.body.innerText.slice(0, 2000) : ''),
                 errors: (window.__tcErrors || []).length };
        """
        if let info = try? await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String: Any] {
            for key in ["path", "state", "visible", "button", "frame", "launcher", "errors"] {
                if let value = info[key] { parts.append("\(key)=\(value)") }
            }
        } else {
            parts.append("page=no answer")
        }
        parts.append("assignmentsFrame=\(frames[ObjectIdentifier(web)] != nil)")
        return parts.joined(separator: " ")
    }

    private func get(_ path: String, on web: WKWebView) async -> Result<Data, Failure> {
        guard let result = await inFrame(web, "return await window.__taxCollectorTeams.get(path);", ["path": path]),
              let dict = result as? [String: Any] else {
            return .failure(Failure(message: "Teams didn't answer."))
        }
        let status = (dict["status"] as? NSNumber)?.intValue ?? 0
        let body = Data((dict["body"] as? String ?? "").utf8)
        switch status {
        case 200..<300: return .success(body)
        case 0: return .failure(Failure(message: "Teams' sign-in ran out. Trying again shortly."))
        case 401: return .failure(Failure(message: "Signed out of Microsoft Teams. Sign in again to keep importing.", signedOut: true))
        case 403: return .failure(Failure(message: "Teams won't show assignments to this account (error 403)."))
        default: return .failure(Failure(message: "Teams answered with error \(status)."))
        }
    }

    /// Everything still owed and due from `now` on, with each one's instructions. Only reads.
    func upcoming(now: Date) async -> Result<[TeamsAssignment], Failure> {
        guard !busy else { return .failure(Failure(message: "Already checking Teams.")) }
        busy = true
        defer { busy = false }
        // A background app with no visible window gets throttled by macOS, and Teams then barely loads. Say this is
        // real work: the check takes a few seconds once Teams isn't held back.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Reading Microsoft Teams assignments")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let web: WKWebView
        switch await readyWorker() {
        case let .failure(f): return .failure(f)
        case let .success(w): web = w
        }

        var classes: [String: String] = [:]
        if case let .success(data) = await get(Teams.classesPath, on: web) { classes = Teams.parseClasses(data) }

        var items: [Teams.WorkItem] = []
        var next: String? = Teams.upcomingWorkPath(now: now)
        var pages = 0
        while let path = next, pages < 10, items.count < Teams.maxAssignments {
            switch await get(path, on: web) {
            case let .failure(f): return .failure(f)
            case let .success(data):
                guard let page = Teams.parseWork(data) else {
                    return .failure(Failure(message: "Teams answered in a way Tax Collector doesn't understand."))
                }
                items += page.items
                next = page.next.flatMap { Teams.isOnSite($0) ? Teams.relativePath($0) : nil }
                pages += 1
            }
        }

        // The list leaves out the teacher's instructions; each assignment's own page has them.
        var instructions: [String: String] = [:]
        for item in items.filter(Teams.isOwed).prefix(60) {
            guard let path = Teams.assignmentPath(classID: item.classID, id: item.id),
                  case let .success(data) = await get(path, on: web),
                  let full = Teams.parseAssignment(data), let html = full.instructionsHTML else { continue }
            instructions[item.id] = html
        }
        // The page is only needed for the check; the next one starts fresh.
        dropWorker()
        return .success(Teams.assignments(from: items, classes: classes, instructions: instructions))
    }

    // MARK: Keeping the sign-in

    /// Clears what Teams itself keeps in a page (its saved tokens), but not Microsoft's sign-in cookies.
    /// Those saved tokens go stale after a few hours, and a window like this one can't renew them quietly (WebKit
    /// blocks the hidden frame Teams would use). With them gone, Teams signs in again from the cookies, which
    /// needs no one at the keyboard for as long as Microsoft's own sign-in lasts.
    private func clearTeamsPageData() async {
        let store = WKWebsiteDataStore.default()
        // Only what holds sign-in state. The cached app files stay, so Teams still starts quickly.
        let types: Set<String> = [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeIndexedDBDatabases,
                                  WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeWebSQLDatabases]
        let records = await store.dataRecords(ofTypes: types)
        let teams = records.filter { $0.displayName.lowercased().contains("cloud.microsoft") }
        if !teams.isEmpty { await store.removeData(ofTypes: types, for: teams) }
    }

    private static func isMicrosoftSignIn(_ domain: String) -> Bool {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["microsoftonline.com", "cloud.microsoft", "microsoft.com"].contains { d == $0 || d.hasSuffix("." + $0) }
    }

    private func saveSession() async {
        guard let sessionFile else { return }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { Self.isMicrosoftSignIn($0.domain) }
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

    private func restoreSession() async {
        guard !sessionRestored else { return }
        sessionRestored = true
        guard let sessionFile, let data = try? Data(contentsOf: sessionFile),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let existing = Set(await store.allCookies().map { "\($0.domain)|\($0.path)|\($0.name)" })
        for item in list {
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in item { properties[HTTPCookiePropertyKey(key)] = value }
            // A cookie the web storage already has is newer than the saved copy.
            guard let cookie = HTTPCookie(properties: properties), Self.isMicrosoftSignIn(cookie.domain),
                  !existing.contains("\(cookie.domain)|\(cookie.path)|\(cookie.name)") else { continue }
            await store.setCookie(cookie)
        }
    }

    /// Forget the Teams sign-in inside Tax Collector. Your school's Microsoft sign-in elsewhere isn't touched.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let microsoft = records.filter { r in
            let name = r.displayName.lowercased()
            return name.contains("microsoftonline.com") || name.contains("cloud.microsoft") || name.contains("microsoft.com")
        }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: microsoft)
        if let sessionFile { try? FileManager.default.removeItem(at: sessionFile) }
        dropWorker()
        onSignedInChange(false)
    }
}
