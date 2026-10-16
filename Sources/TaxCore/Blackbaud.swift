import Foundation

/// One assignment as the feed describes it, already mapped to what a task needs.
public struct BlackbaudAssignment: Codable, Equatable, Sendable {
    public var uid: String
    public var title: String
    public var details: String
    public var dueDate: Date

    public init(uid: String, title: String, details: String = "", dueDate: Date) {
        self.uid = uid
        self.title = title
        self.details = details
        self.dueDate = dueDate
    }
}

/// What the importer remembers between polls.
public struct BlackbaudState: Codable, Equatable, Sendable {
    /// What the feed last said about each imported assignment, so a poll can tell a teacher's change from your own edit.
    public var lastSeen: [String: BlackbaudAssignment]
    /// Assignments you deleted. The next poll doesn't bring them back.
    public var dismissed: Set<String>
    public var lastSync: Date?

    public init() {
        lastSeen = [:]
        dismissed = []
        lastSync = nil
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSeen = try c.decodeIfPresent([String: BlackbaudAssignment].self, forKey: .lastSeen) ?? [:]
        dismissed = try c.decodeIfPresent(Set<String>.self, forKey: .dismissed) ?? []
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
    }

    public mutating func dismiss(uid: String) {
        dismissed.insert(uid)
        lastSeen[uid] = nil
    }
}

public struct BlackbaudSyncResult: Sendable {
    public var tasks: [TaxTask]
    public var state: BlackbaudState
    public var added: [TaxTask]
    /// One line per change the feed made or tried to make, for the log.
    public var notes: [String]
}

/// Turns a Blackbaud (myschoolapp) iCal feed into tasks.
public enum Blackbaud {
    public static let pollInterval: TimeInterval = 30 * 60
    public static let retryInterval: TimeInterval = 5 * 60
    /// Default for assignments with a date but no time: minutes after midnight on the due day.
    public static let defaultAllDayDueMinutes = 23 * 60 + 59

    // MARK: Feed link

    /// Accepts what Blackbaud hands out (`webcal://…/podium/feed/iCal.aspx?z=…`) and returns a link URLSession can fetch.
    /// `file://` is allowed for testing with a saved .ics file.
    public static func feedURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        let lower = s.lowercased()
        for prefix in ["webcals://", "webcal://", "http://"] where lower.hasPrefix(prefix) {
            s = "https://" + s.dropFirst(prefix.count)
            break
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return url.path.isEmpty ? nil : url }
        guard scheme == "https", let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// The link without its query. Blackbaud's token lives in `?z=`, and anyone with it can read the calendar.
    public static func redacted(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        return (url.host ?? "feed") + url.path
    }

    // MARK: Events to assignments

    /// Cancelled events and events without a date are skipped. A repeated UID counts once.
    public static func assignments(from events: [ICalEvent], allDayDueMinutes: Int,
                                   timeZone: TimeZone = .current) -> [BlackbaudAssignment] {
        var seen = Set<String>()
        return events.compactMap { e in
            guard e.status != "CANCELLED",
                  let due = dueDate(of: e, allDayDueMinutes: allDayDueMinutes, timeZone: timeZone),
                  seen.insert(e.uid).inserted else { return nil }
            let title = plainText(e.summary)
            return BlackbaudAssignment(uid: e.uid, title: title.isEmpty ? "Untitled assignment" : title,
                                       details: String(plainText(e.description).prefix(2000)), dueDate: due)
        }
    }

    /// DUE when there is one. Otherwise the start, unless the event stretches over days
    /// (set on Monday, due Thursday), in which case its last day.
    public static func dueDate(of event: ICalEvent, allDayDueMinutes: Int, timeZone: TimeZone) -> Date? {
        if let due = event.due { return resolve(due, allDayDueMinutes: allDayDueMinutes, timeZone: timeZone) }
        guard let start = event.start ?? event.end else { return nil }
        var pick = start
        if event.start != nil, let end = event.end,
           let a = resolve(start, allDayDueMinutes: 0, timeZone: timeZone),
           let b = resolve(end, allDayDueMinutes: 0, timeZone: timeZone),
           b.timeIntervalSince(a) > 25 * 3600 {
            pick = end
            // An all-day DTEND is the day after the last one.
            if case let .allDay(y, m, d) = end, let last = shift(y, m, d, days: -1, timeZone: timeZone) {
                pick = last
            }
        }
        return resolve(pick, allDayDueMinutes: allDayDueMinutes, timeZone: timeZone)
    }

    /// A moment stays as is. A whole day becomes that day's midnight plus `allDayDueMinutes`
    /// (negative means the evening before).
    public static func resolve(_ time: ICalTime, allDayDueMinutes: Int, timeZone: TimeZone) -> Date? {
        switch time {
        case let .moment(date):
            return date
        case let .allDay(y, m, d):
            let days = Int((Double(allDayDueMinutes) / 1440).rounded(.down))
            let minutes = allDayDueMinutes - days * 1440
            guard case let .allDay(y2, m2, d2)? = shift(y, m, d, days: days, timeZone: timeZone) else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            return cal.date(from: DateComponents(year: y2, month: m2, day: d2, hour: minutes / 60, minute: minutes % 60))
        }
    }

    private static func shift(_ y: Int, _ m: Int, _ d: Int, days: Int, timeZone: TimeZone) -> ICalTime? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let noon = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              let moved = cal.date(byAdding: .day, value: days, to: noon) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: moved)
        guard let y2 = c.year, let m2 = c.month, let d2 = c.day else { return nil }
        return .allDay(year: y2, month: m2, day: d2)
    }

    /// Blackbaud descriptions are often HTML. Keep the words and line breaks, not the blank lines.
    public static func plainText(_ text: String) -> String {
        var t = text
        if t.contains("<") && t.contains(">") {
            t = t.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>", with: "\n",
                                       options: [.regularExpression, .caseInsensitive])
            t = t.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        }
        for (entity, plain) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: entity, with: plain, options: .caseInsensitive)
        }
        return t.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Sync

    /// Merges one poll into the task list.
    ///
    /// - New assignments due in the future become tasks. Past ones aren't owed, so they're skipped.
    /// - A UID that already has a task, or that you deleted, is never imported twice.
    /// - When the teacher changes an assignment, the change goes through the same rule as your own edits:
    ///   anything while it isn't locked in, only an earlier deadline once it is. Never a deadline in the past.
    /// - Assignments that drop out of the feed stay. The feed only looks a few weeks ahead.
    public static func sync(tasks: [TaxTask], state: BlackbaudState, assignments: [BlackbaudAssignment],
                            now: Date) -> BlackbaudSyncResult {
        var tasks = tasks
        var state = state
        var added: [TaxTask] = []
        var notes: [String] = []

        for item in assignments {
            if let i = tasks.firstIndex(where: { $0.source == .blackbaud(uid: item.uid) }) {
                let before = state.lastSeen[item.uid]
                state.lastSeen[item.uid] = item
                guard let before, before != item, tasks[i].isPending else { continue }

                let original = tasks[i]
                var edited = original
                if item.title != before.title { edited.title = item.title }
                if item.details != before.details { edited.details = item.details }
                if item.dueDate != before.dueDate && item.dueDate > now { edited.dueDate = item.dueDate }
                guard edited != original else {
                    if item.dueDate != before.dueDate {
                        notes.append("kept \"\(original.title)\" due \(original.dueDate): the feed moved it into the past")
                    }
                    continue
                }
                if LockPolicy.canEditWithoutGuardian(original: original, edited: edited, now: now) {
                    tasks[i] = edited
                    notes.append("updated \"\(edited.title)\" due \(edited.dueDate)")
                } else if edited.dueDate < original.dueDate {
                    tasks[i].dueDate = edited.dueDate
                    notes.append("moved \"\(original.title)\" earlier to \(edited.dueDate); skipped its other changes because it's locked in")
                } else {
                    notes.append("kept \"\(original.title)\" as is: it's locked in and the feed's change would loosen it")
                }
            } else if !state.dismissed.contains(item.uid), item.dueDate > now {
                let task = TaxTask(title: item.title, details: item.details, dueDate: item.dueDate,
                                   createdAt: now, source: .blackbaud(uid: item.uid))
                tasks.append(task)
                added.append(task)
                state.lastSeen[item.uid] = item
            }
        }
        return BlackbaudSyncResult(tasks: tasks, state: state, added: added, notes: notes)
    }
}
