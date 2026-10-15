import AppKit
import Observation
import TaxCore

enum GuardianCheck: Equatable {
    case ok
    case wrong
    case coolingDown(until: Date)
}

enum EditResult {
    case saved
    case needsGuardian
}

@MainActor
@Observable
final class AppModel {
    static let label = "io.github.mrpythoneer.taxcollector"
    static let warningMarks: [TimeInterval] = [24 * 3600, 3600, 15 * 60, 5 * 60]

    let store: Store
    let dryRun: Bool
    var tasks: [TaxTask]
    var settings: Settings
    var guardian: GuardianRecord?
    var now = Date()
    var lock = LockState()
    /// Names of apps closed during the current lock, newest first.
    var closedApps: [String] = []
    var checking: Set<UUID> = []
    var auditorStatus = "Checking…"

    @ObservationIgnored let enforcer: Enforcer
    @ObservationIgnored var onLockChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onWarning: (TaxTask, TimeInterval) -> Void = { _, _ in }
    @ObservationIgnored var onClosedApp: (String) -> Void = { _ in }
    @ObservationIgnored var onPaid: (TaxTask) -> Void = { _ in }
    @ObservationIgnored var allowQuit = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var warned: [UUID: Set<Int>] = [:]
    @ObservationIgnored private var lastClockSave = Date.distantPast
    @ObservationIgnored private var lastUptime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var wasLocked = false

    var tokenFile: URL { store.dir.appendingPathComponent("claude-token") }
    var selfBundleID: String? { Bundle.main.bundleIdentifier }

    init(store: Store, dryRun: Bool) {
        self.store = store
        self.dryRun = dryRun
        tasks = store.loadTasks()
        settings = store.loadSettings()
        guardian = store.loadGuardian()
        enforcer = Enforcer(dryRun: dryRun)
        now = LockPolicy.effectiveNow(systemNow: Date(), lastSeen: settings.lastSeen)

        // A check that was running when the app died can't be left hanging, or it would hold off the lock forever.
        var interrupted = false
        for t in tasks.indices {
            for p in tasks[t].proofs.indices where tasks[t].proofs[p].verdict == nil {
                tasks[t].proofs[p].verdict = .error
                tasks[t].proofs[p].reason = "The check was interrupted. Send it again."
                interrupted = true
            }
        }
        if interrupted { store.saveTasks(tasks) }

        enforcer.isAllowed = { [weak self] id in
            guard let self else { return true }
            return Allowlist.isAllowed(bundleID: id, extra: self.settings.extraAllowedBundleIDs, selfID: self.selfBundleID)
        }
        enforcer.log = { [weak self] in self?.store.log($0) }
        enforcer.onClosed = { [weak self] name in
            guard let self else { return }
            self.closedApps.removeAll { $0 == name }
            self.closedApps.insert(name, at: 0)
            self.onClosedApp(name)
        }
    }

    func start() {
        store.log("START\(dryRun ? " (dry run)" : "") pid \(ProcessInfo.processInfo.processIdentifier)")
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshAuditorStatus()
    }

    // MARK: Clock and lock

    func tick() {
        // Advance by monotonic uptime too, so winding the clock back mid-session doesn't stall deadlines.
        let uptime = ProcessInfo.processInfo.systemUptime
        let advanced = now.addingTimeInterval(max(0, uptime - lastUptime))
        lastUptime = uptime
        let floor = max(advanced, settings.lastSeen ?? .distantPast)
        now = LockPolicy.effectiveNow(systemNow: Date(), lastSeen: floor)

        if now.timeIntervalSince(lastClockSave) >= 30 {
            settings.lastSeen = now
            store.saveSettings(settings)
            lastClockSave = now
        }

        lock = LockPolicy.state(tasks: tasks, overrideUntil: settings.overrideUntil, now: now)
        if lock.isLocked != wasLocked {
            wasLocked = lock.isLocked
            lockChanged()
        }
        checkWarnings()
    }

    private func lockChanged() {
        if lock.isLocked {
            closedApps.removeAll()
            let owed = (lock.overdue + lock.penalties).map(\.title).joined(separator: ", ")
            store.log("LOCK ON — owed: \(owed)")
            enforcer.activate()
        } else {
            store.log(lock.overrideUntil != nil ? "LOCK OFF — guardian unlock" : "LOCK OFF — paid in full")
            enforcer.deactivate()
        }
        onLockChange(lock.isLocked)
    }

    private func checkWarnings() {
        for t in tasks where t.isPending {
            let remaining = t.dueDate.timeIntervalSince(now)
            guard remaining > 0 else { continue }
            let crossed = Self.warningMarks.indices.filter { remaining <= Self.warningMarks[$0] }
            guard let smallest = crossed.last else { continue }
            var done = warned[t.id] ?? []
            guard !done.contains(smallest) else { continue }
            done.formUnion(crossed)
            warned[t.id] = done
            onWarning(t, remaining)
        }
    }

    // MARK: Queries

    var pendingTasks: [TaxTask] {
        tasks.filter { $0.isPending || LockPolicy.isInPenalty($0, now: now) }.sorted { $0.dueDate < $1.dueDate }
    }

    var settledTasks: [TaxTask] {
        tasks.filter { !$0.isPending && !LockPolicy.isInPenalty($0, now: now) }
            .sorted { $0.dueDate > $1.dueDate }
    }

    var nextDue: TaxTask? { tasks.filter(\.isPending).min { $0.dueDate < $1.dueDate } }

    func task(_ id: UUID) -> TaxTask? { tasks.first { $0.id == id } }

    func isFrozen(_ task: TaxTask) -> Bool { LockPolicy.isFrozen(task, now: now) }

    // MARK: Tasks

    func addTask(title: String, details: String, due: Date) {
        let t = TaxTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                        dueDate: due, createdAt: now)
        tasks.append(t)
        save()
        store.log("TASK added \"\(t.title)\" due \(t.dueDate)")
        tick()
    }

    func saveEdit(_ edited: TaxTask, guardianApproved: Bool = false) -> EditResult {
        guard let i = tasks.firstIndex(where: { $0.id == edited.id }) else { return .saved }
        let original = tasks[i]
        if !guardianApproved && !LockPolicy.canEditWithoutGuardian(original: original, edited: edited, now: now) {
            return .needsGuardian
        }
        tasks[i] = edited
        if edited.dueDate != original.dueDate { warned[edited.id] = nil }
        save()
        store.log("TASK edited \"\(edited.title)\" due \(edited.dueDate)\(guardianApproved ? " (guardian)" : "")")
        tick()
        return .saved
    }

    func delete(_ id: UUID, guardianApproved: Bool = false) -> EditResult {
        guard let t = task(id) else { return .saved }
        if !guardianApproved && !LockPolicy.canDeleteWithoutGuardian(t, now: now) { return .needsGuardian }
        tasks.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: store.proofsRoot.appendingPathComponent(id.uuidString))
        save()
        store.log("TASK deleted \"\(t.title)\"\(guardianApproved ? " (guardian)" : "")")
        tick()
        return .saved
    }

    // MARK: Proof

    func submitProof(taskID: UUID, note: String, files: [URL]) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var submission = ProofSubmission(submittedAt: now, note: note, attachments: [])
        let folder = store.proofFolder(task: taskID, submission: submission.id)
        var names: [String] = []
        for (n, file) in files.enumerated() {
            var name = file.lastPathComponent.replacingOccurrences(of: "/", with: "-")
            if names.contains(name) { name = "\(n + 1)-\(name)" }
            do {
                try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
                names.append(name)
            } catch {
                store.log("PROOF could not copy \(file.path): \(error.localizedDescription)")
            }
        }
        submission.attachments = names
        tasks[i].proofs.append(submission)
        save()
        store.log("PROOF sent for \"\(tasks[i].title)\" with \(names.count) file(s)")
        runCheck(taskID: taskID, submissionID: submission.id)
    }

    func recheck(taskID: UUID, submissionID: UUID) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskID }),
              let si = tasks[ti].proofs.firstIndex(where: { $0.id == submissionID }) else { return }
        tasks[ti].proofs[si].verdict = nil
        tasks[ti].proofs[si].reason = ""
        save()
        runCheck(taskID: taskID, submissionID: submissionID)
    }

    private func runCheck(taskID: UUID, submissionID: UUID) {
        guard let t = task(taskID), let submission = t.proofs.first(where: { $0.id == submissionID }) else { return }
        checking.insert(submissionID)
        let folder = store.proofFolder(task: taskID, submission: submissionID)
        let settings = self.settings
        let tokenFile = self.tokenFile
        Task {
            let outcome = await ProofVerifier.verify(task: t, submission: submission, folder: folder,
                                                     settings: settings, tokenFile: tokenFile)
            self.checking.remove(submissionID)
            self.record(verdict: outcome.verdict, reason: outcome.reason, taskID: taskID, submissionID: submissionID)
        }
    }

    private func record(verdict: Verdict, reason: String, taskID: UUID, submissionID: UUID) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskID }),
              let si = tasks[ti].proofs.firstIndex(where: { $0.id == submissionID }) else { return }
        tasks[ti].proofs[si].verdict = verdict
        tasks[ti].proofs[si].reason = reason
        let accepted = verdict == .accepted || verdict == .guardianApproved
        if accepted && tasks[ti].isPending {
            tasks[ti].status = LockPolicy.statusAfterAccepting(
                tasks[ti], submittedAt: tasks[ti].proofs[si].submittedAt, acceptedAt: now,
                penaltyMinutes: settings.penaltyMinutes)
        }
        save()
        store.log("PROOF \(verdict.rawValue) for \"\(tasks[ti].title)\": \(reason)")
        if accepted { onPaid(tasks[ti]) }
        tick()
    }

    func latestProof(_ taskID: UUID) -> ProofSubmission? { task(taskID)?.proofs.last }

    func proofFolder(task: UUID, submission: UUID) -> URL {
        store.proofFolder(task: task, submission: submission)
    }

    func refreshAuditorStatus() {
        let settings = self.settings
        let tokenFile = self.tokenFile
        Task {
            self.auditorStatus = await ProofVerifier.authStatus(settings: settings, tokenFile: tokenFile)
        }
    }

    func saveAuditorToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: tokenFile)
        } else {
            FileManager.default.createFile(atPath: tokenFile.path, contents: Data(trimmed.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
        refreshAuditorStatus()
    }

    var hasAuditorToken: Bool { FileManager.default.fileExists(atPath: tokenFile.path) }

    // MARK: Guardian

    func setupGuardian(code: String) {
        let record = Guardian.makeRecord(code: code, now: now)
        guardian = record
        store.saveGuardian(record)
        store.log("GUARDIAN code set")
    }

    func checkGuardian(_ code: String) -> GuardianCheck {
        if let until = settings.guardianLockedUntil, until > now { return .coolingDown(until: until) }
        guard let record = guardian, Guardian.verify(code: code, record: record) else {
            settings.guardianFailures += 1
            let wait = LockPolicy.guardianCooldown(afterFailures: settings.guardianFailures)
            settings.guardianLockedUntil = wait > 0 ? now.addingTimeInterval(wait) : nil
            store.saveSettings(settings)
            store.log("GUARDIAN wrong code (#\(settings.guardianFailures))")
            if let until = settings.guardianLockedUntil { return .coolingDown(until: until) }
            return .wrong
        }
        settings.guardianFailures = 0
        settings.guardianLockedUntil = nil
        store.saveSettings(settings)
        store.log("GUARDIAN opened the panel")
        return .ok
    }

    func unlock(hours: Double) {
        settings.overrideUntil = now.addingTimeInterval(hours * 3600)
        store.saveSettings(settings)
        store.log("GUARDIAN unlocked for \(hours)h")
        tick()
    }

    func endUnlock() {
        settings.overrideUntil = nil
        store.saveSettings(settings)
        store.log("GUARDIAN ended the unlock")
        tick()
    }

    func excuse(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].status = .excused(at: now)
        save()
        store.log("GUARDIAN excused \"\(tasks[i].title)\"")
        tick()
    }

    func approveLatestProof(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[i].proofs.isEmpty {
            tasks[i].proofs.append(ProofSubmission(submittedAt: now, note: "Approved by guardian", attachments: []))
        }
        let sid = tasks[i].proofs[tasks[i].proofs.count - 1].id
        checking.remove(sid)
        record(verdict: .guardianApproved, reason: "Approved by your guardian.", taskID: id, submissionID: sid)
    }

    func setPenalty(minutes: Int) {
        settings.penaltyMinutes = max(0, minutes)
        store.saveSettings(settings)
        store.log("GUARDIAN set late fee to \(settings.penaltyMinutes) min")
    }

    func allowApp(bundleID: String) {
        guard !settings.extraAllowedBundleIDs.contains(bundleID) else { return }
        settings.extraAllowedBundleIDs.append(bundleID)
        store.saveSettings(settings)
        store.log("GUARDIAN allowed \(bundleID)")
    }

    func disallowApp(bundleID: String) {
        settings.extraAllowedBundleIDs.removeAll { $0 == bundleID }
        store.saveSettings(settings)
        store.log("Removed \(bundleID) from the allowlist")
        enforcer.sweep()
    }

    func changeGuardianCode(_ code: String) {
        setupGuardian(code: code)
        store.log("GUARDIAN changed the code")
    }

    func resetClockGuard() {
        settings.lastSeen = Date()
        now = Date()
        store.saveSettings(settings)
        store.log("GUARDIAN reset the clock guard")
        tick()
    }

    func uninstall() {
        store.log("GUARDIAN uninstalled Tax Collector")
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
        try? FileManager.default.removeItem(at: plist)
        enforcer.deactivate()
        allowQuit = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(Self.label)"]
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func save() { store.saveTasks(tasks) }
}
