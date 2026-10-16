import Foundation

/// How reliably you've met your deadlines lately. It decides whether you can ask for more time.
public struct TrackRecord: Equatable, Sendable {
    /// Proof accepted before the deadline.
    public var onTime: Int
    /// Proof accepted after the deadline (the Mac was locked first).
    public var late: Int
    /// Overdue right now with no accepted proof.
    public var missed: Int
    /// Extensions granted in the last 7 days.
    public var extensionsThisWeek: Int

    public var finished: Int { onTime + late }

    /// Share of deadlines met. Excused tasks don't count either way.
    public var onTimeRate: Double {
        let counted = onTime + late + missed
        return counted == 0 ? 0 : Double(onTime) / Double(counted)
    }

    public static func of(_ tasks: [TaxTask], now: Date) -> TrackRecord {
        var record = TrackRecord(onTime: 0, late: 0, missed: 0, extensionsThisWeek: 0)
        let since = now.addingTimeInterval(-ExtensionPolicy.window)
        for task in tasks where task.dueDate > since {
            switch task.status {
            case .proven: record.onTime += 1
            case .provenLate: record.late += 1
            case .pending where task.dueDate <= now: record.missed += 1
            case .pending, .excused: break
            }
        }
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        record.extensionsThisWeek = tasks.flatMap { $0.extensions ?? [] }
            .filter { $0.decision == .granted && $0.requestedAt > weekAgo }
            .count
        return record
    }
}

/// The limits on asking for more time. Claude judges the reason; these are enforced no matter what it says.
public enum ExtensionPolicy {
    public static let maxHours = 12
    public static let window: TimeInterval = 30 * 86400
    public static let minimumFinished = 5
    public static let minimumOnTimeRate = 0.8
    public static let perWeek = 2
    /// The shortest reason worth sending.
    public static let minimumReason = 30

    /// nil when you can ask for more time on this task; otherwise why not.
    public static func whyNot(task: TaxTask, record: TrackRecord, enabled: Bool, now: Date) -> String? {
        if !enabled { return "Your guardian has turned off requests for more time." }
        if !task.isPending { return "This task is already finished." }
        if task.dueDate <= now { return "You can only ask before the deadline." }
        // A request Claude couldn't answer doesn't count; anything else does, so there's no asking again.
        if (task.extensions ?? []).contains(where: { $0.decision != .error }) {
            return "You've already asked for more time on this task."
        }
        if record.finished < minimumFinished {
            return "You need at least \(minimumFinished) finished tasks in the last 30 days first. You have \(record.finished)."
        }
        if record.onTimeRate < minimumOnTimeRate {
            return "\(Int((record.onTimeRate * 100).rounded()))% of your recent deadlines were met. It needs to be at least \(Int(minimumOnTimeRate * 100))%."
        }
        if record.extensionsThisWeek >= perWeek {
            return "You've already had \(perWeek) extensions in the last 7 days."
        }
        return nil
    }

    /// Never more than asked, never more than the maximum, never negative.
    public static func clampedHours(granted: Int, asked: Int) -> Int {
        max(0, min(granted, asked, maxHours))
    }
}
