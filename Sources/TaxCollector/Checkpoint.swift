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
    /// The last app in front that wasn't being checkpointed, for "Not now".
    private var previousApp: NSRunningApplication?
    private var told: Set<String> = []
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
            if item == nil { previousApp = app }
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
        let frame = Checkpoint.frontWindowFrame(pid: app.processIdentifier)
            ?? (NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
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

    /// "Not now": back to the app you were in before. Nothing is closed.
    private func leave() {
        let watched = shownPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        hide()
        if let previous = previousApp, !previous.isTerminated, previous.processIdentifier != watched?.processIdentifier {
            previous.activate()
        } else {
            watched?.hide()
        }
    }
}
