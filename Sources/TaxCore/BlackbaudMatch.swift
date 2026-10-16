import Foundation

/// One assignment as Blackbaud's own assignment list describes it (not the calendar feed).
public struct BlackbaudListedAssignment: Equatable, Sendable {
    /// The ID the status change needs.
    public var indexID: Int
    public var assignmentID: Int?
    public var title: String
    public var course: String
    public var due: Date?
    /// Blackbaud's status code: -1 to do, 0 in progress, 1 completed (as far as we know).
    public var status: Int?

    public init(indexID: Int, assignmentID: Int? = nil, title: String, course: String = "", due: Date? = nil,
                status: Int? = nil) {
        self.indexID = indexID
        self.assignmentID = assignmentID
        self.title = title
        self.course = course
        self.due = due
        self.status = status
    }
}

/// Finds the Blackbaud assignment behind an imported task.
public enum BlackbaudMatch {
    /// The all-day default can move a deadline to the evening before, so allow a day and a half either way.
    public static let dueSlack: TimeInterval = 36 * 3600

    public static func find(feedUID: String, title: String, due: Date,
                            in list: [BlackbaudListedAssignment]) -> BlackbaudListedAssignment? {
        // Best case: the feed's UID carries one of the IDs.
        let numbers = Set(numbersIn(feedUID))
        if let exact = list.first(where: { numbers.contains($0.indexID) || ($0.assignmentID.map(numbers.contains) ?? false) }) {
            return exact
        }
        // Otherwise the same title, due around the same time. The feed title may have the course glued on.
        let wanted = normalized(title)
        guard !wanted.isEmpty else { return nil }
        let candidates = list.filter { item in
            let have = normalized(item.title)
            guard !have.isEmpty, wanted == have || wanted.contains(have) || have.contains(wanted) else { return false }
            guard let itemDue = item.due else { return true }
            return abs(itemDue.timeIntervalSince(due)) <= dueSlack
        }
        return candidates.min { a, b in
            let da = a.due.map { abs($0.timeIntervalSince(due)) } ?? .greatestFiniteMagnitude
            let db = b.due.map { abs($0.timeIntervalSince(due)) } ?? .greatestFiniteMagnitude
            if da != db { return da < db }
            // Prefer the closer title when the times tie.
            return abs(normalized(a.title).count - wanted.count) < abs(normalized(b.title).count - wanted.count)
        }
    }

    /// Lowercase letters and digits only, so punctuation and HTML leftovers don't break a match.
    public static func normalized(_ s: String) -> String {
        String(Blackbaud.plainText(s).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func numbersIn(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { $0.count >= 4 ? Int($0) : nil }
    }
}
