import Foundation

/// A task that comes back every week, like homework for a class you have every Monday.
///
/// Only one copy is out at a time. The next one appears once the current copy's deadline has passed,
/// however early you paid it, so finishing on Friday doesn't bring next week's homework forward.
/// Each copy is an ordinary task with its own proof and the usual 24-hour lock-in.
public struct RecurringTask: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var details: String
    /// The days it's due, as `Calendar` weekdays: 1 is Sunday, 2 is Monday … 7 is Saturday.
    public var weekdays: Set<Int>
    /// The time it's due on those days, in minutes after midnight.
    public var minuteOfDay: Int
    public var createdAt: Date
    /// When the copy that's out now is due. The next copy appears once this has passed.
    public var currentDue: Date?

    public init(id: UUID = UUID(), title: String, details: String = "", weekdays: Set<Int>, minuteOfDay: Int,
                createdAt: Date, currentDue: Date? = nil) {
        self.id = id
        self.title = title
        self.details = details
        self.weekdays = weekdays
        self.minuteOfDay = minuteOfDay
        self.createdAt = createdAt
        self.currentDue = currentDue
    }

    /// The first deadline after `date`.
    public func nextDue(after date: Date, calendar: Calendar = .current) -> Date? {
        Recurrence.nextDue(after: date, weekdays: weekdays, minuteOfDay: minuteOfDay, calendar: calendar)
    }

    /// "Every Monday at 8:30 AM", "Every Monday and Wednesday at 3:00 PM", "Every weekday at 9:00 PM".
    public func schedule(calendar: Calendar = .current) -> String {
        let days: String
        switch weekdays {
        case Set(1...7): days = "day"
        case Set(2...6): days = "weekday"
        default:
            // In the order the week starts in this calendar, Monday first in most places.
            let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }.filter(weekdays.contains)
            let names = order.map { calendar.weekdaySymbols[$0 - 1] }
            days = names.count <= 2 ? names.joined(separator: " and ")
                : names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
        let time = DateFormatter()
        time.locale = calendar.locale ?? .current
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let sample = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0,
                                   of: calendar.startOfDay(for: createdAt)) ?? createdAt
        return "Every \(days) at \(time.string(from: sample))"
    }
}

public enum Recurrence {
    /// The first moment after `date` that falls on one of `weekdays` at `minuteOfDay`.
    public static func nextDue(after date: Date, weekdays: Set<Int>, minuteOfDay: Int,
                               calendar: Calendar = .current) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        let today = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let due = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day),
                  due > date else { continue }
            return due
        }
        return nil
    }

    /// The copies that should be out by `now`, and the series with their new current deadlines.
    /// A series whose current copy isn't due yet gets nothing. After a long gap, like the Mac being off for
    /// weeks, only the next copy appears, never a backlog of missed ones that would lock you at once.
    public static func newCopies(of series: [RecurringTask], now: Date,
                                 calendar: Calendar = .current) -> (tasks: [TaxTask], series: [RecurringTask]) {
        var updated = series
        var tasks: [TaxTask] = []
        for i in updated.indices {
            if let current = updated[i].currentDue, current > now { continue }
            guard let due = updated[i].nextDue(after: now, calendar: calendar) else { continue }
            var copy = TaxTask(title: updated[i].title, details: updated[i].details, dueDate: due, createdAt: now)
            copy.seriesID = updated[i].id
            tasks.append(copy)
            updated[i].currentDue = due
        }
        return (tasks, updated)
    }
}
