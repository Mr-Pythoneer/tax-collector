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

        model.settings.claudePath = fakeClaude("claude-accept-written", #"{"verdict":"accept","reason":"Specific and believable.","checklist":["Play No. 41"]}"#)
        model.addTask(title: "Written proof", details: "Playing test: No. 41", due: Date().addingTimeInterval(86400))
        if let w = newest("Written proof") {
            model.submitProof(taskID: w.id, note: "Played No. 41 for the class this morning; lost the beat once in bar 12 and got 4/5.", files: [])
            _ = await wait { model.task(w.id)?.proofs.last?.verdict != nil }
            let after = model.task(w.id)
            check("proof: a written account with no files is checked and accepted",
                  after?.proofs.last?.attachments.isEmpty == true && after?.proofs.last?.verdict == .accepted && after?.isPending == false)
        }

        let rejected = await submit("Proof rejected",
                                    claude: fakeClaude("claude-reject", #"{"verdict":"reject","reason":"Blank page."}"#))
        check("proof: rejected proof leaves the task due", rejected?.isPending == true && rejected?.proofs.last?.verdict == .rejected)

        let broken = await submit("Proof broken", claude: dir.appendingPathComponent("no-such-claude").path)
        check("proof: a missing Claude is reported, task stays due",
              broken?.isPending == true && broken?.proofs.last?.verdict == .error,
              broken?.proofs.last?.reason ?? "")
        // Cancelling a check: the proof counts for nothing, and Claude's late answer is ignored
        func slowClaude(_ name: String, _ inner: String) -> String {
            let path = fakeClaude(name, inner)
            let script = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            FileManager.default.createFile(atPath: path, contents: Data(script.replacingOccurrences(of: "#!/bin/sh\n", with: "#!/bin/sh\nsleep 3\n").utf8),
                                           attributes: [.posixPermissions: 0o755])
            return path
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        let slowAccept = slowClaude("claude-slow-accept", #"{"verdict":"accept","reason":"Fine."}"#)
        model.settings.claudePath = slowAccept
        model.addTask(title: "Proof cancelled", details: "Problems 1-10", due: Date().addingTimeInterval(86400))
        if let c = newest("Proof cancelled") {
            model.submitProof(taskID: c.id, note: "done", files: [proofFile])
            let sid = model.task(c.id)?.proofs.last?.id
            check("cancel: the check is running", sid.map { model.checking.contains($0) } == true)
            if let sid { model.cancelCheck(taskID: c.id, submissionID: sid) }
            check("cancel: the proof is withdrawn and the task stays due",
                  model.task(c.id)?.proofs.isEmpty == true && model.task(c.id)?.isPending == true && model.checking.isEmpty)
            await pause(4.5)
            check("cancel: Claude's late answer doesn't pass it",
                  model.task(c.id)?.isPending == true && model.task(c.id)?.proofs.isEmpty == true)
        }

        model.settings.claudePath = dir.appendingPathComponent("no-such-claude").path
        model.addTask(title: "Proof recheck cancelled", details: "", due: Date().addingTimeInterval(86400))
        if let r = newest("Proof recheck cancelled") {
            model.submitProof(taskID: r.id, note: "done", files: [proofFile])
            _ = await wait { model.task(r.id)?.proofs.last?.verdict != nil }
            model.settings.claudePath = slowAccept
            if let sid = model.task(r.id)?.proofs.last?.id {
                model.recheck(taskID: r.id, submissionID: sid)
                model.cancelCheck(taskID: r.id, submissionID: sid)
            }
            await pause(4.5)
            let proof = model.task(r.id)?.proofs.last
            check("cancel: a cancelled re-check goes back to couldn't check, not passed",
                  proof?.verdict == .error && proof?.reason == "You cancelled the check." && model.task(r.id)?.isPending == true,
                  "\(String(describing: proof?.verdict)) \(proof?.reason ?? "")")
        }

        model.settings.claudePath = slowClaude("claude-slow-reject", #"{"verdict":"reject","reason":"Too late to count."}"#)
        model.addTask(title: "Proof approved meanwhile", details: "", due: Date().addingTimeInterval(86400))
        if let g = newest("Proof approved meanwhile") {
            model.submitProof(taskID: g.id, note: "done", files: [proofFile])
            model.approveLatestProof(g.id)
            await pause(4.5)
            check("cancel: Claude's late answer doesn't undo a guardian's approval",
                  model.task(g.id)?.proofs.last?.verdict == .guardianApproved && model.task(g.id)?.isPending == false)
        }

        // A guardian unlock keeps this from showing a real lock while it tests one.
        model.settings.overrideUntil = Date().addingTimeInterval(120)
        model.settings.claudePath = slowAccept
        model.addTask(title: "Proof cancelled after the deadline", details: "", due: Date().addingTimeInterval(2))
        if let l = newest("Proof cancelled after the deadline") {
            model.submitProof(taskID: l.id, note: "done", files: [proofFile])
            await pause(2.5)
            model.tick()
            check("cancel: a check sent before the deadline holds the lock off", !model.lock.overdue.contains { $0.id == l.id })
            if let sid = model.task(l.id)?.proofs.last?.id { model.cancelCheck(taskID: l.id, submissionID: sid) }
            check("cancel: cancelled after the deadline, it's overdue at once", model.lock.overdue.contains { $0.id == l.id })
            await pause(3)
            check("cancel: and Claude's late answer doesn't unlock it", model.lock.overdue.contains { $0.id == l.id })
            _ = model.delete(l.id, guardianApproved: true)
        }
        model.settings.overrideUntil = nil
        model.tick()

        model.settings.claudePath = realClaude
        for t in model.tasks where t.title.hasPrefix("Proof ") || t.title == "Written proof" { _ = model.delete(t.id, guardianApproved: true) }

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

        // Teams import, with a pretend Teams
        let teamsLab = TeamsAssignment(id: "selftest-teams-lab", classID: "c", title: "Science 8: Lab", details: "Write it up.",
                                       dueDate: Date().addingTimeInterval(3 * 86400), link: "https://teams.microsoft.com/l/x")
        let teamsOld = TeamsAssignment(id: "selftest-teams-old", title: "Old", dueDate: Date().addingTimeInterval(-86400))
        model.teamsFetcher = { _ in .success([teamsLab, teamsOld]) }
        model.teamsSignInChanged(true)
        check("teams: signing in alone doesn't turn import on", !model.teamsIsOn)
        model.turnOnTeams()
        _ = await wait { !model.teamsSyncing && model.tasks.contains { $0.source == .teams(id: teamsLab.id) } }
        let fromTeams = model.tasks.first { $0.source == .teams(id: teamsLab.id) }
        check("teams: upcoming assignments are imported", model.teamsIsOn && fromTeams?.title == "Science 8: Lab")
        check("teams: past assignments are skipped", !model.tasks.contains { $0.source == .teams(id: teamsOld.id) })
        check("teams: the task links back to Teams", fromTeams.flatMap { model.teams.link(of: $0) } != nil)
        if let fromTeams {
            check("teams: an imported task days away can be deleted", model.delete(fromTeams.id) == .saved)
            model.syncTeams()
            _ = await wait(5) { !model.teamsSyncing }
            check("teams: a deleted assignment isn't imported again", !model.tasks.contains { $0.source == .teams(id: teamsLab.id) })
        }
        model.teamsFetcher = { _ in .failure(.init(message: "Signed out of Microsoft Teams.", signedOut: true)) }
        model.syncTeams()
        _ = await wait(5) { !model.teamsSyncing }
        check("teams: a lapsed sign-in shows as an error", model.teamsError != nil && !model.teamsSignedIn)
        check("teams: can be turned off in the first minutes", model.stopTeams() == .saved && !model.teamsIsOn)

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

        // Asking for more time, with fake Claude decisions
        func fakeDecision(_ name: String, _ inner: String, wait: Int = 0) -> String {
            let path = dir.appendingPathComponent(name).path
            let body = #"{"type":"result","is_error":false,"result":"\#(inner.replacingOccurrences(of: "\"", with: "\\\""))"}"#
            let script = "#!/bin/sh\nsleep \(wait)\ncat <<'EOF'\n\(body)\nEOF\n"
            FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
            return path
        }
        func extended(_ title: String) -> TaxTask? { newest(title) }
        let reason = "I have a fever of 39 and the nurse sent me home early today."

        // Start with no record: requests are refused before Claude is even asked.
        let savedTasks = model.tasks
        model.tasks = []
        model.addTask(title: "Too soon", details: "", due: Date().addingTimeInterval(7200))
        if let t = newest("Too soon") {
            check("more time: refused without a track record", model.extensionWhyNot(t)?.contains("at least") == true)
            model.requestExtension(taskID: t.id, hours: 6, reason: reason)
            check("more time: a refused request isn't recorded", model.task(t.id)?.extensions == nil)
        }
        // Build a record: five tasks proven on time.
        for n in 1...5 {
            model.addTask(title: "Record \(n)", details: "", due: Date().addingTimeInterval(3600))
            if let t = newest("Record \(n)") { model.approveLatestProof(t.id) }
        }
        check("more time: five on-time tasks make you eligible", model.trackRecord.onTime == 5 && model.trackRecord.onTimeRate == 1)

        model.settings.claudePath = fakeDecision("claude-grant-20", #"{"decision":"grant","hours":20,"reason":"Being sick is a real reason."}"#)
        model.addTask(title: "Granted", details: "", due: Date().addingTimeInterval(7200))
        if let t = extended("Granted") {
            let before = t.dueDate
            check("more time: allowed with a good record", model.extensionWhyNot(t) == nil)
            model.requestExtension(taskID: t.id, hours: 6, reason: reason)
            _ = await wait { model.task(t.id)?.extensions?.last?.decision != nil }
            let after = model.task(t.id)
            check("more time: granted, but never more than you asked",
                  after?.extensions?.last?.hoursGranted == 6 && abs((after?.dueDate.timeIntervalSince(before) ?? 0) - 6 * 3600) < 1)
            check("more time: one request per task", after.flatMap { model.extensionWhyNot($0) }?.contains("already asked") == true)
        }

        model.settings.claudePath = fakeDecision("claude-deny", #"{"decision":"deny","hours":0,"reason":"That's putting it off."}"#)
        model.addTask(title: "Denied", details: "", due: Date().addingTimeInterval(7200))
        if let t = extended("Denied") {
            model.requestExtension(taskID: t.id, hours: 4, reason: "I was busy all evening and didn't get to it at all.")
            _ = await wait { model.task(t.id)?.extensions?.last?.decision != nil }
            check("more time: a denied request leaves the deadline alone",
                  model.task(t.id)?.extensions?.last?.decision == .denied && model.task(t.id)?.dueDate == t.dueDate)
        }

        model.settings.claudePath = dir.appendingPathComponent("no-such-claude").path
        model.addTask(title: "Unreachable", details: "", due: Date().addingTimeInterval(7200))
        if let t = extended("Unreachable") {
            model.requestExtension(taskID: t.id, hours: 4, reason: reason)
            _ = await wait { model.task(t.id)?.extensions?.last?.decision != nil }
            check("more time: if Claude can't answer, you can ask again",
                  model.task(t.id)?.extensions?.last?.decision == .error && model.task(t.id).flatMap { model.extensionWhyNot($0) } == nil)
        }

        // A request just before the deadline holds off the lock until Claude answers.
        model.settings.claudePath = fakeDecision("claude-slow-grant", #"{"decision":"grant","hours":2,"reason":"OK."}"#, wait: 4)
        model.addTask(title: "Last minute", details: "", due: Date().addingTimeInterval(2))
        if let t = extended("Last minute") {
            model.requestExtension(taskID: t.id, hours: 2, reason: reason)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            model.tick()
            check("more time: no lock while Claude is still deciding", !model.lock.isLocked)
            _ = await wait { model.task(t.id)?.extensions?.last?.decision != nil }
            model.tick()
            check("more time: once granted, still no lock", !model.lock.isLocked && model.task(t.id)?.extensions?.last?.decision == .granted)
        }

        // Two granted this week: the third is refused.
        model.addTask(title: "Third", details: "", due: Date().addingTimeInterval(7200))
        if let t = extended("Third") {
            check("more time: at most two a week", model.extensionWhyNot(t)?.contains("2 extensions") == true)
        }
        model.setExtensionsEnabled(false)
        if let t = extended("Third") {
            check("more time: your guardian can turn it off", model.extensionWhyNot(t)?.contains("guardian") == true)
        }
        model.setExtensionsEnabled(true)
        model.settings.claudePath = realClaude
        model.tasks = savedTasks
        model.store.saveTasks(model.tasks)
        model.tick()

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

        // A teacher's instructions, as the details window shows them
        func rich(_ html: String) -> String? { RichText.fromHTML(html).map { String($0.characters) } }
        let page = RichText.fromHTML("<p>Read <b>chapter 3</b>.</p><p>&nbsp;</p><ul><li>Take notes</li><li>Answer 1&ndash;5</li></ul>"
                                     + "<p>See <a href=\"https://example.com/guide\">the guide</a>.</p>")
        let pageText = page.map { String($0.characters) } ?? ""
        check("details: paragraphs get a blank line, list items stay together",
              pageText == "Read chapter 3.\n\n   • Take notes\n   • Answer 1–5\n\nSee the guide.", pageText.debugDescription)
        check("details: the teacher's links still work",
              page?.runs.contains { $0.link?.absoluteString == "https://example.com/guide" } == true)
        check("details: bold stays bold", page?.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized } == true)
        let breaks = rich("Due Friday<br>Points: 20<br><br>Bring notes</p><p>Next</p>") ?? ""
        check("details: a <br> is one line break", breaks == "Due Friday\nPoints: 20\n\nBring notes\n\nNext", breaks.debugDescription)
        let numbered = rich("<ol><li>One</li><li>Two<ul><li>Nested</li></ul></li></ol>") ?? ""
        check("details: numbered and nested lists", numbered == "   1. One\n   2. Two\n       ◦ Nested", numbered.debugDescription)
        check("details: an empty page falls back to the calendar's text", rich("<p>&nbsp;</p>") == nil)
        check("details: plain addresses become links",
              RichText.linkified("See www.example.com today").runs.contains { $0.link?.host == "www.example.com" })

        // The teacher's files land in Downloads (a scratch folder here), like a browser download
        let downloads = dir.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let source = URL(string: "https://school.example/ftpimages/1/rubric.pdf")!
        let first = try? model.saveDownload(Data("rubric".utf8), named: "Rubric.pdf", from: source, into: downloads)
        check("files: saved under the teacher's name", first?.lastPathComponent == "Rubric.pdf")
        let again = try? model.saveDownload(Data("rubric".utf8), named: "Rubric.pdf", from: source, into: downloads)
        check("files: opening it again reuses the copy", again == first)
        let changed = try? model.saveDownload(Data("new rubric".utf8), named: "Rubric.pdf", from: source, into: downloads)
        check("files: a different file with the same name gets a number", changed?.lastPathComponent == "Rubric 2.pdf")
        let odd = try? model.saveDownload(Data("x".utf8), named: "../Unit 3/Notes:v2.docx", from: source, into: downloads)
        check("files: odd names stay inside the folder", odd?.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL
              && odd?.lastPathComponent == "-Unit 3-Notes-v2.docx", odd?.path ?? "nil")
        let marked = (try? first?.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        check("files: marked as downloaded from the web", marked != nil)

        // Weekly repeats: one copy at a time, the next once the deadline has passed.
        // The app's clock jumps ahead here, under a guardian unlock so nothing really locks.
        model.settings.overrideUntil = Date().addingTimeInterval(600)
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: model.now)!
        model.addRecurring(title: "Repeat: homework", details: "Exercises",
                           weekdays: [calendar.component(.weekday, from: tomorrow)], minuteOfDay: 8 * 60)
        let seriesID = model.recurring.first { $0.title == "Repeat: homework" }?.id
        func copies() -> [TaxTask] { model.tasks.filter { $0.seriesID != nil && $0.seriesID == seriesID } }
        let firstDue = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)!
        check("repeat: the first copy is out, due on the right day",
              copies().count == 1 && copies().first?.dueDate == firstDue, "\(copies().map(\.dueDate))")
        if let first = copies().first, let i = model.tasks.firstIndex(where: { $0.id == first.id }) {
            model.tasks[i].status = .proven(at: model.now)
            model.tick()
            check("repeat: paying early doesn't bring the next one forward", copies().count == 1)
            model.settings.lastSeen = firstDue.addingTimeInterval(60)
            model.tick()
            let next = copies().filter(\.isPending)
            check("repeat: after the deadline, next week's copy appears",
                  copies().count == 2 && next.first?.dueDate == calendar.date(byAdding: .day, value: 7, to: firstDue),
                  "\(copies().map(\.dueDate))")
            if let n = next.first { _ = model.delete(n.id) }
            model.tick()
            check("repeat: deleting a copy doesn't bring it straight back", copies().count == 1)
            if let id = seriesID { model.stopRepeating(id) }
            model.tick()
            check("repeat: stopping keeps the copies already out",
                  model.recurring.isEmpty && model.store.loadRecurring().isEmpty && copies().count == 1)
        }
        for t in copies() { _ = model.delete(t.id, guardianApproved: true) }
        model.resetClockGuard()
        model.settings.overrideUntil = nil
        model.tick()

        // Every 4 days, from a start date
        model.settings.overrideUntil = Date().addingTimeInterval(600)
        let startDay = calendar.date(byAdding: .day, value: 1, to: model.now)!
        model.addRecurring(title: "Repeat: every 4 days", details: "", unit: .days, interval: 4, weekdays: [],
                           minuteOfDay: 8 * 60, startDate: startDay)
        let fourID = model.recurring.first { $0.title == "Repeat: every 4 days" }?.id
        func fours() -> [TaxTask] { model.tasks.filter { $0.seriesID != nil && $0.seriesID == fourID } }
        let fourFirst = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: startDay)!
        check("repeat: every 4 days starts on its start date", fours().map(\.dueDate) == [fourFirst],
              "\(fours().map(\.dueDate))")
        if let first = fours().first, let i = model.tasks.firstIndex(where: { $0.id == first.id }) {
            model.tasks[i].status = .proven(at: model.now)
            model.settings.lastSeen = fourFirst.addingTimeInterval(60)
            model.tick()
            check("repeat: and the next copy is 4 days later",
                  fours().filter(\.isPending).first?.dueDate == calendar.date(byAdding: .day, value: 4, to: fourFirst),
                  "\(fours().map(\.dueDate))")
        }
        if let id = fourID { model.stopRepeating(id) }
        for t in fours() { _ = model.delete(t.id, guardianApproved: true) }
        model.resetClockGuard()
        model.settings.overrideUntil = nil
        model.tick()

        // What a parent's phone can do
        model.settings.overrideUntil = nil
        var outcome = model.applyParent(.lock(until: Date().addingTimeInterval(600), strength: .all, note: "Dinner"), by: "Test Phone")
        model.tick()
        check("parent: a phone's lock locks, everything closed", outcome.0 == "applied" && model.lock.isLocked && model.lock.strength == .all)
        outcome = model.applyParent(.free(until: Date().addingTimeInterval(600)), by: "Test Phone")
        model.tick()
        check("parent: an unlock beats it", !model.lock.isLocked && model.settings.parentLock == nil)
        _ = model.applyParent(.normal, by: "Test Phone")
        _ = model.applyParent(.blockApp(AppRef(id: "org.example.game", name: "Game")), by: "Test Phone")
        model.tick()
        check("parent: a blocked app keeps the enforcer running while unlocked", model.enforcer.isActive && !model.lock.isLocked)
        _ = model.applyParent(.unblockApp(AppRef(id: "org.example.game", name: "Game")), by: "Test Phone")
        model.tick()
        check("parent: unblocking stops it", !model.enforcer.isActive)
        let phoneTask = UUID()
        _ = model.applyParent(.addTask(id: phoneTask, title: "From a phone", details: "", due: Date().addingTimeInterval(3 * 86400)), by: "Test Phone")
        let twice = model.applyParent(.addTask(id: phoneTask, title: "From a phone", details: "", due: Date().addingTimeInterval(3 * 86400)), by: "Test Phone")
        check("parent: the same task sent twice is added once", twice.0 == "noop" && model.tasks.filter { $0.id == phoneTask }.count == 1)
        if let i = model.tasks.firstIndex(where: { $0.id == phoneTask }) {
            let first = ProofSubmission(submittedAt: Date(), note: "first", attachments: [], verdict: .rejected, reason: "x")
            let second = ProofSubmission(submittedAt: Date(), note: "second", attachments: [], verdict: .rejected, reason: "y")
            model.tasks[i].proofs = [first, second]
            let approved = model.applyParent(.approveProof(taskID: phoneTask, proofID: first.id), by: "Test Phone")
            let after = model.task(phoneTask)
            check("parent: approving names the exact proof", approved.0 == "applied" && after?.isPending == false
                  && after?.proofs.first?.verdict == .guardianApproved && after?.proofs.last?.verdict == .rejected)
        }
        _ = model.delete(phoneTask, guardianApproved: true)
        let savedGuardian = model.guardian
        model.guardian = nil
        model.settings.parentLinked = true
        check("parent: no guardian code while linked asks for a parent", model.needsParentForGuardianSetup)
        _ = model.applyParent(.allowGuardianSetup(until: Date().addingTimeInterval(300)), by: "Test Phone")
        check("parent: until a parent allows a new one", !model.needsParentForGuardianSetup)
        model.guardian = savedGuardian
        model.settings.parentLinked = false
        model.guardianSetupAllowedUntil = nil
        model.tick()

        // Inbox: tasks other tools drop into <data dir>/inbox
        do {
            let inbox = model.store.inboxURL
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let due = Date().addingTimeInterval(7 * 86400)
            func drop(_ name: String, id: String, title: String) {
                let body = "{\"v\":1,\"id\":\"\(id)\",\"title\":\"\(title)\",\"details\":\"From a test\",\"due\":\"\(ISO8601DateFormatter().string(from: due))\",\"from\":\"Self Test\"}"
                try? Data(body.utf8).write(to: inbox.appendingPathComponent(name))
            }
            func scan() { model.lastInboxScan = .distantPast; model.importInbox() }
            let before = model.tasks.count
            drop("a.json", id: "selftest:1", title: "Inbox homework")
            scan()
            let landed = model.tasks.filter { $0.title == "Inbox homework" }
            check("inbox: a dropped file becomes a task", landed.count == 1 && model.tasks.count == before + 1)
            check("inbox: it is a manual task due when the file said",
                  landed.first.map { $0.source == .manual && abs($0.dueDate.timeIntervalSince(due)) < 2 && $0.isPending } ?? false)
            check("inbox: the details say who added it", landed.first?.details.contains("Self Test") == true)
            check("inbox: an accepted file is removed", !FileManager.default.fileExists(atPath: inbox.appendingPathComponent("a.json").path))
            drop("b.json", id: "selftest:1", title: "Inbox homework")
            scan()
            check("inbox: the same id never adds a second task", model.tasks.filter { $0.title == "Inbox homework" }.count == 1)
            try? Data("not json".utf8).write(to: inbox.appendingPathComponent("c.json"))
            scan()
            check("inbox: an unusable file is moved aside, not retried",
                  !FileManager.default.fileExists(atPath: inbox.appendingPathComponent("c.json").path)
                  && FileManager.default.fileExists(atPath: inbox.appendingPathComponent("rejected/malformed-c.json").path))
            check("inbox: a task from the inbox follows the normal edit rules", {
                guard let t = landed.first else { return false }
                return !model.isFrozen(t)        // a week out: still editable
            }())
            if let t = landed.first { _ = model.delete(t.id, guardianApproved: true) }
            model.tick()
        }

        // Everything ends up on disk
        let saved = model.store.loadTasks()
        check("storage: tasks on disk match the app", Set(saved.map(\.id)) == Set(model.tasks.map(\.id)))

        lines.append("")
        lines.append(failures == 0 ? "All \(lines.count - 1) self-test checks passed." : "\(failures) failed.")
        return lines.joined(separator: "\n")
    }
}
