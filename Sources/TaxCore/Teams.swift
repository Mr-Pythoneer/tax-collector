import Foundation

/// One assignment from Microsoft Teams, already mapped to what a task needs.
public struct TeamsAssignment: Codable, Equatable, Sendable {
    /// Teams' own assignment ID. Unlike Blackbaud's feed UIDs, it never changes.
    public var id: String
    public var classID: String
    /// "<class>: <assignment>", like Blackbaud's titles, so the class shows the same way.
    public var title: String
    public var details: String
    public var dueDate: Date
    /// The assignment in Teams.
    public var link: String?

    public init(id: String, classID: String = "", title: String, details: String = "", dueDate: Date, link: String? = nil) {
        self.id = id
        self.classID = classID
        self.title = title
        self.details = details
        self.dueDate = dueDate
        self.link = link
    }

    /// What counts as the teacher changing it. The link isn't one.
    func sameWork(as other: TeamsAssignment) -> Bool {
        title == other.title && details == other.details && dueDate == other.dueDate
    }
}

/// What the Teams importer remembers between checks.
public struct TeamsState: Codable, Equatable, Sendable {
    /// What Teams last said about each imported assignment, so a check can tell a teacher's change from your own edit.
    public var lastSeen: [String: TeamsAssignment]
    /// Assignments you deleted. The next check doesn't bring them back.
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
        lastSeen = try c.decodeIfPresent([String: TeamsAssignment].self, forKey: .lastSeen) ?? [:]
        dismissed = try c.decodeIfPresent(Set<String>.self, forKey: .dismissed) ?? []
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
    }

    public mutating func dismiss(id: String) {
        dismissed.insert(id)
        lastSeen[id] = nil
    }

    /// The assignment in Teams, for an imported task.
    public func link(of task: TaxTask) -> URL? {
        guard case let .teams(id) = task.source, let raw = lastSeen[id]?.link, let url = URL(string: raw),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

public struct TeamsSyncResult: Sendable {
    public var tasks: [TaxTask]
    public var state: TeamsState
    public var added: [TaxTask]
    /// One line per change Teams made or tried to make, for the log.
    public var notes: [String]
}

/// Turns Microsoft Teams Assignments (the student's "work" list) into tasks.
///
/// The list comes from the Assignments page itself (`assignments.edu.cloud.microsoft`), signed in as you;
/// see `TeamsLink` in the app. This part only reads its JSON and decides what becomes a task.
public enum Teams {
    public static let pollInterval: TimeInterval = 30 * 60
    public static let retryInterval: TimeInterval = 5 * 60
    public static let site = "https://assignments.edu.cloud.microsoft"
    /// Who the Assignments page's sign-in tokens are for. The page sends other tokens too (photos, Graph).
    public static let tokenAudience = "8f348934-64be-4bb2-bc16-c54c96789f43"
    /// Teams' own ID for the Assignments app. Its button in Teams has this as its `id`.
    public static let appID = "66aeee93-507d-479a-a3ef-8f494af43945"
    /// Most assignments a check asks Teams for. Upcoming work rarely tops a few dozen.
    public static let maxAssignments = 200

    // MARK: Requests

    /// The upcoming list: still assigned, not finished, due from `now` on, soonest first.
    /// The same query the Assignments page makes for its own lists, with the date the other way.
    public static func upcomingWorkPath(now: Date) -> String {
        let filter = "status eq microsoft.education.assignments.api.educationAssignmentStatus'assigned'"
            + " and isCompleted eq false and dueDateTime ge \(isoString(now))"
        var c = URLComponents()
        c.path = "/api/v1.0/edu/me/work"
        c.queryItems = [
            URLQueryItem(name: "$filter", value: filter),
            URLQueryItem(name: "$top", value: "50"),
            URLQueryItem(name: "$orderby", value: "dueDateTime asc"),
            URLQueryItem(name: "$expand", value: "submissions"),
        ]
        // "+" in a query reads as a space to many servers; spell it out.
        return (c.string ?? c.path).replacingOccurrences(of: "+", with: "%2B")
    }

    public static let classesPath = "/api/v1.0/edu/me/classes"

    /// One assignment, which (unlike the list) includes the teacher's instructions.
    public static func assignmentPath(classID: String, id: String) -> String? {
        guard isSafeID(classID), isSafeID(id) else { return nil }
        return "/api/v1.0/edu/classes/\(classID)/assignments/\(id)"
    }

    /// A next-page link as a path and query on the site, for requests made from inside the page.
    public static func relativePath(_ link: String) -> String? {
        guard isOnSite(link), let url = URL(string: link) else { return nil }
        let query = url.query.map { "?" + $0 } ?? ""
        return url.path + query
    }

    /// IDs go into a URL path, so only letters, digits and dashes.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A next-page link is only followed when it stays on the Assignments site.
    public static func isOnSite(_ link: String) -> Bool {
        guard let url = URL(string: link), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "assignments.edu.cloud.microsoft"
    }

    // MARK: Reading the JSON

    /// One item of the work list, as much of it as the importer uses.
    public struct WorkItem: Equatable, Sendable {
        public var id: String
        public var classID: String
        public var name: String
        public var due: Date?
        public var status: String
        public var isCompleted: Bool
        /// Your submission's status: "working", "submitted", "returned", "reassigned"…
        public var submission: String?
        public var excused: Bool
        public var link: String?
        public var instructionsHTML: String?
    }

    /// Reads one page of `/edu/me/work`. nil when it isn't that kind of answer at all.
    public static func parseWork(_ data: Data) -> (items: [WorkItem], next: String?)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = root["value"] as? [[String: Any]] else { return nil }
        let items = values.compactMap(workItem)
        let next = (root["@odata.nextLink"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (items, next)
    }

    /// Reads one assignment (`/edu/classes/{c}/assignments/{a}`).
    public static func parseAssignment(_ data: Data) -> WorkItem? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return workItem(root)
    }

    static func workItem(_ v: [String: Any]) -> WorkItem? {
        guard let id = v["id"] as? String, !id.isEmpty else { return nil }
        let submission = (v["submissions"] as? [[String: Any]])?.first
        let instructions = v["instructions"] as? [String: Any]
        return WorkItem(
            id: id,
            classID: v["classId"] as? String ?? "",
            name: v["displayName"] as? String ?? "",
            due: (v["dueDateTime"] as? String).flatMap(parseDate),
            status: (v["status"] as? String ?? "").lowercased(),
            isCompleted: v["isCompleted"] as? Bool ?? false,
            submission: (submission?["status"] as? String)?.lowercased(),
            excused: submission?["excusedDateTime"] is String,
            link: v["webUrl"] as? String,
            instructionsHTML: instructions?["content"] as? String)
    }

    /// Class ID → name, from `/edu/me/classes`.
    public static func parseClasses(_ data: Data) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = root["value"] as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for v in values {
            guard let id = v["id"] as? String,
                  let name = (v["name"] as? String) ?? (v["displayName"] as? String) else { continue }
            names[id] = name
        }
        return names
    }

    public static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Whether you still owe it: assigned, not marked done, not turned in, not excused, with a due date.
    public static func isOwed(_ item: WorkItem) -> Bool {
        guard item.due != nil, item.status == "assigned", !item.isCompleted, !item.excused else { return false }
        return !["submitted", "returned"].contains(item.submission ?? "")
    }

    /// "Mathematics 8 - MAT8 - 8D" → "Mathematics 8". Teams class names put the subject first.
    public static func shortClassName(_ name: String) -> String {
        let first = name.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? name.trimmingCharacters(in: .whitespaces) : first
    }

    /// Work items to assignments. `instructions` holds the teacher's HTML by assignment ID, when it was fetched.
    public static func assignments(from items: [WorkItem], classes: [String: String],
                                   instructions: [String: String] = [:]) -> [TeamsAssignment] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard isOwed(item), let due = item.due, seen.insert(item.id).inserted else { return nil }
            let name = Blackbaud.plainText(item.name)
            let title = name.isEmpty ? "Untitled assignment" : name
            let className = classes[item.classID].map(shortClassName).map(Blackbaud.plainText) ?? ""
            let html = withoutStyles(instructions[item.id] ?? item.instructionsHTML ?? "")
            return TeamsAssignment(
                id: item.id, classID: item.classID,
                title: className.isEmpty ? title : "\(className): \(title)",
                details: String(Blackbaud.plainText(html).prefix(2000)),
                dueDate: due, link: item.link)
        }
    }

    /// Teachers' pages carry a <style> block (and a <head>); its rules aren't text anyone wrote.
    static func withoutStyles(_ html: String) -> String {
        html.replacingOccurrences(of: "(?s)<(style|script|head)[^>]*>.*?</\\1>", with: "",
                                  options: [.regularExpression, .caseInsensitive])
    }

    // MARK: Sync

    /// Merges one check into the task list. The same rules as Blackbaud's feed:
    ///
    /// - New assignments due in the future become tasks. Past ones aren't owed here, so they're skipped.
    /// - An assignment that already has a task, or that you deleted, is never imported twice.
    /// - When the teacher changes one, the change goes through the same rule as your own edits:
    ///   anything while it isn't locked in, only an earlier deadline once it is. Never a deadline in the past.
    /// - Assignments that leave the list (turned in, or no longer assigned) stay as tasks: proof is still owed here.
    public static func sync(tasks: [TaxTask], state: TeamsState, assignments: [TeamsAssignment],
                            now: Date) -> TeamsSyncResult {
        var tasks = tasks
        var state = state
        var added: [TaxTask] = []
        var notes: [String] = []
        var owner: [String: Int] = [:]
        for (i, task) in tasks.enumerated() {
            if case let .teams(id) = task.source { owner[id] = i }
        }
        var seen = Set<String>()
        for item in assignments where seen.insert(item.id).inserted {
            if let i = owner[item.id] {
                let before = state.lastSeen[item.id]
                state.lastSeen[item.id] = item
                guard let before, !before.sameWork(as: item), tasks[i].isPending else { continue }

                let original = tasks[i]
                var edited = original
                if item.title != before.title { edited.title = item.title }
                if item.details != before.details { edited.details = item.details }
                if item.dueDate != before.dueDate && item.dueDate > now { edited.dueDate = item.dueDate }
                guard edited != original else {
                    if item.dueDate != before.dueDate {
                        notes.append("kept \"\(original.title)\" due \(original.dueDate): Teams moved it into the past")
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
                    notes.append("kept \"\(original.title)\" as is: it's locked in and Teams' change would loosen it")
                }
            } else if !state.dismissed.contains(item.id), item.dueDate > now {
                let task = TaxTask(title: item.title, details: item.details, dueDate: item.dueDate,
                                   createdAt: now, source: .teams(id: item.id))
                tasks.append(task)
                added.append(task)
                state.lastSeen[item.id] = item
            }
        }
        return TeamsSyncResult(tasks: tasks, state: state, added: added, notes: notes)
    }
}
