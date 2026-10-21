import AppKit
import SwiftUI
import TaxCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private let blackbaudLink = BlackbaudLink()
    private let teamsLink = TeamsLink()
    private let router = Router()
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var lockWindow: NSWindow?
    private var detailWindows: [UUID: NSWindow] = [:]
    private var banner: NSPanel?
    private var bannerHide: DispatchWorkItem?
    private var statusTimer: Timer?
    private var notificationsAllowed = false
    /// Dry runs and scratch-data test runs can be quit normally; the real thing can't.
    private var canQuitFreely = false
    /// Test runs (separate data folder) never install anything unless TAXCOLLECTOR_TEST_SETUP=1.
    private var setupAllowed = true
    /// A test copy with its own data folder. It mustn't change anything of the installed copy's, like window sizes.
    private var isTestCopy = false
    /// The self-test locks and unlocks a scratch copy many times; none of that should reach your screen.
    private var isSelfTest = false
    private(set) var parentLink: ParentLinkClient!

    private static let showNotification = Notification.Name(AppModel.label + ".show")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let dryRun = env["TAXCOLLECTOR_DRY_RUN"] == "1"
        let testing = !(env["TAXCOLLECTOR_DATA_DIR"] ?? "").isEmpty
        canQuitFreely = dryRun || env["TAXCOLLECTOR_ALLOW_QUIT"] == "1"
        setupAllowed = !testing || env["TAXCOLLECTOR_TEST_SETUP"] == "1"
        isTestCopy = testing
        let snapshotPath = testing ? env["TAXCOLLECTOR_TEST_SNAPSHOT"].flatMap { $0.isEmpty ? nil : $0 } : nil
        // A quiet test copy (the parent-link end-to-end test) shows nothing: no windows, menu icon or notifications.
        let quiet = testing && env["TAXCOLLECTOR_TEST_QUIET"] == "1"
        isSelfTest = testing && (env["TAXCOLLECTOR_SELFTEST"] == "1" || snapshotPath != nil || quiet)
        if !testing { enforceSingleInstance() }

        model = AppModel(store: Store(), dryRun: dryRun)
        parentLink = ParentLinkClient(store: model.store)
        parentLink.model = model
        parentLink.isTestCopy = testing
        model.onLocalSetting = { [weak self] in self?.parentLink.noteLocal($0) }
        model.onParentAction = { [weak self] text in
            self?.notify("Tax Collector", text)
            self?.showBanner(text)
        }
        if let only = env["TAXCOLLECTOR_ENFORCE_ONLY"], !only.isEmpty {
            model.enforcer.onlyTargets = Set(only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        Theme.apply(model.settings.appearance)
        model.onLockChange = { [weak self] in self?.lockChanged($0) }
        model.onWarning = { [weak self] in self?.warn($0, remaining: $1) }
        model.onClosedApp = { [weak self] name in
            guard let self else { return }
            if self.model.lock.isLocked {
                self.showLockWindow()
                self.showBanner(self.model.dryRun ? "Test mode: would have closed \(name)" : "Closed \(name). Submit proof to unlock.")
            } else {
                self.showBanner(self.model.dryRun ? "Test mode: would have closed \(name)" : "Closed \(name): a parent blocked it.")
            }
        }
        model.onPaid = { [weak self] task in
            self?.notify("Proof accepted", Agenda.courseAndTitle(task).title)
        }
        model.onRecurred = { [weak self] task in
            self?.notify("\(Agenda.courseAndTitle(task).title) is due again", "Due \(Fmt.dateTime.string(from: task.dueDate)).")
        }
        blackbaudLink.sessionFile = model.store.dir.appendingPathComponent("blackbaud-session.plist")
        blackbaudLink.configure(feedURL: model.feedURL)
        // Testing aid: TAXCOLLECTOR_BLACKBAUD_PROBE=1 opens the sign-in window and writes a read-only report.
        let probe = env["TAXCOLLECTOR_BLACKBAUD_PROBE"] == "1"
        var probed = false
        let runProbe = { [weak self] in
            guard let self, probe, !probed else { return }
            probed = true
            Task {
                await BlackbaudProbe.run(link: self.blackbaudLink, tasks: self.model.tasks,
                                         blackbaudDue: self.model.blackbaud.blackbaudDue(of:),
                                         to: self.model.store.dir.appendingPathComponent("blackbaud-probe.json"))
                self.model.store.log("PROBE wrote blackbaud-probe.json")
            }
        }
        blackbaudLink.onSignedInChange = { [weak self] signedIn in
            self?.model.blackbaudSignedIn = signedIn
            if signedIn {
                runProbe()
                self?.model.retrySignedOutDetails()
            }
        }
        teamsLink.sessionFile = model.store.dir.appendingPathComponent("teams-session.plist")
        teamsLink.onSignedInChange = { [weak self] signedIn in self?.model.teamsSignInChanged(signedIn) }
        model.onTeamsSignIn = { [weak self] in self?.teamsLink.showSignIn() }
        model.onTeamsSignOut = { [weak self] in
            guard let self else { return }
            Task { await self.teamsLink.signOut() }
        }
        model.teamsFetcher = { [weak self] now in
            guard let self else { return .failure(.init(message: "Tax Collector is shutting down.")) }
            // Testing aid: read a saved work list (the JSON Teams sends) instead of signing in.
            if let sample = env["TAXCOLLECTOR_TEST_TEAMS_JSON"], !sample.isEmpty {
                guard let data = FileManager.default.contents(atPath: sample), let page = Teams.parseWork(data) else {
                    return .failure(.init(message: "The test Teams file can't be read."))
                }
                return .success(Teams.assignments(from: page.items, classes: ["selftest-class": "Science 8 - SNC8 - 8D"]))
            }
            return await self.teamsLink.upcoming(now: now)
        }
        // Testing aid: TAXCOLLECTOR_TEAMS_PROBE=1 opens the sign-in (if needed) and writes what Teams would import,
        // without importing anything.
        if env["TAXCOLLECTOR_TEAMS_PROBE"] == "1" {
            Task { await self.runTeamsProbe() }
        }
        model.onFinishSetup = { [weak self] in self?.finishSetup() }
        model.onOpenDetails = { [weak self] in self?.openDetails($0) }
        model.blackbaudDetails = { [weak self] task in
            guard let self else { return .failure(.init(message: "Tax Collector is shutting down.")) }
            // Testing aid: show a saved assignment page instead of asking Blackbaud.
            if let sample = env["TAXCOLLECTOR_TEST_DETAILS_JSON"], !sample.isEmpty,
               let data = FileManager.default.contents(atPath: sample),
               let json = try? JSONSerialization.jsonObject(with: data),
               let page = AssignmentDetailsParser.parse(json, indexID: ((json as? [String: Any])?["AssignmentIndexId"] as? Int) ?? 1,
                                                        host: self.model.feedURL?.host ?? "school.myschoolapp.com") {
                return .success(page)
            }
            self.blackbaudLink.configure(feedURL: self.model.feedURL)
            return await BlackbaudAPI.details(for: task, due: self.model.blackbaud.blackbaudDue(of: task),
                                              link: self.blackbaudLink)
        }
        model.blackbaudDownload = { [weak self] url in
            guard let self else { return .failure(.init(message: "Tax Collector is shutting down.")) }
            return await BlackbaudAPI.download(url, link: self.blackbaudLink)
        }
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
            let failure = await BlackbaudAPI.markCompleted(task, due: self.model.blackbaud.blackbaudDue(of: task),
                                                           link: self.blackbaudLink)
            self.model.blackbaudSignedIn = await self.blackbaudLink.isSignedIn()
            return failure
        }
        if model.feedURL != nil {
            Task {
                let signedIn = await self.blackbaudLink.isSignedIn()
                self.model.blackbaudSignedIn = signedIn
                if probe {
                    if signedIn { runProbe() } else { self.blackbaudLink.showSignIn() }
                }
                if signedIn, let target = env["TAXCOLLECTOR_TEST_LAST_CHECK"], !target.isEmpty {
                    self.runLastCheckTest(titleContaining: target)
                }
            }
        }
        model.onImported = { [weak self] added in
            guard let self, let next = added.min(by: { $0.dueDate < $1.dueDate }) else { return }
            let from = added.allSatisfy(\.isFromTeams) ? "Teams" : "Blackbaud"
            let title = added.count == 1 ? "New from \(from): \(Agenda.courseAndTitle(next).title)" : "\(added.count) assignments from \(from)"
            var body = "Next: \(Agenda.courseAndTitle(next).title), due \(Fmt.relative(next.dueDate, now: self.model.now))."
            if next.dueDate.timeIntervalSince(self.model.now) <= LockPolicy.freezeWindow {
                body += " Due within a day, so it locks in after 5 minutes."
            }
            self.notify(title, body)
        }

        // A snapshot run stays completely out of sight: no menu bar icon either.
        if snapshotPath == nil && !quiet { setUpStatusItem() }
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
        if snapshotPath == nil && !quiet && (model.guardian == nil || !startedAtLogin) { showMain() }
        parentLink.start()
        startParentLinkTest(env, testing: testing)
        refreshSetupNeed()
        if startedAtLogin && model.settings.justSetUp {
            model.settings.justSetUp = false
            model.store.saveSettings(model.settings)
            showMain()
            showBanner("Tax Collector is set up. It runs in the menu bar and starts when you log in.")
        }
        if CommandLine.arguments.contains("--finish-setup") && model.guardian != nil {
            finishSetup()
        }

        // Testing aids: open one sheet for a screenshot, or run the self-test and quit.
        if let spec = env["TAXCOLLECTOR_TEST_SHEET"], !spec.isEmpty {
            if let snapshotPath {
                snapshot(spec, to: snapshotPath)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openTestSheet(spec) }
            }
        }
        if env["TAXCOLLECTOR_SELFTEST"] == "1" {
            Task {
                let report = await SelfTest.run(model: self.model)
                try? report.write(to: self.model.store.dir.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8)
                self.model.allowQuit = true
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Setup

    /// Writes what Teams import would add to `teams-probe.json` in the data folder. Imports nothing.
    private func runTeamsProbe() async {
        let out = model.store.dir.appendingPathComponent("teams-probe.json")
        func write(_ value: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out)
            }
            model.store.log("PROBE wrote teams-probe.json")
        }
        let watch = Task { [weak self] in
            let debug = out.deletingLastPathComponent().appendingPathComponent("teams-debug.json")
            while !Task.isCancelled {
                guard let self else { return }
                let snap = await self.teamsLink.debugSnapshot()
                if !snap.isEmpty, let data = try? JSONSerialization.data(withJSONObject: snap, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: debug)
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        defer { watch.cancel() }
        for attempt in 0..<2 {
            switch await teamsLink.upcoming(now: model.now) {
            case let .success(items):
                let result = Teams.sync(tasks: model.tasks, state: model.teams, assignments: items, now: model.now)
                let iso = ISO8601DateFormatter()
                write(["owed": items.count,
                       "wouldAdd": result.added.map { ["title": $0.title, "due": iso.string(from: $0.dueDate),
                                                      "details": String($0.details.prefix(300))] },
                       "links": items.filter { $0.link != nil }.count])
                return
            case let .failure(failure):
                guard failure.signedOut, attempt == 0 else {
                    return write(["error": failure.message, "stuckHost": teamsLink.lastStuckHost ?? "none",
                                  "navigationError": teamsLink.lastNavigationError ?? "none"])
                }
                teamsLink.showSignIn()
                for _ in 0..<300 where !model.teamsSignedIn {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private func refreshSetupNeed() {
        if !setupAllowed || BackgroundAgent.isInstalled {
            model.setupNeed = nil
        } else {
            model.setupNeed = BackgroundAgent.isInApplicationsFolder ? .runInBackground : .moveToApplications
        }
    }

    /// Copies the app into Applications if it isn't there yet (the copy then carries on), or else sets it to run
    /// in the background and at every login, and hands over to that background copy.
    private func finishSetup() {
        guard setupAllowed else { return }
        model.setupError = nil
        if !BackgroundAgent.isInApplicationsFolder {
            do {
                let copy = try AppMover.copyToApplications()
                model.store.log("SETUP copied the app to \(copy.deletingLastPathComponent().path)")
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = ["--finish-setup"]
                configuration.createsNewApplicationInstance = true
                configuration.environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("TAXCOLLECTOR_") }
                NSWorkspace.shared.openApplication(at: copy, configuration: configuration) { _, error in
                    DispatchQueue.main.async {
                        if let error {
                            self.model.setupError = "Copied Tax Collector to \(copy.deletingLastPathComponent().path), but couldn't open it: \(error.localizedDescription). Open it from there."
                            return
                        }
                        self.model.allowQuit = true
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                model.setupError = error.localizedDescription
            }
            return
        }
        do {
            model.settings.justSetUp = true
            model.store.saveSettings(model.settings)
            try BackgroundAgent.install()
            model.store.log("SETUP runs in the background and at login from \(Bundle.main.bundlePath)")
            // The background copy takes over from here.
            model.allowQuit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        } catch {
            model.settings.justSetUp = false
            model.store.saveSettings(model.settings)
            model.setupError = error.localizedDescription
            refreshSetupNeed()
        }
    }

    /// Testing aid, in test copies only: `TAXCOLLECTOR_PARENT_SERVER` + `TAXCOLLECTOR_PARENT_SETUP` link to a server,
    /// `TAXCOLLECTOR_TEST_PAIR=1` starts pairing and writes the code to pairing-code.txt, and
    /// `TAXCOLLECTOR_TEST_PAIR_AUTOCONFIRM=1` approves without the guardian code. For scripts/parent-link-e2e.sh.
    private func startParentLinkTest(_ env: [String: String], testing: Bool) {
        guard testing, let server = env["TAXCOLLECTOR_PARENT_SERVER"], !server.isEmpty else { return }
        parentLink.autoConfirmPairing = env["TAXCOLLECTOR_TEST_PAIR_AUTOCONFIRM"] == "1"
        Task {
            if !parentLink.isConfigured {
                if let problem = await parentLink.setUp(server: server, setupCode: env["TAXCOLLECTOR_PARENT_SETUP"] ?? "") {
                    model.store.log("PARENT test setup failed: \(problem)")
                    return
                }
            }
            guard env["TAXCOLLECTOR_TEST_PAIR"] == "1" else { return }
            parentLink.startPairing()
            if case let .waiting(code, _) = parentLink.pairing {
                try? code.write(to: model.store.dir.appendingPathComponent("pairing-code.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    /// `TAXCOLLECTOR_TEST_SHEET=name` or `name:part of a task title`.
    private func openTestSheet(_ spec: String) {
        let (kind, sheet, task) = testScreen(spec)
        if kind == "details", let task {
            openDetails(task.id)
        } else if kind == "lock" {
            showLockWindow()
        } else if let sheet {
            showMain()
            router.mainSheet = sheet
        }
    }

    /// Testing aid, with `TAXCOLLECTOR_TEST_SNAPSHOT=/path/to.png` in a test copy: draws the screen that
    /// `TAXCOLLECTOR_TEST_SHEET` names into a window that's never shown, saves it as a PNG and quits.
    /// So a screen can be checked while you're using the Mac, without anything popping up.
    private func snapshot(_ spec: String, to path: String) {
        let (kind, sheet, task) = testScreen(spec)
        let content: AnyView
        var size: NSSize?
        if kind == "details", let task {
            content = AnyView(AssignmentDetailView(taskID: task.id))
            size = NSSize(width: 620, height: 660)
        } else if kind == "main" {
            content = AnyView(MainView(openLockWindow: {}))
            size = NSSize(width: 680, height: 620)
        } else if let sheet {
            content = AnyView(SheetContent(sheet: sheet, dismiss: {}, present: { _ in }))
        } else {
            content = AnyView(Text("Nothing to show for \(spec)").padding())
        }
        let hosting = NSHostingView(rootView: content
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(model)
            .environment(router)
            .environment(parentLink))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? NSSize(width: 600, height: 400)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if size == nil { window.setContentSize(hosting.fittingSize) }
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            self?.model.allowQuit = true
            NSApp.terminate(nil)
        }
    }

    private func testScreen(_ spec: String) -> (kind: String, sheet: Sheet?, task: TaxTask?) {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let task = parts.count > 1
            ? model.tasks.first { $0.title.localizedCaseInsensitiveContains(parts[1]) }
            : model.tasks.first(where: \.isPending)
        let sheet: Sheet? = switch parts[0] {
        case "new": .newTask
        case "edit": task.map { .edit($0.id) }
        case "proof": task.map { .proof($0.id) }
        case "lastcheck": task.map { .lastCheck($0.id) }
        case "extend": task.map { .extend($0.id) }
        case "guardian": .guardian
        case "log": .log
        case "auditor": .auditor
        case "blackbaud": .blackbaud
        case "teams": .teams
        default: nil
        }
        return (parts[0], sheet, task)
    }

    /// Testing aid, only with `TAXCOLLECTOR_TEST_LAST_CHECK=<part of a task title>`: opens that task's
    /// last check, then does what your clicks would (tick every item, confirm) with pauses for screenshots.
    private func runLastCheckTest(titleContaining target: String) {
        guard let task = model.tasks.first(where: { $0.title.localizedCaseInsensitiveContains(target) && $0.needsLastCheck })
        else {
            model.store.log("TEST no paid Blackbaud task matching \"\(target)\" needs a last check")
            return
        }
        model.store.log("TEST last check for \"\(task.title)\"")
        showMain()
        router.mainSheet = .lastCheck(task.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            for item in self.model.task(task.id)?.checklist ?? [] {
                self.model.setChecklistItem(task.id, item: item.id, done: true)
            }
            self.model.store.log("TEST ticked every item")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.model.confirmLastCheck(task.id)
                self?.model.store.log("TEST pressed I've done all of this")
            }
        }
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
        if CommandLine.arguments.contains("--launchd") || CommandLine.arguments.contains("--finish-setup") {
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
            let overdue = model.lock.overdue.map { Agenda.courseAndTitle($0).title }
            if overdue.isEmpty {
                notify("Late penalty", "Your proof was late, so the Mac stays locked a little longer.")
            } else {
                notify("Your Mac is locked", "Overdue: \(overdue.joined(separator: ", ")). Other apps will close until you submit proof.")
            }
        } else {
            lockWindow?.close()
            lockWindow = nil
            router.lockSheet = nil
            if model.lock.overrideUntil == nil {
                showBanner("Unlocked.")
                notify("Unlocked", "Everything is open again.")
            } else {
                showBanner("Unlocked by your guardian until \(Fmt.time.string(from: model.lock.overrideUntil!)).")
            }
        }
        refreshStatusItem()
    }

    private func warn(_ task: TaxTask, remaining: TimeInterval) {
        let left = Fmt.span(remaining)
        let name = Agenda.courseAndTitle(task).title
        if remaining <= 5 * 60 {
            notify("Locking in \(left)", "“\(name)” has no proof yet. Save your work in other apps.")
            showBanner("Locking in \(left) unless “\(name)” has proof. Save your work.")
        } else {
            notify("“\(name)” is due in \(left)", "Submit proof before then to keep your Mac unlocked.")
        }
    }

    // MARK: Windows

    func showMain() {
        if mainWindow == nil {
            let view = MainView(openLockWindow: { [weak self] in self?.showLockWindow() })
            mainWindow = makeWindow(title: "Tax Collector", size: NSSize(width: 680, height: 620),
                                    closable: true, toolbar: true, content: view)
            if !isTestCopy { mainWindow?.setFrameAutosaveName("TaxCollectorMain") }
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// One window per assignment, so you can keep its instructions open while you work.
    func openDetails(_ taskID: UUID) {
        guard let task = model.task(taskID) else { return }
        let window = detailWindows[taskID] ?? makeWindow(
            title: Agenda.courseAndTitle(task).title, size: NSSize(width: 620, height: 660), closable: true, toolbar: false,
            content: AssignmentDetailView(taskID: taskID))
        detailWindows[taskID] = window
        model.loadDetails(taskID)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func showLockWindow() {
        guard model.lock.isLocked, !isSelfTest else { return }
        if lockWindow == nil {
            lockWindow = makeWindow(title: "Tax Collector — Locked", size: NSSize(width: 620, height: 520),
                                    closable: false, toolbar: false, content: LockScreenView())
        }
        lockWindow?.deminiaturize(nil)
        NSApp.activate()
        lockWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, closable: Bool, toolbar: Bool, content: V) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .miniaturizable, .resizable]
        if closable { style.insert(.closable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content.environment(model).environment(router).environment(parentLink))
        if toolbar {
            // Let the SwiftUI toolbar and title become the window's own.
            hosting.sceneBridgingOptions = [.toolbars, .title]
            window.toolbarStyle = .unified
        }
        window.contentView = hosting
        window.center()
        return window
    }

    /// A short message at the top of the screen that doesn't take focus.
    private func showBanner(_ text: String) {
        guard !isSelfTest else { return }
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
            menu.addItem(item("Submit Proof…", #selector(menuPayUp)))
        }
        menu.addItem(item("Open Tax Collector", #selector(menuOpen), key: "o"))
        menu.addItem(item("New Task…", #selector(menuNewTask), key: "n"))
        menu.addItem(.separator())
        menu.addItem(item("Blackbaud…", #selector(menuBlackbaud)))
        menu.addItem(item("Teams…", #selector(menuTeams)))
        menu.addItem(item("Guardian…", #selector(menuGuardian)))
        menu.addItem(item("Activity Log…", #selector(menuLog)))
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        let current = Theme.appearanceName(model.settings.appearance)
        for (title, value) in [("Light", "light"), ("Dark", "dark"), ("Match System", "system")] {
            let choice = item(title, #selector(menuAppearance(_:)))
            choice.representedObject = value
            choice.state = current == value ? .on : .off
            choices.addItem(choice)
        }
        appearance.submenu = choices
        menu.addItem(appearance)
        if canQuitFreely {
            menu.addItem(.separator())
            menu.addItem(item("Quit (test mode)", #selector(menuQuit), key: "q"))
        }
    }

    private func headerText() -> String {
        if model.lock.isLocked {
            if !model.lock.overdue.isEmpty { return "Locked: \(model.lock.overdue.count) overdue" }
            if let end = model.lock.penaltyEndsAt { return "Late penalty: unlocks at \(Fmt.time.string(from: end))" }
        }
        if let until = model.lock.overrideUntil { return "Unlocked by your guardian until \(Fmt.time.string(from: until))" }
        if let next = model.nextDue { return "Next: \(Agenda.courseAndTitle(next).title), due \(Fmt.relative(next.dueDate, now: model.now))" }
        return "Nothing due"
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
    @objc private func menuBlackbaud() {
        showMain()
        router.mainSheet = .blackbaud
    }
    @objc private func menuTeams() {
        showMain()
        router.mainSheet = .teams
    }
    @objc private func menuLog() {
        showMain()
        router.mainSheet = .log
    }
    @objc private func menuAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        model.setAppearance(value)
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
        guard notificationsAllowed, !isSelfTest else { return }
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
