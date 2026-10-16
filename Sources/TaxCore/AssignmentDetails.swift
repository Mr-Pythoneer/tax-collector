import Foundation

/// What an assignment's page in Blackbaud shows: the full instructions and the teacher's files and links.
public struct AssignmentDetails: Equatable, Sendable {
    public struct Attachment: Equatable, Sendable, Identifiable {
        public var id: String { url.absoluteString }
        public var title: String
        public var fileName: String
        public var url: URL
    }

    public struct Link: Equatable, Sendable, Identifiable {
        public var id: String { url.absoluteString }
        public var title: String
        public var url: URL
    }

    public var indexID: Int
    /// The teacher's instructions, as HTML.
    public var instructionsHTML: String
    /// For example "Homework (Minor)".
    public var type: String
    public var maxPoints: Double?
    /// Handed in through Blackbaud's own drop box.
    public var submitsOnline: Bool
    public var attachments: [Attachment]
    public var links: [Link]
    /// The assignment's own page in Blackbaud, to open in the browser.
    public var pageURL: URL
}

public enum AssignmentDetailsParser {
    /// Reads `UserAssignmentDetailsGetAllStudentData`. `host` is the school's site, for relative file links.
    public static func parse(_ json: Any?, indexID: Int, host: String) -> AssignmentDetails? {
        guard let row = json as? [String: Any],
              let page = URL(string: "https://\(host)/lms-assignment/assignment/assignment-student-view/\(indexID)")
        else { return nil }
        let files: [AssignmentDetails.Attachment] = (row["DownloadItems"] as? [[String: Any]] ?? []).compactMap { item in
            guard let url = absolute(string(item["DownloadUrl"]), host: host) else { return nil }
            let fileName = string(item["FriendlyFileName"]).isEmpty ? string(item["FileName"]) : string(item["FriendlyFileName"])
            let title = string(item["ShortDescription"]).isEmpty ? fileName : string(item["ShortDescription"])
            return AssignmentDetails.Attachment(title: Blackbaud.plainText(title), fileName: fileName.isEmpty ? url.lastPathComponent : fileName,
                                                url: url)
        }
        let links: [AssignmentDetails.Link] = (row["LinkItems"] as? [[String: Any]] ?? []).compactMap { item in
            guard let url = absolute(string(item["Url"]), host: host) else { return nil }
            let title = string(item["ShortDescription"])
            return AssignmentDetails.Link(title: title.isEmpty ? (url.host ?? url.absoluteString) : Blackbaud.plainText(title), url: url)
        }
        return AssignmentDetails(
            indexID: indexID,
            instructionsHTML: string(row["LongDescription"]),
            type: string(row["AssignmentType"]),
            maxPoints: (row["MaxPoints"] as? NSNumber)?.doubleValue,
            submitsOnline: (row["DropboxInd"] as? Bool) ?? false,
            attachments: files,
            links: links,
            pageURL: page)
    }

    /// Blackbaud gives some file links as paths on the school's site ("/ftpimages/…"). Web links without a
    /// scheme ("www.example.com") get https.
    public static func absolute(_ raw: String, host: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" { return url }
        if s.hasPrefix("//") { return URL(string: "https:" + s) }
        if s.hasPrefix("/") { return URL(string: "https://\(host)" + s) }
        if s.contains("."), !s.contains(" "), let url = URL(string: "https://" + s), url.host != nil { return url }
        return nil
    }

    /// Files on the school's own site can be fetched with your Blackbaud sign-in; anything else opens in the browser.
    public static func isOnSchoolSite(_ url: URL, host: String) -> Bool {
        url.host?.lowercased() == host.lowercased()
    }

    private static func string(_ v: Any?) -> String { v as? String ?? "" }
}
