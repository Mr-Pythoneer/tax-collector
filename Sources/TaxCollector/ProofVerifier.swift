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
                guard FileManager.default.isExecutableFile(atPath: settings.claudePath) else {
                    cont.resume(returning: "Claude CLI not found at \(settings.claudePath)")
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: settings.claudePath)
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
        guard FileManager.default.isExecutableFile(atPath: settings.claudePath) else {
            return Outcome(verdict: .error, reason: "Couldn't find the Claude CLI at \(settings.claudePath).")
        }
        // Read only sees what we name, so give it absolute paths.
        let files = submission.attachments.map { folder.appendingPathComponent($0).path }
        let prompt = Auditor.prompt(task: task, note: submission.note, files: files, now: submission.submittedAt)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.claudePath)
        p.arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--tools", "Read",
            "--model", settings.claudeModel,
            "--no-session-persistence",
            "--strict-mcp-config",
            "--setting-sources", "local",
            "--disable-slash-commands",
            "--append-system-prompt", Auditor.systemRules,
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
            return Outcome(verdict: .error, reason: "Couldn't start the Claude CLI: \(error.localizedDescription)")
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        try? data.write(to: folder.appendingPathComponent("auditor.json"))

        if p.terminationReason == .uncaughtSignal {
            return Outcome(verdict: .error, reason: "Claude took longer than \(Int(timeout)) seconds, so the check was stopped.")
        }
        let parsed = Auditor.parse(cliOutput: data)
        return Outcome(verdict: parsed.verdict, reason: parsed.reason, checklist: parsed.checklist)
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
