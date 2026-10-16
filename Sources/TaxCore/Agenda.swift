import Foundation

/// The task list as a planner: what's charging a late fee, what's overdue, then one section per day.
public struct AgendaSection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case lateFee
        case overdue
        /// The start of that day.
        case day(Date)
    }

    public var kind: Kind
    /// Soonest due first.
    public var tasks: [TaxTask]
}

public enum Agenda {
    /// Owed tasks ranked by when they're due, grouped by day. Settled tasks aren't included.
    public static func sections(_ tasks: [TaxTask], now: Date, calendar: Calendar = .current) -> [AgendaSection] {
        let byDue: (TaxTask, TaxTask) -> Bool = { a, b in
            a.dueDate != b.dueDate ? a.dueDate < b.dueDate : a.title.localizedCompare(b.title) == .orderedAscending
        }
        var sections: [AgendaSection] = []

        let lateFee = tasks.filter { LockPolicy.isInPenalty($0, now: now) }.sorted(by: byDue)
        if !lateFee.isEmpty { sections.append(AgendaSection(kind: .lateFee, tasks: lateFee)) }

        let pending = tasks.filter(\.isPending).sorted(by: byDue)
        let overdue = pending.filter { $0.dueDate <= now }
        if !overdue.isEmpty { sections.append(AgendaSection(kind: .overdue, tasks: overdue)) }

        var dayOrder: [Date] = []
        var days: [Date: [TaxTask]] = [:]
        for task in pending where task.dueDate > now {
            let day = calendar.startOfDay(for: task.dueDate)
            if days[day] == nil { dayOrder.append(day) }
            days[day, default: []].append(task)
        }
        for day in dayOrder { sections.append(AgendaSection(kind: .day(day), tasks: days[day] ?? [])) }
        return sections
    }

    /// Blackbaud titles look like "Mathematics 7 - MAT7 - 7B: Unit 1 Lesson 4". Split off the course
    /// ("Mathematics 7") so the assignment name can lead. Your own tasks have no course.
    public static func courseAndTitle(_ task: TaxTask) -> (course: String?, title: String) {
        // Older versions saved some titles with codes like "&#160;" still in them.
        let title = task.isFromBlackbaud ? Blackbaud.plainText(task.title) : task.title
        guard task.isFromBlackbaud, let colon = title.range(of: ": ") else { return (nil, title) }
        let prefix = String(title[..<colon.lowerBound])
        let rest = String(title[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return (nil, title) }
        // Course parts are joined by a dash followed by a space; "2026-27" has none, so it stays whole.
        let course = prefix.components(separatedBy: " - ").first?
            .replacingOccurrences(of: #"\s*-\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) ?? prefix
        return (course.isEmpty ? prefix : course, rest)
    }

    /// The same course always gets the same slot, in any run of the app (unlike `hashValue`).
    public static func colorSlot(for course: String, slots: Int) -> Int {
        guard slots > 0 else { return 0 }
        var hash: UInt32 = 5381
        for byte in course.lowercased().utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return Int(hash % UInt32(slots))
    }
}
