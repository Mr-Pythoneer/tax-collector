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

    public init(id: UUID = UUID(), submittedAt: Date, note: String, attachments: [String],
                verdict: Verdict? = nil, reason: String = "") {
        self.id = id
        self.submittedAt = submittedAt
        self.note = note
        self.attachments = attachments
        self.verdict = verdict
        self.reason = reason
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
    /// While one exists the task doesn't count as overdue, so a slow check can't make you late.
    public var hasCheckInFlightFromBeforeDue: Bool {
        proofs.contains { $0.verdict == nil && $0.submittedAt <= dueDate }
    }
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
    }
}
