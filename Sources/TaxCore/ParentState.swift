import Foundation

/// What parents' phones see: docs/parent-link-v1.md §8. Times are ms since 1970. A field that's null may be left out.
public struct WireState: Codable, Equatable, Sendable {
    public var v = 1
    public var seq: Int64
    public var sentAt: Int64
    public var computer: Computer
    public var access: Access
    public var lock: Lock
    public var tasks: [Task]
    public var repeats: [Repeat]
    public var apps: Apps
    public var settings: SettingsSummary
    public var trackRecord: Record
    public var activity: [Event]
    public var results: [CommandResult]
    public var devices: [Device]
    public var flags: [Flag]
    public var message: Message?

    public struct Computer: Codable, Equatable, Sendable {
        public var name: String
        public var platform: String
        public var app: String
        public var os: String
        public var timeZone: String
        public var capabilities: [String]

        public init(name: String, platform: String = "mac", app: String, os: String, timeZone: String,
                    capabilities: [String] = WireState.capabilities) {
            self.name = name
            self.platform = platform
            self.app = app
            self.os = os
            self.timeZone = timeZone
            self.capabilities = capabilities
        }
    }

    public struct Access: Codable, Equatable, Sendable {
        public var mode: String
        public var until: Int64?
        public var strength: String?
        public var by: String
        public var at: Int64
    }

    public struct Lock: Codable, Equatable, Sendable {
        public var locked: Bool
        public var reasons: [Reason]
    }

    public struct Reason: Codable, Equatable, Sendable {
        public var kind: String
        public var taskId: String?
        public var title: String?
        public var until: Int64?
    }

    public struct Task: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var course: String?
        public var details: String
        public var due: Int64
        public var created: Int64
        public var status: String
        public var statusAt: Int64?
        public var penaltyEndsAt: Int64?
        public var source: String
        public var repeatId: String?
        public var checking: Bool
        public var proofs: [Proof]
        public var extensions: [Ext]
    }

    public struct Proof: Codable, Equatable, Sendable {
        public var id: String
        public var at: Int64
        public var files: Int
        public var note: String
        public var verdict: String?
        public var reason: String
    }

    public struct Ext: Codable, Equatable, Sendable {
        public var at: Int64
        public var hoursAsked: Int
        public var hoursGranted: Int
        public var decision: String?
        public var reason: String
        public var answer: String
    }

    public struct Repeat: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var details: String
        public var unit: String
        public var interval: Int
        public var weekdays: [Int]
        public var minuteOfDay: Int
        public var startDate: String
        public var currentDue: Int64?
        public var schedule: String
    }

    public struct Apps: Codable, Equatable, Sendable {
        public var builtIn: [App]
        public var allowed: [App]
        public var blocked: [App]
        public var running: [App]
        public var recent: [App]
    }

    public struct App: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var lastSeen: Int64?

        public init(id: String, name: String, lastSeen: Int64? = nil) {
            self.id = id
            self.name = name
            self.lastSeen = lastSeen
        }
    }

    public struct SettingsSummary: Codable, Equatable, Sendable {
        public var penaltyMinutes: Int
        public var extensionsEnabled: Bool
    }

    public struct Record: Codable, Equatable, Sendable {
        public var onTime: Int
        public var late: Int
        public var missed: Int
        public var extensionsThisWeek: Int
    }

    public struct Event: Codable, Equatable, Sendable {
        public var at: Int64
        public var kind: String
        public var text: String

        public init(at: Int64, kind: String, text: String) {
            self.at = at
            self.kind = kind
            self.text = WireState.clean(text, max: 200)
        }
    }

    public struct Device: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var pairedAt: Int64
    }

    public struct Flag: Codable, Equatable, Sendable {
        public var kind: String
        public var text: String
        public var at: Int64

        public init(kind: String, text: String, at: Int64) {
            self.kind = kind
            self.text = WireState.clean(text, max: 200)
            self.at = at
        }
    }

    public struct Message: Codable, Equatable, Sendable {
        public var text: String
        public var by: String
        public var at: Int64
    }

    public static let capabilities = ["lock", "tasks", "repeats", "apps", "block", "penalty", "extensions", "message",
                                      "approveProof"]

    /// No line breaks (they could fake a log line on the other end), and no more than `max` characters.
    public static func clean(_ text: String, max: Int) -> String {
        let flat = text.map { "\n\r\u{2028}\u{2029}\u{85}\u{0B}\u{0C}".contains($0) ? " " : $0 }
        return String(String(flat).prefix(max))
    }

    public static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

/// One answer to a command, in the state's `results`.
public struct CommandResult: Codable, Equatable, Sendable {
    public var dev: String
    public var n: Int64
    public var id: String
    public var type: String
    /// "applied", "noop", "rejected" or "unsupported".
    public var outcome: String
    public var reason: String
    public var at: Int64

    public init(dev: String, n: Int64, id: String, type: String, outcome: String, reason: String = "", at: Int64) {
        self.dev = dev
        self.n = n
        self.id = id
        self.type = type
        self.outcome = outcome
        self.reason = WireState.clean(reason, max: 200)
        self.at = at
    }
}

/// Builds the state from the app's own data. Pure, so it can be checked.
public enum StateBuilder {
    public struct Input {
        public var seq: Int64
        public var now: Date
        public var computer: WireState.Computer
        public var tasks: [TaxTask]
        public var recurring: [RecurringTask]
        public var settings: Settings
        public var lock: LockState
        public var checking: Set<UUID>
        public var builtIn: [AppRef]
        public var running: [AppRef]
        public var recent: [WireState.App]
        public var activity: [WireState.Event]
        public var results: [CommandResult]
        public var devices: [WireState.Device]
        public var flags: [WireState.Flag]
        public var accessBy: String
        public var accessAt: Int64
        public var calendar: Calendar

        public init(seq: Int64, now: Date, computer: WireState.Computer, tasks: [TaxTask], recurring: [RecurringTask],
                    settings: Settings, lock: LockState, checking: Set<UUID>, builtIn: [AppRef], running: [AppRef],
                    recent: [WireState.App], activity: [WireState.Event], results: [CommandResult],
                    devices: [WireState.Device], flags: [WireState.Flag], accessBy: String, accessAt: Int64,
                    calendar: Calendar = .current) {
            self.seq = seq
            self.now = now
            self.computer = computer
            self.tasks = tasks
            self.recurring = recurring
            self.settings = settings
            self.lock = lock
            self.checking = checking
            self.builtIn = builtIn
            self.running = running
            self.recent = recent
            self.activity = activity
            self.results = results
            self.devices = devices
            self.flags = flags
            self.accessBy = accessBy
            self.accessAt = accessAt
            self.calendar = calendar
        }
    }

    public static let maxTasks = 150
    public static let finishedFor: TimeInterval = 14 * 86400

    public static func build(_ input: Input) -> WireState {
        let ms = WireState.ms
        let clean = WireState.clean
        let s = input.settings

        // Access: a parent lock, an unlock, or the normal rules.
        let access: WireState.Access
        if let p = s.parentLock, p.isActive(at: input.now) {
            access = .init(mode: "locked", until: p.until.map(ms), strength: p.strength.rawValue, by: clean(p.by, 100),
                           at: input.accessAt)
        } else if let until = s.overrideUntil, until > input.now {
            access = .init(mode: "free", until: ms(until), strength: nil, by: clean(input.accessBy, 100), at: input.accessAt)
        } else {
            access = .init(mode: "normal", until: nil, strength: nil, by: clean(input.accessBy, 100), at: input.accessAt)
        }

        var reasons: [WireState.Reason] = []
        if let p = input.lock.parentLock {
            reasons.append(.init(kind: "parent", taskId: nil, title: clean(p.by, 100), until: p.until.map(ms)))
        }
        for t in input.lock.overdue {
            reasons.append(.init(kind: "overdue", taskId: t.id.uuidString.lowercased(),
                                 title: clean(Agenda.courseAndTitle(t).title, 200), until: nil))
        }
        for t in input.lock.penalties {
            var end: Int64?
            if case let .provenLate(_, e) = t.status { end = ms(e) }
            reasons.append(.init(kind: "penalty", taskId: t.id.uuidString.lowercased(),
                                 title: clean(Agenda.courseAndTitle(t).title, 200), until: end))
        }

        // Every pending task, and what was settled in the last two weeks.
        let cutoff = input.now.addingTimeInterval(-finishedFor)
        let shown = input.tasks.filter { t in
            if t.isPending { return true }
            return (settledAt(t) ?? t.dueDate) >= cutoff
        }
        let tasks = shown.sorted { $0.dueDate < $1.dueDate }.prefix(maxTasks).map { t -> WireState.Task in
            let parts = Agenda.courseAndTitle(t)
            var penaltyEnd: Int64?
            if case let .provenLate(_, e) = t.status { penaltyEnd = ms(e) }
            let source: String
            if t.seriesID != nil { source = "repeat" } else if case .blackbaud = t.source { source = "blackbaud" } else { source = "manual" }
            return WireState.Task(
                id: t.id.uuidString.lowercased(), title: clean(parts.title, 200), course: parts.course.map { clean($0, 100) },
                details: clean(t.details, 500), due: ms(t.dueDate), created: ms(t.createdAt),
                status: statusWord(t.status), statusAt: settledAt(t).map(ms), penaltyEndsAt: penaltyEnd, source: source,
                repeatId: t.seriesID?.uuidString.lowercased(),
                checking: t.proofs.contains { input.checking.contains($0.id) },
                proofs: t.proofs.suffix(10).map { p in
                    WireState.Proof(id: p.id.uuidString.lowercased(), at: ms(p.submittedAt), files: p.attachments.count,
                                    note: clean(p.note, 300), verdict: p.verdict?.rawValue, reason: clean(p.reason, 300))
                },
                extensions: (t.extensions ?? []).suffix(5).map { e in
                    WireState.Ext(at: ms(e.requestedAt), hoursAsked: e.hoursAsked, hoursGranted: e.hoursGranted,
                                  decision: e.decision?.rawValue, reason: clean(e.reason, 300), answer: clean(e.answer, 300))
                })
        }

        let dayFormat = DateFormatter()
        dayFormat.calendar = input.calendar
        dayFormat.timeZone = input.calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        let repeats = input.recurring.map { r in
            WireState.Repeat(id: r.id.uuidString.lowercased(), title: clean(r.title, 200), details: clean(r.details, 500),
                             unit: r.unit.rawValue, interval: r.interval, weekdays: r.weekdays.sorted(),
                             minuteOfDay: r.minuteOfDay, startDate: dayFormat.string(from: r.startDate),
                             currentDue: r.currentDue.map(ms), schedule: clean(r.schedule(calendar: input.calendar), 200))
        }

        let app = { (a: AppRef) in WireState.App(id: clean(a.id, 300), name: clean(a.name, 100)) }
        let extra = s.extraAllowedBundleIDs.map { AppRef(id: $0, name: s.appNames[$0] ?? $0) }
        let record = TrackRecord.of(input.tasks, now: input.now)
        let message = s.parentMessage.flatMap { m in
            input.now.timeIntervalSince(m.at) < ParentMessage.showFor
                ? WireState.Message(text: clean(m.text, 300), by: clean(m.by, 100), at: ms(m.at)) : nil
        }

        return WireState(
            seq: input.seq, sentAt: ms(input.now), computer: input.computer, access: access,
            lock: .init(locked: input.lock.isLocked, reasons: reasons), tasks: Array(tasks), repeats: repeats,
            apps: .init(builtIn: input.builtIn.map(app), allowed: extra.map(app), blocked: s.blockedApps.map(app),
                        running: input.running.prefix(50).map(app),
                        recent: input.recent.prefix(50).map { WireState.App(id: clean($0.id, 300), name: clean($0.name, 100), lastSeen: $0.lastSeen) }),
            settings: .init(penaltyMinutes: s.penaltyMinutes, extensionsEnabled: s.extensionsEnabled),
            trackRecord: .init(onTime: record.onTime, late: record.late, missed: record.missed,
                               extensionsThisWeek: record.extensionsThisWeek),
            activity: Array(input.activity.suffix(100)), results: Array(input.results.suffix(50)),
            devices: input.devices, flags: input.flags, message: message)
    }

    static func statusWord(_ status: TaskStatus) -> String {
        switch status {
        case .pending: "pending"
        case .proven: "proven"
        case .provenLate: "provenLate"
        case .excused: "excused"
        }
    }

    static func settledAt(_ t: TaxTask) -> Date? {
        switch t.status {
        case .pending: nil
        case let .proven(at), let .provenLate(at, _), let .excused(at): at
        }
    }

    /// The bytes to seal: the JSON, compressed.
    public static func encode(_ state: WireState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let json = try? encoder.encode(state) else { return nil }
        return LinkCrypto.deflateRaw(json)
    }
}
