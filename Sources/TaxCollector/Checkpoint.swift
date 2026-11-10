import AppKit
import ApplicationServices
import TaxCore

/// What the checkpoint needs to know about browsers and windows.
enum Checkpoint {
    enum BrowserKind {
        /// Answers AppleScript's `URL of current tab of front window`.
        case safari
        /// Answers `URL of active tab of front window`.
        case chromium
        /// Gives no address; only the window title, through Accessibility.
        case other
    }

    static let safariIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromiumIDs: Set<String> = [
        "com.google.Chrome", "com.google.chrome.for.testing", "org.chromium.Chromium", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX", "company.thebrowser.Browser",
        "company.thebrowser.dia", "ai.perplexity.comet", "ru.yandex.desktop.yandex-browser",
    ]
    /// Chrome Beta/Dev/Canary and Edge's channels share a prefix.
    static let chromiumPrefixes = ["com.google.Chrome.", "com.microsoft.edgemac"]
    static let arcID = "company.thebrowser.Browser"

    static func browserKind(_ bundleID: String?) -> BrowserKind? {
        guard let id = bundleID else { return nil }
        if safariIDs.contains(id) { return .safari }
        if chromiumIDs.contains(id) || chromiumPrefixes.contains(where: { id.hasPrefix($0) }) { return .chromium }
        if id == arcID || Allowlist.browsers.contains(where: { $0.bundleID == id }) { return .other }
        return nil
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's Accessibility prompt (for watching Firefox-type browsers by window title).
    static func askForAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The focused window's title, for browsers that don't give their address. Needs Accessibility.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    /// The web page's area inside a browser's focused window, in screen coordinates (bottom-left origin), so the
    /// checkpoint covers the page but not the tabs, sidebar or address bar. Needs Accessibility; nil without it
    /// or when the page can't be found (then the whole window is covered).
    static func webAreaFrame(pid: pid_t) -> NSRect? {
        guard AXIsProcessTrusted(), let primary = NSScreen.screens.first else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // Chrome and other Chromium browsers only build their page's accessibility tree when asked to.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var queue: [(AXUIElement, Int)] = [(window as! AXUIElement, 0)]
        var visited = 0
        var best: CGRect?
        while !queue.isEmpty && visited < 800 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" {
                if let rect = frame(of: element), rect.width >= 200, rect.height >= 150,
                   rect.width * rect.height > (best.map { $0.width * $0.height } ?? 0) {
                    best = rect
                }
                continue   // a page's own frames are inside it
            }
            guard depth < 30 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.map { ($0, depth + 1) })
            }
        }
        guard let rect = best else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// An element's frame in Accessibility's coordinates (top-left origin).
    private static func frame(of element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Presses ⌘[ (Back) in that app. Sent to the app itself, so it doesn't matter what's in front. Needs Accessibility.
    static func pressBack(pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let bracket: CGKeyCode = 33
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: bracket, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.postToPid(pid)
        }
    }

    /// The app's frontmost normal window, in screen coordinates (bottom-left origin). Needs no permission.
    static func frontWindowFrame(pid: pid_t) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        var rects: [CGRect] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            rects.append(rect)
        }
        guard let rect = Rewards.coverRect(frontToBack: rects) else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Reads a browser's front-tab address with AppleScript, one request at a time, off the main thread.
/// macOS asks once per browser whether Tax Collector may control it.
final class BrowserAddressReader: @unchecked Sendable {
    enum Answer: Sendable {
        case url(String)
        /// No window, or a page without an address.
        case none
        /// You said no to "Tax Collector wants to control …".
        case notAllowed
        case failed(String)
    }

    private let queue = DispatchQueue(label: AppModel.label + ".browser-address")
    /// Only touched on `queue`.
    private var scripts: [String: NSAppleScript] = [:]

    /// Chromium browsers: Back in the front tab, through AppleScript (works without Accessibility).
    func goBack(bundleID: String) {
        queue.async {
            let source = "tell application id \"\(bundleID)\" to tell active tab of front window to go back"
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    func read(bundleID: String, kind: Checkpoint.BrowserKind, done: @escaping @Sendable (Answer) -> Void) {
        queue.async { [self] in
            let source: String
            switch kind {
            case .safari: source = "tell application id \"\(bundleID)\" to return URL of current tab of front window"
            case .chromium: source = "tell application id \"\(bundleID)\" to return URL of active tab of front window"
            case .other:
                done(.none)
                return
            }
            let script: NSAppleScript
            if let cached = scripts[bundleID] {
                script = cached
            } else if let made = NSAppleScript(source: source) {
                scripts[bundleID] = made
                script = made
            } else {
                done(.failed("couldn't make the script"))
                return
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                // -1743: not allowed to send Apple events. -1728/-1719: no such window or tab.
                switch code {
                case -1743, -1744: done(.notAllowed)
                case -1728, -1719, -2753: done(.none)
                default: done(.failed("AppleScript error \(code)"))
                }
                return
            }
            if let text = result.stringValue, !text.isEmpty { done(.url(text)) } else { done(.none) }
        }
    }
}

/// A panel that can take typing (for the school reason) without making Tax Collector the active app,
/// so the browser or game stays the front app underneath.
final class CheckpointPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Watches what's in front. When it's on the watchlist and not open (no free time running, no pass),
/// puts the checkpoint over its window. Nothing is ever closed or hidden by this.
@MainActor
final class CheckpointController {
    private let model: AppModel
    /// Makes the SwiftUI content with the app's environment.
    private let makeContent: (WatchItem, @escaping () -> Void) -> NSView
    private let reader = BrowserAddressReader()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var panel: CheckpointPanel?
    private var shownItemID: UUID?
    private var shownPID: pid_t?
    /// The latest address read from each browser, by process.
    private var addresses: [pid_t: String] = [:]
    private var reading: Set<pid_t> = []
    private var told: Set<String> = []
    private var spaceObserver: NSObjectProtocol?
    /// Where the page is in each browser window, so the tree isn't searched twice a second.
    private var webAreas: [pid_t: (window: NSRect, area: NSRect?, at: Date)] = [:]
    var log: (String) -> Void = { _ in }
    /// For the self-test: what's being covered, if anything.
    private(set) var coveringItem: WatchItem?

    init(model: AppModel, makeContent: @escaping (WatchItem, @escaping () -> Void) -> NSView) {
        self.model = model
        self.makeContent = makeContent
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Swiping to another workspace: take the checkpoint down at once, then look at what's in front there.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
                self?.check()
            }
        }
        check()
    }

    func check() {
        // Not started (the self-test): never look at the real screen.
        guard timer != nil else { return }
        guard !model.rewards.watchlist.isEmpty else {
            setWatched(nil)
            hide()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // You're in Tax Collector itself (not the checkpoint, which never makes it the active app).
            hide()
            return
        }
        let pid = app.processIdentifier
        let kind = Checkpoint.browserKind(app.bundleIdentifier)
        var front = FrontThing(bundleID: app.bundleIdentifier, appName: app.localizedName ?? "",
                               processName: app.executableURL?.lastPathComponent ?? "")
        if let kind, model.rewards.watchlist.contains(where: \.isSite) {
            switch kind {
            case .safari, .chromium:
                front.url = addresses[pid]
                refreshAddress(app, kind: kind)
            case .other:
                front.windowTitle = Checkpoint.focusedWindowTitle(pid: pid)
            }
        }
        let item = Rewards.match(front, watchlist: model.rewards.watchlist, isBrowser: kind != nil)
        setWatched(item)
        if let item, !Rewards.isOpen(item, state: model.rewards, now: model.now) {
            show(item, over: app)
        } else {
            hide()
        }
    }

    private func setWatched(_ item: WatchItem?) {
        if model.watchedInFront?.id != item?.id { model.watchedInFront = item }
    }

    private func refreshAddress(_ app: NSRunningApplication, kind: Checkpoint.BrowserKind) {
        let pid = app.processIdentifier
        guard let id = app.bundleIdentifier, !reading.contains(pid) else { return }
        reading.insert(pid)
        let name = app.localizedName ?? id
        reader.read(bundleID: id, kind: kind) { [weak self] answer in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading.remove(pid)
                    let before = self.addresses[pid]
                    switch answer {
                    case let .url(url): self.addresses[pid] = url
                    case .none: self.addresses[pid] = nil
                    case .notAllowed:
                        self.addresses[pid] = nil
                        self.tellOnce("CHECKPOINT can't read \(name)'s address: not allowed in System Settings > Privacy & Security > Automation")
                    case let .failed(why):
                        self.tellOnce("CHECKPOINT can't read \(name)'s address: \(why)")
                    }
                    if self.addresses[pid] != before { self.check() }
                }
            }
        }
    }

    private func tellOnce(_ line: String) {
        guard told.insert(line).inserted else { return }
        log(line)
    }

    private func show(_ item: WatchItem, over app: NSRunningApplication) {
        let window = Checkpoint.frontWindowFrame(pid: app.processIdentifier)
            ?? (NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        var frame = window
        // For a site, only the page: the tabs, sidebar and address bar stay usable, so you can just go elsewhere.
        if item.isSite, let area = pageArea(pid: app.processIdentifier, window: window) {
            frame = area
        }
        let panel = self.panel ?? makePanel()
        if shownItemID != item.id {
            panel.contentView = container(makeContent(item) { [weak self] in self?.leave() })
            if coveringItem == nil || shownPID != app.processIdentifier {
                log("CHECKPOINT over \(item.name) in \(app.localizedName ?? "an app")")
            }
            shownItemID = item.id
        }
        shownPID = app.processIdentifier
        coveringItem = item
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func pageArea(pid: pid_t, window: NSRect) -> NSRect? {
        if let cached = webAreas[pid], cached.window == window, Date().timeIntervalSince(cached.at) < 3 {
            return cached.area
        }
        // Something too small to be the page (a frame, a pop-up) means the whole window is covered instead.
        let area = Checkpoint.webAreaFrame(pid: pid).map { $0.intersection(window) }
            .flatMap { $0.width * $0.height >= window.width * window.height * 0.3 ? $0 : nil }
        webAreas[pid] = (window, area, Date())
        return area
    }

    /// Puts the content in a plain view that follows the panel's size, so the content can never resize the panel.
    private func container(_ content: NSView) -> NSView {
        let box = NSView(frame: NSRect(origin: .zero, size: panel?.frame.size ?? NSSize(width: 600, height: 400)))
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = box.bounds
        content.autoresizingMask = [.width, .height]
        box.addSubview(content)
        return box
    }

    /// Testing aid: lays the checkpoint out in an invisible, off-screen panel of `size` and returns the size
    /// the panel ends up with. It should stay `size`.
    func panelSizeAfterLayout(item: WatchItem, size: NSSize) async -> NSSize {
        let panel = self.panel ?? makePanel()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.contentView = container(makeContent(item) {})
        panel.setFrame(NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), display: true)
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 800_000_000)
        panel.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let result = panel.frame.size
        panel.orderOut(nil)
        panel.contentView = nil
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        return result
    }

    private func makePanel() -> CheckpointPanel {
        let panel = CheckpointPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // On the workspace in front only: it mustn't show up on the next one while you swipe.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    private func hide() {
        guard let panel, panel.isVisible || coveringItem != nil else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        shownItemID = nil
        shownPID = nil
        coveringItem = nil
    }

    /// A site: the browser goes back a page (its tabs stay clickable anyway). An app: it's hidden, not closed,
    /// and you stay on this workspace.
    private func leave() {
        guard let item = coveringItem, let pid = shownPID,
              let watched = NSRunningApplication(processIdentifier: pid) else {
            hide()
            return
        }
        if item.isSite {
            if Checkpoint.browserKind(watched.bundleIdentifier) == .chromium, let id = watched.bundleIdentifier {
                reader.goBack(bundleID: id)
            } else {
                Checkpoint.pressBack(pid: pid)
            }
            log("CHECKPOINT went back a page in \(watched.localizedName ?? "the browser")")
        } else {
            hide()
            watched.hide()
        }
    }
}
