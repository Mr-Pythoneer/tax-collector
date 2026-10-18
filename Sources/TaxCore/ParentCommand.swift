import CryptoKit
import Foundation

/// One command from a parent's phone, after it passed the gate (docs/parent-link-v1.md §5.1, §7).
public struct ParentCommand: Equatable, Sendable {
    public var channel: String
    public var device: String
    /// The phone's counter, `n`.
    public var counter: Int64
    /// When the phone made it, in ms.
    public var issuedAt: Int64
    public var id: String
    public var type: String
    /// nil when this app doesn't know the type: answered "unsupported".
    public var action: ParentAction?
}

public enum ParentAction: Equatable, Sendable {
    case lock(until: Date?, strength: LockStrength, note: String?)
    case free(until: Date)
    case normal
    case addTask(id: UUID, title: String, details: String, due: Date)
    case editTask(id: UUID, title: String?, details: String?, due: Date?)
    case deleteTask(UUID)
    case excuseTask(UUID)
    case approveProof(taskID: UUID, proofID: UUID)
    case addRepeat(RecurringTask)
    case stopRepeat(UUID)
    case allowApp(AppRef)
    case disallowApp(AppRef)
    case blockApp(AppRef)
    case unblockApp(AppRef)
    case setPenalty(Int)
    case setExtensions(Bool)
    case message(String)
    case removeDevice(String)
    case allowGuardianSetup(until: Date)

    /// The setting a command writes, for "the latest issued wins". nil for one-off actions.
    public var setting: String? {
        switch self {
        case .lock, .free, .normal: return "access"
        case let .allowApp(app), let .disallowApp(app), let .blockApp(app), let .unblockApp(app): return "app:" + app.id
        case .setPenalty: return "penalty"
        case .setExtensions: return "extensions"
        default: return nil
        }
    }
}

public enum CommandRejection: String, Error, Sendable {
    case badBox = "bad_box"
    case badSignature = "bad_signature"
    case wrongTarget = "wrong_target"
    case replayed
    case stale
    case badArgs = "bad_args"
    case unknownDevice = "unknown_device"
}

public enum CommandGate {
    /// How far the phone's clock and the server's receive time may disagree.
    public static let freshness: Int64 = 10 * 60 * 1000

    /// Opens the box, checks the signature over the exact bytes, then the target, the counter and freshness.
    /// Nothing is applied here.
    public static func admit(box: Data, linkKey: SymmetricKey, signKey: Data, channel: String, device: String,
                             receivedAt: Int64, lastCounter: Int64,
                             calendar: Calendar = .current) -> Result<ParentCommand, CommandRejection> {
        guard let opened = try? LinkCrypto.open(box, key: linkKey, aad: LinkCrypto.commandAAD(channel: channel, device: device)),
              opened.count > 64 else { return .failure(.badBox) }
        let signature = Data(opened.prefix(64)), body = Data(opened.dropFirst(64))
        guard LinkCrypto.isValidSignature(signature, of: body, by: signKey) else { return .failure(.badSignature) }
        guard let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              int(fields["v"]) == 1, let ch = fields["ch"] as? String, let dev = fields["dev"] as? String,
              let n = int(fields["n"]), let at = int(fields["at"]), let id = fields["id"] as? String,
              let type = fields["type"] as? String else { return .failure(.badArgs) }
        guard ch == channel, dev == device else { return .failure(.wrongTarget) }
        guard n > lastCounter else { return .failure(.replayed) }
        guard abs(receivedAt - at) <= freshness else { return .failure(.stale) }
        var command = ParentCommand(channel: ch, device: dev, counter: n, issuedAt: at, id: id, type: type, action: nil)
        guard known.contains(type) else { return .success(command) }
        guard let action = parse(type: type, args: fields["args"] as? [String: Any] ?? [:], calendar: calendar) else {
            return .failure(.badArgs)
        }
        command.action = action
        return .success(command)
    }

    public static let known: Set<String> = [
        "lock", "free", "normal", "addTask", "editTask", "deleteTask", "excuseTask", "approveProof",
        "addRepeat", "stopRepeat", "allowApp", "disallowApp", "blockApp", "unblockApp",
        "setPenalty", "setExtensions", "message", "removeDevice", "allowGuardianSetup",
    ]

    /// The arguments of a known type, checked. nil if they're wrong.
    public static func parse(type: String, args: [String: Any], calendar: Calendar = .current) -> ParentAction? {
        switch type {
        case "lock":
            guard let strength = (args["strength"] as? String).flatMap(LockStrength.init(rawValue:)) else { return nil }
            let until: Date?
            if args["until"] == nil || args["until"] is NSNull { until = nil } else {
                guard let ms = int(args["until"]) else { return nil }
                until = date(ms)
            }
            let note = args["note"] as? String
            guard (note?.count ?? 0) <= 300 else { return nil }
            return .lock(until: until, strength: strength, note: note)
        case "free":
            guard let ms = int(args["until"]) else { return nil }
            return .free(until: date(ms))
        case "normal":
            return .normal
        case "addTask":
            guard let task = args["task"] as? [String: Any], let id = uuid(task["id"]), let title = text(task["title"], max: 200),
                  !title.isEmpty, let due = int(task["due"]) else { return nil }
            return .addTask(id: id, title: title, details: text(task["details"], max: 2000) ?? "", due: date(due))
        case "editTask":
            guard let id = uuid(args["id"]) else { return nil }
            let title = text(args["title"], max: 200)
            if args["title"] != nil, title?.isEmpty ?? true { return nil }
            if args["details"] != nil, text(args["details"], max: 2000) == nil { return nil }
            if args["due"] != nil, int(args["due"]) == nil { return nil }
            return .editTask(id: id, title: title, details: text(args["details"], max: 2000), due: int(args["due"]).map(date))
        case "deleteTask":
            return uuid(args["id"]).map(ParentAction.deleteTask)
        case "excuseTask":
            return uuid(args["id"]).map(ParentAction.excuseTask)
        case "approveProof":
            guard let task = uuid(args["taskId"]), let proof = uuid(args["proofId"]) else { return nil }
            return .approveProof(taskID: task, proofID: proof)
        case "addRepeat":
            guard let r = args["repeat"] as? [String: Any], let id = uuid(r["id"]), let title = text(r["title"], max: 200),
                  !title.isEmpty, let unit = (r["unit"] as? String).flatMap(RepeatUnit.init(rawValue:)),
                  let interval = int(r["interval"]), interval >= 1,
                  interval <= (unit == .days ? RecurringTask.maxDays : RecurringTask.maxWeeks),
                  let minute = int(r["minuteOfDay"]), (0..<1440).contains(minute),
                  let start = day(r["startDate"], calendar: calendar) else { return nil }
            let weekdays = Set((r["weekdays"] as? [Any] ?? []).compactMap(int).map(Int.init))
            guard weekdays.allSatisfy({ (1...7).contains($0) }), unit == .days || !weekdays.isEmpty else { return nil }
            return .addRepeat(RecurringTask(id: id, title: title, details: text(r["details"], max: 2000) ?? "", unit: unit,
                                            interval: Int(interval), weekdays: unit == .weeks ? weekdays : [],
                                            minuteOfDay: Int(minute), startDate: start, createdAt: start))
        case "stopRepeat":
            return uuid(args["id"]).map(ParentAction.stopRepeat)
        case "allowApp", "disallowApp", "blockApp", "unblockApp":
            guard let a = args["app"] as? [String: Any], let id = text(a["id"], max: 300), !id.isEmpty else { return nil }
            let app = AppRef(id: id, name: text(a["name"], max: 100) ?? id)
            switch type {
            case "allowApp": return .allowApp(app)
            case "disallowApp": return .disallowApp(app)
            case "blockApp": return .blockApp(app)
            default: return .unblockApp(app)
            }
        case "setPenalty":
            guard let minutes = int(args["minutes"]), (0...720).contains(minutes) else { return nil }
            return .setPenalty(Int(minutes))
        case "setExtensions":
            guard let enabled = bool(args["enabled"]) else { return nil }
            return .setExtensions(enabled)
        case "message":
            guard let t = text(args["text"], max: 300), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .message(t)
        case "allowGuardianSetup":
            guard let ms = int(args["until"]) else { return nil }
            return .allowGuardianSetup(until: date(ms))
        case "removeDevice":
            guard let id = args["id"] as? String, !id.isEmpty else { return nil }
            return .removeDevice(id)
        default:
            return nil
        }
    }

    // MARK: Reading JSON strictly

    private static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func int(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 9.0e15 else { return nil }
        return n.int64Value
    }

    private static func bool(_ v: Any?) -> Bool? { isBool(v) ? (v as? NSNumber)?.boolValue : nil }

    private static func text(_ v: Any?, max: Int) -> String? {
        guard let s = v as? String, s.count <= max else { return nil }
        return s
    }

    private static func uuid(_ v: Any?) -> UUID? { (v as? String).flatMap(UUID.init(uuidString:)) }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// "YYYY-MM-DD", as the start of that day in the computer's time zone.
    private static func day(_ v: Any?, calendar: Calendar) -> Date? {
        guard let s = v as? String else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, s.count == 10 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
