import Foundation
import TaxCore

/// Testing aid, only with `TAXCOLLECTOR_SELFTEST=1` and a throwaway `TAXCOLLECTOR_DATA_DIR`: runs the app's
/// own model through every feature and returns a PASS/FAIL report. It uses a fake Claude program and a fake
/// Blackbaud, so it never touches your real accounts.
@MainActor
enum SelfTest {
    static func run(model: AppModel) async -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { lines.append("PASS  \(name)") } else {
                failures += 1
                lines.append("FAIL  \(name)\(detail().isEmpty ? "" : ": \(detail())")")
            }
        }
        func wait(_ seconds: Double = 20, until done: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
            return done()
        }
        func newest(_ title: String) -> TaxTask? { model.tasks.last { $0.title == title } }
        let dir = model.store.dir
        let realClaude = model.settings.claudePath
        let realMarker = model.blackbaudMarker

        // Guardian code
        model.setupGuardian(code: "abcdef")
        check("guardian: wrong code refused", model.checkGuardian("nope-1") == .wrong)
        _ = model.checkGuardian("nope-2")
        if case .coolingDown = model.checkGuardian("nope-3") { check("guardian: third wrong code starts a cooldown", true) }
        else { check("guardian: third wrong code starts a cooldown", false) }
        if case .coolingDown = model.checkGuardian("abcdef") { check("guardian: even the right code waits out the cooldown", true) }
        else { check("guardian: even the right code waits out the cooldown", false) }
        model.settings.guardianFailures = 0
        model.settings.guardianLockedUntil = nil
        check("guardian: right code accepted", model.checkGuardian("abcdef") == .ok)
        model.changeGuardianCode("ghijkl")
        check("guardian: new code works", model.checkGuardian("ghijkl") == .ok)
        check("guardian: old code no longer works", model.checkGuardian("abcdef") == .wrong)

        // Adding, editing and deleting
        model.addTask(title: "Far away", details: "", due: Date().addingTimeInterval(3 * 86400))
        if let far = newest("Far away") {
            var later = far
            later.dueDate = far.dueDate.addingTimeInterval(86400)
            check("edit: a task days away can be pushed back", model.saveEdit(later) == .saved)
            check("delete: a task days away can be deleted", model.delete(far.id) == .saved)
        } else { check("add: task saved", false) }

        model.addTask(title: "Soon", details: "", due: Date().addingTimeInterval(2 * 3600))
        if let i = model.tasks.firstIndex(where: { $0.title == "Soon" }) {
            check("edit: a new task can be fixed during the 5-minute grace", !model.isFrozen(model.tasks[i]))
            model.tasks[i].createdAt = Date().addingTimeInterval(-600)
            let soon = model.tasks[i]
            var later = soon
            later.dueDate = soon.dueDate.addingTimeInterval(3600)
            check("edit: inside 24 hours, pushing it back needs the guardian", model.saveEdit(later) == .needsGuardian)
            var earlier = soon
            earlier.dueDate = soon.dueDate.addingTimeInterval(-600)
            check("edit: inside 24 hours, moving it earlier is fine", model.saveEdit(earlier) == .saved)
            check("delete: inside 24 hours needs the guardian", model.delete(soon.id) == .needsGuardian)
            check("delete: the guardian can delete it", model.delete(soon.id, guardianApproved: true) == .saved)
        } else { check("add: task saved", false) }

        // Warnings
        var warned: [UUID] = []
        let realWarning = model.onWarning
        model.onWarning = { task, _ in warned.append(task.id) }
        model.addTask(title: "In four minutes", details: "", due: Date().addingTimeInterval(240))
        model.tick()
        check("warning: fires inside the last 5 minutes", newest("In four minutes").map { warned.contains($0.id) } ?? false)
        model.onWarning = realWarning
        if let t = newest("In four minutes") { _ = model.delete(t.id, guardianApproved: true) }

        // Locking, guardian unlock, excuse
        model.addTask(title: "Already late", details: "", due: Date().addingTimeInterval(-60))
        model.tick()
        check("lock: an overdue task locks the Mac", model.lock.isLocked)
        check("lock: the enforcer is running", model.enforcer.isActive)
        model.unlock(hours: 1)
        check("guardian: unlock pauses the lock", !model.lock.isLocked && model.lock.overrideUntil != nil)
        model.endUnlock()
        check("guardian: ending the unlock locks again", model.lock.isLocked)
        if let late = newest("Already late") { model.excuse(late.id) }
        model.tick()
        check("guardian: excusing the task unlocks", !model.lock.isLocked)
        check("lock: the enforcer stops when unlocked", !model.enforcer.isActive)

        // Late proof and the penalty
        model.setPenalty(minutes: 1)
        model.addTask(title: "Late homework", details: "", due: Date().addingTimeInterval(-120))
        model.tick()
        if let late = newest("Late homework") {
            model.approveLatestProof(late.id)
            model.tick()
            let after = model.task(late.id)
            var penaltyRunning = false
            if case .provenLate = after?.status { penaltyRunning = true }
            check("penalty: late proof is accepted as late", penaltyRunning)
            check("penalty: the Mac stays locked during the penalty", model.lock.isLocked && model.lock.overdue.isEmpty)
            model.excuse(late.id)
            model.tick()
            check("penalty: excusing ends it", !model.lock.isLocked)
        }
        model.setPenalty(minutes: 30)

        // Clock guard
        model.settings.lastSeen = Date().addingTimeInterval(3600)
        model.tick()
        check("clock: winding the clock back doesn't move time back", model.now >= Date().addingTimeInterval(3500))
        model.resetClockGuard()
        check("clock: the guardian can reset it", abs(model.now.timeIntervalSinceNow) < 5)

        // Proof checking, with fake Claude programs
        let proofFile = dir.appendingPathComponent("selftest-proof.txt")
        try? "All ten problems done.".write(to: proofFile, atomically: true, encoding: .utf8)
        func fakeClaude(_ name: String, _ inner: String) -> String {
            let path = dir.appendingPathComponent(name).path
            let body = #"{"type":"result","is_error":false,"result":"\#(inner.replacingOccurrences(of: "\"", with: "\\\""))"}"#
            let script = "#!/bin/sh\ncat <<'EOF'\n\(body)\nEOF\n"
            FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
            return path
        }
        func submit(_ title: String, claude: String) async -> TaxTask? {
            model.settings.claudePath = claude
            model.addTask(title: title, details: "Problems 1-10", due: Date().addingTimeInterval(86400))
            guard let t = newest(title) else { return nil }
            model.submitProof(taskID: t.id, note: "done", files: [proofFile])
            _ = await wait { model.task(t.id)?.proofs.last?.verdict != nil }
            return model.task(t.id)
        }
        let accepted = await submit("Proof accepted",
                                    claude: fakeClaude("claude-accept", #"{"verdict":"accept","reason":"Shows all ten.","checklist":["Do 1-5","Do 6-10"]}"#))
        check("proof: accepted proof marks the task done", accepted?.status == .proven(at: accepted?.proofs.last?.submittedAt ?? .distantPast),
              "\(String(describing: accepted?.status))")
        check("proof: the file was copied into the proof folder",
              accepted.flatMap { t in t.proofs.last.map { FileManager.default.fileExists(atPath: model.proofFolder(task: t.id, submission: $0.id).appendingPathComponent("selftest-proof.txt").path) } } ?? false)
        check("proof: Claude's checklist is kept", accepted?.checklist?.map(\.text) == ["Do 1-5", "Do 6-10"])

        let rejected = await submit("Proof rejected",
                                    claude: fakeClaude("claude-reject", #"{"verdict":"reject","reason":"Blank page."}"#))
        check("proof: rejected proof leaves the task due", rejected?.isPending == true && rejected?.proofs.last?.verdict == .rejected)

        let broken = await submit("Proof broken", claude: dir.appendingPathComponent("no-such-claude").path)
        check("proof: a missing Claude is reported, task stays due",
              broken?.isPending == true && broken?.proofs.last?.verdict == .error,
              broken?.proofs.last?.reason ?? "")
        model.settings.claudePath = realClaude
        for t in model.tasks where t.title.hasPrefix("Proof ") { _ = model.delete(t.id, guardianApproved: true) }

        // A check cut off by a crash isn't left hanging
        let hanging = TaxTask(title: "Interrupted", dueDate: Date().addingTimeInterval(86400), createdAt: Date(),
                              proofs: [ProofSubmission(submittedAt: Date(), note: "", attachments: [])])
        model.tasks.append(hanging)
        model.store.saveTasks(model.tasks)
        let reopened = AppModel(store: model.store, dryRun: true)
        check("proof: an interrupted check comes back as an error",
              reopened.task(hanging.id)?.proofs.last?.verdict == .error)
        _ = model.delete(hanging.id, guardianApproved: true)

        // Blackbaud import from a local calendar file
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        let inThree = f.string(from: Date().addingTimeInterval(3 * 86400))
        let inFour = f.string(from: Date().addingTimeInterval(4 * 86400))
        let ago = f.string(from: Date().addingTimeInterval(-3 * 86400))
        let ics = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:selftest-lab\r
        DTSTART;VALUE=DATE:\(inThree)\r
        SUMMARY:Science 7- SCI7 - 7B: Lab report\r
        DESCRIPTION:Write it up.\\n- Hypothesis\\n- Results &#9989;\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:selftest-reading\r
        DTSTART;VALUE=DATE:\(inFour)\r
        SUMMARY:English 7 - ENG7 - 7B: Reading log\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:selftest-old\r
        DTSTART;VALUE=DATE:\(ago)\r
        SUMMARY:Science 7- SCI7 - 7B: Old thing\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        let icsURL = dir.appendingPathComponent("selftest.ics")
        try? ics.write(to: icsURL, atomically: true, encoding: .utf8)
        model.startFeed(icsURL)
        _ = await wait { !model.feedSyncing && model.tasks.contains { $0.source == .blackbaud(uid: "selftest-lab") } }
        let lab = model.tasks.first { $0.source == .blackbaud(uid: "selftest-lab") }
        check("feed: upcoming assignments are imported", lab != nil && model.tasks.contains { $0.source == .blackbaud(uid: "selftest-reading") })
        check("feed: past assignments are skipped", !model.tasks.contains { $0.source == .blackbaud(uid: "selftest-old") })
        check("feed: text codes are decoded", lab?.details.contains("✅") == true && lab?.details.contains("&#") == false)
        if let reading = model.tasks.first(where: { $0.source == .blackbaud(uid: "selftest-reading") }) {
            check("feed: an imported task days away can be deleted", model.delete(reading.id) == .saved)
            model.syncFeed()
            _ = await wait(5) { !model.feedSyncing }
            try? await Task.sleep(nanoseconds: 500_000_000)
            check("feed: a deleted assignment isn't imported again", !model.tasks.contains { $0.source == .blackbaud(uid: "selftest-reading") })
        }

        // Last check, with a pretend Blackbaud
        if let lab {
            var marked: [String] = []
            model.blackbaudMarker = { task in marked.append(task.title); return nil }
            model.approveLatestProof(lab.id)
            let paid = model.task(lab.id)
            check("last check: paid Blackbaud work waits for it", paid?.needsLastCheck == true)
            check("last check: the checklist comes from the assignment's list", paid?.checklist?.map(\.text) == ["Hypothesis", "Results ✅"],
                  "\(paid?.checklist?.map(\.text) ?? [])")
            model.confirmLastCheck(lab.id)
            check("last check: can't confirm with items unticked", model.task(lab.id)?.lastCheckDoneAt == nil)
            for item in paid?.checklist ?? [] { model.setChecklistItem(lab.id, item: item.id, done: true) }
            model.confirmLastCheck(lab.id)
            _ = await wait(5) { if case .done = model.task(lab.id)?.blackbaudMark { true } else { false } }
            var done = false
            if case .done = model.task(lab.id)?.blackbaudMark { done = true }
            check("last check: confirming marks it complete in Blackbaud", done && marked == [lab.title])

            model.addTask(title: "Science 7- SCI7 - 7B: Failing mark", details: "", due: Date().addingTimeInterval(86400))
            if let i = model.tasks.firstIndex(where: { $0.title.hasSuffix("Failing mark") }) {
                model.tasks[i].source = .blackbaud(uid: "selftest-fail")
                let id = model.tasks[i].id
                model.blackbaudMarker = { _ in "Blackbaud refused the change (HTTP 500)." }
                model.approveLatestProof(id)
                for item in model.task(id)?.checklist ?? [] { model.setChecklistItem(id, item: item.id, done: true) }
                model.confirmLastCheck(id)
                _ = await wait(5) { model.task(id)?.blackbaudMarkFailed == true }
                check("last check: a Blackbaud failure is shown so it can be retried", model.task(id)?.blackbaudMarkFailed == true)
            }
            model.blackbaudMarker = realMarker
        }
        check("feed: turning import off is allowed while nothing it imported is locked in", model.stopFeed() == .saved)

        // Settings
        model.setAppearance("dark")
        check("appearance: saved", model.store.loadSettings().appearance == "dark")
        model.setAppearance("light")
        model.allowApp(bundleID: "com.apple.TextEdit")
        check("allowlist: the guardian can add an app",
              Allowlist.isAllowed(bundleID: "com.apple.TextEdit", extra: model.settings.extraAllowedBundleIDs, selfID: nil))
        model.disallowApp(bundleID: "com.apple.TextEdit")
        check("allowlist: and remove it",
              !Allowlist.isAllowed(bundleID: "com.apple.TextEdit", extra: model.settings.extraAllowedBundleIDs, selfID: nil))

        // Everything ends up on disk
        let saved = model.store.loadTasks()
        check("storage: tasks on disk match the app", Set(saved.map(\.id)) == Set(model.tasks.map(\.id)))

        lines.append("")
        lines.append(failures == 0 ? "All \(lines.count - 1) self-test checks passed." : "\(failures) failed.")
        return lines.joined(separator: "\n")
    }
}
