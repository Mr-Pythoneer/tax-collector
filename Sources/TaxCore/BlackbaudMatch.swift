import Foundation

/// One assignment as Blackbaud's own assignment list describes it (not the calendar feed).
public struct BlackbaudListedAssignment: Equatable, Sendable {
    /// The ID the status change needs.
    public var indexID: Int
    public var assignmentID: Int?
    public var title: String
    public var course: String
    public var due: Date?
    /// The status you set yourself: -1 to do, 0 in progress, 1 completed. Blackbaud sends
    /// -2147483648 when you've never set one.
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
///
/// The feed carries no assignment ID: its UIDs are random, and its titles are exactly
/// "<class>: <assignment>" (for example "Mathematics 7 - MAT7 - 7B: NS Lesson 4"). So the match is
/// made on class and title, then on title alone, then on a looser comparison, always near the due date.
public enum BlackbaudMatch {
    /// The all-day default can move a deadline to the evening before, so allow a day and a half either way.
    public static let dueSlack: TimeInterval = 36 * 3600

    public static func find(feedUID: String, title: String, due: Date,
                            in list: [BlackbaudListedAssignment]) -> BlackbaudListedAssignment? {
        // If a feed ever does carry an ID in its UID, that wins. Random GUIDs (what Blackbaud sends today) don't count.
        let isGUID = feedUID.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                                   options: .regularExpression) != nil
        let numbers = isGUID ? [] : Set(numbersIn(feedUID))
        if let exact = list.first(where: { numbers.contains($0.indexID) || ($0.assignmentID.map(numbers.contains) ?? false) }) {
            return exact
        }

        let (course, name) = split(title)
        let wantedName = normalized(name)
        guard !wantedName.isEmpty else { return nil }
        let wantedCourse = course.map(normalized)
        let nearby = list.filter { item in
            guard let itemDue = item.due else { return true }
            return abs(itemDue.timeIntervalSince(due)) <= dueSlack
        }

        // 1. Same class and same title.
        if let wantedCourse,
           let hit = closest(nearby.filter { normalized($0.course) == wantedCourse && normalized($0.title) == wantedName }, to: due) {
            return hit
        }
        // 2. Same title in any class.
        if let hit = closest(nearby.filter { normalized($0.title) == wantedName }, to: due) {
            return hit
        }
        // 3. One title contains the other (a teacher renamed it slightly). Prefer the closest length, so
        //    "Cross Country Run" doesn't pick "D. Cross Country Run" when a plainer one exists.
        let loose = nearby.filter { item in
            let have = normalized(item.title)
            return !have.isEmpty && (wantedName.contains(have) || have.contains(wantedName))
        }
        return loose.min { a, b in
            let la = abs(normalized(a.title).count - wantedName.count)
            let lb = abs(normalized(b.title).count - wantedName.count)
            if la != lb { return la < lb }
            return distance(a, due) < distance(b, due)
        }
    }

    /// "Mathematics 7 - MAT7 - 7B: Unit 1 Lesson 4 : Transformations" → ("Mathematics 7 - MAT7 - 7B", "Unit 1 Lesson 4 : Transformations").
    /// Split at the first ": ", since class names never contain one and assignment titles sometimes do.
    public static func split(_ feedTitle: String) -> (course: String?, name: String) {
        guard let colon = feedTitle.range(of: ": ") else { return (nil, feedTitle) }
        let course = String(feedTitle[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        let name = String(feedTitle[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? (nil, feedTitle) : (course, name)
    }

    /// Lowercase letters and digits only, so punctuation and HTML leftovers don't break a match.
    public static func normalized(_ s: String) -> String {
        String(Blackbaud.plainText(s).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func closest(_ items: [BlackbaudListedAssignment], to due: Date) -> BlackbaudListedAssignment? {
        items.min { distance($0, due) < distance($1, due) }
    }

    private static func distance(_ item: BlackbaudListedAssignment, _ due: Date) -> TimeInterval {
        item.due.map { abs($0.timeIntervalSince(due)) } ?? .greatestFiniteMagnitude
    }

    static func numbersIn(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { $0.count >= 4 ? Int($0) : nil }
    }
}
