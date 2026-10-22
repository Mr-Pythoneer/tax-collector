// Runs the TaxCore checks. Swift Testing can't discover tests under Command Line Tools
// alone, so this is a plain executable: `swift run taxcore-check`.
import CryptoKit
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

    func checkInFlightHoldsOffTheLockOnlyBriefly() {
        // Proof sent before the deadline, Claude still checking after it.
        var t = task(due: -60)
        t.proofs = [ProofSubmission(submittedAt: t0.addingTimeInterval(-120), note: "", attachments: [])]
        expect(!LockPolicy.isOverdue(t, now: t0))
        expect(LockPolicy.isOverdue(t, now: t.dueDate.addingTimeInterval(LockPolicy.checkGrace + 1)))
        // Sent after the deadline: no grace at all.
        t.proofs = [ProofSubmission(submittedAt: t0.addingTimeInterval(-30), note: "", attachments: [])]
        expect(LockPolicy.isOverdue(t, now: t0))
    }

    func recheckAfterDeadlineDoesNotLift() {
        var t = task(due: -60)
        t.proofs = [ProofSubmission(submittedAt: t0.addingTimeInterval(-120), note: "", attachments: [],
                                    recheckedAt: t0.addingTimeInterval(-30))]
        expect(LockPolicy.isOverdue(t, now: t0))
        t.proofs[0].recheckedAt = t0.addingTimeInterval(-90)
        expect(!LockPolicy.isOverdue(t, now: t0))
        // The new field survives a save, and files without it still load.
        let data = try? JSONEncoder().encode(t.proofs[0])
        expect(data.flatMap { try? JSONDecoder().decode(ProofSubmission.self, from: $0) } == t.proofs[0])
        let old = #"{"id":"4D1C8B0E-7F4A-4C11-9E2B-1A2B3C4D5E6F","submittedAt":0,"note":"","attachments":[],"reason":""}"#
        expect((try? JSONDecoder().decode(ProofSubmission.self, from: Data(old.utf8)))?.recheckedAt == nil)
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
        settings.blackbaudURL = "https://school.myschoolapp.com/podium/feed/iCal.aspx?z=abc"
        settings.blackbaudOnSince = t0
        settings.allDayDueMinutes = 8 * 60
        store.saveSettings(settings)
        expect(store.loadSettings() == settings)

        var feed = BlackbaudState()
        feed.lastSeen["u1"] = BlackbaudAssignment(uid: "u1", title: "Essay", dueDate: t0)
        feed.dismiss(uid: "u2", title: "Gone", due: t0)
        feed.lastSync = t0
        store.saveBlackbaud(feed)
        expect(store.loadBlackbaud() == feed)
    }

    func oldSettingsFileKeepsDefaults() {
        let data = #"{"penaltyMinutes": 10}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let s = try! decoder.decode(Settings.self, from: data)
        expect(s.penaltyMinutes == 10)
        expect(s.claudePath == "/opt/homebrew/bin/claude")
        expect(s.blackbaudURL == nil)
        expect(s.allDayDueMinutes == Blackbaud.defaultAllDayDueMinutes)
        // 10 PM the evening before.
        let e = ICalEvent(uid: "a", start: .allDay(year: 2026, month: 10, day: 16))
        expect(Blackbaud.dueDate(of: e, allDayDueMinutes: s.allDayDueMinutes, timeZone: ny) == nyDate(2026, 10, 15, 22, 0))
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

// MARK: Blackbaud feed

private let ny = TimeZone(identifier: "America/New_York")!

private func nyDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = ny
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func calendarText(_ body: String) -> String {
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\n" + body + "END:VCALENDAR\r\n"
}

private func event(_ lines: String) -> String { "BEGIN:VEVENT\r\n" + lines + "END:VEVENT\r\n" }

private func one(_ body: String, zone: TimeZone = ny) -> ICalEvent? {
    let events = ICal.parse(calendarText(body), defaultTimeZone: zone)
    return events.count == 1 ? events[0] : nil
}

struct ICalParsing {
    func unfoldsFoldedLines() {
        let e = one(event("UID:a1\r\nSUMMARY:AP Biology - 2: Unit 3\r\n  Test\r\nDESCRIPTION:Line one\r\n\tcontinued\r\nDTSTART;VALUE=DATE:20261016\r\n"))
        expect(e?.summary == "AP Biology - 2: Unit 3 Test")
        expect(e?.description == "Line onecontinued")
        expect(e?.uid == "a1")
    }

    func bareLineFeedsWork() {
        let text = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:lf\nSUMMARY:Lab\n  report\nDTSTART;VALUE=DATE:20261016\nEND:VEVENT\nEND:VCALENDAR\n"
        let events = ICal.parse(text, defaultTimeZone: ny)
        expect(events.count == 1)
        expect(events.first?.summary == "Lab report")
    }

    func multibyteSplitAcrossFold() {
        var bytes = Array("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nSUMMARY:Caf".utf8)
        bytes += [0xC3, 0x0D, 0x0A, 0x20, 0xA9]
        bytes += Array(" quiz\r\nDTSTART;VALUE=DATE:20261016\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        let events = ICal.parse(Data(bytes), defaultTimeZone: ny)
        expect(events.first?.summary == "Café quiz")
    }

    func allDayDates() {
        expect(one(event("UID:a\r\nDTSTART;VALUE=DATE:20261016\r\nDTEND;VALUE=DATE:20261017\r\n"))?.start
               == .allDay(year: 2026, month: 10, day: 16))
        expect(one(event("UID:b\r\nDTSTART:20261016\r\n"))?.start == .allDay(year: 2026, month: 10, day: 16))
        expect(one(event("UID:c\r\nDTSTART:2026-13-01\r\n"))?.start == nil)
    }

    func zonedTimes() {
        let eight = nyDate(2026, 10, 16, 8, 0)
        expect(one(event("UID:a\r\nDTSTART;TZID=America/New_York:20261016T080000\r\n"))?.start == .moment(eight))
        expect(one(event("UID:b\r\nDTSTART;TZID=\"Eastern Standard Time\":20261016T080000\r\n"))?.start == .moment(eight))
        expect(one(event("UID:c\r\nDTSTART;TZID=/mozilla.org/20050126_1/America/New_York:20261016T080000\r\n"))?.start == .moment(eight))
        expect(one(event("UID:d\r\nDTSTART:20261016T120000Z\r\n"), zone: TimeZone(identifier: "Asia/Tokyo")!)?.start == .moment(eight))
    }

    func floatingTimesUseCalendarZone() {
        let hk = TimeZone(identifier: "Asia/Hong_Kong")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = hk
        let hkEight = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 8))!
        expect(one("X-WR-TIMEZONE:Asia/Hong_Kong\r\n" + event("UID:a\r\nDTSTART:20261016T080000\r\n"))?.start == .moment(hkEight))
        expect(one(event("UID:b\r\nDTSTART:20261016T080000\r\n"), zone: hk)?.start == .moment(hkEight))
        // An unknown TZID falls back to the calendar's zone instead of dropping the time.
        expect(one(event("UID:c\r\nDTSTART;TZID=Nowhere/Special:20261016T080000\r\n"), zone: hk)?.start == .moment(hkEight))
    }

    func todoWithDue() {
        let e = one("BEGIN:VTODO\r\nUID:t1\r\nSUMMARY:Problem set\r\nDUE;VALUE=DATE:20261020\r\nEND:VTODO\r\n")
        expect(e?.kind == .todo)
        expect(e?.due == .allDay(year: 2026, month: 10, day: 20))
    }

    func textEscapes() {
        let e = one(event(#"UID:a\;1"# + "\r\n" + #"SUMMARY:Read pp. 1\,2\; quiz\\notes\nthen rest"# + "\r\nDTSTART:20261016\r\n"))
        expect(e?.summary == "Read pp. 1,2; quiz\\notes\nthen rest")
        expect(e?.uid == "a;1")
    }

    func nestedPartsDontLeak() {
        let tz = "BEGIN:VTIMEZONE\r\nTZID:America/New_York\r\nBEGIN:STANDARD\r\nDTSTART:19701101T020000\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n"
        let body = event("UID:a\r\nSUMMARY:Essay\r\nDTSTART;VALUE=DATE:20261016\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nEND:VALARM\r\nDESCRIPTION:Real details\r\n")
        let e = one(tz + body)
        expect(e?.description == "Real details")
        expect(e?.start == .allDay(year: 2026, month: 10, day: 16))
    }

    func quotedParameters() {
        let e = one(event("UID:a\r\nDTSTART;X-NOTE=\"a:b;c\";TZID=\"America/New_York\":20261016T080000\r\n"))
        expect(e?.start == .moment(nyDate(2026, 10, 16, 8, 0)))
    }

    func statusAndCategories() {
        let e = one(event("UID:a\r\nSTATUS:cancelled\r\nCATEGORIES:Homework,Major Assessment\r\nCATEGORIES:Lab\\, practical\r\nDTSTART:20261016\r\n"))
        expect(e?.status == "CANCELLED")
        expect(e?.categories == ["Homework", "Major Assessment", "Lab, practical"])
    }

    func missingUIDIsStable() {
        let body = event("SUMMARY:No id\r\nDTSTART;VALUE=DATE:20261016\r\n")
        let a = one(body)?.uid, b = one(body)?.uid
        expect(a != nil && a == b && !(a ?? "").isEmpty)
    }

    func spotsNonCalendars() {
        expect(ICal.looksLikeCalendar(Data(calendarText("").utf8)))
        expect(!ICal.looksLikeCalendar(Data("<!DOCTYPE html><html><body>Sign in</body></html>".utf8)))
        expect(ICal.parse("garbage").isEmpty)
    }
}

struct FeedMapping {
    private func due(_ e: ICalEvent, minutes: Int = 23 * 60 + 59) -> Date? {
        Blackbaud.dueDate(of: e, allDayDueMinutes: minutes, timeZone: ny)
    }
    private let day = ICalTime.allDay(year: 2026, month: 10, day: 16)

    func allDayUsesChosenTime() {
        let e = ICalEvent(uid: "a", start: day, end: .allDay(year: 2026, month: 10, day: 17))
        expect(due(e) == nyDate(2026, 10, 16, 23, 59))
        expect(due(e, minutes: 8 * 60) == nyDate(2026, 10, 16, 8, 0))
        expect(due(e, minutes: -120) == nyDate(2026, 10, 15, 22, 0))
    }

    func allDayOnClockChangeDay() {
        // US clocks fall back on 1 Nov 2026. 11:59 PM is still 11:59 PM.
        let e = ICalEvent(uid: "a", start: .allDay(year: 2026, month: 11, day: 1))
        expect(due(e) == nyDate(2026, 11, 1, 23, 59))
        expect(due(e, minutes: 8 * 60) == nyDate(2026, 11, 1, 8, 0))
    }

    func timedEventUsesItsStart() {
        let e = ICalEvent(uid: "a", start: .moment(nyDate(2026, 10, 16, 8, 0)), end: .moment(nyDate(2026, 10, 16, 9, 0)))
        expect(due(e) == nyDate(2026, 10, 16, 8, 0))
    }

    func spanningEventUsesItsLastDay() {
        let allDay = ICalEvent(uid: "a", start: .allDay(year: 2026, month: 10, day: 12), end: .allDay(year: 2026, month: 10, day: 16))
        expect(due(allDay) == nyDate(2026, 10, 15, 23, 59))
        let timed = ICalEvent(uid: "b", start: .moment(nyDate(2026, 10, 12, 8, 0)), end: .moment(nyDate(2026, 10, 16, 15, 0)))
        expect(due(timed) == nyDate(2026, 10, 16, 15, 0))
    }

    func dueBeatsStart() {
        let e = ICalEvent(kind: .todo, uid: "a", start: .allDay(year: 2026, month: 10, day: 1), due: .moment(nyDate(2026, 10, 20, 9, 0)))
        expect(due(e) == nyDate(2026, 10, 20, 9, 0))
    }

    func skipsCancelledUndatedAndRepeats() {
        let events = [ICalEvent(uid: "a", summary: "Keep", start: day),
                      ICalEvent(uid: "b", summary: "Cancelled", start: day, status: "CANCELLED"),
                      ICalEvent(uid: "c", summary: "No date"),
                      ICalEvent(uid: "a", summary: "Repeat", start: day),
                      ICalEvent(uid: "d", summary: "  ", start: day)]
        let items = Blackbaud.assignments(from: events, allDayDueMinutes: 0, timeZone: ny)
        expect(items.map(\.uid) == ["a", "d"])
        expect(items.first?.title == "Keep")
        expect(items.last?.title == "Untitled assignment")
    }

    func htmlBecomesPlainText() {
        let html = "<p>Read <b>chapter 3</b> &amp; answer 1&nbsp;-&nbsp;5.</p><br>Bring   notes &amp;lt;3"
        expect(Blackbaud.plainText(html) == "Read chapter 3 & answer 1 - 5.\nBring notes &lt;3")
        expect(Blackbaud.plainText("Plain 2 < 3 text") == "Plain 2 < 3 text")
    }

    func feedLinks() {
        let link = "webcal://school.myschoolapp.com/podium/feed/iCal.aspx?z=SECRET%3d%3d"
        let url = Blackbaud.feedURL(from: "  \(link)\n")
        expect(url?.absoluteString == "https://school.myschoolapp.com/podium/feed/iCal.aspx?z=SECRET%3d%3d")
        expect(Blackbaud.feedURL(from: "WEBCAL://school.myschoolapp.com/x.ics")?.scheme == "https")
        expect(Blackbaud.feedURL(from: "http://school.myschoolapp.com/x.ics")?.scheme == "https")
        expect(Blackbaud.feedURL(from: "file:///tmp/sample.ics")?.isFileURL == true)
        expect(Blackbaud.feedURL(from: "not a link") == nil)
        expect(Blackbaud.feedURL(from: "") == nil)
        expect(Blackbaud.feedURL(from: "ftp://school.myschoolapp.com/x") == nil)
        expect(Blackbaud.feedURL(from: "https://intranet/x") == nil)
        let shown = url.map(Blackbaud.redacted) ?? ""
        expect(shown == "school.myschoolapp.com/podium/feed/iCal.aspx")
        expect(!shown.contains("SECRET"))
    }
}

struct FeedSync {
    private let essay = BlackbaudAssignment(uid: "u1", title: "Essay", details: "Two pages", dueDate: t0.addingTimeInterval(hours(48)))

    private func imported(_ items: [BlackbaudAssignment], at now: Date = t0) -> BlackbaudSyncResult {
        Blackbaud.sync(tasks: [], state: BlackbaudState(), assignments: items, now: now)
    }

    func importsFutureAssignmentsOnly() {
        let past = BlackbaudAssignment(uid: "old", title: "Old", dueDate: t0.addingTimeInterval(-60))
        let r = imported([essay, past])
        expect(r.added.count == 1)
        expect(r.tasks.count == 1)
        expect(r.tasks.first?.source == .blackbaud(uid: "u1"))
        expect(r.tasks.first?.title == "Essay")
        expect(r.tasks.first?.details == "Two pages")
        expect(r.tasks.first?.createdAt == t0)
        expect(r.state.lastSeen["u1"] == essay)
        expect(r.state.lastSeen["old"] == nil)
    }

    func repollDedupesOnUID() {
        let first = imported([essay])
        let again = Blackbaud.sync(tasks: first.tasks, state: first.state, assignments: [essay, essay],
                                   now: t0.addingTimeInterval(1800))
        expect(again.tasks.count == 1)
        expect(again.added.isEmpty)
        expect(again.notes.isEmpty)
    }

    func deletedAssignmentsStayDeleted() {
        var state = imported([essay]).state
        state.dismiss(uid: "u1", title: essay.title, due: essay.dueDate)
        let r = Blackbaud.sync(tasks: [], state: state, assignments: [essay], now: t0.addingTimeInterval(60))
        expect(r.tasks.isEmpty)
        expect(r.state.lastSeen["u1"] == nil)
    }

    func teacherChangeAppliesBeforeLockIn() {
        let first = imported([essay])
        var changed = essay
        changed.title = "Essay (3 pages)"
        changed.dueDate = t0.addingTimeInterval(hours(72))
        let r = Blackbaud.sync(tasks: first.tasks, state: first.state, assignments: [changed], now: t0.addingTimeInterval(hours(1)))
        expect(r.tasks.first?.title == "Essay (3 pages)")
        expect(r.tasks.first?.dueDate == changed.dueDate)
        expect(r.tasks.first?.details == "Two pages")
        expect(r.notes.count == 1)
    }

    func yourEditsSurviveAnUnchangedFeed() {
        let first = imported([essay])
        var tasks = first.tasks
        tasks[0].title = "Essay, with outline photo"
        tasks[0].dueDate = t0.addingTimeInterval(hours(30))
        let r = Blackbaud.sync(tasks: tasks, state: first.state, assignments: [essay], now: t0.addingTimeInterval(hours(1)))
        expect(r.tasks == tasks)
    }

    func lockedInTaskOnlyMovesEarlier() {
        let first = imported([essay])
        let lockedIn = t0.addingTimeInterval(hours(30)) // 18 hours left
        var later = essay
        later.title = "Essay (optional)"
        later.dueDate = t0.addingTimeInterval(hours(96))
        let kept = Blackbaud.sync(tasks: first.tasks, state: first.state, assignments: [later], now: lockedIn)
        expect(kept.tasks.first?.title == "Essay")
        expect(kept.tasks.first?.dueDate == essay.dueDate)
        expect(kept.notes.count == 1)
        // The feed's new version is remembered, so the same refusal isn't logged every 30 minutes.
        let quiet = Blackbaud.sync(tasks: kept.tasks, state: kept.state, assignments: [later], now: lockedIn.addingTimeInterval(1800))
        expect(quiet.notes.isEmpty)

        var sooner = essay
        sooner.title = "Essay (renamed)"
        sooner.dueDate = t0.addingTimeInterval(hours(40))
        let moved = Blackbaud.sync(tasks: first.tasks, state: first.state, assignments: [sooner], now: lockedIn)
        expect(moved.tasks.first?.dueDate == sooner.dueDate)
        expect(moved.tasks.first?.title == "Essay")
    }

    func neverMovesADeadlineIntoThePast() {
        let first = imported([essay])
        var past = essay
        past.dueDate = t0.addingTimeInterval(-hours(1))
        let r = Blackbaud.sync(tasks: first.tasks, state: first.state, assignments: [past], now: t0.addingTimeInterval(60))
        expect(r.tasks.first?.dueDate == essay.dueDate)
        expect(r.notes.count == 1)
    }

    func paidTasksIgnoreTheFeed() {
        let first = imported([essay])
        var tasks = first.tasks
        tasks[0].status = .proven(at: t0.addingTimeInterval(60))
        var changed = essay
        changed.dueDate = t0.addingTimeInterval(hours(20))
        let r = Blackbaud.sync(tasks: tasks, state: first.state, assignments: [changed], now: t0.addingTimeInterval(120))
        expect(r.tasks == tasks)
    }

    func assignmentsLeavingTheFeedStay() {
        let first = imported([essay])
        let r = Blackbaud.sync(tasks: first.tasks, state: first.state, assignments: [], now: t0.addingTimeInterval(60))
        expect(r.tasks == first.tasks)
    }

    func manualTasksAreUntouched() {
        let manual = task(due: hours(5))
        let r = Blackbaud.sync(tasks: [manual], state: BlackbaudState(), assignments: [essay], now: t0)
        expect(r.tasks.count == 2)
        expect(r.tasks.first == manual)
    }

    func endToEndFromFeedText() {
        let text = calendarText(
            event("UID:bb-1\r\nSUMMARY:English 10 - 3: Read ch. 4\r\nDTSTART;VALUE=DATE:20261016\r\nDTEND;VALUE=DATE:20261017\r\n")
            + event("UID:bb-2\r\nSUMMARY:Old\r\nDTSTART;VALUE=DATE:20261001\r\n"))
        let items = Blackbaud.assignments(from: ICal.parse(text, defaultTimeZone: ny), allDayDueMinutes: 8 * 60, timeZone: ny)
        let r = Blackbaud.sync(tasks: [], state: BlackbaudState(), assignments: items, now: nyDate(2026, 10, 10, 12, 0))
        expect(r.tasks.map(\.title) == ["English 10 - 3: Read ch. 4"])
        expect(r.tasks.first?.dueDate == nyDate(2026, 10, 16, 8, 0))
    }
}

struct FeedPolicy {
    private func importedTask(due: TimeInterval) -> TaxTask {
        TaxTask(title: "Lab", dueDate: t0.addingTimeInterval(due), createdAt: t0.addingTimeInterval(-hours(72)),
                source: .blackbaud(uid: "x"))
    }

    func stoppingTheFeed() {
        let far = importedTask(due: hours(48))
        let soon = importedTask(due: hours(3))
        let onLongAgo = t0.addingTimeInterval(-hours(100))
        expect(LockPolicy.canStopFeedWithoutGuardian(onSince: onLongAgo, tasks: [far], now: t0))
        expect(!LockPolicy.canStopFeedWithoutGuardian(onSince: onLongAgo, tasks: [far, soon], now: t0))
        // A manual task that's locked in doesn't hold the feed.
        expect(LockPolicy.canStopFeedWithoutGuardian(onSince: onLongAgo, tasks: [far, task(due: hours(3))], now: t0))
        // Five minutes to undo turning it on.
        expect(LockPolicy.canStopFeedWithoutGuardian(onSince: t0.addingTimeInterval(-60), tasks: [soon], now: t0))
        var paid = soon
        paid.status = .proven(at: t0)
        expect(LockPolicy.canStopFeedWithoutGuardian(onSince: onLongAgo, tasks: [paid], now: t0))
    }
}

struct LastCheckRules {
    func auditorChecklistParsed() {
        let r = Auditor.parseVerdict(#"{"verdict":"accept","reason":"ok","checklist":["Answer 1-10"," ","Show work",3]}"#)
        expect(r.checklist == ["Answer 1-10", "Show work"])
        let many = (1...20).map { "\"item \($0)\"" }.joined(separator: ",")
        expect(Auditor.parseVerdict("{\"verdict\":\"reject\",\"checklist\":[\(many)]}").checklist.count == Auditor.maxChecklistItems)
        expect(Auditor.parseVerdict(#"{"verdict":"accept"}"#).checklist.isEmpty)
    }

    func fallbackUsesListLines() {
        let details = "Read chapter 4.\n- Answer questions 1-5\n- Write a summary\n2) Upload to OneDrive"
        expect(Auditor.fallbackChecklist(title: "HW", details: details)
               == ["Answer questions 1-5", "Write a summary", "Upload to OneDrive"])
        expect(Auditor.fallbackChecklist(title: "Essay draft", details: "Write the draft.") == ["Essay draft"])
    }

    func onlyPaidBlackbaudTasksNeedIt() {
        var t = TaxTask(title: "HW", dueDate: t0, createdAt: t0, source: .blackbaud(uid: "x"))
        expect(!t.needsLastCheck)
        t.status = .proven(at: t0)
        expect(t.needsLastCheck)
        t.status = .provenLate(at: t0, penaltyEndsAt: t0)
        expect(t.needsLastCheck)
        t.lastCheckDoneAt = t0
        expect(!t.needsLastCheck)
        var manual = TaxTask(title: "HW", dueDate: t0, createdAt: t0)
        manual.status = .proven(at: t0)
        expect(!manual.needsLastCheck)
    }

    func oldTasksStillLoad() {
        let json = #"[{"id":"6F1C2C3E-0000-4000-8000-000000000001","title":"Old","details":"","dueDate":"2026-10-15T23:35:15Z","createdAt":"2026-10-15T23:00:00Z","source":{"manual":{}},"status":{"pending":{}},"proofs":[]}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let tasks = try? decoder.decode([TaxTask].self, from: Data(json.utf8))
        expect(tasks?.count == 1)
        expect(tasks?.first?.checklist == nil)
        expect(tasks?.first?.blackbaudMark == nil)
    }
}

struct MatchRules {
    let list = [
        BlackbaudListedAssignment(indexID: 90011, assignmentID: 5501, title: "Worksheet 3.2", course: "Algebra II",
                                  due: t0, status: -1),
        BlackbaudListedAssignment(indexID: 90012, assignmentID: 5502, title: "Worksheet 3.3", course: "Algebra II",
                                  due: t0.addingTimeInterval(2 * 86400), status: -1),
        BlackbaudListedAssignment(indexID: 90013, assignmentID: 5503, title: "Essay draft", course: "English",
                                  due: t0.addingTimeInterval(7 * 86400), status: -1),
    ]

    func idInUIDWins() {
        expect(BlackbaudMatch.find(feedUID: "assignment-5502@school", title: "whatever", due: t0, in: list)?.indexID == 90012)
    }

    func titleAndDayMatch() {
        // Feed title with the course glued on, deadline moved to the evening before.
        let m = BlackbaudMatch.find(feedUID: "abc", title: "Algebra II: Worksheet 3.2!", due: t0.addingTimeInterval(-10 * 3600), in: list)
        expect(m?.indexID == 90011)
    }

    func wrongDayOrTitleIsNoMatch() {
        expect(BlackbaudMatch.find(feedUID: "abc", title: "Worksheet 3.2", due: t0.addingTimeInterval(5 * 86400), in: list) == nil)
        expect(BlackbaudMatch.find(feedUID: "abc", title: "Lab report", due: t0, in: list) == nil)
        expect(BlackbaudMatch.find(feedUID: "abc", title: "", due: t0, in: list) == nil)
    }

    func movedDeadlineStillMatches() {
        // The guardian moved the task three days later; Blackbaud still has it on the original day.
        var state = BlackbaudState()
        state.lastSeen["uid-1"] = BlackbaudAssignment(uid: "uid-1", title: "Algebra II: Worksheet 3.2", dueDate: t0)
        let moved = TaxTask(title: "Algebra II: Worksheet 3.2", dueDate: t0.addingTimeInterval(3 * 86400),
                            createdAt: t0.addingTimeInterval(-86400), source: .blackbaud(uid: "uid-1"))
        expect(BlackbaudMatch.find(feedUID: "uid-1", title: moved.title, due: moved.dueDate, in: list) == nil)
        let due = state.blackbaudDue(of: moved)
        expect(due == t0)
        expect(BlackbaudMatch.find(feedUID: "uid-1", title: moved.title, due: due, in: list)?.indexID == 90011)
        // A UID Blackbaud has since changed: found by title instead.
        var renamed = moved
        renamed.source = .blackbaud(uid: "uid-old")
        expect(state.blackbaudDue(of: renamed) == t0)
        // Nothing known about it, or not from Blackbaud: its own deadline.
        let manual = TaxTask(title: "Read", dueDate: t0, createdAt: t0)
        expect(state.blackbaudDue(of: manual) == t0)
        renamed.title = "Something else"
        expect(state.blackbaudDue(of: renamed) == renamed.dueDate)
    }
}

struct FeedText {
    func numericEntitiesDecoded() {
        expect(Blackbaud.plainText("&#9989; To be completed : &#128187; Amplify") == "✅ To be completed : 💻 Amplify")
        expect(Blackbaud.plainText("Playing Test No.1&#160;") == "Playing Test No.1")
        expect(Blackbaud.plainText("caf&#xE9; &amp;#160; &lt;b&gt;") == "café &#160; <b>")
        expect(Blackbaud.plainText("bad &#99999999; stays") == "bad &#99999999; stays")
    }
}

struct AgendaRules {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func task(_ title: String, due: TimeInterval, status: TaskStatus = .pending, bb: Bool = false) -> TaxTask {
        TaxTask(title: title, dueDate: t0.addingTimeInterval(due), createdAt: t0.addingTimeInterval(-86400 * 3),
                source: bb ? .blackbaud(uid: title) : .manual, status: status)
    }

    func groupsAndRanks() {
        let tasks = [
            task("later today", due: 2 * 3600),
            task("overdue b", due: -60),
            task("next week", due: 7 * 86400),
            task("soon today", due: 600),
            task("overdue a", due: -7200),
            task("paid", due: 3600, status: .proven(at: t0)),
            task("fee", due: -3600, status: .provenLate(at: t0, penaltyEndsAt: t0.addingTimeInterval(900))),
        ]
        let s = Agenda.sections(tasks, now: t0, calendar: cal)
        expect(s.first?.kind == .lateFee)
        expect(s[1].kind == .overdue)
        expect(s[1].tasks.map(\.title) == ["overdue a", "overdue b"])
        let days = s.dropFirst(2)
        expect(days.flatMap(\.tasks).map(\.title) == ["soon today", "later today", "next week"])
        expect(days.count >= 2)
        expect(!s.flatMap(\.tasks).contains { $0.title == "paid" })
        if case let .day(d) = days.first?.kind { expect(d == cal.startOfDay(for: t0.addingTimeInterval(600))) } else { expect(false) }
    }

    func blackbaudTitlesSplit() {
        let a = Agenda.courseAndTitle(task("Mathematics 7 - MAT7 - 7B: Unit 1 Lesson 4 : Transformations", due: 0, bb: true))
        expect(a.course == "Mathematics 7")
        expect(a.title == "Unit 1 Lesson 4 : Transformations")
        expect(Agenda.courseAndTitle(task("Science 7- SCI7 - 7B: Microscopy Lab", due: 0, bb: true)).course == "Science 7")
        expect(Agenda.courseAndTitle(task("Middle School Students - 2026-27: Exploratory Form", due: 0, bb: true)).course == "Middle School Students")
        expect(Agenda.courseAndTitle(task("Physical Education - PHE7 - 7B: Cross Country Run", due: 0, bb: true)).course == "Physical Education")
        expect(Agenda.courseAndTitle(task("Music 7 - MUS7 - 7B: Playing Test No.1&#160;", due: 0, bb: true)).title == "Playing Test No.1")
        let manual = Agenda.courseAndTitle(task("Note: buy pens", due: 0))
        expect(manual.course == nil && manual.title == "Note: buy pens")
    }

    func colorsAreStable() {
        expect(Agenda.colorSlot(for: "Mathematics 7", slots: 8) == Agenda.colorSlot(for: "mathematics 7", slots: 8))
        expect(Agenda.colorSlot(for: "Science 7", slots: 8) < 8)
        expect(Agenda.colorSlot(for: "x", slots: 0) == 0)
    }
}

struct RealFeedMatching {
    // Shapes taken from a real school's feed and assignment list.
    let pe = "Physical Education - PHE7 - 7B"
    var list: [BlackbaudListedAssignment] {
        [
            BlackbaudListedAssignment(indexID: 90438812, title: "B. Cross Country Run", course: pe, due: t0, status: Int(Int32.min)),
            BlackbaudListedAssignment(indexID: 90438830, title: "Cross Country Run", course: pe, due: t0, status: Int(Int32.min)),
            BlackbaudListedAssignment(indexID: 90438848, title: "D. Cross Country Run", course: pe, due: t0, status: Int(Int32.min)),
            BlackbaudListedAssignment(indexID: 90339902, title: "Lesson 2", course: "Mathematics - MTHX - MS - 2", due: t0, status: -1),
            BlackbaudListedAssignment(indexID: 90400001, title: "Lesson 2", course: "Science 7- SCI7 - 7B", due: t0, status: -1),
        ]
    }
    let guid = "9463ec1f-94af-412a-9d57-9a2b015afa99"

    func similarTitlesPickTheExactOne() {
        let evening = t0.addingTimeInterval(-20 * 3600)
        expect(BlackbaudMatch.find(feedUID: guid, title: "\(pe): Cross Country Run", due: evening, in: list)?.indexID == 90438830)
        expect(BlackbaudMatch.find(feedUID: guid, title: "\(pe): D. Cross Country Run", due: evening, in: list)?.indexID == 90438848)
        expect(BlackbaudMatch.find(feedUID: guid, title: "\(pe): B. Cross Country Run", due: evening, in: list)?.indexID == 90438812)
    }

    func classDecidesBetweenSameTitles() {
        expect(BlackbaudMatch.find(feedUID: guid, title: "Science 7- SCI7 - 7B: Lesson 2", due: t0, in: list)?.indexID == 90400001)
        expect(BlackbaudMatch.find(feedUID: guid, title: "Mathematics - MTHX - MS - 2: Lesson 2", due: t0, in: list)?.indexID == 90339902)
    }

    func titlesWithColonsSplitOnce() {
        let s = BlackbaudMatch.split("Mathematics - MTHX - MS - 2: Tentative Test Date: Fractions")
        expect(s.course == "Mathematics - MTHX - MS - 2")
        expect(s.name == "Tentative Test Date: Fractions")
    }

    func guidDigitsNeverCountAsIDs() {
        let tricky = [BlackbaudListedAssignment(indexID: 9463, title: "Other thing", course: pe, due: t0)]
        expect(BlackbaudMatch.find(feedUID: guid, title: "\(pe): Cross Country Run", due: t0, in: tricky) == nil)
    }
}

struct ChangingUIDs {
    let day: TimeInterval = 86400
    func item(_ uid: String, _ title: String, in days: Double) -> BlackbaudAssignment {
        BlackbaudAssignment(uid: uid, title: title, dueDate: t0.addingTimeInterval(days * 86400))
    }

    func newUIDsDontDuplicate() {
        let first = Blackbaud.sync(tasks: [], state: BlackbaudState(), assignments: [item("a", "Math 7: Lesson 4", in: 3), item("b", "Science 7: Lab", in: 4)], now: t0)
        let later = Blackbaud.sync(tasks: first.tasks, state: first.state,
                                   assignments: [item("x", "Math 7: Lesson 4", in: 3), item("y", "Science 7: Lab", in: 4)], now: t0.addingTimeInterval(3600))
        expect(later.tasks.count == 2)
        expect(later.added.isEmpty)
        expect(later.tasks.contains { $0.source == .blackbaud(uid: "x") })
        expect(later.state.lastSeen["x"] != nil && later.state.lastSeen["a"] == nil)
    }

    func deletedStaysDeletedAfterNewUID() {
        var state = Blackbaud.sync(tasks: [], state: BlackbaudState(), assignments: [item("a", "Math 7: Lesson 4", in: 3)], now: t0).state
        state.dismiss(uid: "a", title: "Math 7: Lesson 4", due: t0.addingTimeInterval(3 * 86400))
        let r = Blackbaud.sync(tasks: [], state: state, assignments: [item("z", "Math 7: Lesson 4", in: 3)], now: t0.addingTimeInterval(3600))
        expect(r.tasks.isEmpty)
    }

    func weeklyRepeatsGetTheirOwnTasks() {
        let first = Blackbaud.sync(tasks: [], state: BlackbaudState(), assignments: [item("w1", "English 7: Reading log", in: 2)], now: t0)
        // New UIDs, and next week's log appears too. Listed first, it still mustn't take this week's task.
        let r = Blackbaud.sync(tasks: first.tasks, state: first.state,
                               assignments: [item("w2b", "English 7: Reading log", in: 9), item("w1b", "English 7: Reading log", in: 2)],
                               now: t0.addingTimeInterval(3600))
        expect(r.tasks.count == 2)
        expect(r.added.count == 1)
        expect(r.added.first.map { abs($0.dueDate.timeIntervalSince(t0.addingTimeInterval(9 * 86400))) < 1 } == true)
    }

    func teacherMovesDateWithNewUID() {
        let first = Blackbaud.sync(tasks: [], state: BlackbaudState(), assignments: [item("a", "Math 7: Test", in: 5)], now: t0)
        let r = Blackbaud.sync(tasks: first.tasks, state: first.state, assignments: [item("b", "Math 7: Test", in: 6)], now: t0.addingTimeInterval(3600))
        expect(r.tasks.count == 1)
        expect(r.tasks.first.map { abs($0.dueDate.timeIntervalSince(t0.addingTimeInterval(6 * 86400))) < 1 } == true)
    }

    func oldDuplicatesMerge() {
        var done = TaxTask(title: "Math 7: Lesson 4", dueDate: t0, createdAt: t0, source: .blackbaud(uid: "a"))
        done.status = .proven(at: t0)
        let copy = TaxTask(title: "Math 7: Lesson 4&#160;", dueDate: t0, createdAt: t0.addingTimeInterval(60), source: .blackbaud(uid: "b"))
        let other = TaxTask(title: "Science 7: Lab", dueDate: t0, createdAt: t0, source: .blackbaud(uid: "c"))
        let manual = TaxTask(title: "Math 7: Lesson 4", dueDate: t0, createdAt: t0)
        let r = Blackbaud.mergeDuplicates([copy, done, other, manual], state: BlackbaudState())
        expect(r.removed.map(\.id) == [copy.id])
        expect(r.tasks.count == 3)
        // Two copies that both have proof are both kept.
        var proofA = copy
        proofA.proofs = [ProofSubmission(submittedAt: t0, note: "", attachments: [])]
        expect(Blackbaud.mergeDuplicates([proofA, done], state: BlackbaudState()).removed.isEmpty)
    }
}

struct WrittenProof {
    let task = TaxTask(title: "Music 7 - MUS7 - 7B: Playing Test No.1", details: "Play No. 41.", dueDate: t0, createdAt: t0)

    func accountOnlyPromptSaysSo() {
        let p = Auditor.prompt(task: task, note: "Played No. 41 in class; missed the key change at bar 12.", files: [], now: t0)
        expect(p.contains("EVIDENCE FILES: none"))
        expect(p.contains("Judge the written account"))
        expect(p.contains("missed the key change"))
        expect(!p.contains("Read every evidence file"))
    }

    func filesAreListedAsFullPaths() {
        let p = Auditor.prompt(task: task, note: "", files: ["/tmp/proof/a.png", "/tmp/proof/b.pdf"], now: t0)
        expect(p.contains("- /tmp/proof/a.png\n- /tmp/proof/b.pdf"))
        expect(!p.contains("./"))
        expect(p.contains("Read every evidence file"))
    }

    func rulesCoverWrittenProof() {
        expect(Auditor.systemRules.contains("When there are no files"))
        expect(Auditor.minimumWrittenProof >= 20)
    }
}

struct MoreTime {
    func task(_ due: TimeInterval, _ status: TaskStatus = .pending, extensions: [Extension]? = nil) -> TaxTask {
        var t = TaxTask(title: "T", dueDate: t0.addingTimeInterval(due), createdAt: t0.addingTimeInterval(-40 * 86400), status: status)
        t.extensions = extensions
        return t
    }
    func onTime(_ n: Int) -> [TaxTask] { (0..<n).map { _ in task(-86400, .proven(at: t0.addingTimeInterval(-90000))) } }

    func trackRecordCounts() {
        let tasks = onTime(4) + [task(-86400, .provenLate(at: t0, penaltyEndsAt: t0)), task(-60), task(-86400, .excused(at: t0)),
                                 task(-40 * 86400, .proven(at: t0.addingTimeInterval(-41 * 86400)))]
        let r = TrackRecord.of(tasks, now: t0)
        expect(r.onTime == 4 && r.late == 1 && r.missed == 1)   // the 40-day-old one is outside the window
        expect(abs(r.onTimeRate - 4.0 / 6.0) < 0.001)
    }

    func needsAGoodRecord() {
        let upcoming = task(3600)
        expect(ExtensionPolicy.whyNot(task: upcoming, record: TrackRecord.of(onTime(4), now: t0), enabled: true, now: t0)?.contains("at least 5") == true)
        let mixed = onTime(5) + [task(-86400, .provenLate(at: t0, penaltyEndsAt: t0)), task(-86400, .provenLate(at: t0, penaltyEndsAt: t0))]
        expect(ExtensionPolicy.whyNot(task: upcoming, record: TrackRecord.of(mixed, now: t0), enabled: true, now: t0)?.contains("71%") == true)
        expect(ExtensionPolicy.whyNot(task: upcoming, record: TrackRecord.of(onTime(5), now: t0), enabled: true, now: t0) == nil)
    }

    func hardLimits() {
        let good = TrackRecord.of(onTime(6), now: t0)
        expect(ExtensionPolicy.whyNot(task: task(3600), record: good, enabled: false, now: t0)?.contains("guardian") == true)
        expect(ExtensionPolicy.whyNot(task: task(-60), record: good, enabled: true, now: t0)?.contains("before the deadline") == true)
        expect(ExtensionPolicy.whyNot(task: task(3600, .proven(at: t0)), record: good, enabled: true, now: t0) != nil)
        let asked = Extension(requestedAt: t0, hoursAsked: 3, reason: "x", decision: .denied, previousDue: t0)
        expect(ExtensionPolicy.whyNot(task: task(3600, extensions: [asked]), record: good, enabled: true, now: t0)?.contains("already asked") == true)
        let granted = Extension(requestedAt: t0.addingTimeInterval(-3600), hoursAsked: 6, reason: "x", decision: .granted, hoursGranted: 6, previousDue: t0)
        let busyWeek = onTime(6) + [task(-86400, .proven(at: t0), extensions: [granted]), task(-86400, .proven(at: t0), extensions: [granted])]
        expect(ExtensionPolicy.whyNot(task: task(3600), record: TrackRecord.of(busyWeek, now: t0), enabled: true, now: t0)?.contains("2 extensions") == true)
        expect(ExtensionPolicy.clampedHours(granted: 20, asked: 8) == 8)
        expect(ExtensionPolicy.clampedHours(granted: 20, asked: 30) == 12)
        expect(ExtensionPolicy.clampedHours(granted: -3, asked: 5) == 0)
    }

    func claudesAnswerRead() {
        func env(_ inner: String) -> Data { Data(#"{"type":"result","is_error":false,"result":"\#(inner.replacingOccurrences(of: "\"", with: "\\\""))"}"#.utf8) }
        let g = Auditor.parseExtension(cliOutput: env(#"{"decision":"grant","hours":6,"reason":"Being sick is a real reason."}"#))
        expect(g.decision == .granted && g.hours == 6)
        let d = Auditor.parseExtension(cliOutput: env(#"{"decision":"deny","hours":0,"reason":"That's procrastination."}"#))
        expect(d.decision == .denied && d.hours == 0)
        expect(Auditor.parseExtension(cliOutput: env(#"{"decision":"grant","hours":0,"reason":"?"}"#)).decision == .denied)
        expect(Auditor.parseExtension(cliOutput: Data()).decision == .error)
        let p = Auditor.extensionPrompt(task: task(7200), hours: 6, reason: "I have a fever of 39.", record: TrackRecord.of(onTime(5), now: t0), now: t0)
        expect(p.contains("Hours asked for: 6") && p.contains("On time: 5") && p.contains("fever"))
    }
}

struct RepeatRules {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2
        return c
    }
    /// October 2026: the 19th and 26th are Mondays.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func nextDueFindsTheRightDay() {
        let monday = 2, wednesday = 4, halfPastEight = 8 * 60 + 30
        expect(Recurrence.nextDue(after: at(19, 8), weekdays: [monday], minuteOfDay: halfPastEight, calendar: cal) == at(19, 8, 30))
        expect(Recurrence.nextDue(after: at(19, 9), weekdays: [monday], minuteOfDay: halfPastEight, calendar: cal) == at(26, 8, 30))
        expect(Recurrence.nextDue(after: at(19, 9), weekdays: [monday, wednesday], minuteOfDay: halfPastEight, calendar: cal) == at(21, 8, 30))
        // Exactly at the deadline, it's next week's.
        expect(Recurrence.nextDue(after: at(19, 8, 30), weekdays: [monday], minuteOfDay: halfPastEight, calendar: cal) == at(26, 8, 30))
        expect(Recurrence.nextDue(after: at(19, 9), weekdays: [], minuteOfDay: 0, calendar: cal) == nil)
    }

    func oneCopyAtATime() {
        let series = RecurringTask(title: "Math: homework", weekdays: [2], minuteOfDay: 8 * 60 + 30, createdAt: at(17, 12))
        let first = Recurrence.newCopies(of: [series], now: at(17, 12), calendar: cal)
        expect(first.tasks.count == 1 && first.tasks.first?.dueDate == at(19, 8, 30) && first.tasks.first?.seriesID == series.id)
        expect(first.series.first?.currentDue == at(19, 8, 30))
        // Paid early or not, nothing new before Monday's deadline…
        expect(Recurrence.newCopies(of: first.series, now: at(19, 8, 29), calendar: cal).tasks.isEmpty)
        // …and right after it, next week's.
        expect(Recurrence.newCopies(of: first.series, now: at(19, 8, 31), calendar: cal).tasks.map(\.dueDate) == [at(26, 8, 30)])
        // Weeks later, only the next one: no backlog of missed weeks.
        let later = at(19, 9).addingTimeInterval(20 * 86400)
        let gap = Recurrence.newCopies(of: first.series, now: later, calendar: cal)
        expect(gap.tasks.count == 1 && gap.tasks[0].dueDate > later)
    }

    func scheduleReads() {
        func text(_ days: Set<Int>) -> String {
            RecurringTask(title: "x", weekdays: days, minuteOfDay: 8 * 60 + 30, createdAt: at(17, 12))
                .schedule(calendar: cal).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        expect(text([2]) == "Every Monday at 8:30 AM")
        expect(text([4, 2]) == "Every Monday and Wednesday at 8:30 AM")
        expect(text([2, 4, 6]) == "Every Monday, Wednesday and Friday at 8:30 AM")
        expect(text([1, 2]) == "Every Monday and Sunday at 8:30 AM")
        expect(text(Set(2...6)) == "Every weekday at 8:30 AM")
        expect(text(Set(1...7)) == "Every day at 8:30 AM")
    }

    func everyFewDays() {
        // Every 4 days from Monday the 19th at 8:30.
        let series = RepeatRules.series(.days, 4, [], start: at(19, 0), cal: cal)
        expect(series.nextDue(after: at(19, 8), calendar: cal) == at(19, 8, 30))
        expect(series.nextDue(after: at(19, 9), calendar: cal) == at(23, 8, 30))
        expect(series.nextDue(after: at(22, 23), calendar: cal) == at(23, 8, 30))
        expect(series.nextDue(after: at(23, 8, 30), calendar: cal) == at(27, 8, 30))
        // Before the start date, the first one is on it.
        expect(RepeatRules.series(.days, 4, [], start: at(25, 0), cal: cal).nextDue(after: at(19, 9), calendar: cal) == at(25, 8, 30))
        // Every day.
        expect(RepeatRules.series(.days, 1, [], start: at(19, 0), cal: cal).nextDue(after: at(19, 9), calendar: cal) == at(20, 8, 30))
    }

    func everyFewWeeks() {
        // Every 2 weeks on Monday, starting the week of the 19th: the 26th is skipped.
        let mondays = RepeatRules.series(.weeks, 2, [2], start: at(19, 0), cal: cal)
        expect(mondays.nextDue(after: at(19, 8), calendar: cal) == at(19, 8, 30))
        expect(mondays.nextDue(after: at(19, 9), calendar: cal)
               == cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 8, minute: 30)))
        // Monday and Wednesday of every other week.
        let twice = RepeatRules.series(.weeks, 2, [2, 4], start: at(19, 0), cal: cal)
        expect(twice.nextDue(after: at(19, 9), calendar: cal) == at(21, 8, 30))
        expect(twice.nextDue(after: at(21, 9), calendar: cal)
               == cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 8, minute: 30)))
        // Starting mid-week counts from that week.
        expect(RepeatRules.series(.weeks, 2, [2, 4], start: at(21, 0), cal: cal).nextDue(after: at(19, 9), calendar: cal) == at(21, 8, 30))
    }

    func customScheduleReads() {
        func text(_ unit: RepeatUnit, _ n: Int, _ days: Set<Int>) -> String {
            RepeatRules.series(unit, n, days, start: at(19, 0), cal: cal).schedule(calendar: cal)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        expect(text(.days, 1, []) == "Every day at 8:30 AM")
        expect(text(.days, 4, []) == "Every 4 days at 8:30 AM")
        expect(text(.weeks, 2, [2]) == "Every 2 weeks on Monday at 8:30 AM")
        expect(text(.weeks, 3, [2, 4]) == "Every 3 weeks on Monday and Wednesday at 8:30 AM")
        expect(text(.weeks, 2, Set(2...6)) == "Every 2 weeks on weekdays at 8:30 AM")
        // Out-of-range intervals are kept sensible.
        expect(RepeatRules.series(.days, 0, [], start: at(19, 0), cal: cal).interval == 1)
        expect(RepeatRules.series(.weeks, 500, [2], start: at(19, 0), cal: cal).interval == RecurringTask.maxWeeks)
    }

    func weeklyRepeatsFromBeforeStillLoad() {
        // Saved by 0.5.0: no unit, interval or start date.
        let json = #"{"id":"4D1C8B0E-7F4A-4C11-9E2B-1A2B3C4D5E6F","title":"Math","details":"","weekdays":[2],"minuteOfDay":510,"createdAt":0}"#
        let old = try? JSONDecoder().decode(RecurringTask.self, from: Data(json.utf8))
        expect(old?.unit == .weeks && old?.interval == 1 && old?.startDate == old?.createdAt)
        expect(old?.nextDue(after: at(19, 9), calendar: cal) == at(26, 8, 30))
    }

    static func series(_ unit: RepeatUnit, _ interval: Int, _ weekdays: Set<Int>, start: Date, cal: Calendar) -> RecurringTask {
        RecurringTask(title: "x", unit: unit, interval: interval, weekdays: weekdays, minuteOfDay: 8 * 60 + 30,
                      startDate: start, createdAt: start)
    }

    func savesAndOldTasksStillLoad() {
        var task = TaxTask(title: "x", dueDate: t0, createdAt: t0)
        task.seriesID = UUID()
        let data = try? JSONEncoder().encode(task)
        expect(data.flatMap { try? JSONDecoder().decode(TaxTask.self, from: $0) }?.seriesID == task.seriesID)
        let series = RecurringTask(title: "x", weekdays: [2, 4], minuteOfDay: 510, createdAt: t0, currentDue: t0)
        let saved = try? JSONEncoder().encode(series)
        expect(saved.flatMap { try? JSONDecoder().decode(RecurringTask.self, from: $0) } == series)
    }
}

/// spec/vectors/v1.json: the bytes every implementation of the parent link has to agree on.
struct LinkVectors {
    let v: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spec/vectors/v1.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }()
    func d(_ path: String) -> Data {
        var node: Any? = v
        for key in path.split(separator: ".") { node = (node as? [String: Any])?[String(key)] }
        return LinkCrypto.fromBase64url(node as? String ?? "") ?? Data()
    }
    func s(_ path: String) -> String {
        var node: Any? = v
        for key in path.split(separator: ".") { node = (node as? [String: Any])?[String(key)] }
        return node as? String ?? ""
    }

    func codesNormaliseAndDerive() {
        expect(!v.isEmpty)
        for pair in v["normalise"] as? [[String]] ?? [] { expect(LinkCrypto.normaliseCode(pair[0]) == pair[1]) }
        let (slot, key) = LinkCrypto.pairing(code: s("pairing.code"))
        expect(slot == s("pairing.slot"))
        expect(key.withUnsafeBytes { Data($0) } == d("pairing.pairKey"))
        expect(LinkCrypto.displayCode("7kq2m9xwhr") == "7KQ2M-9XWHR")
        expect(LinkCrypto.normaliseCode(LinkCrypto.newPairingCode()).count == 10)
    }

    func helloBoxIsExact() {
        let (slot, key) = LinkCrypto.pairing(code: s("pairing.code"))
        let aad = LinkCrypto.pairAAD(slot: slot)
        let sealed = try? LinkCrypto.seal(Data(s("pairing.hello.plaintext").utf8), key: key, aad: aad, nonce: d("pairing.hello.nonce"))
        expect(sealed == d("pairing.hello.box"))
        expect((try? LinkCrypto.open(d("pairing.hello.box"), key: key, aad: aad)) == Data(s("pairing.hello.plaintext").utf8))
        expect((try? LinkCrypto.open(d("pairing.hello.box"), key: key, aad: aad + Data("x".utf8))) == nil)
    }

    func commitAndComparisonCode() {
        expect(LinkCrypto.sha256(d("pairing.phone.token")) == d("pairing.phone.tokenHash"))
        let commit = LinkCrypto.commitment(signKey: d("pairing.phone.signKey.public"), dhKey: d("pairing.phone.dhKey.public"),
                                           nonce: d("pairing.phone.nonce"), tokenHash: d("pairing.phone.tokenHash"),
                                           name: s("pairing.phone.name"))
        expect(LinkCrypto.base64url(commit) == s("pairing.commit"))
        let code = LinkCrypto.comparisonCode(computerNonce: d("pairing.computer.nonce"), phoneNonce: d("pairing.phone.nonce"),
                                             computerDhKey: d("pairing.computer.dhKey.public"),
                                             phoneSignKey: d("pairing.phone.signKey.public"), phoneDhKey: d("pairing.phone.dhKey.public"))
        expect(code == s("pairing.sas"))
    }

    func linkKeyMatches() {
        guard let computer = try? P256.KeyAgreement.PrivateKey(rawRepresentation: d("pairing.computer.dhKey.d")) else {
            expect(false); return
        }
        expect(computer.publicKey.x963Representation == d("pairing.computer.dhKey.public"))
        let phone = try? P256.KeyAgreement.PublicKey(x963Representation: d("pairing.phone.dhKey.public"))
        let shared = phone.flatMap { try? computer.sharedSecretFromKeyAgreement(with: $0) }
        expect(shared?.withUnsafeBytes { Data($0) } == d("link.shared"))
        let key = try? LinkCrypto.linkKey(computer: computer, phoneDhKey: d("pairing.phone.dhKey.public"),
                                          channel: s("link.channel"), deviceID: s("link.deviceId"))
        expect(key?.withUnsafeBytes { Data($0) } == d("link.linkKey"))
    }

    func commandOpensAndVerifies() {
        let key = SymmetricKey(data: d("link.linkKey"))
        let aad = LinkCrypto.commandAAD(channel: s("link.channel"), device: s("link.deviceId"))
        guard let opened = try? LinkCrypto.open(d("command.box"), key: key, aad: aad) else { expect(false); return }
        let sig = opened.prefix(64), body = opened.dropFirst(64)
        expect(sig == d("command.signature") && body == Data(s("command.body").utf8))
        let pub = d("pairing.phone.signKey.public")
        expect(LinkCrypto.isValidSignature(Data(sig), of: Data(body), by: pub))
        expect(!LinkCrypto.isValidSignature(d("command.tamperedSignature"), of: Data(body), by: pub))
        expect(!LinkCrypto.isValidSignature(Data(sig), of: Data(s("command.body").replacingOccurrences(of: "homework", with: "all").utf8), by: pub))
        expect((try? LinkCrypto.open(d("command.box"), key: key, aad: LinkCrypto.commandAAD(channel: "other", device: s("link.deviceId")))) == nil)
    }

    func stateOpensAndInflates() {
        let key = SymmetricKey(data: d("link.linkKey"))
        let aad = LinkCrypto.stateAAD(channel: s("link.channel"), device: s("link.deviceId"))
        let opened = try? LinkCrypto.open(d("state.box"), key: key, aad: aad)
        expect(opened == d("state.deflated"))
        expect(opened.flatMap(LinkCrypto.inflateRaw) == Data(s("state.json").utf8))
        // Our own compression round-trips too (its bytes may differ from Node's, which is fine).
        let mine = LinkCrypto.deflateRaw(Data(s("state.json").utf8))
        expect(mine.flatMap(LinkCrypto.inflateRaw) == Data(s("state.json").utf8))
    }
}

struct ParentRules {
    func parentLockAndUnlock() {
        let lock = ParentLock(until: t0.addingTimeInterval(3600), strength: .all, by: "Mom's iPhone", since: t0)
        var state = LockPolicy.state(tasks: [], overrideUntil: nil, parentLock: lock, now: t0)
        expect(state.isLocked && state.strength == .all && state.parentLock == lock)
        // An unlock beats it, and it ends on its own.
        state = LockPolicy.state(tasks: [], overrideUntil: t0.addingTimeInterval(60), parentLock: lock, now: t0)
        expect(!state.isLocked)
        expect(!LockPolicy.state(tasks: [], overrideUntil: nil, parentLock: lock, now: t0.addingTimeInterval(3601)).isLocked)
        // Until lifted.
        let open = ParentLock(until: nil, strength: .homework, by: "x", since: t0)
        expect(LockPolicy.state(tasks: [], overrideUntil: nil, parentLock: open, now: t0.addingTimeInterval(1e7)).isLocked)
        // Overdue work alone still uses the homework rules.
        expect(LockPolicy.state(tasks: [task(due: -60)], overrideUntil: nil, now: t0).strength == .homework)
    }

    func whatGetsClosed() {
        func close(_ id: String?, locked: Bool, _ strength: LockStrength = .homework, blocked: [String] = [], extra: [String] = []) -> Bool {
            Allowlist.shouldClose(bundleID: id, locked: locked, strength: strength, extra: extra, blocked: blocked, selfID: "me.self")
        }
        expect(!close("com.apple.finder", locked: true, .all, blocked: ["com.apple.finder"]))
        expect(!close("me.self", locked: true, .all, blocked: ["me.self"]))
        expect(close("org.game", locked: false, blocked: ["org.game"]))
        expect(close("org.game.helper", locked: false, blocked: ["org.game"]))
        expect(!close("org.game", locked: false))
        expect(!close("com.apple.mail", locked: true))
        expect(close("com.apple.mail", locked: true, .all))
        expect(close("com.apple.mail", locked: false, blocked: ["com.apple.mail"]))
        expect(!close("org.extra", locked: true, extra: ["org.extra"]))
        expect(close("org.other", locked: true))
        expect(close(nil, locked: true))
        expect(!close(nil, locked: false))
    }

    func oldSettingsStillLoad() {
        let json = #"{"penaltyMinutes":15,"extraAllowedBundleIDs":["org.x"]}"#
        let settings = try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        expect(settings?.penaltyMinutes == 15 && settings?.blockedApps == [] && settings?.parentLock == nil && settings?.parentLinked == false)
        var withLock = Settings()
        withLock.parentLock = ParentLock(until: nil, strength: .all, by: "x", since: t0)
        withLock.blockedApps = [AppRef(id: "org.game", name: "Game")]
        let round = (try? JSONEncoder().encode(withLock)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        expect(round == withLock)
    }
}

struct CommandRules {
    let channel = "EBESExQVFhcYGRobHB0eHw", device = "6f1c0e3a-2b4d-4c8e-9a1f-0d2e3c4b5a69"
    let signer = P256.Signing.PrivateKey()
    let key = SymmetricKey(size: .bits256)
    let at: Int64 = 1_800_000_000_000

    func box(_ body: String, sign: P256.Signing.PrivateKey? = nil, flip: Bool = false, channel ch: String? = nil) -> Data {
        var sig = (try? (sign ?? signer).signature(for: Data(body.utf8)).rawRepresentation) ?? Data()
        if flip { sig[5] ^= 1 }
        return (try? LinkCrypto.seal(sig + Data(body.utf8), key: key,
                                     aad: LinkCrypto.commandAAD(channel: ch ?? channel, device: device))) ?? Data()
    }
    func body(_ type: String, _ args: String, n: Int64? = nil, at a: Int64? = nil, ch: String? = nil) -> String {
        #"{"v":1,"ch":"\#(ch ?? channel)","dev":"\#(device)","n":\#(n ?? at),"at":\#(a ?? at),"id":"c1","type":"\#(type)","args":\#(args)}"#
    }
    func admit(_ b: Data, last: Int64 = 0, received: Int64? = nil) -> Result<ParentCommand, GateRejection> {
        CommandGate.admit(box: b, linkKey: key, signKey: signer.publicKey.x963Representation, channel: channel,
                          device: device, receivedAt: received ?? at, lastCounter: last)
    }

    func goodCommandsPass() {
        let lock = admit(box(body("lock", #"{"until":null,"strength":"all"}"#)))
        expect((try? lock.get().action) == .lock(until: nil, strength: .all, note: nil))
        let free = admit(box(body("free", #"{"until":1800000360000}"#)))
        expect((try? free.get().action) == .free(until: Date(timeIntervalSince1970: 1_800_000_360)))
        let approve = admit(box(body("approveProof", #"{"taskId":"0b8f2c64-7d1e-4f3a-9c5b-2e6d8a4f1b37","proofId":"1b8f2c64-7d1e-4f3a-9c5b-2e6d8a4f1b37"}"#)))
        if case .approveProof? = try? approve.get().action {} else { expect(false) }
        let block = admit(box(body("blockApp", #"{"app":{"id":"org.game","name":"Game"}}"#)))
        expect((try? block.get().action)??.setting == "app:org.game")
        let rep = admit(box(body("addRepeat", #"{"repeat":{"id":"0b8f2c64-7d1e-4f3a-9c5b-2e6d8a4f1b37","title":"Math","details":"","unit":"days","interval":4,"weekdays":[],"minuteOfDay":510,"startDate":"2026-10-19"}}"#)))
        if case let .addRepeat(r)? = (try? rep.get())?.action { expect(r.unit == .days && r.interval == 4 && r.minuteOfDay == 510) } else { expect(false) }
        // Unknown types get through the gate with no action: answered "unsupported".
        let unknown = admit(box(body("makeCoffee", "{}")))
        expect((try? unknown.get())?.action == nil && (try? unknown.get())?.type == "makeCoffee")
    }

    func badCommandsAreRejected() {
        func reason(_ r: Result<ParentCommand, GateRejection>) -> CommandRejection? {
            if case let .failure(e) = r { return e.reason }
            return nil
        }
        // After a good signature, the rejection names the command, so the phone can match it up.
        if case let .failure(e) = admit(box(body("normal", "{}")), last: at) { expect(e.command?.id == "c1" && e.command?.counter == at) } else { expect(false) }
        let ok = body("normal", "{}")
        expect(reason(admit(box(ok), last: at)) == .replayed)
        expect(reason(admit(box(ok), received: at + 11 * 60 * 1000)) == .stale)
        expect(reason(admit(box(ok), received: at - 11 * 60 * 1000)) == .stale)
        expect(reason(admit(box(ok, flip: true))) == .badSignature)
        expect(reason(admit(box(ok, sign: P256.Signing.PrivateKey()))) == .badSignature)
        expect(reason(admit(box(ok, channel: "other"))) == .badBox)
        expect(reason(admit(Data([1, 2, 3]))) == .badBox)
        expect(reason(admit(box(body("normal", "{}", ch: "someOtherChannelId00")))) == .wrongTarget)
        expect(reason(admit(box(body("setPenalty", #"{"minutes":5000}"#)))) == .badArgs)
        expect(reason(admit(box(body("lock", #"{"until":null}"#)))) == .badArgs)
        expect(reason(admit(box(body("setExtensions", #"{"enabled":1}"#)))) == .badArgs)
        expect(reason(admit(box(body("addTask", #"{"task":{"id":"nope","title":"x","due":1}}"#)))) == .badArgs)
    }

    func stateHasNoSecretsOrLineBreaks() {
        var settings = Settings()
        settings.blackbaudURL = "webcal://school.example/podium/feed/iCal.aspx?z=SECRETTOKEN"
        settings.parentMessage = ParentMessage(text: "Dinner at 6", by: "Mom's iPhone", at: t0)
        var t = TaxTask(title: "Math: Worksheet\nGUARDIAN unlocked", details: "line one\nline two", dueDate: t0.addingTimeInterval(3600),
                        createdAt: t0, source: .blackbaud(uid: "uid-1"))
        t.proofs = [ProofSubmission(submittedAt: t0, note: "did it\r\nall", attachments: ["a.png"], verdict: .rejected, reason: "Blank")]
        let input = StateBuilder.Input(
            seq: 7, now: t0, computer: .init(name: "Test Mac", app: "0.7.0", os: "macOS", timeZone: "UTC"),
            tasks: [t], recurring: [], settings: settings, lock: LockState(), checking: [], builtIn: [], running: [],
            recent: [], activity: [WireState.Event(at: 1, kind: "task", text: "a\nb")], results: [], devices: [], flags: [],
            accessBy: "", accessAt: 0)
        let state = StateBuilder.build(input)
        let json = String(data: (try? JSONEncoder().encode(state)) ?? Data(), encoding: .utf8) ?? ""
        expect(!json.contains("SECRETTOKEN") && !json.contains("podium"))
        expect(!state.tasks[0].title.contains("\n") && !state.tasks[0].details.contains("\n") && !state.tasks[0].proofs[0].note.contains("\n"))
        expect(state.tasks[0].course == "Math" && state.tasks[0].status == "pending" && state.tasks[0].proofs[0].verdict == "rejected")
        expect(state.message?.text == "Dinner at 6" && state.seq == 7 && state.access.mode == "normal")
        expect(state.activity[0].text == "a b")
        let packed = StateBuilder.encode(state)
        expect(packed.flatMap(LinkCrypto.inflateRaw).flatMap { try? JSONDecoder().decode(WireState.self, from: $0) } == state)
    }
}

struct AssignmentPage {
    let host = "school.myschoolapp.com"
    var sample: [String: Any] {
        [
            "LongDescription": "<p>Finish <b>both</b> parts.</p>",
            "AssignmentType": "Homework (Minor)",
            "MaxPoints": 10,
            "DropboxInd": true,
            "DownloadItems": [
                ["DownloadUrl": "/ftpimages/12/download/download_99.pdf", "FriendlyFileName": "Worksheet 1.4.pdf",
                 "FileName": "download_99.pdf", "ShortDescription": "Worksheet 1.4"],
                ["DownloadUrl": "", "FileName": "broken.pdf"],
            ],
            "LinkItems": [
                ["Url": "https://example.org/lesson/4", "ShortDescription": "Lesson &amp; slides"],
                ["Url": "www.example.com/video", "ShortDescription": ""],
            ],
        ]
    }

    func parsesEverything() {
        guard let d = AssignmentDetailsParser.parse(sample, indexID: 90398882, host: host) else { expect(false); return }
        expect(d.instructionsHTML.contains("<b>both</b>"))
        expect(d.type == "Homework (Minor)" && d.maxPoints == 10 && d.submitsOnline)
        expect(d.attachments.count == 1)
        expect(d.attachments.first?.url.absoluteString == "https://school.myschoolapp.com/ftpimages/12/download/download_99.pdf")
        expect(d.attachments.first?.title == "Worksheet 1.4" && d.attachments.first?.fileName == "Worksheet 1.4.pdf")
        expect(d.links.map(\.title) == ["Lesson & slides", "www.example.com"])
        expect(d.links.last?.url.absoluteString == "https://www.example.com/video")
        expect(d.pageURL.absoluteString == "https://school.myschoolapp.com/lms-assignment/assignment/assignment-student-view/90398882")
    }

    func urlsAndSites() {
        expect(AssignmentDetailsParser.absolute("//cdn.example.com/a.pdf", host: host)?.absoluteString == "https://cdn.example.com/a.pdf")
        expect(AssignmentDetailsParser.absolute("not a link", host: host) == nil)
        expect(AssignmentDetailsParser.isOnSchoolSite(URL(string: "https://School.myschoolapp.com/x")!, host: host))
        expect(!AssignmentDetailsParser.isOnSchoolSite(URL(string: "https://example.org/x")!, host: host))
        expect(AssignmentDetailsParser.parse(["nothing": 1], indexID: 1, host: host)?.attachments.isEmpty == true)
        expect(AssignmentDetailsParser.parse("not an object", indexID: 1, host: host) == nil)
    }
}

struct TeamsImport {
    /// Shaped like one page of `/api/v1.0/edu/me/work` (made-up classes and assignments).
    private let page = """
    {"@odata.context": "x", "@odata.nextLink": "https://assignments.edu.cloud.microsoft/api/v1.0/edu/me/work?$skiptoken=abc",
     "value": [
      {"id": "a-1", "classId": "c-1", "displayName": "Lab &amp; report", "dueDateTime": "2027-01-15T20:00:00Z",
       "status": "assigned", "isCompleted": false, "webUrl": "https://teams.microsoft.com/l/entity/x",
       "instructions": null, "submissions": [{"status": "working", "excusedDateTime": null}]},
      {"id": "a-2", "classId": "c-2", "displayName": "Handed in", "dueDateTime": "2027-01-16T20:00:00.000Z",
       "status": "assigned", "isCompleted": false, "submissions": [{"status": "submitted"}]},
      {"id": "a-3", "classId": "c-1", "displayName": "Excused", "dueDateTime": "2027-01-17T20:00:00Z",
       "status": "assigned", "isCompleted": false, "submissions": [{"status": "working", "excusedDateTime": "2027-01-01T00:00:00Z"}]},
      {"id": "a-4", "classId": "c-1", "displayName": "Draft", "dueDateTime": "2027-01-18T20:00:00Z",
       "status": "draft", "isCompleted": false, "submissions": []},
      {"id": "a-5", "classId": "c-1", "displayName": "No due date", "status": "assigned", "isCompleted": false},
      {"id": "a-6", "classId": "c-2", "displayName": "Returned", "dueDateTime": "2027-01-19T20:00:00Z",
       "status": "assigned", "isCompleted": false, "submissions": [{"status": "returned"}]},
      {"id": "a-7", "classId": "c-9", "displayName": "Reflection", "dueDateTime": "2027-01-20T03:59:00Z",
       "status": "assigned", "isCompleted": false, "submissions": [{"status": "reassigned"}]},
      {"id": "a-1", "classId": "c-1", "displayName": "Lab &amp; report", "dueDateTime": "2027-01-15T20:00:00Z",
       "status": "assigned", "isCompleted": false, "submissions": [{"status": "working"}]},
      {"classId": "c-1", "displayName": "No id"}
     ]}
    """
    private let classes = """
    {"value": [{"id": "c-1", "name": "Science 8 - SNC8 - 8D"}, {"id": "c-2", "displayName": "French 8 - FSF8 - 8D"}]}
    """

    func readsAPage() {
        guard let parsed = Teams.parseWork(Data(page.utf8)) else { return expect(false) }
        expect(parsed.items.count == 8)
        expect(parsed.next?.contains("skiptoken") == true)
        expect(parsed.items.first?.submission == "working")
        expect(parsed.items.first?.due == Date(timeIntervalSince1970: 1_800_043_200))
        expect(parsed.items[1].due != nil)
        expect(Teams.parseWork(Data("{}".utf8)) == nil)
        expect(Teams.parseWork(Data("not json".utf8)) == nil)
        let names = Teams.parseClasses(Data(classes.utf8))
        expect(names["c-1"] == "Science 8 - SNC8 - 8D" && names["c-2"] == "French 8 - FSF8 - 8D")
    }

    func onlyOwedWorkBecomesAssignments() {
        guard let parsed = Teams.parseWork(Data(page.utf8)) else { return expect(false) }
        let names = Teams.parseClasses(Data(classes.utf8))
        let items = Teams.assignments(from: parsed.items, classes: names,
                                      instructions: ["a-1": "<p>Read <b>pages</b> 4&ndash;5</p><p>Then answer</p>"])
        expect(items.map(\.id) == ["a-1", "a-7"])
        expect(items.first?.title == "Science 8: Lab & report")
        expect(items.first?.details.hasPrefix("Read pages 4") == true)
        expect(items.first?.details.contains("\nThen answer") == true)
        let styled = Teams.assignments(from: parsed.items, classes: names,
                                       instructions: ["a-1": "<html><head><style>.c0{display:inline!important}</style></head><body><div><span class=\"c0\">Read it</span></div></body></html>"])
        expect(styled.first?.details == "Read it")
        expect(items.first?.link == "https://teams.microsoft.com/l/entity/x")
        // A class Tax Collector couldn't name: just the assignment.
        expect(items.last?.title == "Reflection")
        // The class shows like Blackbaud's.
        let t = TaxTask(title: items[0].title, dueDate: items[0].dueDate, createdAt: t0, source: .teams(id: "a-1"))
        expect(Agenda.courseAndTitle(t).course == "Science 8")
        expect(Agenda.courseAndTitle(t).title == "Lab & report")
        expect(Teams.shortClassName("Mathematics - MTH1W - MS - 1") == "Mathematics")
        expect(Teams.shortClassName("Middle School Students - 2026-27") == "Middle School Students")
    }

    func requestsStayOnTheSite() {
        let path = Teams.upcomingWorkPath(now: t0)
        expect(path.hasPrefix("/api/v1.0/edu/me/work?"))
        expect(path.contains("dueDateTime%20ge%202027-01-15T08:00:00Z") || path.contains("dueDateTime ge 2027-01-15T08:00:00Z"))
        expect(path.contains("isCompleted%20eq%20false"))
        expect(!path.contains("+"))
        expect(Teams.assignmentPath(classID: "c-1", id: "a-1") == "/api/v1.0/edu/classes/c-1/assignments/a-1")
        expect(Teams.assignmentPath(classID: "../x", id: "a-1") == nil)
        expect(Teams.assignmentPath(classID: "c-1", id: "a?b=1") == nil)
        expect(Teams.isOnSite("https://assignments.edu.cloud.microsoft/api/v1.0/edu/me/work?$skiptoken=1"))
        expect(!Teams.isOnSite("https://evil.example/api"))
        expect(!Teams.isOnSite("http://assignments.edu.cloud.microsoft/api"))
        expect(Teams.relativePath("https://assignments.edu.cloud.microsoft/api/v1.0/edu/me/work?$skiptoken=1") == "/api/v1.0/edu/me/work?$skiptoken=1")
        expect(Teams.relativePath("https://evil.example/api") == nil)
    }

    private let lab = TeamsAssignment(id: "a-1", classID: "c-1", title: "Science 8: Lab", details: "Do it",
                                      dueDate: t0.addingTimeInterval(hours(48)), link: "https://teams.microsoft.com/l/x")

    func importsAndRemembers() {
        let past = TeamsAssignment(id: "old", title: "Old", dueDate: t0.addingTimeInterval(-60))
        let r = Teams.sync(tasks: [], state: TeamsState(), assignments: [lab, past, lab], now: t0)
        expect(r.added.count == 1 && r.tasks.count == 1)
        expect(r.tasks.first?.source == .teams(id: "a-1"))
        expect(r.tasks.first?.isFromTeams == true && r.tasks.first?.isImported == true && r.tasks.first?.isFromBlackbaud == false)
        expect(r.state.lastSeen["a-1"] == lab && r.state.lastSeen["old"] == nil)
        expect(r.state.link(of: r.tasks[0])?.host == "teams.microsoft.com")
        // Checking again adds nothing.
        let again = Teams.sync(tasks: r.tasks, state: r.state, assignments: [lab], now: t0)
        expect(again.added.isEmpty && again.tasks.count == 1)
        // Deleted stays deleted.
        var state = r.state
        state.dismiss(id: "a-1")
        let afterDelete = Teams.sync(tasks: [], state: state, assignments: [lab], now: t0)
        expect(afterDelete.added.isEmpty && afterDelete.tasks.isEmpty)
        // A link that isn't https isn't opened.
        var odd = r.state
        odd.lastSeen["a-1"]?.link = "file:///etc/passwd"
        expect(odd.link(of: r.tasks[0]) == nil)
    }

    func teacherChangesFollowTheLockRule() {
        let first = Teams.sync(tasks: [], state: TeamsState(), assignments: [lab], now: t0)
        // Not locked in yet: a later deadline and new instructions both apply.
        var later = lab
        later.dueDate = t0.addingTimeInterval(hours(72))
        later.details = "Do it well"
        let moved = Teams.sync(tasks: first.tasks, state: first.state, assignments: [later], now: t0)
        expect(moved.tasks[0].dueDate == later.dueDate && moved.tasks[0].details == "Do it well")
        // Locked in (due within a day): only earlier.
        let soon = TeamsAssignment(id: "s", title: "Quiz", dueDate: t0.addingTimeInterval(hours(10)))
        let s1 = Teams.sync(tasks: [], state: TeamsState(), assignments: [soon], now: t0.addingTimeInterval(-hours(1)))
        var looser = soon
        looser.dueDate = t0.addingTimeInterval(hours(30))
        let kept = Teams.sync(tasks: s1.tasks, state: s1.state, assignments: [looser], now: t0)
        expect(kept.tasks[0].dueDate == soon.dueDate)
        var stricter = soon
        stricter.dueDate = t0.addingTimeInterval(hours(5))
        let tightened = Teams.sync(tasks: s1.tasks, state: s1.state, assignments: [stricter], now: t0)
        expect(tightened.tasks[0].dueDate == stricter.dueDate)
        // Never into the past.
        var past = lab
        past.dueDate = t0.addingTimeInterval(-hours(1))
        let notPast = Teams.sync(tasks: first.tasks, state: first.state, assignments: [past], now: t0)
        expect(notPast.tasks[0].dueDate == lab.dueDate)
        // Only a new link isn't a change.
        var relinked = lab
        relinked.link = "https://teams.microsoft.com/l/y"
        let r = Teams.sync(tasks: first.tasks, state: first.state, assignments: [relinked], now: t0)
        expect(r.notes.isEmpty && r.state.lastSeen["a-1"]?.link == relinked.link)
        // Blackbaud tasks and your own aren't touched.
        let mine = TaxTask(title: "Science 8: Lab", dueDate: lab.dueDate, createdAt: t0)
        let both = Teams.sync(tasks: [mine], state: TeamsState(), assignments: [lab], now: t0)
        expect(both.tasks.count == 2 && both.tasks[0] == mine)
    }

    func stoppingTeams() {
        let soon = TaxTask(title: "Quiz", dueDate: t0.addingTimeInterval(hours(3)), createdAt: t0.addingTimeInterval(-hours(72)),
                           source: .teams(id: "s"))
        let bbSoon = TaxTask(title: "Lab", dueDate: t0.addingTimeInterval(hours(3)), createdAt: t0.addingTimeInterval(-hours(72)),
                             source: .blackbaud(uid: "x"))
        let longAgo = t0.addingTimeInterval(-hours(100))
        expect(!LockPolicy.canStopTeamsWithoutGuardian(onSince: longAgo, tasks: [soon], now: t0))
        expect(LockPolicy.canStopTeamsWithoutGuardian(onSince: longAgo, tasks: [bbSoon], now: t0))
        expect(LockPolicy.canStopFeedWithoutGuardian(onSince: longAgo, tasks: [soon], now: t0))
        expect(LockPolicy.canStopTeamsWithoutGuardian(onSince: t0.addingTimeInterval(-60), tasks: [soon], now: t0))
    }

    func savedFilesStillLoad() {
        // Tasks saved before Teams import existed, and a Teams task, both round-trip.
        let tasks = [TaxTask(title: "A", dueDate: t0, createdAt: t0, source: .blackbaud(uid: "u")),
                     TaxTask(title: "B", dueDate: t0, createdAt: t0, source: .teams(id: "t"))]
        let data = try! JSONEncoder().encode(tasks)
        expect((try? JSONDecoder().decode([TaxTask].self, from: data)) == tasks)
        let old = try? JSONDecoder().decode(Settings.self, from: Data(#"{"penaltyMinutes": 45}"#.utf8))
        expect(old?.teamsOn == false && old?.penaltyMinutes == 45)
        let state = try? JSONDecoder().decode(TeamsState.self, from: Data("{}".utf8))
        expect(state == TeamsState())
    }
}

let checks: [(String, () -> Void)] = [
    ("MatchRules.movedDeadlineStillMatches", { MatchRules().movedDeadlineStillMatches() }),
    ("RepeatRules.nextDueFindsTheRightDay", { RepeatRules().nextDueFindsTheRightDay() }),
    ("RepeatRules.oneCopyAtATime", { RepeatRules().oneCopyAtATime() }),
    ("RepeatRules.scheduleReads", { RepeatRules().scheduleReads() }),
    ("RepeatRules.savesAndOldTasksStillLoad", { RepeatRules().savesAndOldTasksStillLoad() }),
    ("RepeatRules.everyFewDays", { RepeatRules().everyFewDays() }),
    ("RepeatRules.everyFewWeeks", { RepeatRules().everyFewWeeks() }),
    ("RepeatRules.customScheduleReads", { RepeatRules().customScheduleReads() }),
    ("RepeatRules.weeklyRepeatsFromBeforeStillLoad", { RepeatRules().weeklyRepeatsFromBeforeStillLoad() }),
    ("LinkVectors.codesNormaliseAndDerive", { LinkVectors().codesNormaliseAndDerive() }),
    ("LinkVectors.helloBoxIsExact", { LinkVectors().helloBoxIsExact() }),
    ("LinkVectors.commitAndComparisonCode", { LinkVectors().commitAndComparisonCode() }),
    ("LinkVectors.linkKeyMatches", { LinkVectors().linkKeyMatches() }),
    ("LinkVectors.commandOpensAndVerifies", { LinkVectors().commandOpensAndVerifies() }),
    ("LinkVectors.stateOpensAndInflates", { LinkVectors().stateOpensAndInflates() }),
    ("ParentRules.parentLockAndUnlock", { ParentRules().parentLockAndUnlock() }),
    ("ParentRules.whatGetsClosed", { ParentRules().whatGetsClosed() }),
    ("ParentRules.oldSettingsStillLoad", { ParentRules().oldSettingsStillLoad() }),
    ("CommandRules.goodCommandsPass", { CommandRules().goodCommandsPass() }),
    ("CommandRules.badCommandsAreRejected", { CommandRules().badCommandsAreRejected() }),
    ("CommandRules.stateHasNoSecretsOrLineBreaks", { CommandRules().stateHasNoSecretsOrLineBreaks() }),
    ("AssignmentPage.parsesEverything", { AssignmentPage().parsesEverything() }),
    ("AssignmentPage.urlsAndSites", { AssignmentPage().urlsAndSites() }),
    ("MoreTime.trackRecordCounts", { MoreTime().trackRecordCounts() }),
    ("MoreTime.needsAGoodRecord", { MoreTime().needsAGoodRecord() }),
    ("MoreTime.hardLimits", { MoreTime().hardLimits() }),
    ("MoreTime.claudesAnswerRead", { MoreTime().claudesAnswerRead() }),
    ("WrittenProof.accountOnlyPromptSaysSo", { WrittenProof().accountOnlyPromptSaysSo() }),
    ("WrittenProof.filesAreListedAsFullPaths", { WrittenProof().filesAreListedAsFullPaths() }),
    ("WrittenProof.rulesCoverWrittenProof", { WrittenProof().rulesCoverWrittenProof() }),
    ("ChangingUIDs.newUIDsDontDuplicate", { ChangingUIDs().newUIDsDontDuplicate() }),
    ("ChangingUIDs.deletedStaysDeletedAfterNewUID", { ChangingUIDs().deletedStaysDeletedAfterNewUID() }),
    ("ChangingUIDs.weeklyRepeatsGetTheirOwnTasks", { ChangingUIDs().weeklyRepeatsGetTheirOwnTasks() }),
    ("ChangingUIDs.teacherMovesDateWithNewUID", { ChangingUIDs().teacherMovesDateWithNewUID() }),
    ("ChangingUIDs.oldDuplicatesMerge", { ChangingUIDs().oldDuplicatesMerge() }),
    ("RealFeedMatching.similarTitlesPickTheExactOne", { RealFeedMatching().similarTitlesPickTheExactOne() }),
    ("RealFeedMatching.classDecidesBetweenSameTitles", { RealFeedMatching().classDecidesBetweenSameTitles() }),
    ("RealFeedMatching.titlesWithColonsSplitOnce", { RealFeedMatching().titlesWithColonsSplitOnce() }),
    ("RealFeedMatching.guidDigitsNeverCountAsIDs", { RealFeedMatching().guidDigitsNeverCountAsIDs() }),
    ("AgendaRules.groupsAndRanks", { AgendaRules().groupsAndRanks() }),
    ("AgendaRules.blackbaudTitlesSplit", { AgendaRules().blackbaudTitlesSplit() }),
    ("AgendaRules.colorsAreStable", { AgendaRules().colorsAreStable() }),
    ("FeedText.numericEntitiesDecoded", { FeedText().numericEntitiesDecoded() }),
    ("MatchRules.idInUIDWins", { MatchRules().idInUIDWins() }),
    ("MatchRules.titleAndDayMatch", { MatchRules().titleAndDayMatch() }),
    ("MatchRules.wrongDayOrTitleIsNoMatch", { MatchRules().wrongDayOrTitleIsNoMatch() }),
    ("LastCheckRules.auditorChecklistParsed", { LastCheckRules().auditorChecklistParsed() }),
    ("LastCheckRules.fallbackUsesListLines", { LastCheckRules().fallbackUsesListLines() }),
    ("LastCheckRules.onlyPaidBlackbaudTasksNeedIt", { LastCheckRules().onlyPaidBlackbaudTasksNeedIt() }),
    ("LastCheckRules.oldTasksStillLoad", { LastCheckRules().oldTasksStillLoad() }),
    ("AuditorParsing.plainJSON", { AuditorParsing().plainJSON() }),
    ("AuditorParsing.fencedAndWrapped", { AuditorParsing().fencedAndWrapped() }),
    ("AuditorParsing.noVerdictIsError", { AuditorParsing().noVerdictIsError() }),
    ("AuditorParsing.cliEnvelope", { AuditorParsing().cliEnvelope() }),
    ("LockRule.nothingDueMeansUnlocked", { LockRule().nothingDueMeansUnlocked() }),
    ("LockRule.overduePendingLocks", { LockRule().overduePendingLocks() }),
    ("LockRule.dueExactlyNowLocks", { LockRule().dueExactlyNowLocks() }),
    ("LockRule.checkInFlightHoldsOffTheLockOnlyBriefly", { LockRule().checkInFlightHoldsOffTheLockOnlyBriefly() }),
    ("LockRule.recheckAfterDeadlineDoesNotLift", { LockRule().recheckAfterDeadlineDoesNotLift() }),
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
    ("ICalParsing.unfoldsFoldedLines", { ICalParsing().unfoldsFoldedLines() }),
    ("ICalParsing.bareLineFeedsWork", { ICalParsing().bareLineFeedsWork() }),
    ("ICalParsing.multibyteSplitAcrossFold", { ICalParsing().multibyteSplitAcrossFold() }),
    ("ICalParsing.allDayDates", { ICalParsing().allDayDates() }),
    ("ICalParsing.zonedTimes", { ICalParsing().zonedTimes() }),
    ("ICalParsing.floatingTimesUseCalendarZone", { ICalParsing().floatingTimesUseCalendarZone() }),
    ("ICalParsing.todoWithDue", { ICalParsing().todoWithDue() }),
    ("ICalParsing.textEscapes", { ICalParsing().textEscapes() }),
    ("ICalParsing.nestedPartsDontLeak", { ICalParsing().nestedPartsDontLeak() }),
    ("ICalParsing.quotedParameters", { ICalParsing().quotedParameters() }),
    ("ICalParsing.statusAndCategories", { ICalParsing().statusAndCategories() }),
    ("ICalParsing.missingUIDIsStable", { ICalParsing().missingUIDIsStable() }),
    ("ICalParsing.spotsNonCalendars", { ICalParsing().spotsNonCalendars() }),
    ("FeedMapping.allDayUsesChosenTime", { FeedMapping().allDayUsesChosenTime() }),
    ("FeedMapping.allDayOnClockChangeDay", { FeedMapping().allDayOnClockChangeDay() }),
    ("FeedMapping.timedEventUsesItsStart", { FeedMapping().timedEventUsesItsStart() }),
    ("FeedMapping.spanningEventUsesItsLastDay", { FeedMapping().spanningEventUsesItsLastDay() }),
    ("FeedMapping.dueBeatsStart", { FeedMapping().dueBeatsStart() }),
    ("FeedMapping.skipsCancelledUndatedAndRepeats", { FeedMapping().skipsCancelledUndatedAndRepeats() }),
    ("FeedMapping.htmlBecomesPlainText", { FeedMapping().htmlBecomesPlainText() }),
    ("FeedMapping.feedLinks", { FeedMapping().feedLinks() }),
    ("FeedSync.importsFutureAssignmentsOnly", { FeedSync().importsFutureAssignmentsOnly() }),
    ("FeedSync.repollDedupesOnUID", { FeedSync().repollDedupesOnUID() }),
    ("FeedSync.deletedAssignmentsStayDeleted", { FeedSync().deletedAssignmentsStayDeleted() }),
    ("FeedSync.teacherChangeAppliesBeforeLockIn", { FeedSync().teacherChangeAppliesBeforeLockIn() }),
    ("FeedSync.yourEditsSurviveAnUnchangedFeed", { FeedSync().yourEditsSurviveAnUnchangedFeed() }),
    ("FeedSync.lockedInTaskOnlyMovesEarlier", { FeedSync().lockedInTaskOnlyMovesEarlier() }),
    ("FeedSync.neverMovesADeadlineIntoThePast", { FeedSync().neverMovesADeadlineIntoThePast() }),
    ("FeedSync.paidTasksIgnoreTheFeed", { FeedSync().paidTasksIgnoreTheFeed() }),
    ("FeedSync.assignmentsLeavingTheFeedStay", { FeedSync().assignmentsLeavingTheFeedStay() }),
    ("FeedSync.manualTasksAreUntouched", { FeedSync().manualTasksAreUntouched() }),
    ("FeedSync.endToEndFromFeedText", { FeedSync().endToEndFromFeedText() }),
    ("FeedPolicy.stoppingTheFeed", { FeedPolicy().stoppingTheFeed() }),
    ("TeamsImport.readsAPage", { TeamsImport().readsAPage() }),
    ("TeamsImport.onlyOwedWorkBecomesAssignments", { TeamsImport().onlyOwedWorkBecomesAssignments() }),
    ("TeamsImport.requestsStayOnTheSite", { TeamsImport().requestsStayOnTheSite() }),
    ("TeamsImport.importsAndRemembers", { TeamsImport().importsAndRemembers() }),
    ("TeamsImport.teacherChangesFollowTheLockRule", { TeamsImport().teacherChangesFollowTheLockRule() }),
    ("TeamsImport.stoppingTeams", { TeamsImport().stoppingTeams() }),
    ("TeamsImport.savedFilesStillLoad", { TeamsImport().savedFilesStillLoad() }),
    ("Inbox.acceptsAWellFormedFile", { InboxChecks().acceptsAWellFormedFile() }),
    ("Inbox.refusesBadFiles", { InboxChecks().refusesBadFiles() }),
    ("Inbox.sameInboxIDGivesTheSameTaskID", { InboxChecks().sameInboxIDGivesTheSameTaskID() }),
    ("Inbox.scanSettlesFiles", { try! InboxChecks().scanSettlesFiles() }),
    ("Inbox.scanIsCapped", { try! InboxChecks().scanIsCapped() }),
]


struct InboxChecks {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func json(_ extra: String = "", due: Date? = nil, id: String = "cc:1", title: String = "Read chapter 4", v: Int = 1) -> Data {
        let f = ISO8601DateFormatter()
        let d = f.string(from: due ?? now.addingTimeInterval(7 * 86400))
        return Data("{\"v\":\(v),\"id\":\"\(id)\",\"title\":\"\(title)\",\"due\":\"\(d)\"\(extra)}".utf8)
    }
    func acceptsAWellFormedFile() {
        guard case .success(let item) = Inbox.parse(json(",\"details\":\"From class\",\"from\":\"Class Capture\""), now: now) else { return expect(false) }
        expect(item.title == "Read chapter 4" && item.details == "From class" && item.from == "Class Capture")
        expect(abs(item.due.timeIntervalSince(now) - 7 * 86400) < 1)
    }
    func refusesBadFiles() {
        expect(Inbox.parse(Data("nope".utf8), now: now) == .failure(.malformed))
        expect(Inbox.parse(json(v: 2), now: now) == .failure(.unsupportedVersion))
        expect(Inbox.parse(json(id: "  "), now: now) == .failure(.emptyID))
        expect(Inbox.parse(json(title: "   "), now: now) == .failure(.emptyTitle))
        expect(Inbox.parse(json(title: String(repeating: "x", count: 201)), now: now) == .failure(.titleTooLong))
        expect(Inbox.parse(json(due: now.addingTimeInterval(-60)), now: now) == .failure(.dueInPast))
        expect(Inbox.parse(json(due: now.addingTimeInterval(200 * 86400)), now: now) == .failure(.dueTooFar))
        expect(Inbox.parse(Data(repeating: 0x20, count: Inbox.maxFileBytes + 1), now: now) == .failure(.tooLarge))
    }
    func sameInboxIDGivesTheSameTaskID() {
        expect(Inbox.taskID(for: "cc:1") == Inbox.taskID(for: "cc:1"))
        expect(Inbox.taskID(for: "cc:1") != Inbox.taskID(for: "cc:2"))
    }
    func scanSettlesFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tc-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try json().write(to: dir.appendingPathComponent("good.json"))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("bad.json"))
        try json().write(to: dir.appendingPathComponent("note.txt"))                 // not .json: ignored
        let entries = Inbox.scan(dir: dir, now: now)
        expect(entries.count == 2)
        entries.forEach { Inbox.settle($0, in: dir) }
        let fm = FileManager.default
        expect(!fm.fileExists(atPath: dir.appendingPathComponent("good.json").path))                      // accepted: removed
        expect(fm.fileExists(atPath: dir.appendingPathComponent("rejected/malformed-bad.json").path))    // refused: kept, with the reason
        expect(fm.fileExists(atPath: dir.appendingPathComponent("note.txt").path))
        expect(Inbox.scan(dir: dir, now: now).isEmpty)
    }
    func scanIsCapped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tc-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<(Inbox.maxFilesPerScan + 5) { try json(id: "cc:\(i)").write(to: dir.appendingPathComponent("\(i).json")) }
        expect(Inbox.scan(dir: dir, now: now).count == Inbox.maxFilesPerScan)
    }
}

for (name, run) in checks {
    current = name
    run()
}
print(failures == 0 ? "All \(checks.count) checks passed." : "\(failures) failure(s) in \(checks.count) checks.")
exit(failures == 0 ? 0 : 1)
