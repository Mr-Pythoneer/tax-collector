import Foundation
import TaxCore

/// The few Blackbaud (myschoolapp) web endpoints Tax Collector uses. They're the ones the student
/// website itself calls. Blackbaud doesn't publish them, so they all live here in case they change.
enum BlackbaudAPI {
    static let contextPath = "/api/webapp/context"
    static let csrfPath = "/api/security/csrftoken"
    /// The current Assignment Center's list: buckets like DueToday, DueThisWeek, PastLastWeek.
    static let centerPath = "/api/assignment2/StudentAssignmentCenterGet?displayByDueDate=true"
    static let statusPath = "/api/assignment2/assignmentstatusupdate"
    /// Blackbaud's codes: -1 to do, 0 in progress, 1 completed.
    static let completedStatus = 1

    static func isSignedIn(_ status: Int, _ json: Any?) -> Bool {
        guard status == 200, let dict = json as? [String: Any],
              let user = dict["UserInfo"] as? [String: Any] else { return false }
        return (int(user["UserId"]) ?? 0) > 0
    }

    /// The older list, as a fallback. `filter` 0 is everything in the date range.
    static func dataDirectPath(from start: Date, to end: Date, filter: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yyyy"
        let a = f.string(from: start).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let b = f.string(from: end).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "/api/DataDirect/AssignmentCenterAssignments/?format=json&filter=\(filter)&dateStart=\(a)&dateEnd=\(b)&persona=2&statusList=&sectionList="
    }

    /// Reads either list. The current one nests rows in buckets with PascalCase names;
    /// the older one is a flat array with snake_case names.
    static func parseList(_ json: Any?) -> [BlackbaudListedAssignment] {
        var rows: [[String: Any]] = []
        if let flat = json as? [[String: Any]] {
            rows = flat
        } else if let buckets = json as? [String: Any] {
            for value in buckets.values {
                if let bucket = value as? [[String: Any]] { rows += bucket }
            }
        }
        var seen = Set<Int>()
        return rows.compactMap { row in
            // Tasks you made yourself in Blackbaud have no assignment behind them.
            guard let index = int(row["AssignmentIndexId"] ?? row["assignment_index_id"]), index > 0,
                  seen.insert(index).inserted else { return nil }
            let title = Blackbaud.plainText(string(row["ShortDescription"] ?? row["short_description"]))
            let due = date(string(row["DateDue"] ?? row["DueDate"] ?? row["date_due"]))
            return BlackbaudListedAssignment(
                indexID: index,
                assignmentID: int(row["AssignmentId"] ?? row["assignment_id"]),
                title: title,
                course: string(row["GroupName"] ?? row["groupname"]),
                due: due,
                // What you set yourself. AssignmentStatusType flips to done on its own, so it's not used.
                status: int(row["StudentStatus"] ?? row["assignment_status"]))
        }
    }

    static func date(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["M/d/yyyy h:mm a", "M/d/yyyy h:mm:ss a", "M/d/yyyy H:mm:ss", "M/d/yyyy",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func string(_ v: Any?) -> String { v as? String ?? "" }

    // MARK: Marking Completed

    /// Everything Blackbaud lists for you around this task's due date: the current list first,
    /// then the older one if the current one is refused or empty.
    @MainActor
    static func assignments(around due: Date, link: BlackbaudLink) async throws -> [BlackbaudListedAssignment] {
        let center = try await link.call("GET", centerPath)
        let fromCenter = center.status == 200 ? parseList(center.json) : []
        if !fromCenter.isEmpty { return fromCenter }
        let window: TimeInterval = 21 * 86400
        for filter in [0, 2] {
            let r = try await link.call("GET", dataDirectPath(from: due.addingTimeInterval(-window),
                                                              to: due.addingTimeInterval(window), filter: filter))
            let items = r.status == 200 ? parseList(r.json) : []
            if !items.isEmpty { return items }
        }
        return []
    }

    /// Sets one assignment's status the way the student site does, then reads it back.
    /// Returns nil on success, or why it failed.
    @MainActor
    static func setStatus(_ indexID: Int, to status: Int, around due: Date, link: BlackbaudLink) async throws -> String? {
        // Some schools want the page's security token on changes. Send it when Blackbaud gives one.
        var headers: [String: String] = [:]
        if let csrf = try? await link.call("GET", csrfPath), csrf.status == 200 {
            let token = (csrf.json as? String ?? csrf.body)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
            if !token.isEmpty, !token.contains("<"), !token.contains("\n") { headers["RequestVerificationToken"] = token }
        }
        let r = try await link.call("POST", statusPath, json: ["assignmentIndexId": indexID, "assignmentStatus": status],
                                    headers: headers)
        guard (200..<300).contains(r.status) else { return "Blackbaud refused the change (HTTP \(r.status))." }

        // Don't take the POST's word for it: read the status back.
        let after = try await assignments(around: due, link: link).first { $0.indexID == indexID }
        if let now = after?.status, now != status {
            return "Blackbaud accepted the request but still shows a different status."
        }
        return nil
    }

    /// Finds the assignment behind `task` and marks it Completed. Returns nil on success, or why it failed.
    @MainActor
    static func markCompleted(_ task: TaxTask, link: BlackbaudLink) async -> String? {
        guard case let .blackbaud(uid) = task.source else { return "This task didn't come from Blackbaud." }
        guard link.host != nil else { return "Turn on Blackbaud import first, so Tax Collector knows your school's address." }
        do {
            let context = try await link.call("GET", contextPath)
            guard isSignedIn(context.status, context.json) else { return "You're signed out of Blackbaud." }

            let items = try await assignments(around: task.dueDate, link: link)
            guard !items.isEmpty else { return "Blackbaud didn't list any of your assignments." }
            guard let match = BlackbaudMatch.find(feedUID: uid, title: task.title, due: task.dueDate, in: items) else {
                return "Couldn't find “\(task.title)” in Blackbaud's assignment list."
            }
            if match.status == completedStatus { return nil }

            return try await setStatus(match.indexID, to: completedStatus, around: task.dueDate, link: link)
        } catch {
            return "Couldn't reach Blackbaud: \(error)"
        }
    }
}
