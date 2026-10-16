import Foundation

/// A time from an iCal file: a whole day, or an exact moment.
public enum ICalTime: Equatable, Sendable {
    /// `VALUE=DATE`, a day with no time. Most school assignments look like this.
    case allDay(year: Int, month: Int, day: Int)
    case moment(Date)
}

public struct ICalEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case event = "VEVENT"
        case todo = "VTODO"
    }

    public var kind: Kind
    public var uid: String
    public var summary: String
    public var description: String
    public var start: ICalTime?
    public var end: ICalTime?
    public var due: ICalTime?
    /// Upper-cased, e.g. "CANCELLED". Empty when the feed doesn't say.
    public var status: String
    public var categories: [String]

    public init(kind: Kind = .event, uid: String, summary: String = "", description: String = "",
                start: ICalTime? = nil, end: ICalTime? = nil, due: ICalTime? = nil,
                status: String = "", categories: [String] = []) {
        self.kind = kind
        self.uid = uid
        self.summary = summary
        self.description = description
        self.start = start
        self.end = end
        self.due = due
        self.status = status
        self.categories = categories
    }
}

/// Just enough of RFC 5545 to read a school's calendar feed. No dependencies.
public enum ICal {
    /// A feed that answers with a sign-in page instead of a calendar should fail loudly, not import nothing.
    public static func looksLikeCalendar(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).uppercased()
        return head.contains("BEGIN:VCALENDAR")
    }

    public static func parse(_ text: String, defaultTimeZone: TimeZone = .current) -> [ICalEvent] {
        parse(Data(text.utf8), defaultTimeZone: defaultTimeZone)
    }

    /// Every VEVENT and VTODO in the file. Properties of nested parts (like a VALARM's DESCRIPTION) are skipped.
    public static func parse(_ data: Data, defaultTimeZone: TimeZone = .current) -> [ICalEvent] {
        let lines = logicalLines(data).compactMap(contentLine)
        // Times with no zone are read in the calendar's own zone when it names one.
        var zone = defaultTimeZone
        if let x = lines.first(where: { $0.name == "X-WR-TIMEZONE" }), let tz = timeZone(named: x.value) {
            zone = tz
        }

        var events: [ICalEvent] = []
        var stack: [String] = []
        var props: [ContentLine] = []
        for line in lines {
            switch line.name {
            case "BEGIN":
                let name = line.value.trimmingCharacters(in: .whitespaces).uppercased()
                stack.append(name)
                if ICalEvent.Kind(rawValue: name) != nil { props = [] }
            case "END":
                let name = line.value.trimmingCharacters(in: .whitespaces).uppercased()
                // Tolerate a missing END somewhere inside by closing back to the matching BEGIN.
                guard let i = stack.lastIndex(of: name) else { continue }
                stack.removeSubrange(i...)
                if let kind = ICalEvent.Kind(rawValue: name) {
                    events.append(makeEvent(kind: kind, props: props, zone: zone))
                }
            default:
                if let top = stack.last, ICalEvent.Kind(rawValue: top) != nil { props.append(line) }
            }
        }
        return events
    }

    // MARK: Lines

    struct ContentLine: Equatable {
        var name: String
        var params: [String: String]
        var value: String
    }

    /// Splits the file into logical lines, joining folded ones (a line break followed by a space or tab).
    /// Works on bytes so a UTF-8 character split across a fold comes back whole.
    static func logicalLines(_ data: Data) -> [String] {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var lines: [String] = []
        var current: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b == 0x0D || b == 0x0A else {
                current.append(b)
                i += 1
                continue
            }
            var next = i + 1
            if b == 0x0D, next < bytes.count, bytes[next] == 0x0A { next += 1 }
            if next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 {
                i = next + 1
                continue
            }
            if !current.isEmpty { lines.append(String(decoding: current, as: UTF8.self)) }
            current = []
            i = next
        }
        if !current.isEmpty { lines.append(String(decoding: current, as: UTF8.self)) }
        return lines
    }

    /// `NAME;PARAM=VALUE;PARAM="a:b":value`. Colons and semicolons inside quotes don't count.
    static func contentLine(_ line: String) -> ContentLine? {
        var segments: [Substring] = []
        var segmentStart = line.startIndex
        var valueStart: String.Index?
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" {
                inQuotes.toggle()
            } else if !inQuotes && (c == ";" || c == ":") {
                segments.append(line[segmentStart..<i])
                segmentStart = line.index(after: i)
                if c == ":" {
                    valueStart = segmentStart
                    break
                }
            }
            i = line.index(after: i)
        }
        guard let valueStart, let name = segments.first, !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var value = String(segment[segment.index(after: eq)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            params[segment[..<eq].uppercased()] = value
        }
        return ContentLine(name: name.uppercased(), params: params, value: String(line[valueStart...]))
    }

    /// TEXT escapes: `\n` `\N` `\,` `\;` `\\`.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var it = text.makeIterator()
        while let c = it.next() {
            guard c == "\\" else {
                out.append(c)
                continue
            }
            guard let n = it.next() else {
                out.append(c)
                break
            }
            out.append(n == "n" || n == "N" ? "\n" : n)
        }
        return out
    }

    /// Splits a list value on commas that aren't escaped.
    static func splitList(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for c in value {
            if escaped {
                current.append("\\")
                current.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts.map { unescape($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Events

    private static func makeEvent(kind: ICalEvent.Kind, props: [ContentLine], zone: TimeZone) -> ICalEvent {
        func first(_ name: String) -> ContentLine? { props.first { $0.name == name } }
        func text(_ name: String) -> String {
            first(name).map { unescape($0.value).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        func when(_ name: String) -> ICalTime? {
            first(name).flatMap { time($0.value, params: $0.params, zone: zone) }
        }

        let summary = text("SUMMARY")
        var uid = text("UID")
        if uid.isEmpty {
            // UID is required, but a feed without one should still dedupe between polls.
            uid = "nouid:\(summary)|\(first("DTSTART")?.value ?? "")|\(first("DUE")?.value ?? "")"
        }
        return ICalEvent(
            kind: kind,
            uid: uid,
            summary: summary,
            description: text("DESCRIPTION"),
            start: when("DTSTART"),
            end: when("DTEND"),
            due: when("DUE"),
            status: text("STATUS").uppercased(),
            categories: props.filter { $0.name == "CATEGORIES" }.flatMap { splitList($0.value) })
    }

    // MARK: Times

    private static let utc = TimeZone(identifier: "UTC")!

    /// `20261016` (all day), `20261016T153000Z` (UTC), `20261016T153000` with or without a TZID.
    static func time(_ raw: String, params: [String: String], zone: TimeZone) -> ICalTime? {
        let value = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        let chars = Array(value)
        func number(_ from: Int, _ to: Int) -> Int? {
            guard to <= chars.count else { return nil }
            let s = String(chars[from..<to])
            return s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) ? Int(s) : nil
        }
        guard let year = number(0, 4), let month = number(4, 6), let day = number(6, 8),
              (1...12).contains(month), (1...31).contains(day) else { return nil }

        if chars.count == 8 || params["VALUE"]?.uppercased() == "DATE" {
            return .allDay(year: year, month: month, day: day)
        }
        guard chars.count >= 13, chars[8] == "T", let hour = number(9, 11), let minute = number(11, 13),
              hour < 24, minute < 60 else { return nil }
        let second = number(13, 15) ?? 0

        var calendar = Calendar(identifier: .gregorian)
        if chars.last == "Z" {
            calendar.timeZone = utc
        } else {
            calendar.timeZone = params["TZID"].flatMap(timeZone(named:)) ?? zone
        }
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: parts).map(ICalTime.moment)
    }

    /// IANA names, Windows names (Blackbaud runs on .NET), and prefixed ids like `/mozilla.org/20050126_1/America/New_York`.
    static func timeZone(named raw: String) -> TimeZone? {
        let name = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        guard !name.isEmpty else { return nil }
        if let tz = TimeZone(identifier: name) { return tz }
        if let mapped = windowsZones[name], let tz = TimeZone(identifier: mapped) { return tz }
        let parts = name.split(separator: "/")
        if parts.count > 1 {
            for start in 1..<parts.count {
                if let tz = TimeZone(identifier: parts[start...].joined(separator: "/")) { return tz }
            }
        }
        return nil
    }

    private static let windowsZones: [String: String] = [
        "Eastern Standard Time": "America/New_York",
        "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver",
        "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles",
        "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Atlantic Standard Time": "America/Halifax",
        "Newfoundland Standard Time": "America/St_Johns",
        "GMT Standard Time": "Europe/London",
        "W. Europe Standard Time": "Europe/Berlin",
        "Romance Standard Time": "Europe/Paris",
        "China Standard Time": "Asia/Shanghai",
        "Singapore Standard Time": "Asia/Singapore",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "UTC": "UTC",
    ]
}
