import AppKit
import Observation
import TaxCore

enum GuardianCheck: Equatable {
    case ok
    case wrong
    case coolingDown(until: Date)
}

/// An assignment's page from Blackbaud, as far as it has loaded.
enum DetailsState: Equatable {
    case loading
    case loaded(AssignmentDetails)
    case failed(String, signedOut: Bool)
}

/// What's left before Tax Collector can lock anything.
enum SetupNeed: Equatable {
    case moveToApplications
    case runInBackground
}

enum EditResult {
    case saved
    case needsGuardian
}

/// What checking a pasted feed link found, before anything is imported.
enum FeedCheck {
    case ok(url: URL, upcoming: [BlackbaudAssignment], total: Int)
    case bad(String)
}

@MainActor
@Observable
final class AppModel {
    nonisolated static let label = "io.github.mrpythoneer.taxcollector"
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
    var blackbaud: BlackbaudState
    /// Tasks that come back every week.
    var recurring: [RecurringTask]
    var feedSyncing = false
    var feedError: String?
    var blackbaudSignedIn = false
    var setupNeed: SetupNeed?
    var details: [UUID: DetailsState] = [:]
    /// Attachments being downloaded, by attachment id.
    var downloading: Set<String> = []
    var setupError: String?

    @ObservationIgnored let enforcer: Enforcer
    @ObservationIgnored var onLockChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onWarning: (TaxTask, TimeInterval) -> Void = { _, _ in }
    @ObservationIgnored var onClosedApp: (String) -> Void = { _ in }
    @ObservationIgnored var onPaid: (TaxTask) -> Void = { _ in }
    @ObservationIgnored var onImported: ([TaxTask]) -> Void = { _ in }
    /// A repeating task's new copy just appeared.
    @ObservationIgnored var onRecurred: (TaxTask) -> Void = { _ in }
    /// A setting parents can also change was changed here, so a phone's older change mustn't win over it.
    @ObservationIgnored var onLocalSetting: (String) -> Void = { _ in }
    /// Something a parent's phone did, worth a notification on this computer.
    @ObservationIgnored var onParentAction: (String) -> Void = { _ in }
    /// While a phone is linked, setting a new guardian code needs a parent's go-ahead until this time.
    var guardianSetupAllowedUntil: Date?
    /// Apps seen running lately, for parents to pick from when blocking: bundle ID → (name, last seen).
    @ObservationIgnored var recentApps: [String: (name: String, seen: Date)] = [:]
    /// Opens the Blackbaud sign-in window.
    @ObservationIgnored var onBlackbaudSignIn: () -> Void = {}
    /// Moves the app into Applications if needed, then sets it to run in the background.
    @ObservationIgnored var onFinishSetup: () -> Void = {}
    @ObservationIgnored var onOpenDetails: (UUID) -> Void = { _ in }
    @ObservationIgnored var blackbaudDetails: (TaxTask) async -> Result<AssignmentDetails, BlackbaudLink.Failure> = { _ in
        .failure(.init(message: "Blackbaud isn't connected."))
    }
    @ObservationIgnored var blackbaudDownload: (URL) async -> Result<Data, BlackbaudLink.Failure> = { _ in
        .failure(.init(message: "Blackbaud isn't connected."))
    }
    @ObservationIgnored var onBlackbaudSignOut: () -> Void = {}
    /// Marks an assignment Completed in Blackbaud. Returns nil on success, or why it failed.
    @ObservationIgnored var blackbaudMarker: (TaxTask) async -> String? = { _ in "Blackbaud isn't connected." }
    @ObservationIgnored var allowQuit = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var warned: [UUID: Set<Int>] = [:]
    @ObservationIgnored private var lastClockSave = Date.distantPast
    @ObservationIgnored private var lastUptime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var wasLocked = false
    @ObservationIgnored private var lastFeedAttempt: Date?

    var tokenFile: URL { store.dir.appendingPathComponent("claude-token") }
    var selfBundleID: String? { Bundle.main.bundleIdentifier }

    init(store: Store, dryRun: Bool) {
        self.store = store
        self.dryRun = dryRun
        tasks = store.loadTasks()
        settings = store.loadSettings()
        guardian = store.loadGuardian()
        blackbaud = store.loadBlackbaud()
        recurring = store.loadRecurring()
        enforcer = Enforcer(dryRun: dryRun)
        now = LockPolicy.effectiveNow(systemNow: Date(), lastSeen: settings.lastSeen)

        // A check that was running when the app died can't be left hanging, or it would hold off the lock forever.
        var interrupted = false
        for t in tasks.indices {
            for p in tasks[t].proofs.indices where tasks[t].proofs[p].verdict == nil {
                tasks[t].proofs[p].verdict = .error
                tasks[t].proofs[p].reason = "The check was interrupted. Try again."
                interrupted = true
            }
        }
        if interrupted { store.saveTasks(tasks) }

        // Same for a request for more time that was waiting on Claude.
        for t in tasks.indices {
            for e in (tasks[t].extensions ?? []).indices where tasks[t].extensions?[e].decision == nil {
                tasks[t].extensions?[e].decision = .error
                tasks[t].extensions?[e].answer = "The request was interrupted. You can ask again."
                interrupted = true
            }
        }
        if interrupted { store.saveTasks(tasks) }

        // Older versions imported a second copy of everything whenever Blackbaud changed its UIDs.
        let merged = Blackbaud.mergeDuplicates(tasks, state: blackbaud)
        if !merged.removed.isEmpty {
            tasks = merged.tasks
            store.saveTasks(tasks)
            store.log("FEED merged \(merged.removed.count) duplicate imported task(s)")
        }

        enforcer.shouldClose = { [weak self] id in
            guard let self else { return false }
            return Allowlist.shouldClose(bundleID: id, locked: self.lock.isLocked, strength: self.lock.strength,
                                         extra: self.settings.extraAllowedBundleIDs,
                                         blocked: self.settings.blockedApps.map(\.id), selfID: self.selfBundleID)
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

        bringBackRepeats()
        // A parent's lock that has run out is gone, not just inactive.
        if let parentLock = settings.parentLock, !parentLock.isActive(at: now) {
            settings.parentLock = nil
            store.saveSettings(settings)
            store.log("PARENT lock by \(parentLock.by) ended")
        }
        lock = LockPolicy.state(tasks: tasks, overrideUntil: settings.overrideUntil, parentLock: settings.parentLock, now: now)
        if lock.isLocked != wasLocked {
            wasLocked = lock.isLocked
            lockChanged()
        }
        updateEnforcer()
        checkWarnings()
        pollFeedIfDue()
    }

    private func lockChanged() {
        if lock.isLocked {
            closedApps.removeAll()
            if let parentLock = lock.parentLock {
                store.log("LOCK ON — locked by \(parentLock.by)")
            } else {
                let due = (lock.overdue + lock.penalties).map(\.title).joined(separator: ", ")
                store.log("LOCK ON — overdue: \(due)")
            }
        } else {
            store.log(lock.overrideUntil != nil ? "LOCK OFF — unlocked" : "LOCK OFF — nothing owed")
        }
        updateEnforcer()
        onLockChange(lock.isLocked)
    }

    /// The enforcer runs during a lock, and whenever a parent has blocked an app.
    func updateEnforcer() {
        let needed = lock.isLocked || !settings.blockedApps.isEmpty
        if needed && !enforcer.isActive { enforcer.activate() }
        if !needed && enforcer.isActive { enforcer.deactivate() }
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

    /// A task that comes back every `interval` days, or every `interval` weeks on `weekdays`, at `minuteOfDay`,
    /// starting on `startDate`. The first copy appears now.
    func addRecurring(title: String, details: String, unit: RepeatUnit = .weeks, interval: Int = 1,
                      weekdays: Set<Int>, minuteOfDay: Int, startDate: Date? = nil) {
        let series = RecurringTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                   details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                                   unit: unit, interval: interval, weekdays: unit == .weeks ? weekdays : [],
                                   minuteOfDay: minuteOfDay, startDate: startDate ?? now, createdAt: now)
        recurring.append(series)
        store.saveRecurring(recurring)
        store.log("REPEAT added \"\(series.title)\": \(series.schedule())")
        tick()
    }

    /// No more copies. The ones already out stay, with the usual rules.
    func stopRepeating(_ seriesID: UUID) {
        guard let i = recurring.firstIndex(where: { $0.id == seriesID }) else { return }
        let series = recurring.remove(at: i)
        store.saveRecurring(recurring)
        store.log("REPEAT stopped \"\(series.title)\"")
    }

    func series(of task: TaxTask) -> RecurringTask? {
        task.seriesID.flatMap { id in recurring.first { $0.id == id } }
    }

    /// Puts out the next copy of each repeating task whose current copy's deadline has passed.
    private func bringBackRepeats() {
        guard !recurring.isEmpty else { return }
        let brandNew = Set(recurring.filter { $0.currentDue == nil }.map(\.id))
        let (copies, updated) = Recurrence.newCopies(of: recurring, now: now)
        guard !copies.isEmpty else { return }
        recurring = updated
        tasks.append(contentsOf: copies)
        store.saveRecurring(recurring)
        save()
        for copy in copies {
            store.log("TASK repeated \"\(copy.title)\" due \(copy.dueDate)")
            // You just made the first one, so only later weeks get a notification.
            if let id = copy.seriesID, !brandNew.contains(id) { onRecurred(copy) }
        }
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
        if case let .blackbaud(uid) = t.source {
            blackbaud.dismiss(uid: uid, title: t.title, due: t.dueDate)
            store.saveBlackbaud(blackbaud)
        }
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
        tasks[ti].proofs[si].recheckedAt = now
        save()
        runCheck(taskID: taskID, submissionID: submissionID)
    }

    /// Takes a proof back while Claude is still checking it. It counts for nothing: the task is still due,
    /// and if the deadline has passed it's overdue right away. A first check is withdrawn completely, so you
    /// can send something else; a re-check goes back to "couldn't check".
    func cancelCheck(taskID: UUID, submissionID: UUID) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskID }),
              let si = tasks[ti].proofs.firstIndex(where: { $0.id == submissionID }),
              tasks[ti].proofs[si].verdict == nil else { return }
        ProofVerifier.cancel(submissionID)
        checking.remove(submissionID)
        if tasks[ti].proofs[si].recheckedAt != nil {
            tasks[ti].proofs[si].verdict = .error
            tasks[ti].proofs[si].reason = "You cancelled the check."
        } else {
            tasks[ti].proofs.remove(at: si)
            try? FileManager.default.removeItem(at: store.proofFolder(task: taskID, submission: submissionID))
        }
        save()
        store.log("PROOF cancelled for \"\(tasks[ti].title)\" before Claude answered")
        tick()
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
            // Cancelled, or approved by the guardian while Claude was busy: its answer doesn't count any more.
            guard let proof = self.task(taskID)?.proofs.first(where: { $0.id == submissionID }), proof.verdict == nil else {
                return
            }
            self.record(verdict: outcome.verdict, reason: outcome.reason, checklist: outcome.checklist,
                        taskID: taskID, submissionID: submissionID)
        }
    }

    func record(verdict: Verdict, reason: String, checklist: [String] = [], taskID: UUID, submissionID: UUID) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskID }),
              let si = tasks[ti].proofs.firstIndex(where: { $0.id == submissionID }) else { return }
        tasks[ti].proofs[si].verdict = verdict
        tasks[ti].proofs[si].reason = reason
        let accepted = verdict == .accepted || verdict == .guardianApproved
        // Keep the first checklist: you may already have ticked some of it.
        if tasks[ti].checklist == nil {
            let items = checklist.isEmpty && accepted
                ? Auditor.fallbackChecklist(title: tasks[ti].title, details: tasks[ti].details)
                : checklist
            if !items.isEmpty { tasks[ti].checklist = items.map { ChecklistItem(text: $0) } }
        }
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

    // MARK: Blackbaud

    var feedURL: URL? { settings.blackbaudURL.flatMap(Blackbaud.feedURL(from:)) }
    var feedIsOn: Bool { settings.blackbaudURL != nil }
    var importedCount: Int {
        tasks.filter { if case .blackbaud = $0.source { true } else { false } }.count
    }
    var canStopFeedFreely: Bool {
        LockPolicy.canStopFeedWithoutGuardian(onSince: settings.blackbaudOnSince, tasks: tasks, now: now)
    }

    /// Fetches a pasted link and shows what it would import, without importing anything.
    func checkFeed(_ raw: String) async -> FeedCheck {
        guard let url = Blackbaud.feedURL(from: raw) else {
            return .bad("That doesn't look like a feed link. It should start with webcal:// or https://.")
        }
        switch await FeedFetcher.fetch(url) {
        case let .failed(message):
            return .bad(message)
        case let .events(events):
            let items = Blackbaud.assignments(from: events, allDayDueMinutes: settings.allDayDueMinutes)
            let wouldAdd = Set(Blackbaud.sync(tasks: tasks, state: blackbaud, assignments: items, now: now).added.map(\.title))
            let upcoming = items.filter { wouldAdd.contains($0.title) }.sorted { $0.dueDate < $1.dueDate }
            return .ok(url: url, upcoming: upcoming, total: events.count)
        }
    }

    /// Makes things stricter, so it never needs the guardian.
    func startFeed(_ url: URL) {
        settings.blackbaudURL = url.absoluteString
        settings.blackbaudOnSince = now
        store.saveSettings(settings)
        store.log("FEED on: \(Blackbaud.redacted(url))")
        feedError = nil
        lastFeedAttempt = nil
        syncFeed()
    }

    func stopFeed(guardianApproved: Bool = false) -> EditResult {
        guard feedIsOn else { return .saved }
        if !guardianApproved && !canStopFeedFreely { return .needsGuardian }
        let shown = feedURL.map(Blackbaud.redacted) ?? "feed"
        settings.blackbaudURL = nil
        settings.blackbaudOnSince = nil
        store.saveSettings(settings)
        feedError = nil
        store.log("FEED off: \(shown)\(guardianApproved ? " (guardian)" : ""). Imported tasks stay.")
        return .saved
    }

    /// No guardian needed: earlier is stricter, and a later time only moves tasks that aren't locked in.
    func setAllDayDue(minutes: Int) {
        guard minutes != settings.allDayDueMinutes else { return }
        settings.allDayDueMinutes = minutes
        store.saveSettings(settings)
        store.log("FEED all-day assignments now due \(minutes) min after midnight on their date")
        lastFeedAttempt = nil
    }

    func syncFeed() {
        guard let url = feedURL, !feedSyncing else {
            if feedIsOn && feedURL == nil { feedError = "The saved feed link can't be read. Turn import off and add it again." }
            return
        }
        feedSyncing = true
        lastFeedAttempt = Date()
        Task {
            let outcome = await FeedFetcher.fetch(url)
            self.feedSyncing = false
            // Import may have been turned off, or pointed somewhere else, while this was in flight.
            guard self.feedURL == url else { return }
            switch outcome {
            case let .events(events):
                self.importFeed(events)
            case let .failed(message):
                if self.feedError != message { self.store.log("FEED failed (\(Blackbaud.redacted(url))): \(message)") }
                self.feedError = message
            }
        }
    }

    private func pollFeedIfDue() {
        guard feedURL != nil, !feedSyncing else { return }
        let wait = feedError == nil ? Blackbaud.pollInterval : Blackbaud.retryInterval
        // abs(): a clock wound back shouldn't stop the polling.
        if let last = lastFeedAttempt, abs(Date().timeIntervalSince(last)) < wait { return }
        syncFeed()
    }

    private func importFeed(_ events: [ICalEvent]) {
        let items = Blackbaud.assignments(from: events, allDayDueMinutes: settings.allDayDueMinutes)
        let result = Blackbaud.sync(tasks: tasks, state: blackbaud, assignments: items, now: now)
        let merged = Blackbaud.mergeDuplicates(result.tasks, state: result.state)
        if !merged.removed.isEmpty { store.log("FEED merged \(merged.removed.count) duplicate imported task(s)") }
        tasks = merged.tasks
        blackbaud = result.state
        blackbaud.lastSync = now
        feedError = nil
        save()
        store.saveBlackbaud(blackbaud)
        for t in result.added { store.log("FEED imported \"\(t.title)\" due \(t.dueDate)") }
        for note in result.notes { store.log("FEED \(note)") }
        if !result.added.isEmpty { onImported(result.added) }
        tick()
    }

    // MARK: Assignment details

    /// Loads an imported assignment's page from Blackbaud (once, unless `force`).
    func loadDetails(_ taskID: UUID, force: Bool = false) {
        guard let task = task(taskID), task.isFromBlackbaud, feedURL != nil else { return }
        switch details[taskID] {
        case .loading: return
        case .loaded where !force: return
        default: break
        }
        details[taskID] = .loading
        Task {
            switch await self.blackbaudDetails(task) {
            case let .success(page): self.details[taskID] = .loaded(page)
            case let .failure(problem): self.details[taskID] = .failed(problem.message, signedOut: problem.signedOut)
            }
        }
    }

    /// After signing in, reload the pages that failed because you were signed out.
    func retrySignedOutDetails() {
        for (id, state) in details {
            if case .failed(_, signedOut: true) = state { loadDetails(id, force: true) }
        }
    }

    /// Files on the school's site download with your Blackbaud sign-in into your Downloads folder, then open
    /// in their usual app. Anything else, or a file that won't download, opens in the browser.
    func openAttachment(_ file: AssignmentDetails.Attachment, taskID: UUID) {
        guard let host = feedURL?.host, AssignmentDetailsParser.isOnSchoolSite(file.url, host: host) else {
            open(file.url)
            return
        }
        downloading.insert(file.id)
        Task {
            let result = await self.blackbaudDownload(file.url)
            self.downloading.remove(file.id)
            switch result {
            case let .success(data):
                do {
                    self.open(try self.saveDownload(data, named: file.fileName, from: file.url))
                } catch {
                    self.store.log("ATTACHMENT couldn't save \(file.fileName): \(error.localizedDescription)")
                    self.open(file.url)
                }
            case let .failure(problem):
                self.store.log("ATTACHMENT couldn't download \(file.fileName): \(problem.message)")
                self.open(file.url)
            }
        }
    }

    /// Saves like a browser would: into Downloads, as "Name 2.pdf" if "Name.pdf" is already there with
    /// something else in it. Opening the same file again reuses the copy already there.
    func saveDownload(_ data: Data, named raw: String, from source: URL, into folder: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let folder = folder ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? store.dir
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "Attachment" }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...50 {
            let candidate = folder.appendingPathComponent(n == 1 ? name : "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if fm.contents(atPath: candidate.path) == data { return candidate }
            guard !fm.fileExists(atPath: candidate.path) else { continue }
            try data.write(to: candidate, options: .withoutOverwriting)
            // Marked as downloaded from the web, like a browser marks its downloads.
            var values = URLResourceValues()
            values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                                           kLSQuarantineDataURLKey as String: source,
                                           kLSQuarantineAgentNameKey as String: "Tax Collector"]
            var saved = candidate
            try? saved.setResourceValues(values)
            return candidate
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Opens a file or web link. During a lock, apps that aren't allowed get closed, so anything that would
    /// open in one (Preview, another browser) opens in Arc instead. Office files open in Office, which is allowed.
    func open(_ url: URL) {
        let workspace = NSWorkspace.shared
        if lock.isLocked,
           let app = workspace.urlForApplication(toOpen: url),
           let id = Bundle(url: app)?.bundleIdentifier,
           !Allowlist.isAllowed(bundleID: id, extra: settings.extraAllowedBundleIDs, selfID: selfBundleID),
           let arc = workspace.urlForApplication(withBundleIdentifier: "company.thebrowser.Browser") {
            workspace.open([url], withApplicationAt: arc, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(url)
        }
    }

    // MARK: More time

    var trackRecord: TrackRecord { TrackRecord.of(tasks, now: now) }

    /// nil when you can ask for more time on this task.
    func extensionWhyNot(_ task: TaxTask) -> String? {
        ExtensionPolicy.whyNot(task: task, record: trackRecord, enabled: settings.extensionsEnabled, now: now)
    }

    /// Asks Claude for up to 12 more hours. The limits are checked here, whatever Claude says.
    func requestExtension(taskID: UUID, hours: Int, reason: String) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let task = tasks[i]
        if let why = extensionWhyNot(task) {
            store.log("EXTENSION refused for \"\(task.title)\": \(why)")
            return
        }
        let asked = max(1, min(hours, ExtensionPolicy.maxHours))
        let record = trackRecord
        let request = Extension(requestedAt: now, hoursAsked: asked, reason: reason, previousDue: task.dueDate)
        tasks[i].extensions = (tasks[i].extensions ?? []) + [request]
        save()
        store.log("EXTENSION asked for \(asked)h on \"\(task.title)\"")
        let folder = store.dir.appendingPathComponent("extensions/\(task.id.uuidString)/\(request.id.uuidString)", isDirectory: true)
        let settings = self.settings
        let tokenFile = self.tokenFile
        Task {
            let (decision, granted, answer) = await ProofVerifier.decideExtension(
                task: task, hours: asked, reason: reason, record: record, folder: folder, settings: settings, tokenFile: tokenFile)
            self.recordExtension(taskID: taskID, requestID: request.id, decision: decision, granted: granted, answer: answer)
        }
    }

    private func recordExtension(taskID: UUID, requestID: UUID, decision: ExtensionDecision, granted: Int, answer: String) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }),
              let e = tasks[i].extensions?.firstIndex(where: { $0.id == requestID }),
              let request = tasks[i].extensions?[e] else { return }
        let hours = decision == .granted ? ExtensionPolicy.clampedHours(granted: granted, asked: request.hoursAsked) : 0
        tasks[i].extensions?[e].decision = hours > 0 ? .granted : (decision == .error ? .error : .denied)
        tasks[i].extensions?[e].hoursGranted = hours
        tasks[i].extensions?[e].answer = answer
        if hours > 0 && tasks[i].isPending {
            // Always from the deadline it had when you asked, so extensions can't stack.
            tasks[i].dueDate = request.previousDue.addingTimeInterval(TimeInterval(hours) * 3600)
            warned[taskID] = nil
        }
        save()
        let word = hours > 0 ? "granted \(hours)h" : (decision == .error ? "couldn't be decided" : "denied")
        store.log("EXTENSION \(word) for \"\(tasks[i].title)\": \(answer)")
        tick()
    }

    func latestExtension(_ taskID: UUID) -> Extension? { task(taskID)?.extensions?.last }

    func setExtensionsEnabled(_ enabled: Bool) {
        settings.extensionsEnabled = enabled
        store.saveSettings(settings)
        store.log("GUARDIAN turned requests for more time \(enabled ? "on" : "off")")
    }

    // MARK: Appearance

    func setAppearance(_ appearance: String) {
        settings.appearance = appearance
        store.saveSettings(settings)
        Theme.apply(appearance)
    }

    // MARK: Last check

    func setChecklistItem(_ taskID: UUID, item: UUID, done: Bool) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[ti].lastCheckDoneAt == nil,
              let ci = tasks[ti].checklist?.firstIndex(where: { $0.id == item }) else { return }
        tasks[ti].checklist?[ci].done = done
        save()
    }

    /// Only after proof is accepted and every item is ticked. Then Blackbaud gets marked.
    func confirmLastCheck(_ taskID: UUID) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskID }), tasks[ti].needsLastCheck,
              let items = tasks[ti].checklist, !items.isEmpty, items.allSatisfy(\.done) else { return }
        tasks[ti].lastCheckDoneAt = now
        save()
        store.log("LAST CHECK confirmed for \"\(tasks[ti].title)\" (\(items.count) items)")
        markInBlackbaud(taskID)
    }

    func markInBlackbaud(_ taskID: UUID) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskID }), tasks[ti].isFromBlackbaud,
              tasks[ti].lastCheckDoneAt != nil, tasks[ti].blackbaudMark != .working else { return }
        if case .done = tasks[ti].blackbaudMark { return }
        tasks[ti].blackbaudMark = .working
        save()
        let task = tasks[ti]
        Task {
            let failure = await self.blackbaudMarker(task)
            guard let i = self.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            if let failure {
                self.tasks[i].blackbaudMark = .failed(reason: failure)
                self.store.log("BLACKBAUD couldn't mark \"\(task.title)\" Completed: \(failure)")
            } else {
                self.tasks[i].blackbaudMark = .done(at: self.now)
                self.store.log("BLACKBAUD marked \"\(task.title)\" Completed")
            }
            self.save()
        }
    }

    // MARK: Guardian

    func setupGuardian(code: String) {
        let record = Guardian.makeRecord(code: code, now: now)
        guardian = record
        store.saveGuardian(record)
        store.log("GUARDIAN code set")
        onLocalSetting("guardian")
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
        unlock(until: now.addingTimeInterval(hours * 3600), by: Self.guardianName)
    }

    func endUnlock() {
        backToNormal(by: Self.guardianName)
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
        ProofVerifier.cancel(sid)
        checking.remove(sid)
        record(verdict: .guardianApproved, reason: "Approved by your guardian.", taskID: id, submissionID: sid)
    }

    func setPenalty(minutes: Int) {
        settings.penaltyMinutes = max(0, minutes)
        store.saveSettings(settings)
        store.log("GUARDIAN set the late penalty to \(settings.penaltyMinutes) min")
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
        enforcer.deactivate()
        allowQuit = true
        // Into the Trash first: removing the background copy ends this process.
        if BackgroundAgent.isInApplicationsFolder {
            try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        }
        BackgroundAgent.remove()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    func save() { store.saveTasks(tasks) }
}
