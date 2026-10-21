import Foundation

public struct LockState: Equatable, Sendable {
    public var overdue: [TaxTask]
    /// Tasks paid late whose penalty is still running.
    public var penalties: [TaxTask]
    public var overrideUntil: Date?
    /// A parent's lock that's still on.
    public var parentLock: ParentLock?

    public init(overdue: [TaxTask] = [], penalties: [TaxTask] = [], overrideUntil: Date? = nil, parentLock: ParentLock? = nil) {
        self.overdue = overdue
        self.penalties = penalties
        self.overrideUntil = overrideUntil
        self.parentLock = parentLock
    }

    public var owesSomething: Bool { !overdue.isEmpty || !penalties.isEmpty }
    /// An unlock (the guardian's, or a parent's "free until") beats everything, including a parent lock.
    public var isLocked: Bool { (owesSomething || parentLock != nil) && overrideUntil == nil }
    /// A parent's "everything" lock closes the allowed apps too.
    public var strength: LockStrength { parentLock?.strength ?? .homework }

    /// When the lock ends by itself (only possible when nothing is overdue, just penalties).
    public var penaltyEndsAt: Date? {
        guard overdue.isEmpty else { return nil }
        return penalties.compactMap { task -> Date? in
            if case let .provenLate(_, end) = task.status { return end }
            return nil
        }.max()
    }
}

public enum LockPolicy {
    /// Inside this window before the deadline, a task is locked in.
    public static let freezeWindow: TimeInterval = 24 * 3600
    /// Right after creating a task you can still fix typos, even if it's due soon.
    public static let creationGrace: TimeInterval = 5 * 60
    /// The longest a check that started before the deadline holds the lock off once the deadline has
    /// passed. Claude gets 3 minutes; if its answer still hasn't come, the task counts as overdue anyway.
    public static let checkGrace: TimeInterval = 5 * 60

    public static func state(tasks: [TaxTask], overrideUntil: Date?, parentLock: ParentLock? = nil, now: Date) -> LockState {
        let overdue = tasks.filter { isOverdue($0, now: now) }
        let penalties = tasks.filter { isInPenalty($0, now: now) }
        let override = overrideUntil.flatMap { $0 > now ? $0 : nil }
        return LockState(overdue: overdue, penalties: penalties, overrideUntil: override,
                         parentLock: parentLock.flatMap { $0.isActive(at: now) ? $0 : nil })
    }

    public static func isOverdue(_ task: TaxTask, now: Date) -> Bool {
        guard task.isPending, task.dueDate <= now else { return false }
        return !(task.hasCheckInFlightFromBeforeDue && now < task.dueDate.addingTimeInterval(checkGrace))
    }

    public static func isInPenalty(_ task: TaxTask, now: Date) -> Bool {
        if case let .provenLate(_, end) = task.status { return end > now }
        return false
    }

    /// Whether the task can be edited or deleted without the guardian code.
    public static func isFrozen(_ task: TaxTask, now: Date) -> Bool {
        if isInPenalty(task, now: now) { return true }
        guard task.isPending else { return false }
        if now.timeIntervalSince(task.createdAt) < creationGrace { return false }
        return task.dueDate.timeIntervalSince(now) <= freezeWindow
    }

    /// Moving a deadline earlier only makes things stricter, so that's always allowed.
    /// Anything else on a frozen task needs the guardian.
    public static func canEditWithoutGuardian(original: TaxTask, edited: TaxTask, now: Date) -> Bool {
        guard isFrozen(original, now: now) else { return true }
        return edited.title == original.title
            && edited.details == original.details
            && edited.dueDate <= original.dueDate
    }

    public static func canDeleteWithoutGuardian(_ task: TaxTask, now: Date) -> Bool {
        !isFrozen(task, now: now)
    }

    /// Turning the Blackbaud feed off loosens the rules, so it gets the same lock-in as tasks:
    /// free while nothing it imported is locked in, or in the first 5 minutes after turning it on.
    /// Otherwise only the guardian can. Tasks it already imported stay either way.
    public static func canStopFeedWithoutGuardian(onSince: Date?, tasks: [TaxTask], now: Date) -> Bool {
        canStopImport(onSince: onSince, tasks: tasks.filter(\.isFromBlackbaud), now: now)
    }

    /// The same rule for Teams import.
    public static func canStopTeamsWithoutGuardian(onSince: Date?, tasks: [TaxTask], now: Date) -> Bool {
        canStopImport(onSince: onSince, tasks: tasks.filter(\.isFromTeams), now: now)
    }

    private static func canStopImport(onSince: Date?, tasks imported: [TaxTask], now: Date) -> Bool {
        if let onSince, now.timeIntervalSince(onSince) < creationGrace { return true }
        return !imported.contains { isFrozen($0, now: now) }
    }

    /// What a task becomes once its proof is accepted.
    public static func statusAfterAccepting(_ task: TaxTask, submittedAt: Date, acceptedAt: Date,
                                            penaltyMinutes: Int) -> TaskStatus {
        if submittedAt <= task.dueDate {
            return .proven(at: submittedAt)
        }
        let end = acceptedAt.addingTimeInterval(TimeInterval(max(0, penaltyMinutes)) * 60)
        return .provenLate(at: submittedAt, penaltyEndsAt: end)
    }

    /// The clock can only go forward as far as Tax Collector is concerned.
    public static func effectiveNow(systemNow: Date, lastSeen: Date?) -> Date {
        guard let lastSeen else { return systemNow }
        return max(systemNow, lastSeen)
    }

    /// Seconds to wait after the nth wrong guardian code (n starts at 1). First three are free.
    public static func guardianCooldown(afterFailures n: Int) -> TimeInterval {
        guard n >= 3 else { return 0 }
        return min(3600, 30 * pow(2, Double(n - 3)))
    }
}
