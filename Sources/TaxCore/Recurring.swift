import Foundation

/// How a repeating task counts: every N days, or every N weeks on chosen days.
public enum RepeatUnit: String, Codable, Equatable, Sendable {
    case days
    case weeks
}

/// A task that comes back on a schedule, like homework for a class you have every Monday, or something
/// every 4 days.
///
/// Only one copy is out at a time. The next one appears once the current copy's deadline has passed,
/// however early you paid it, so finishing on Friday doesn't bring next week's homework forward.
/// Each copy is an ordinary task with its own proof and the usual 24-hour lock-in.
public struct RecurringTask: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var details: String
    public var unit: RepeatUnit
    /// Every this many days or weeks.
    public var interval: Int
    /// For weeks: the days it's due, as `Calendar` weekdays (1 is Sunday, 2 is Monday … 7 is Saturday).
    public var weekdays: Set<Int>
    /// The time it's due, in minutes after midnight.
    public var minuteOfDay: Int
    /// The first day it can be due. Every N days counts from here, and every N weeks from this week.
    public var startDate: Date
    public var createdAt: Date
    /// When the copy that's out now is due. The next copy appears once this has passed.
    public var currentDue: Date?

    public static let maxDays = 365
    public static let maxWeeks = 52

    public init(id: UUID = UUID(), title: String, details: String = "", unit: RepeatUnit = .weeks, interval: Int = 1,
                weekdays: Set<Int> = [], minuteOfDay: Int, startDate: Date? = nil, createdAt: Date,
                currentDue: Date? = nil) {
        self.id = id
        self.title = title
        self.details = details
        self.unit = unit
        self.interval = max(1, min(interval, unit == .days ? Self.maxDays : Self.maxWeeks))
        self.weekdays = weekdays
        self.minuteOfDay = minuteOfDay
        self.startDate = startDate ?? createdAt
        self.createdAt = createdAt
        self.currentDue = currentDue
    }

    /// Repeats saved by 0.5.0 were weekly and had no start date.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        unit = try c.decodeIfPresent(RepeatUnit.self, forKey: .unit) ?? .weeks
        interval = max(1, try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1)
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? []
        minuteOfDay = try c.decode(Int.self, forKey: .minuteOfDay)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate) ?? createdAt
        currentDue = try c.decodeIfPresent(Date.self, forKey: .currentDue)
    }

    /// The first deadline after `date`.
    public func nextDue(after date: Date, calendar: Calendar = .current) -> Date? {
        let hour = minuteOfDay / 60, minute = minuteOfDay % 60
        let start = calendar.startOfDay(for: startDate)
        switch unit {
        case .days:
            let today = calendar.startOfDay(for: date)
            let elapsed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            var step = max(0, elapsed / interval)
            for _ in 0..<3 {
                guard let day = calendar.date(byAdding: .day, value: step * interval, to: start),
                      let due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return nil }
                if due > date { return due }
                step += 1
            }
            return nil
        case .weeks:
            guard !weekdays.isEmpty, let firstWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start else { return nil }
            var day = max(calendar.startOfDay(for: date), start)
            for _ in 0..<(7 * interval + 8) {
                if weekdays.contains(calendar.component(.weekday, from: day)),
                   let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start,
                   let days = calendar.dateComponents([.day], from: firstWeek, to: week).day,
                   (days / 7) % interval == 0,
                   let due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                   due > date {
                    return due
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = next
            }
            return nil
        }
    }

    /// "Every Monday at 8:30 AM", "Every 4 days at 9:00 PM", "Every 2 weeks on Monday and Wednesday at 3:00 PM".
    public func schedule(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let sample = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0,
                                   of: calendar.startOfDay(for: createdAt)) ?? createdAt
        let time = formatter.string(from: sample)
        switch unit {
        case .days:
            return interval == 1 ? "Every day at \(time)" : "Every \(interval) days at \(time)"
        case .weeks:
            if interval == 1 {
                switch weekdays {
                case Set(1...7): return "Every day at \(time)"
                case Set(2...6): return "Every weekday at \(time)"
                default: return "Every \(dayNames(calendar)) at \(time)"
                }
            }
            let days = weekdays == Set(1...7) ? "every day" : weekdays == Set(2...6) ? "weekdays" : dayNames(calendar)
            return "Every \(interval) weeks on \(days) at \(time)"
        }
    }

    /// "Monday", "Monday and Wednesday", "Monday, Wednesday and Friday", in the order this calendar's week starts.
    private func dayNames(_ calendar: Calendar) -> String {
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }.filter(weekdays.contains)
        let names = order.map { calendar.weekdaySymbols[$0 - 1] }
        return names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

public enum Recurrence {
    /// The first moment after `date` that falls on one of `weekdays` at `minuteOfDay`: an every-week repeat.
    public static func nextDue(after date: Date, weekdays: Set<Int>, minuteOfDay: Int,
                               calendar: Calendar = .current) -> Date? {
        RecurringTask(title: "", weekdays: weekdays, minuteOfDay: minuteOfDay, startDate: .distantPast, createdAt: date)
            .nextDue(after: date, calendar: calendar)
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
