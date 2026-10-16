import AppKit

/// While active, closes every Dock app that isn't allowed.
@MainActor
final class Enforcer {
    /// Graceful quit first; force-quit if the app is still around after this long.
    static let forceAfter: TimeInterval = 10

    private(set) var isActive = false
    let dryRun: Bool
    var isAllowed: (String?) -> Bool = { _ in true }
    /// Testing aid: when set, only these apps are ever closed, so a real lock can be tested
    /// without closing anything else you have open.
    var onlyTargets: Set<String>?
    var onClosed: (String) -> Void = { _ in }
    var log: (String) -> Void = { _ in }

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var askedToQuit: [pid_t: Date] = [:]
    private var dryRunSeen: Set<pid_t> = []

    init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        sweep()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        askedToQuit.removeAll()
        dryRunSeen.removeAll()
    }

    func sweep() {
        guard isActive else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        let live = Set(running.map(\.processIdentifier))
        askedToQuit = askedToQuit.filter { live.contains($0.key) }

        for app in running where app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != me {
            if isAllowed(app.bundleIdentifier) { continue }
            if let onlyTargets, !onlyTargets.contains(app.bundleIdentifier ?? "") { continue }
            collect(app)
        }
    }

    private func collect(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        let id = app.bundleIdentifier ?? "no bundle ID"

        if dryRun {
            if dryRunSeen.insert(pid).inserted {
                log("DRY RUN would close \(name) (\(id))")
                onClosed(name)
            }
            return
        }

        if let asked = askedToQuit[pid] {
            if Date().timeIntervalSince(asked) >= Self.forceAfter {
                if app.forceTerminate() { log("FORCE-CLOSED \(name) (\(id))") }
            }
        } else {
            askedToQuit[pid] = Date()
            app.hide()
            app.terminate()
            log("CLOSED \(name) (\(id))")
            onClosed(name)
        }
    }
}
