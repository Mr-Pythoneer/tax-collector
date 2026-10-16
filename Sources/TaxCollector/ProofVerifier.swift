import Foundation
import TaxCore

/// Asks the local Claude Code CLI to judge a proof submission.
enum ProofVerifier {
    struct Outcome {
        var verdict: Verdict
        var reason: String
        var checklist: [String] = []
    }

    static let timeout: TimeInterval = 180

    /// Where the `claude` tool is. Homebrew, the official installer and npm each put it somewhere else,
    /// so when the setting is still the default, look in the usual places.
    static func claudePath(_ settings: Settings) -> String? {
        let home = NSHomeDirectory()
        var candidates = [settings.claudePath]
        if settings.claudePath == Settings().claudePath {
            candidates += ["/usr/local/bin/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                           "\(home)/.npm-global/bin/claude", "/opt/homebrew/bin/claude"]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func verify(task: TaxTask, submission: ProofSubmission, folder: URL, settings: Settings,
                       tokenFile: URL) async -> Outcome {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(task: task, submission: submission, folder: folder,
                                           settings: settings, tokenFile: tokenFile))
            }
        }
    }

    /// `claude auth status`, so the app can say whether the auditor will work before you need it.
    static func authStatus(settings: Settings, tokenFile: URL) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                guard let path = claudePath(settings) else {
                    cont.resume(returning: "Not installed")
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = ["auth", "status"]
                p.environment = environment(tokenFile: tokenFile)
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: "Couldn't run Claude: \(error.localizedDescription)")
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let loggedIn = obj["loggedIn"] as? Bool {
                    cont.resume(returning: loggedIn ? "Ready" : "Not logged in")
                } else {
                    cont.resume(returning: String(decoding: data.prefix(200), as: UTF8.self))
                }
            }
        }
    }

    private static func run(task: TaxTask, submission: ProofSubmission, folder: URL, settings: Settings,
                            tokenFile: URL) -> Outcome {
        // Read only sees what we name, so give it full paths.
        let files = submission.attachments.map { folder.appendingPathComponent($0).path }
        let prompt = Auditor.prompt(task: task, note: submission.note, files: files, now: submission.submittedAt)
        switch runClaude(prompt: prompt, rules: Auditor.systemRules, tools: "Read", folder: folder,
                         settings: settings, tokenFile: tokenFile) {
        case let .failure(problem):
            return Outcome(verdict: .error, reason: problem.message)
        case let .success(data):
            let parsed = Auditor.parse(cliOutput: data)
            return Outcome(verdict: parsed.verdict, reason: parsed.reason, checklist: parsed.checklist)
        }
    }

    struct Problem: Error {
        let message: String
    }

    /// Asks Claude whether you get more time. Returns its decision, hours and explanation.
    static func decideExtension(task: TaxTask, hours: Int, reason: String, record: TrackRecord, folder: URL,
                                settings: Settings, tokenFile: URL) async -> (ExtensionDecision, Int, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let prompt = Auditor.extensionPrompt(task: task, hours: hours, reason: reason, record: record, now: Date())
                switch runClaude(prompt: prompt, rules: Auditor.extensionRules, tools: "", folder: folder,
                                 settings: settings, tokenFile: tokenFile) {
                case let .failure(problem): cont.resume(returning: (.error, 0, problem.message))
                case let .success(data):
                    let answer = Auditor.parseExtension(cliOutput: data)
                    cont.resume(returning: (answer.decision, answer.hours, answer.reason))
                }
            }
        }
    }

    /// One run of `claude -p` in `folder`, with its answer saved there as auditor.json.
    private static func runClaude(prompt: String, rules: String, tools: String, folder: URL, settings: Settings,
                                  tokenFile: URL) -> Result<Data, Problem> {
        guard let path = claudePath(settings) else {
            return .failure(Problem(message: "The Claude command-line tool isn't installed on this Mac."))
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--tools", tools,
            "--model", settings.claudeModel,
            "--no-session-persistence",
            "--strict-mcp-config",
            "--setting-sources", "local",
            "--disable-slash-commands",
            "--append-system-prompt", rules,
        ]
        p.currentDirectoryURL = folder
        p.environment = environment(tokenFile: tokenFile)
        let out = Pipe()
        p.standardOutput = out
        let errURL = folder.appendingPathComponent("auditor-stderr.log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: errURL)) ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            return .failure(Problem(message: "Couldn't start the Claude CLI: \(error.localizedDescription)"))
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        try? data.write(to: folder.appendingPathComponent("auditor.json"))

        if p.terminationReason == .uncaughtSignal {
            return .failure(Problem(message: "Claude took longer than \(Int(timeout)) seconds, so it was stopped."))
        }
        return .success(data)
    }

    /// launchd gives a bare environment, and Claude Code variables from a parent session would confuse the CLI.
    private static func environment(tokenFile: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("CLAUDE_CODE") && key != "CLAUDECODE" && !key.hasPrefix("ANTHROPIC_")
        }
        env["HOME"] = NSHomeDirectory()
        env["USER"] = NSUserName()
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        if let token = try? String(contentsOf: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
        }
        return env
    }
}
