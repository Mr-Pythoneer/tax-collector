import Foundation
import TaxCore

/// Testing aid, only with `TAXCOLLECTOR_BLACKBAUD_PROBE=1`: writes a read-only report of what Blackbaud's
/// endpoints return for the signed-in account, so the parsing can be checked against the real thing.
/// It records only the fields Tax Collector uses, never cookies or tokens, and changes nothing.
@MainActor
enum BlackbaudProbe {
    static func run(link: BlackbaudLink, tasks: [TaxTask], blackbaudDue: (TaxTask) -> Date, to url: URL) async {
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
                let match = BlackbaudMatch.find(feedUID: uid, title: task.title, due: blackbaudDue(task), in: items)
                return ["task": task.title, "due": task.dueDate.description, "blackbaudDue": blackbaudDue(task).description,
                        "match": match.map(describe) ?? "NONE"] as [String: Any]
            }

            // Each assignment's page, as the details window reads it. Counts only, not what it says.
            // One teacher's file is downloaded to see that it really comes down with the sign-in.
            let host = link.host ?? ""
            var pages: [[String: Any]] = []
            var downloadTried = false
            for task in tasks.prefix(15) {
                guard case let .blackbaud(uid) = task.source,
                      BlackbaudMatch.find(feedUID: uid, title: task.title, due: blackbaudDue(task), in: items) != nil else { continue }
                switch await BlackbaudAPI.details(for: task, due: blackbaudDue(task), link: link) {
                case let .success(page):
                    var details: [String: Any] = [
                        "task": task.title, "type": page.type, "maxPoints": page.maxPoints ?? -1,
                        "submitsOnline": page.submitsOnline, "instructionsLength": page.instructionsHTML.count,
                        "attachments": page.attachments.count,
                        "attachmentsOnSchoolSite": page.attachments.filter {
                            AssignmentDetailsParser.isOnSchoolSite($0.url, host: host)
                        }.count,
                        "attachmentHosts": Array(Set(page.attachments.compactMap(\.url.host))).sorted(),
                        "links": page.links.count,
                        "linkHosts": Array(Set(page.links.compactMap(\.url.host))).sorted()]
                    if !downloadTried, let file = page.attachments.first {
                        downloadTried = true
                        switch await BlackbaudAPI.download(file.url, link: link) {
                        case let .success(data): details["download"] = ["bytes": data.count, "kind": kind(of: data)] as [String: Any]
                        case let .failure(problem): details["download"] = ["error": problem.message]
                        }
                    }
                    pages.append(details)
                case let .failure(problem):
                    pages.append(["task": task.title, "error": problem.message])
                }
            }
            report["details"] = pages
        } catch {
            report["error"] = "\(error)"
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// What a downloaded file looks like from its first bytes. A web page here usually means a sign-in page.
    private static func kind(of data: Data) -> String {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: Array("%PDF".utf8)) { return "pdf" }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip (Office file)" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8]) { return "jpeg" }
        if let text = String(data: data.prefix(200), encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { return "html (not a file)" }
        return "other"
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
