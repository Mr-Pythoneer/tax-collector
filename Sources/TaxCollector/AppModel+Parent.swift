import AppKit
import TaxCore

/// What a parent can do, from their phone or with the guardian code here. Every change says who made it.
extension AppModel {
    static let guardianName = "your guardian"

    // MARK: Lock and unlock (one setting: "access")

    /// Locked whatever is due, until `until` or until a parent lifts it.
    func lockByParent(until: Date?, strength: LockStrength, note: String?, by: String) {
        settings.parentLock = ParentLock(until: until, strength: strength, by: by, since: now, note: note)
        settings.overrideUntil = nil
        store.saveSettings(settings)
        let when = until.map { "until \(Fmt.dateTime.string(from: $0))" } ?? "until a parent unlocks it"
        store.log("PARENT \(by) locked this Mac \(when)\(strength == .all ? ", everything closed" : "")")
        if by == Self.guardianName { onLocalSetting("access") }
        tick()
    }

    /// Unlocked until `until`, whatever is overdue. Also lifts a parent lock.
    func unlock(until: Date, by: String) {
        settings.overrideUntil = until
        settings.parentLock = nil
        store.saveSettings(settings)
        store.log("\(by == Self.guardianName ? "GUARDIAN" : "PARENT \(by)") unlocked until \(Fmt.dateTime.string(from: until))")
        if by == Self.guardianName { onLocalSetting("access") }
        tick()
    }

    /// Back to the usual rules: no parent lock, no unlock.
    func backToNormal(by: String) {
        settings.overrideUntil = nil
        settings.parentLock = nil
        store.saveSettings(settings)
        store.log("\(by == Self.guardianName ? "GUARDIAN" : "PARENT \(by)") ended the lock or unlock")
        if by == Self.guardianName { onLocalSetting("access") }
        tick()
    }

    // MARK: Tasks

    /// Adds a task with the ID the phone chose, so sending it twice doesn't add it twice.
    @discardableResult
    func addTask(id: UUID, title: String, details: String, due: Date, by: String) -> Bool {
        guard task(id) == nil else { return false }
        var t = TaxTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        details: details.trimmingCharacters(in: .whitespacesAndNewlines), dueDate: due, createdAt: now)
        t.id = id
        tasks.append(t)
        save()
        store.log("PARENT \(by) added \"\(t.title)\" due \(t.dueDate)")
        tick()
        return true
    }

    /// Approves that exact submission. Its submit time decides whether it was on time.
    func approveProof(taskID: UUID, submissionID: UUID, by: String) -> (String, String) {
        guard let t = task(taskID) else { return ("noop", "That task is gone.") }
        guard t.isPending else { return ("noop", "That task is already settled.") }
        guard t.proofs.contains(where: { $0.id == submissionID }) else { return ("rejected", "not_found") }
        ProofVerifier.cancel(submissionID)
        checking.remove(submissionID)
        record(verdict: .guardianApproved, reason: "Approved by \(by).", taskID: taskID, submissionID: submissionID)
        return ("applied", "")
    }

    // MARK: Apps

    func blockApp(_ app: AppRef, by: String) {
        guard !settings.blockedApps.contains(where: { $0.id == app.id }) else { return }
        settings.blockedApps.append(app)
        store.saveSettings(settings)
        store.log("\(by == Self.guardianName ? "GUARDIAN" : "PARENT \(by)") blocked \(app.name) (\(app.id))")
        if by == Self.guardianName { onLocalSetting("app:" + app.id) }
        updateEnforcer()
    }

    func unblockApp(_ id: String, by: String) {
        guard let app = settings.blockedApps.first(where: { $0.id == id }) else { return }
        settings.blockedApps.removeAll { $0.id == id }
        store.saveSettings(settings)
        store.log("\(by == Self.guardianName ? "GUARDIAN" : "PARENT \(by)") unblocked \(app.name) (\(app.id))")
        if by == Self.guardianName { onLocalSetting("app:" + id) }
        updateEnforcer()
    }

    func allowApp(_ app: AppRef, by: String) {
        settings.appNames[app.id] = app.name
        if !settings.extraAllowedBundleIDs.contains(app.id) { settings.extraAllowedBundleIDs.append(app.id) }
        store.saveSettings(settings)
        store.log("\(by == Self.guardianName ? "GUARDIAN" : "PARENT \(by)") allowed \(app.name) (\(app.id)) during locks")
        if by == Self.guardianName { onLocalSetting("app:" + app.id) }
    }

    func disallowApp(_ id: String, by: String) {
        settings.extraAllowedBundleIDs.removeAll { $0 == id }
        store.saveSettings(settings)
        store.log("\(by == Self.guardianName ? "GUARDIAN" : "PARENT \(by)") removed \(settings.appNames[id] ?? id) from the allowed apps")
        if by == Self.guardianName { onLocalSetting("app:" + id) }
        enforcer.sweep()
    }

    /// Regular apps running now, by name, for picking one to block.
    func runningApps() -> [AppRef] {
        let me = selfBundleID
        var seen = Set<String>()
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppRef? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != me,
                  !Allowlist.implicit.contains(id), seen.insert(id).inserted else { return nil }
            return AppRef(id: id, name: app.localizedName ?? id)
        }
        for app in apps { recentApps[app.id] = (app.name, now) }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Applying a parent's command

    /// Does what a checked command asks. Returns its outcome and reason (docs/parent-link-v1.md §5.3).
    func applyParent(_ action: ParentAction, by: String) -> (String, String) {
        switch action {
        case let .lock(until, strength, note):
            if let until, until <= now { return ("noop", "That time has passed.") }
            lockByParent(until: until, strength: strength, note: note, by: by)
            let when = until.map { " until \(Fmt.time.string(from: $0))" } ?? ""
            onParentAction("\(by) locked this Mac\(when).")
        case let .free(until):
            guard until > now else { return ("noop", "That time has passed.") }
            unlock(until: until, by: by)
            onParentAction("\(by) unlocked this Mac until \(Fmt.time.string(from: until)).")
        case .normal:
            backToNormal(by: by)
            onParentAction("\(by) set this Mac back to the usual rules.")
        case let .addTask(id, title, details, due):
            guard addTask(id: id, title: title, details: details, due: due, by: by) else { return ("noop", "Already added.") }
            onParentAction("\(by) added \u{201C}\(title)\u{201D}.")
        case let .editTask(id, title, details, due):
            guard var t = task(id) else { return ("noop", "That task is gone.") }
            if let title { t.title = title }
            if let details { t.details = details }
            if let due { t.dueDate = due }
            _ = saveEdit(t, guardianApproved: true)
            store.log("PARENT \(by) changed \"\(t.title)\"")
            onParentAction("\(by) changed \u{201C}\(Agenda.courseAndTitle(t).title)\u{201D}.")
        case let .deleteTask(id):
            guard let t = task(id) else { return ("noop", "That task is gone.") }
            _ = delete(id, guardianApproved: true)
            store.log("PARENT \(by) deleted \"\(t.title)\"")
            onParentAction("\(by) deleted \u{201C}\(Agenda.courseAndTitle(t).title)\u{201D}.")
        case let .excuseTask(id):
            guard let t = task(id) else { return ("noop", "That task is gone.") }
            guard t.isPending else { return ("noop", "That task is already settled.") }
            excuse(id)
            store.log("PARENT \(by) excused \"\(t.title)\"")
            onParentAction("\(by) excused \u{201C}\(Agenda.courseAndTitle(t).title)\u{201D}.")
        case let .approveProof(taskID, proofID):
            let result = approveProof(taskID: taskID, submissionID: proofID, by: by)
            if result.0 == "applied", let t = task(taskID) {
                onParentAction("\(by) approved your proof for \u{201C}\(Agenda.courseAndTitle(t).title)\u{201D}.")
            }
            return result
        case let .addRepeat(series):
            guard !recurring.contains(where: { $0.id == series.id }) else { return ("noop", "Already added.") }
            var s = series
            s.createdAt = now
            recurring.append(s)
            store.saveRecurring(recurring)
            store.log("REPEAT added by \(by): \"\(s.title)\", \(s.schedule())")
            tick()
            onParentAction("\(by) added a repeating task: \u{201C}\(s.title)\u{201D}.")
        case let .stopRepeat(id):
            guard let s = recurring.first(where: { $0.id == id }) else { return ("noop", "Already stopped.") }
            stopRepeating(id)
            onParentAction("\(by) stopped \u{201C}\(s.title)\u{201D} repeating.")
        case let .allowApp(app):
            allowApp(app, by: by)
            onParentAction("\(by) allowed \(app.name) during locks.")
        case let .disallowApp(app):
            guard settings.extraAllowedBundleIDs.contains(app.id) else { return ("noop", "It wasn't allowed.") }
            disallowApp(app.id, by: by)
        case let .blockApp(app):
            guard !settings.blockedApps.contains(where: { $0.id == app.id }) else { return ("noop", "Already blocked.") }
            blockApp(app, by: by)
            onParentAction("\(by) blocked \(app.name).")
        case let .unblockApp(app):
            guard settings.blockedApps.contains(where: { $0.id == app.id }) else { return ("noop", "It wasn't blocked.") }
            unblockApp(app.id, by: by)
            onParentAction("\(by) unblocked \(app.name).")
        case let .setPenalty(minutes):
            guard minutes != settings.penaltyMinutes else { return ("noop", "") }
            setPenalty(minutes: minutes)
            store.log("PARENT \(by) set the late penalty to \(minutes) min")
        case let .setExtensions(enabled):
            guard enabled != settings.extensionsEnabled else { return ("noop", "") }
            setExtensionsEnabled(enabled)
            store.log("PARENT \(by) turned asking for more time \(enabled ? "on" : "off")")
        case let .message(text):
            settings.parentMessage = ParentMessage(text: text, by: by, at: now)
            store.saveSettings(settings)
            store.log("PARENT message from \(by)")
            onParentAction("\(by): \(text)")
        case let .allowGuardianSetup(until):
            guard until > now else { return ("noop", "That time has passed.") }
            guardianSetupAllowedUntil = min(until, now.addingTimeInterval(15 * 60))
            store.log("PARENT \(by) allowed setting a new guardian code until \(Fmt.time.string(from: guardianSetupAllowedUntil!))")
            onParentAction("\(by) lets you set a new guardian code for the next few minutes.")
        case .removeDevice:
            return ("unsupported", "")  // the link handles this itself
        }
        return ("applied", "")
    }

    /// No guardian code, and a parent's phone is linked: first-time setup waits for a parent's go-ahead.
    var needsParentForGuardianSetup: Bool {
        guardian == nil && settings.parentLinked && !(guardianSetupAllowedUntil.map { $0 > now } ?? false)
    }

    // MARK: What parents see

    /// The activity list: the latest log lines as events, newest last.
    func activityEvents(limit: Int = 100) -> [WireState.Event] {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        return store.recentLog(lines: limit).reversed().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let at = stamp.date(from: String(parts[0])) else { return nil }
            let text = parts[1].trimmingCharacters(in: .whitespaces)
            let kind = text.split(separator: " ").first.map { $0.lowercased() } ?? "event"
            return WireState.Event(at: WireState.ms(at), kind: kind, text: text)
        }
    }

    func stateInput(seq: Int64, computer: WireState.Computer, results: [CommandResult], devices: [WireState.Device],
                    flags: [WireState.Flag], accessAt: Int64) -> StateBuilder.Input {
        let running = runningApps()
        let recent = recentApps.filter { now.timeIntervalSince($0.value.seen) < 14 * 86400 }
            .map { WireState.App(id: $0.key, name: $0.value.name, lastSeen: WireState.ms($0.value.seen)) }
            .sorted { ($0.lastSeen ?? 0) > ($1.lastSeen ?? 0) }
        return StateBuilder.Input(
            seq: seq, now: now, computer: computer, tasks: tasks, recurring: recurring, settings: settings, lock: lock,
            checking: checking, builtIn: Allowlist.apps.map { AppRef(id: $0.bundleID, name: $0.name) }, running: running,
            recent: recent, activity: activityEvents(), results: results, devices: devices, flags: flags,
            accessBy: settings.parentLock?.by ?? "", accessAt: accessAt)
    }
}
