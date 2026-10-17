import Foundation

/// Plain JSON files in one folder. `TAXCOLLECTOR_DATA_DIR` points it elsewhere for testing.
public final class Store {
    public let dir: URL

    public init(dir: URL? = nil) {
        if let dir {
            self.dir = dir
        } else if let env = ProcessInfo.processInfo.environment["TAXCOLLECTOR_DATA_DIR"], !env.isEmpty {
            self.dir = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TaxCollector", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    private var tasksURL: URL { dir.appendingPathComponent("tasks.json") }
    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    private var guardianURL: URL { dir.appendingPathComponent("guardian.json") }
    private var blackbaudURL: URL { dir.appendingPathComponent("blackbaud.json") }
    private var recurringURL: URL { dir.appendingPathComponent("recurring.json") }
    public var logURL: URL { dir.appendingPathComponent("events.log") }
    public var proofsRoot: URL { dir.appendingPathComponent("proofs", isDirectory: true) }

    public func loadTasks() -> [TaxTask] { load([TaxTask].self, from: tasksURL) ?? [] }
    public func saveTasks(_ tasks: [TaxTask]) { save(tasks, to: tasksURL) }

    public func loadSettings() -> Settings { load(Settings.self, from: settingsURL) ?? Settings() }
    public func saveSettings(_ settings: Settings) { save(settings, to: settingsURL) }

    public func loadGuardian() -> GuardianRecord? { load(GuardianRecord.self, from: guardianURL) }
    public func saveGuardian(_ record: GuardianRecord) { save(record, to: guardianURL) }

    public func loadBlackbaud() -> BlackbaudState { load(BlackbaudState.self, from: blackbaudURL) ?? BlackbaudState() }
    public func saveBlackbaud(_ state: BlackbaudState) { save(state, to: blackbaudURL) }

    public func loadRecurring() -> [RecurringTask] { load([RecurringTask].self, from: recurringURL) ?? [] }
    public func saveRecurring(_ series: [RecurringTask]) { save(series, to: recurringURL) }

    public func proofFolder(task: UUID, submission: UUID) -> URL {
        let url = proofsRoot
            .appendingPathComponent(task.uuidString, isDirectory: true)
            .appendingPathComponent(submission.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func log(_ message: String, at date: Date = Date()) {
        let line = "\(Self.stamp.string(from: date))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    public func recentLog(lines: Int = 200) -> [String] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(lines).map(String.init).reversed())
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            // Keep the unreadable file instead of silently overwriting it next save.
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: url, to: backup)
            log("could not read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
