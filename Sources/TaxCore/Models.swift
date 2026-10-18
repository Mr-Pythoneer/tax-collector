import Foundation

/// Where a task came from: typed in, or imported from a Blackbaud iCal feed (keyed by the event's UID).
public enum TaskSource: Codable, Equatable, Sendable {
    case manual
    case blackbaud(uid: String)
}

public enum Verdict: String, Codable, Equatable, Sendable {
    case accepted
    case rejected
    case error
    case guardianApproved
}

public struct ProofSubmission: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var submittedAt: Date
    public var note: String
    /// File names inside this submission's proof folder.
    public var attachments: [String]
    /// nil while the auditor is still checking.
    public var verdict: Verdict?
    public var reason: String
    /// When you last asked for it to be checked again, after a check that couldn't finish.
    public var recheckedAt: Date?

    public init(id: UUID = UUID(), submittedAt: Date, note: String, attachments: [String],
                verdict: Verdict? = nil, reason: String = "", recheckedAt: Date? = nil) {
        self.id = id
        self.submittedAt = submittedAt
        self.note = note
        self.attachments = attachments
        self.verdict = verdict
        self.reason = reason
        self.recheckedAt = recheckedAt
    }

    public var isAccepted: Bool { verdict == .accepted || verdict == .guardianApproved }
}

/// One thing the task asks for, ticked off in the last check.
public struct ChecklistItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var done: Bool

    public init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}

/// Claude's answer to a request for more time.
public enum ExtensionDecision: String, Codable, Equatable, Sendable {
    case granted
    case denied
    case error
}

/// A request for more time on a task, and how it went.
public struct Extension: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var requestedAt: Date
    public var hoursAsked: Int
    /// Why the student asked.
    public var reason: String
    /// nil while Claude is deciding.
    public var decision: ExtensionDecision?
    public var hoursGranted: Int
    /// Claude's explanation, to the student.
    public var answer: String
    public var previousDue: Date

    public init(id: UUID = UUID(), requestedAt: Date, hoursAsked: Int, reason: String, decision: ExtensionDecision? = nil,
                hoursGranted: Int = 0, answer: String = "", previousDue: Date) {
        self.id = id
        self.requestedAt = requestedAt
        self.hoursAsked = hoursAsked
        self.reason = reason
        self.decision = decision
        self.hoursGranted = hoursGranted
        self.answer = answer
        self.previousDue = previousDue
    }
}

/// Where marking the assignment Completed in Blackbaud stands.
public enum BlackbaudMark: Codable, Equatable, Sendable {
    case working
    case done(at: Date)
    case failed(reason: String)
}

public enum TaskStatus: Codable, Equatable, Sendable {
    case pending
    case proven(at: Date)
    case provenLate(at: Date, penaltyEndsAt: Date)
    case excused(at: Date)
}

public struct TaxTask: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var details: String
    public var dueDate: Date
    public var createdAt: Date
    public var source: TaskSource
    public var status: TaskStatus
    public var proofs: [ProofSubmission]
    /// Filled in when proof is accepted. Optional so older saved tasks still load.
    public var checklist: [ChecklistItem]?
    /// When you confirmed every checklist item.
    public var lastCheckDoneAt: Date?
    public var blackbaudMark: BlackbaudMark?
    /// Requests for more time. Optional so older saved tasks still load.
    public var extensions: [Extension]?
    /// The repeating task this is one week's copy of.
    public var seriesID: UUID?

    public init(id: UUID = UUID(), title: String, details: String = "", dueDate: Date,
                createdAt: Date, source: TaskSource = .manual, status: TaskStatus = .pending,
                proofs: [ProofSubmission] = []) {
        self.id = id
        self.title = title
        self.details = details
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.source = source
        self.status = status
        self.proofs = proofs
    }

    public var isPending: Bool { status == .pending }

    public var isFromBlackbaud: Bool {
        if case .blackbaud = source { return true }
        return false
    }

    /// Paid, but you haven't yet confirmed the checklist and had Blackbaud marked.
    public var needsLastCheck: Bool {
        guard isFromBlackbaud, lastCheckDoneAt == nil else { return false }
        switch status {
        case .proven, .provenLate: return true
        case .pending, .excused: return false
        }
    }

    /// A proof sent in before the deadline that the auditor hasn't ruled on yet.
    /// While one exists the task doesn't count as overdue (for a few minutes at most, see
    /// `LockPolicy.checkGrace`), so a slow check can't make you late. Checking again after the
    /// deadline doesn't count: it can't lift a lock that has already started.
    public var hasCheckInFlightFromBeforeDue: Bool {
        proofs.contains { $0.verdict == nil && $0.submittedAt <= dueDate && ($0.recheckedAt ?? $0.submittedAt) <= dueDate }
            || (extensions ?? []).contains { $0.decision == nil && $0.requestedAt <= dueDate }
    }
}

/// How much a parent lock closes. `homework` keeps the allowed apps open, like a lock for overdue work;
/// `all` closes everything except the system and Tax Collector.
public enum LockStrength: String, Codable, Equatable, Sendable {
    case homework
    case all
}

/// A lock a parent put on, whatever is due.
public struct ParentLock: Codable, Equatable, Sendable {
    /// nil until a parent lifts it.
    public var until: Date?
    public var strength: LockStrength
    /// Who: a phone's name, or "your guardian" for the guardian code on this computer.
    public var by: String
    public var since: Date
    public var note: String?

    public init(until: Date?, strength: LockStrength, by: String, since: Date, note: String? = nil) {
        self.until = until
        self.strength = strength
        self.by = by
        self.since = since
        self.note = note
    }

    public func isActive(at now: Date) -> Bool { until.map { $0 > now } ?? true }
}

/// An app, by bundle ID, with the name to show for it.
public struct AppRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A note a parent sent from their phone. Shown for a day.
public struct ParentMessage: Codable, Equatable, Sendable {
    public var text: String
    public var by: String
    public var at: Date

    public init(text: String, by: String, at: Date) {
        self.text = text
        self.by = by
        self.at = at
    }

    public static let showFor: TimeInterval = 24 * 3600
}

public struct Settings: Codable, Equatable, Sendable {
    public var penaltyMinutes: Int
    /// Apps the guardian added on top of the built-in allowlist.
    public var extraAllowedBundleIDs: [String]
    public var claudePath: String
    public var claudeModel: String
    public var overrideUntil: Date?
    /// Latest time this app has seen, used so winding the clock back doesn't undo a deadline.
    public var lastSeen: Date?
    public var guardianFailures: Int
    public var guardianLockedUntil: Date?
    /// The Blackbaud feed link. nil means import is off.
    public var blackbaudURL: String?
    /// When import was turned on, for the 5-minute grace to undo a mistake.
    public var blackbaudOnSince: Date?
    /// When an assignment has a date but no time, it's due this many minutes after midnight on that day.
    /// Negative means the evening before.
    public var allDayDueMinutes: Int
    /// "light" (the default), "dark" or "system". Older versions saved "paper" and "ink".
    public var appearance: String
    /// Set just before setup hands over to the background copy, so that copy can say it's ready.
    public var justSetUp: Bool
    /// Whether you can ask Claude for up to 12 more hours. Only the guardian can change it.
    public var extensionsEnabled: Bool
    /// A lock a parent put on from their phone (or the guardian here).
    public var parentLock: ParentLock?
    /// Apps closed whenever they run, locked or not.
    public var blockedApps: [AppRef]
    /// Names for the extra allowed apps, when a parent's phone added them.
    public var appNames: [String: String]
    /// A parent's phone is paired. While it is, a missing guardian code doesn't reopen first-time setup.
    public var parentLinked: Bool
    public var parentMessage: ParentMessage?

    public init() {
        penaltyMinutes = 30
        extraAllowedBundleIDs = []
        claudePath = "/opt/homebrew/bin/claude"
        claudeModel = "sonnet"
        overrideUntil = nil
        lastSeen = nil
        guardianFailures = 0
        guardianLockedUntil = nil
        blackbaudURL = nil
        blackbaudOnSince = nil
        allDayDueMinutes = Blackbaud.defaultAllDayDueMinutes
        appearance = "light"
        justSetUp = false
        extensionsEnabled = true
        parentLock = nil
        blockedApps = []
        appNames = [:]
        parentLinked = false
        parentMessage = nil
    }

    // Decode field by field so adding a setting later doesn't wipe saved ones.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        penaltyMinutes = try c.decodeIfPresent(Int.self, forKey: .penaltyMinutes) ?? penaltyMinutes
        extraAllowedBundleIDs = try c.decodeIfPresent([String].self, forKey: .extraAllowedBundleIDs) ?? []
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? claudePath
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? claudeModel
        overrideUntil = try c.decodeIfPresent(Date.self, forKey: .overrideUntil)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        guardianFailures = try c.decodeIfPresent(Int.self, forKey: .guardianFailures) ?? 0
        guardianLockedUntil = try c.decodeIfPresent(Date.self, forKey: .guardianLockedUntil)
        blackbaudURL = try c.decodeIfPresent(String.self, forKey: .blackbaudURL)
        blackbaudOnSince = try c.decodeIfPresent(Date.self, forKey: .blackbaudOnSince)
        allDayDueMinutes = try c.decodeIfPresent(Int.self, forKey: .allDayDueMinutes) ?? allDayDueMinutes
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        justSetUp = try c.decodeIfPresent(Bool.self, forKey: .justSetUp) ?? false
        extensionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .extensionsEnabled) ?? true
        parentLock = try c.decodeIfPresent(ParentLock.self, forKey: .parentLock)
        blockedApps = try c.decodeIfPresent([AppRef].self, forKey: .blockedApps) ?? []
        appNames = try c.decodeIfPresent([String: String].self, forKey: .appNames) ?? [:]
        parentLinked = try c.decodeIfPresent(Bool.self, forKey: .parentLinked) ?? false
        parentMessage = try c.decodeIfPresent(ParentMessage.self, forKey: .parentMessage)
    }
}
