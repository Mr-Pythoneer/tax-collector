import CryptoKit
import Foundation

/// Other tools on this Mac hand Tax Collector a task by dropping one small JSON file into the inbox folder
/// (`<data dir>/inbox`). Tax Collector turns each valid file into an ordinary manual task and deletes the file.
/// A file that can't be used moves to `inbox/rejected` instead of being retried forever.
///
///     {"v":1, "id":"class-capture:20261021-170201-dfd1:1", "title":"Do problems 1-10 on page 42",
///      "details":"From Chemistry, 2026-10-21 …", "due":"2026-10-28T17:02:00Z", "from":"Class Capture"}
///
/// `id` is the sender's own stable name for the item: sending it again never adds a second task.
public struct InboxItem: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var title: String
    public var details: String?
    public var due: Date
    public var from: String?

    public init(v: Int = 1, id: String, title: String, details: String? = nil, due: Date, from: String? = nil) {
        self.v = v; self.id = id; self.title = title; self.details = details; self.due = due; self.from = from
    }
}

public enum Inbox {
    /// A scan reads at most this many files, so a flood of files can't swamp the list in one go.
    public static let maxFilesPerScan = 20
    public static let maxFileBytes = 20_000
    public static let maxTitleLength = 200
    /// Due dates further out than this are refused: a typo shouldn't plant a task for next year.
    public static let maxHorizon: TimeInterval = 120 * 24 * 3600

    public enum Rejection: String, Error, Equatable, Sendable {
        case tooLarge, malformed, unsupportedVersion, emptyID, emptyTitle, titleTooLong, dueInPast, dueTooFar
    }

    public static func parse(_ data: Data, now: Date) -> Result<InboxItem, Rejection> {
        if data.count > maxFileBytes { return .failure(.tooLarge) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "not an ISO 8601 date"))
        }
        guard var item = try? decoder.decode(InboxItem.self, from: data) else { return .failure(.malformed) }
        guard item.v == 1 else { return .failure(.unsupportedVersion) }
        item.id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.details = item.details?.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.id.isEmpty { return .failure(.emptyID) }
        if item.title.isEmpty { return .failure(.emptyTitle) }
        if item.title.count > maxTitleLength { return .failure(.titleTooLong) }
        if item.due <= now { return .failure(.dueInPast) }
        if item.due.timeIntervalSince(now) > maxHorizon { return .failure(.dueTooFar) }
        return .success(item)
    }

    /// The same inbox id always gives the same task ID, so a re-sent item is recognised (and skipped) by the model.
    public static func taskID(for inboxID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("taxcollector-inbox:" + inboxID).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50      // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public struct Entry: Sendable {
        public var url: URL
        public var result: Result<InboxItem, Rejection>
    }

    /// Reads up to `maxFilesPerScan` `.json` files, oldest first. Files are not touched; call `settle` after handling each.
    public static func scan(dir: URL, now: Date) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        let files = names.filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
        return files.prefix(maxFilesPerScan).map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > maxFileBytes { return Entry(url: url, result: .failure(.tooLarge)) }
            guard let data = try? Data(contentsOf: url) else { return Entry(url: url, result: .failure(.malformed)) }
            return Entry(url: url, result: parse(data, now: now))
        }
    }

    /// Accepted files are deleted (the event log keeps the record); refused ones move to `rejected/` named with the reason.
    public static func settle(_ entry: Entry, in dir: URL) {
        let fm = FileManager.default
        switch entry.result {
        case .success:
            try? fm.removeItem(at: entry.url)
        case .failure(let reason):
            let rejected = dir.appendingPathComponent("rejected", isDirectory: true)
            try? fm.createDirectory(at: rejected, withIntermediateDirectories: true)
            let target = rejected.appendingPathComponent("\(reason.rawValue)-\(entry.url.lastPathComponent)")
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: entry.url, to: target)
        }
    }
}
