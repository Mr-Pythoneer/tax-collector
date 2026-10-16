import Foundation
import TaxCore

/// Testing aid, only with `TAXCOLLECTOR_BLACKBAUD_PROBE=1`: writes a read-only report of what Blackbaud's
/// endpoints return for the signed-in account, so the parsing can be checked against the real thing.
/// It records only the fields Tax Collector uses, never cookies or tokens, and changes nothing.
@MainActor
enum BlackbaudProbe {
    static func run(link: BlackbaudLink, tasks: [TaxTask], to url: URL) async {
        var report: [String: Any] = ["generated": ISO8601DateFormatter().string(from: Date())]
        do {
            let context = try await link.call("GET", BlackbaudAPI.contextPath)
            let userInfo = (context.json as? [String: Any])?["UserInfo"] as? [String: Any]
            report["context"] = ["status": context.status,
                                 "signedIn": BlackbaudAPI.isSignedIn(context.status, context.json),
                                 "userInfoKeys": userInfo.map { Array($0.keys).sorted() } ?? []] as [String: Any]

            report["center"] = shape(try await link.call("GET", BlackbaudAPI.centerPath))
            let now = Date()
            for filter in [0, 1, 2] {
                let path = BlackbaudAPI.dataDirectPath(from: now.addingTimeInterval(-30 * 86400),
                                                       to: now.addingTimeInterval(30 * 86400), filter: filter)
                report["dataDirect_filter\(filter)"] = shape(try await link.call("GET", path))
            }

            let csrf = try await link.call("GET", BlackbaudAPI.csrfPath)
            report["csrf"] = ["status": csrf.status, "length": csrf.body.count,
                              "jsonString": csrf.json is String, "looksLikeHTML": csrf.body.contains("<")] as [String: Any]

            // What the app would really use, and whether each imported task finds its assignment.
            let items = try await BlackbaudAPI.assignments(around: now, link: link)
            report["parsedCount"] = items.count
            report["parsedSample"] = items.prefix(6).map(describe)
            report["matches"] = tasks.compactMap { task -> [String: Any]? in
                guard case let .blackbaud(uid) = task.source else { return nil }
                let match = BlackbaudMatch.find(feedUID: uid, title: task.title, due: task.dueDate, in: items)
                return ["task": task.title, "due": task.dueDate.description,
                        "match": match.map(describe) ?? "NONE"] as [String: Any]
            }

            // One assignment's page, as the details window reads it. Counts only, not what it says.
            let matched = tasks.first { task in
                guard case let .blackbaud(uid) = task.source else { return false }
                return BlackbaudMatch.find(feedUID: uid, title: task.title, due: task.dueDate, in: items) != nil
            }
            if let task = matched {
                switch await BlackbaudAPI.details(for: task, link: link) {
                case let .success(page):
                    let host = link.host ?? ""
                    report["details"] = ["task": task.title, "type": page.type, "maxPoints": page.maxPoints ?? -1,
                                         "submitsOnline": page.submitsOnline, "instructionsLength": page.instructionsHTML.count,
                                         "attachments": page.attachments.count,
                                         "attachmentsOnSchoolSite": page.attachments.filter {
                                             AssignmentDetailsParser.isOnSchoolSite($0.url, host: host)
                                         }.count,
                                         "links": page.links.count] as [String: Any]
                case let .failure(problem):
                    report["details"] = ["task": task.title, "error": problem.message]
                }
            }
        } catch {
            report["error"] = "\(error)"
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func describe(_ item: BlackbaudListedAssignment) -> [String: Any] {
        ["indexID": item.indexID, "title": item.title, "course": item.course,
         "due": item.due?.description ?? "none", "status": item.status ?? -99]
    }

    private static func shape(_ r: BlackbaudLink.Response) -> [String: Any] {
        var out: [String: Any] = ["status": r.status, "bytes": r.body.count]
        if let rows = r.json as? [[String: Any]] {
            out["kind"] = "array"
            out["count"] = rows.count
            out["rowKeys"] = rows.first.map { Array($0.keys).sorted() } ?? []
            out["samples"] = rows.prefix(3).map(sample)
        } else if let dict = r.json as? [String: Any] {
            out["kind"] = "object"
            out["keys"] = dict.mapValues { value -> String in
                if let list = value as? [Any] { return "array[\(list.count)]" }
                return String(describing: type(of: value))
            }
            if let rows = dict.values.compactMap({ $0 as? [[String: Any]] }).first(where: { !$0.isEmpty }) {
                out["rowKeys"] = Array(rows[0].keys).sorted()
                out["samples"] = rows.prefix(3).map(sample)
            }
            if let error = dict["ErrorType"] as? String { out["errorType"] = error }
        } else {
            out["kind"] = "not json"
            out["head"] = String(r.body.prefix(80))
        }
        return out
    }

    /// Only the fields Tax Collector reads, so the report doesn't collect anything else.
    private static func sample(_ row: [String: Any]) -> [String: Any] {
        let wanted = ["AssignmentIndexId", "assignment_index_id", "AssignmentId", "assignment_id", "UserTaskId",
                      "ShortDescription", "short_description", "GroupName", "groupname",
                      "DateDue", "DueDate", "date_due", "StudentStatus", "AssignmentStatusType", "assignment_status"]
        var out: [String: Any] = [:]
        for key in wanted {
            guard let value = row[key], !(value is NSNull) else { continue }
            out[key] = (value as? String).map { String($0.prefix(60)) } ?? value
        }
        return out
    }
}
