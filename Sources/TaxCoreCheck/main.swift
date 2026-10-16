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

let checks: [(String, () -> Void)] = [
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
]

for (name, run) in checks {
    current = name
    run()
}
print(failures == 0 ? "All \(checks.count) checks passed." : "\(failures) failure(s) in \(checks.count) checks.")
exit(failures == 0 ? 0 : 1)
