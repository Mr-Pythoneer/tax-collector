// Runs the TaxCore checks. Swift Testing can't discover tests under Command Line Tools
// alone, so this is a plain executable: `swift run taxcore-check`.
import Foundation
import TaxCore

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var current = ""

func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        failures += 1
        print("  FAIL \(current) (line \(line))")
    }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func hours(_ h: Double) -> TimeInterval { h * 3600 }

private func task(due: TimeInterval, created: TimeInterval = -hours(72), status: TaskStatus = .pending,
                  proofs: [ProofSubmission] = []) -> TaxTask {
    TaxTask(title: "Essay", dueDate: t0.addingTimeInterval(due), createdAt: t0.addingTimeInterval(created),
            status: status, proofs: proofs)
}

struct LockRule {
    func nothingDueMeansUnlocked() {
        let s = LockPolicy.state(tasks: [task(due: hours(2))], overrideUntil: nil, now: t0)
        expect(!s.isLocked)
    }

    func overduePendingLocks() {
        let s = LockPolicy.state(tasks: [task(due: -60)], overrideUntil: nil, now: t0)
        expect(s.isLocked)
        expect(s.overdue.count == 1)
    }

    func dueExactlyNowLocks() {
        expect(LockPolicy.state(tasks: [task(due: 0)], overrideUntil: nil, now: t0).isLocked)
    }

    func provenAndExcusedDoNotLock() {
        let tasks = [task(due: -60, status: .proven(at: t0.addingTimeInterval(-120))),
                     task(due: -60, status: .excused(at: t0))]
        expect(!LockPolicy.state(tasks: tasks, overrideUntil: nil, now: t0).isLocked)
    }

    func penaltyLocksUntilItEnds() {
        let late = task(due: -hours(1), status: .provenLate(at: t0.addingTimeInterval(-60),
                                                            penaltyEndsAt: t0.addingTimeInterval(600)))
        let during = LockPolicy.state(tasks: [late], overrideUntil: nil, now: t0)
        expect(during.isLocked)
        expect(during.penaltyEndsAt == t0.addingTimeInterval(600))
        expect(!LockPolicy.state(tasks: [late], overrideUntil: nil, now: t0.addingTimeInterval(601)).isLocked)
    }

    func guardianOverrideUnlocksUntilItExpires() {
        let tasks = [task(due: -60)]
        let override = t0.addingTimeInterval(hours(1))
        expect(!LockPolicy.state(tasks: tasks, overrideUntil: override, now: t0).isLocked)
        expect(LockPolicy.state(tasks: tasks, overrideUntil: override, now: override).isLocked)
    }

    func proofSentBeforeDueHoldsTheLockWhileChecking() {
        let inFlight = ProofSubmission(submittedAt: t0.addingTimeInterval(-120), note: "", attachments: ["a.png"])
        expect(!LockPolicy.state(tasks: [task(due: -60, proofs: [inFlight])], overrideUntil: nil, now: t0).isLocked)

        let lateInFlight = ProofSubmission(submittedAt: t0.addingTimeInterval(-10), note: "", attachments: ["a.png"])
        expect(LockPolicy.state(tasks: [task(due: -60, proofs: [lateInFlight])], overrideUntil: nil, now: t0).isLocked)
    }

    func acceptingOnTimeVersusLate() {
        let t = task(due: 0)
        expect(LockPolicy.statusAfterAccepting(t, submittedAt: t0.addingTimeInterval(-5), acceptedAt: t0.addingTimeInterval(30),
                                                penaltyMinutes: 30) == .proven(at: t0.addingTimeInterval(-5)))
        let late = LockPolicy.statusAfterAccepting(t, submittedAt: t0.addingTimeInterval(60), acceptedAt: t0.addingTimeInterval(90),
                                                   penaltyMinutes: 30)
        expect(late == .provenLate(at: t0.addingTimeInterval(60), penaltyEndsAt: t0.addingTimeInterval(90 + 1800)))
    }
}

struct EditWindow {
    func farAwayTaskIsEditable() {
        let t = task(due: hours(48))
        expect(!LockPolicy.isFrozen(t, now: t0))
        var later = t
        later.dueDate = t.dueDate.addingTimeInterval(hours(24))
        expect(LockPolicy.canEditWithoutGuardian(original: t, edited: later, now: t0))
        expect(LockPolicy.canDeleteWithoutGuardian(t, now: t0))
    }

    func inside24HoursIsFrozen() {
        let t = task(due: hours(23))
        expect(LockPolicy.isFrozen(t, now: t0))
        var pushed = t
        pushed.dueDate = t.dueDate.addingTimeInterval(60)
        expect(!LockPolicy.canEditWithoutGuardian(original: t, edited: pushed, now: t0))
        var renamed = t
        renamed.title = "Nothing"
        expect(!LockPolicy.canEditWithoutGuardian(original: t, edited: renamed, now: t0))
        expect(!LockPolicy.canDeleteWithoutGuardian(t, now: t0))
    }

    func movingEarlierIsAlwaysAllowed() {
        let t = task(due: hours(3))
        var sooner = t
        sooner.dueDate = t.dueDate.addingTimeInterval(-hours(1))
        expect(LockPolicy.canEditWithoutGuardian(original: t, edited: sooner, now: t0))
    }

    func freshTaskHasTypoGrace() {
        let t = task(due: hours(1), created: -60)
        expect(!LockPolicy.isFrozen(t, now: t0))
        expect(LockPolicy.isFrozen(t, now: t0.addingTimeInterval(LockPolicy.creationGrace)))
    }

    func finishedTasksCanBeDeleted() {
        expect(LockPolicy.canDeleteWithoutGuardian(task(due: hours(1), status: .proven(at: t0)), now: t0))
    }

    func taskInPenaltyIsFrozen() {
        let t = task(due: -hours(1), status: .provenLate(at: t0, penaltyEndsAt: t0.addingTimeInterval(600)))
        expect(!LockPolicy.canDeleteWithoutGuardian(t, now: t0))
    }
}

struct ClockAndGuardian {
    func clockCannotGoBackwards() {
        let seen = t0.addingTimeInterval(hours(5))
        expect(LockPolicy.effectiveNow(systemNow: t0, lastSeen: seen) == seen)
        expect(LockPolicy.effectiveNow(systemNow: t0, lastSeen: nil) == t0)
        expect(LockPolicy.effectiveNow(systemNow: seen.addingTimeInterval(1), lastSeen: seen) == seen.addingTimeInterval(1))
    }

    func guardianCodeVerifies() {
        let record = Guardian.makeRecord(code: "correct-horse", iterations: 1000)
        expect(Guardian.verify(code: "correct-horse", record: record))
        expect(!Guardian.verify(code: "correct-hors", record: record))
        expect(!Guardian.verify(code: "", record: record))
        expect(record.hash.count == 32)
    }

    func saltDiffersEachTime() {
        let a = Guardian.makeRecord(code: "123456", iterations: 1000)
        let b = Guardian.makeRecord(code: "123456", iterations: 1000)
        expect(a.salt != b.salt)
        expect(a.hash != b.hash)
    }

    func wrongCodesBackOff() {
        expect(LockPolicy.guardianCooldown(afterFailures: 2) == 0)
        expect(LockPolicy.guardianCooldown(afterFailures: 3) == 30)
        expect(LockPolicy.guardianCooldown(afterFailures: 4) == 60)
        expect(LockPolicy.guardianCooldown(afterFailures: 20) == 3600)
    }
}

struct AllowlistRules {
    func listedAppsAndHelpersAllowed() {
        expect(Allowlist.isAllowed(bundleID: "company.thebrowser.Browser", extra: [], selfID: nil))
        expect(Allowlist.isAllowed(bundleID: "us.zoom.xos.Helper", extra: [], selfID: nil))
        expect(Allowlist.isAllowed(bundleID: "com.apple.finder", extra: [], selfID: nil))
    }

    func othersBlocked() {
        expect(!Allowlist.isAllowed(bundleID: "com.microsoft.VSCode", extra: [], selfID: nil))
        expect(!Allowlist.isAllowed(bundleID: "com.apple.Terminal", extra: [], selfID: nil))
        expect(!Allowlist.isAllowed(bundleID: "com.apple.mailfake", extra: [], selfID: nil))
        expect(!Allowlist.isAllowed(bundleID: nil, extra: [], selfID: nil))
    }

    func guardianExtrasAndSelfAllowed() {
        expect(Allowlist.isAllowed(bundleID: "com.apple.Terminal", extra: ["com.apple.Terminal"], selfID: nil))
        expect(Allowlist.isAllowed(bundleID: "io.example.me", extra: [], selfID: "io.example.me"))
    }
}

struct Persistence {
    func roundTripsTasksAndSettings() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir)
        let proof = ProofSubmission(submittedAt: t0, note: "done", attachments: ["a.png"], verdict: .accepted, reason: "ok")
        let tasks = [task(due: hours(1), status: .provenLate(at: t0, penaltyEndsAt: t0.addingTimeInterval(60)), proofs: [proof]),
                     TaxTask(title: "Imported", dueDate: t0, createdAt: t0, source: .blackbaud(uid: "abc"))]
        store.saveTasks(tasks)
        expect(store.loadTasks() == tasks)

        var settings = Settings()
        settings.penaltyMinutes = 5
        settings.overrideUntil = t0
        store.saveSettings(settings)
        expect(store.loadSettings() == settings)
    }

    func oldSettingsFileKeepsDefaults() {
        let data = #"{"penaltyMinutes": 10}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let s = try! decoder.decode(Settings.self, from: data)
        expect(s.penaltyMinutes == 10)
        expect(s.claudePath == "/opt/homebrew/bin/claude")
    }
}

struct AuditorParsing {
    func plainJSON() {
        let r = Auditor.parseVerdict(#"{"verdict":"accept","reason":"All ten problems shown."}"#)
        expect(r.verdict == .accepted)
        expect(r.reason == "All ten problems shown.")
    }

    func fencedAndWrapped() {
        let r = Auditor.parseVerdict("Here you go:\n```json\n{\"verdict\": \"reject\", \"reason\": \"Blank page.\"}\n```")
        expect(r.verdict == .rejected)
    }

    func noVerdictIsError() {
        expect(Auditor.parseVerdict("I think it's fine").verdict == .error)
        expect(Auditor.parseVerdict(#"{"verdict":"maybe"}"#).verdict == .error)
    }

    func cliEnvelope() {
        let ok = #"{"type":"result","is_error":false,"result":"{\"verdict\":\"accept\",\"reason\":\"ok\"}"}"#
        expect(Auditor.parse(cliOutput: Data(ok.utf8)).verdict == .accepted)
        let failed = #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate"}"#
        let r = Auditor.parse(cliOutput: Data(failed.utf8))
        expect(r.verdict == .error)
        expect(r.reason.contains("Failed to authenticate"))
        expect(Auditor.parse(cliOutput: Data()).verdict == .error)
    }
}

let checks: [(String, () -> Void)] = [
    ("AuditorParsing.plainJSON", { AuditorParsing().plainJSON() }),
    ("AuditorParsing.fencedAndWrapped", { AuditorParsing().fencedAndWrapped() }),
    ("AuditorParsing.noVerdictIsError", { AuditorParsing().noVerdictIsError() }),
    ("AuditorParsing.cliEnvelope", { AuditorParsing().cliEnvelope() }),
    ("LockRule.nothingDueMeansUnlocked", { LockRule().nothingDueMeansUnlocked() }),
    ("LockRule.overduePendingLocks", { LockRule().overduePendingLocks() }),
    ("LockRule.dueExactlyNowLocks", { LockRule().dueExactlyNowLocks() }),
    ("LockRule.provenAndExcusedDoNotLock", { LockRule().provenAndExcusedDoNotLock() }),
    ("LockRule.penaltyLocksUntilItEnds", { LockRule().penaltyLocksUntilItEnds() }),
    ("LockRule.guardianOverrideUnlocksUntilItExpires", { LockRule().guardianOverrideUnlocksUntilItExpires() }),
    ("LockRule.proofSentBeforeDueHoldsTheLockWhileChecking", { LockRule().proofSentBeforeDueHoldsTheLockWhileChecking() }),
    ("LockRule.acceptingOnTimeVersusLate", { LockRule().acceptingOnTimeVersusLate() }),
    ("EditWindow.farAwayTaskIsEditable", { EditWindow().farAwayTaskIsEditable() }),
    ("EditWindow.inside24HoursIsFrozen", { EditWindow().inside24HoursIsFrozen() }),
    ("EditWindow.movingEarlierIsAlwaysAllowed", { EditWindow().movingEarlierIsAlwaysAllowed() }),
    ("EditWindow.freshTaskHasTypoGrace", { EditWindow().freshTaskHasTypoGrace() }),
    ("EditWindow.finishedTasksCanBeDeleted", { EditWindow().finishedTasksCanBeDeleted() }),
    ("EditWindow.taskInPenaltyIsFrozen", { EditWindow().taskInPenaltyIsFrozen() }),
    ("ClockAndGuardian.clockCannotGoBackwards", { ClockAndGuardian().clockCannotGoBackwards() }),
    ("ClockAndGuardian.guardianCodeVerifies", { ClockAndGuardian().guardianCodeVerifies() }),
    ("ClockAndGuardian.saltDiffersEachTime", { ClockAndGuardian().saltDiffersEachTime() }),
    ("ClockAndGuardian.wrongCodesBackOff", { ClockAndGuardian().wrongCodesBackOff() }),
    ("AllowlistRules.listedAppsAndHelpersAllowed", { AllowlistRules().listedAppsAndHelpersAllowed() }),
    ("AllowlistRules.othersBlocked", { AllowlistRules().othersBlocked() }),
    ("AllowlistRules.guardianExtrasAndSelfAllowed", { AllowlistRules().guardianExtrasAndSelfAllowed() }),
    ("Persistence.roundTripsTasksAndSettings", { Persistence().roundTripsTasksAndSettings() }),
    ("Persistence.oldSettingsFileKeepsDefaults", { Persistence().oldSettingsFileKeepsDefaults() }),
]

for (name, run) in checks {
    current = name
    run()
}
print(failures == 0 ? "All \(checks.count) checks passed." : "\(failures) failure(s) in \(checks.count) checks.")
exit(failures == 0 ? 0 : 1)
