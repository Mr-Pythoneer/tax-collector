import AppKit
import SwiftUI
import TaxCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private let blackbaudLink = BlackbaudLink()
    private let router = Router()
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var lockWindow: NSWindow?
    private var banner: NSPanel?
    private var bannerHide: DispatchWorkItem?
    private var statusTimer: Timer?
    private var notificationsAllowed = false
    /// Dry runs and scratch-data test runs can be quit normally; the real thing can't.
    private var canQuitFreely = false

    private static let showNotification = Notification.Name(AppModel.label + ".show")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let dryRun = env["TAXCOLLECTOR_DRY_RUN"] == "1"
        let testing = !(env["TAXCOLLECTOR_DATA_DIR"] ?? "").isEmpty
        canQuitFreely = dryRun || testing
        if !testing { enforceSingleInstance() }

        model = AppModel(store: Store(), dryRun: dryRun)
        Theme.apply(model.settings.appearance)
        model.onLockChange = { [weak self] in self?.lockChanged($0) }
        model.onWarning = { [weak self] in self?.warn($0, remaining: $1) }
        model.onClosedApp = { [weak self] name in
            guard let self else { return }
            self.showLockWindow()
            self.showBanner(self.model.dryRun ? "Would close \(name)" : "Closed \(name). Pay up first.")
        }
        model.onPaid = { [weak self] task in
            self?.notify("Paid: \(task.title)", "The auditor accepted your proof.")
        }
        blackbaudLink.configure(feedURL: model.feedURL)
        blackbaudLink.onSignedInChange = { [weak self] in self?.model.blackbaudSignedIn = $0 }
        model.onBlackbaudSignIn = { [weak self] in
            guard let self else { return }
            self.blackbaudLink.configure(feedURL: self.model.feedURL)
            self.blackbaudLink.showSignIn()
        }
        model.onBlackbaudSignOut = { [weak self] in
            guard let self else { return }
            Task { await self.blackbaudLink.signOut() }
        }
        model.blackbaudMarker = { [weak self] task in
            guard let self else { return "Tax Collector is shutting down." }
            self.blackbaudLink.configure(feedURL: self.model.feedURL)
            let failure = await BlackbaudAPI.markCompleted(task, link: self.blackbaudLink)
            self.model.blackbaudSignedIn = await self.blackbaudLink.isSignedIn()
            return failure
        }
        if model.feedURL != nil {
            Task { self.model.blackbaudSignedIn = await self.blackbaudLink.isSignedIn() }
        }
        model.onImported = { [weak self] added in
            guard let self, let next = added.min(by: { $0.dueDate < $1.dueDate }) else { return }
            let title = added.count == 1 ? "New from Blackbaud: \(next.title)" : "\(added.count) assignments from Blackbaud"
            var body = "Next: \(next.title), \(Fmt.due(next, now: self.model.now))."
            if next.dueDate.timeIntervalSince(self.model.now) <= LockPolicy.freezeWindow {
                body += " Due within a day, so it locks in after 5 minutes."
            }
            self.notify(title, body)
        }

        setUpStatusItem()
        setUpNotifications()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Never block a logout or shutdown.
            MainActor.assumeIsolated { self?.model.allowQuit = true }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showMain() }
        }

        model.start()
        let startedAtLogin = CommandLine.arguments.contains("--launchd")
        if model.guardian == nil || !startedAtLogin { showMain() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model == nil || model.allowQuit || canQuitFreely { return .terminateNow }
        // Activity Monitor's plain "Quit" lands here. Force Quit can't be stopped, but launchd brings us back.
        model.store.log("QUIT refused")
        showMain()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// One copy only. The launchd copy wins over one opened by hand.
    private func enforceSingleInstance() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        if CommandLine.arguments.contains("--launchd") {
            others.forEach { $0.forceTerminate() }
        } else {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
    }

    // MARK: Lock transitions

    private func lockChanged(_ locked: Bool) {
        if locked {
            showLockWindow()
            let owed = model.lock.overdue.map(\.title)
            if owed.isEmpty {
                notify("Late fee", "Proof accepted late. Locked a little longer.")
            } else {
                notify("The Tax Collector is here", "Overdue: \(owed.joined(separator: ", ")). Other apps will close until you pay.")
            }
        } else {
            lockWindow?.close()
            lockWindow = nil
            router.lockSheet = nil
            if model.lock.overrideUntil == nil {
                showBanner("Paid up. Everything's unlocked.")
                notify("Paid up", "Everything's unlocked.")
            } else {
                showBanner("Guardian unlock until \(Fmt.time.string(from: model.lock.overrideUntil!)).")
            }
        }
        refreshStatusItem()
    }

    private func warn(_ task: TaxTask, remaining: TimeInterval) {
        let left = Fmt.span(remaining)
        if remaining <= 5 * 60 {
            notify("Lockdown in \(left)", "“\(task.title)” isn't paid. Save your work in other apps now.")
            showBanner("Lockdown in \(left) unless “\(task.title)” is paid. Save your work.")
        } else {
            notify("“\(task.title)” is due in \(left)", "Pay with proof before the deadline to stay unlocked.")
        }
    }

    // MARK: Windows

    func showMain() {
        if mainWindow == nil {
            let view = MainView(openLockWindow: { [weak self] in self?.showLockWindow() })
            mainWindow = makeWindow(title: "Tax Collector", size: NSSize(width: 640, height: 600),
                                    closable: true, content: view)
            mainWindow?.setFrameAutosaveName("TaxCollectorMain")
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func showLockWindow() {
        guard model.lock.isLocked else { return }
        if lockWindow == nil {
            lockWindow = makeWindow(title: "Pay Up", size: NSSize(width: 680, height: 600),
                                    closable: false, content: LockScreenView())
        }
        lockWindow?.deminiaturize(nil)
        NSApp.activate()
        lockWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, closable: Bool, content: V) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .miniaturizable, .resizable]
        if closable { style.insert(.closable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.environment(model).environment(router))
        window.center()
        return window
    }

    /// A short message at the top of the screen that doesn't take focus.
    private func showBanner(_ text: String) {
        bannerHide?.cancel()
        banner?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let hosting = NSHostingView(rootView: BannerView(text: text))
        let size = hosting.fittingSize
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.maxY - size.height - 12,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        banner = panel
        let hide = DispatchWorkItem { [weak self] in
            self?.banner?.orderOut(nil)
            self?.banner = nil
        }
        bannerHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hide)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusItem()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusItem() }
        }
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button, let model else { return }
        let locked = model.lock.isLocked
        button.image = NSImage(systemSymbolName: locked ? "lock.fill" : "building.columns",
                               accessibilityDescription: "Tax Collector")
        button.imagePosition = .imageLeading
        var title = ""
        if locked, let end = model.lock.penaltyEndsAt {
            title = Fmt.span(end.timeIntervalSince(model.now))
        } else if !locked, let next = model.nextDue {
            let left = next.dueDate.timeIntervalSince(model.now)
            if left > 0 && left <= 24 * 3600 { title = Fmt.span(left) }
        }
        button.title = title.isEmpty ? "" : " \(title)"
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        if model.lock.isLocked {
            menu.addItem(item("Pay Up…", #selector(menuPayUp)))
        }
        menu.addItem(item("Open Tax Collector", #selector(menuOpen), key: "o"))
        menu.addItem(item("New Task…", #selector(menuNewTask), key: "n"))
        menu.addItem(.separator())
        menu.addItem(item("Guardian…", #selector(menuGuardian)))
        if canQuitFreely {
            menu.addItem(.separator())
            menu.addItem(item("Quit (test mode)", #selector(menuQuit), key: "q"))
        }
    }

    private func headerText() -> String {
        if model.lock.isLocked {
            if !model.lock.overdue.isEmpty { return "Locked: \(model.lock.overdue.count) overdue" }
            if let end = model.lock.penaltyEndsAt { return "Late fee: unlocks at \(Fmt.time.string(from: end))" }
        }
        if let until = model.lock.overrideUntil { return "Guardian unlock until \(Fmt.time.string(from: until))" }
        if let next = model.nextDue { return "Next: \(next.title), \(Fmt.due(next, now: model.now))" }
        return "Nothing owed"
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func menuOpen() { showMain() }
    @objc private func menuPayUp() { showLockWindow() }
    @objc private func menuNewTask() {
        showMain()
        router.mainSheet = .newTask
    }
    @objc private func menuGuardian() {
        if model.lock.isLocked {
            showLockWindow()
            router.lockSheet = .guardian
        } else {
            showMain()
            router.mainSheet = .guardian
        }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Notifications

    private func setUpNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.notificationsAllowed = granted }
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

private struct BannerView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
            .padding(4)
    }
}
