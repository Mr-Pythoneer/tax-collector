import AppKit

enum SetupError: LocalizedError {
    case launchctl(String)
    case move(String)

    var errorDescription: String? {
        switch self {
        case let .launchctl(output): "macOS wouldn't start Tax Collector in the background: \(output)"
        case let .move(reason): "Couldn't copy Tax Collector into Applications: \(reason)"
        }
    }
}

/// Runs Tax Collector in the background and at every login, set up from inside the app.
/// It writes the same per-user LaunchAgent that scripts/install.sh writes, pointing at this copy of the app.
enum BackgroundAgent {
    /// `TAXCOLLECTOR_LABEL` gives a test copy its own agent, so testing never touches a real install.
    static var label: String {
        let test = ProcessInfo.processInfo.environment["TAXCOLLECTOR_LABEL"] ?? ""
        return test.isEmpty ? AppModel.label : test
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var executablePath: String { Bundle.main.executablePath ?? "" }

    /// Set up, and starting this copy of the app (not an older one somewhere else).
    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return false }
        return arguments.first == executablePath
    }

    /// The background copy starts the app from exactly where it is, so it has to live in an Applications folder,
    /// not in Downloads or on the disk image.
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let test = ProcessInfo.processInfo.environment["TAXCOLLECTOR_TEST_APPLICATIONS_DIR"], !test.isEmpty {
            return path.hasPrefix(URL(fileURLWithPath: test).resolvingSymlinksInPath().path + "/")
                || path.hasPrefix(test + "/")
        }
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    static func install() throws {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TaxCollector.log").path
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "--launchd"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 2,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        // A test copy keeps its own data, name and limits in the background too.
        let carried = ["TAXCOLLECTOR_DATA_DIR", "TAXCOLLECTOR_LABEL", "TAXCOLLECTOR_ENFORCE_ONLY", "TAXCOLLECTOR_DRY_RUN",
                       "TAXCOLLECTOR_TEST_SETUP", "TAXCOLLECTOR_TEST_APPLICATIONS_DIR"]
        let environment = ProcessInfo.processInfo.environment.filter { carried.contains($0.key) && !$0.value.isEmpty }
        if !environment.isEmpty { plist["EnvironmentVariables"] = environment }

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)

        let domain = "gui/\(getuid())"
        launchctl(["bootout", "\(domain)/\(label)"])
        let (status, output) = launchctl(["bootstrap", domain, plistURL.path])
        if status != 0 { throw SetupError.launchctl(output.isEmpty ? "error \(status)" : output) }
    }

    /// Stops the background copy and removes it from login. This ends the current process too when it's the
    /// background copy, so do everything else first.
    static func remove() {
        try? FileManager.default.removeItem(at: plistURL)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Copies the app into Applications when it was opened straight from the disk image or Downloads.
enum AppMover {
    static func copyToApplications() throws -> URL {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        var targets = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        // Testing aid: copy somewhere else instead of the real Applications folder.
        if let test = ProcessInfo.processInfo.environment["TAXCOLLECTOR_TEST_APPLICATIONS_DIR"], !test.isEmpty {
            targets = [URL(fileURLWithPath: test)]
        }
        var lastError = "no Applications folder could be written to"
        for folder in targets {
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source, to: destination)
                // You already chose to open it, so don't make macOS ask again about the copy.
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
                try? xattr.run()
                xattr.waitUntilExit()
                return destination
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw SetupError.move(lastError)
    }
}
