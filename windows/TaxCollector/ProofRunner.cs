using System.Diagnostics;
using System.Text;
using TaxCore;

namespace TaxCollector;

/// Asks the local Claude Code CLI to judge a proof or an extension request.
/// The prompt always goes in through stdin, never as a command-line argument.
internal static class ProofRunner
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(180);

    public readonly record struct Outcome(Verdict Verdict, string Reason, List<string> Checklist);

    private static readonly object RunningLock = new();
    private static readonly Dictionary<Guid, Process> Running = new();

    /// Stops the check of that submission, if it's still running. Its answer is ignored either way.
    public static void Cancel(Guid submissionId)
    {
        Process? p;
        lock (RunningLock) { Running.Remove(submissionId, out p); }
        try { if (p is { HasExited: false }) p.Kill(entireProcessTree: true); } catch { }
    }

    /// Where the `claude` tool is. A path set in settings is used on its own; with
    /// none set, look in %USERPROFILE%\.local\bin\claude.exe, then
    /// %APPDATA%\npm\claude.cmd, then `where claude`.
    public static string? ClaudePath(Settings settings)
    {
        if (!string.IsNullOrEmpty(settings.ClaudePath))
            return File.Exists(settings.ClaudePath) ? settings.ClaudePath : null;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var local = Path.Combine(home, ".local", "bin", "claude.exe");
        if (File.Exists(local)) return local;
        var npm = Path.Combine(appData, "npm", "claude.cmd");
        if (File.Exists(npm)) return npm;
        return WhereClaude();
    }

    private static string? WhereClaude()
    {
        try
        {
            var psi = new ProcessStartInfo("where.exe", "claude")
            {
                RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
            };
            using var p = Process.Start(psi);
            if (p == null) return null;
            var outp = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            var first = outp.Split('\n', '\r').FirstOrDefault(s => s.Trim().Length > 0)?.Trim();
            return first is { Length: > 0 } && File.Exists(first) ? first : null;
        }
        catch { return null; }
    }

    public static async Task<Outcome> Verify(TaxTask task, ProofSubmission submission, string folder, Settings settings, string tokenFile)
    {
        var files = submission.Attachments.Select(a => Path.Combine(folder, a)).ToList();
        var prompt = Auditor.Prompt(task, submission.Note, files, submission.SubmittedAt);
        var result = await RunClaude(prompt, Auditor.SystemRules, "Read", folder, settings, tokenFile, submission.Id);
        if (result.Problem is { } why) return new Outcome(Verdict.Error, why, new());
        var parsed = Auditor.Parse(result.Output!);
        return new Outcome(parsed.Verdict, parsed.Reason, parsed.Checklist);
    }

    public static async Task<(ExtensionDecision Decision, int Hours, string Reason)> DecideExtension(
        TaxTask task, int hours, string reason, TrackRecord record, string folder, Settings settings, string tokenFile)
    {
        var prompt = Auditor.ExtensionPrompt(task, hours, reason, record, DateTimeOffset.Now);
        var result = await RunClaude(prompt, Auditor.ExtensionRules, "", folder, settings, tokenFile, null);
        if (result.Problem is { } why) return (ExtensionDecision.Error, 0, why);
        return Auditor.ParseExtension(result.Output!);
    }

    public static async Task<string> AuthStatus(Settings settings, string tokenFile)
    {
        var path = ClaudePath(settings);
        if (path == null) return "Not installed";
        try
        {
            var psi = NewStartInfo(path, tokenFile);
            psi.ArgumentList.Add("auth");
            psi.ArgumentList.Add("status");
            WrapBatchShim(psi);
            using var p = Process.Start(psi)!;
            p.StandardInput.Close();
            var outp = await p.StandardOutput.ReadToEndAsync();
            await p.WaitForExitAsync();
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(outp);
                if (doc.RootElement.TryGetProperty("loggedIn", out var li))
                    return li.ValueKind == System.Text.Json.JsonValueKind.True ? "Ready" : "Not logged in";
            }
            catch { }
            return outp.Length > 200 ? outp[..200] : outp;
        }
        catch (Exception ex) { return $"Couldn't run Claude: {ex.Message}"; }
    }

    private readonly record struct RunResult(byte[]? Output, string? Problem);

    private static async Task<RunResult> RunClaude(string prompt, string rules, string tools, string folder,
                                                   Settings settings, string tokenFile, Guid? id)
    {
        var path = ClaudePath(settings);
        if (path == null) return new RunResult(null, "The Claude command-line tool isn't installed on this PC.");
        Directory.CreateDirectory(folder);

        var psi = NewStartInfo(path, tokenFile);
        psi.WorkingDirectory = folder;
        foreach (var a in new[] { "-p", "--output-format", "json", "--tools", tools, "--model", settings.ClaudeModel,
                                  "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "local",
                                  "--disable-slash-commands", "--append-system-prompt", rules })
            psi.ArgumentList.Add(a);
        WrapBatchShim(psi);

        Process p;
        try { p = Process.Start(psi)!; }
        catch (Exception ex) { return new RunResult(null, $"Couldn't start the Claude CLI: {ex.Message}"); }

        if (id is { } sid) { lock (RunningLock) Running[sid] = p; }
        try
        {
            // The prompt goes in through stdin, then stdin is closed.
            await p.StandardInput.WriteAsync(prompt);
            p.StandardInput.Close();

            using var ms = new MemoryStream();
            var copy = p.StandardOutput.BaseStream.CopyToAsync(ms);
            var errTask = p.StandardError.ReadToEndAsync();
            using var cts = new CancellationTokenSource(Timeout);
            bool timedOut = false;
            try { await p.WaitForExitAsync(cts.Token); }
            catch (OperationCanceledException) { timedOut = true; try { p.Kill(entireProcessTree: true); } catch { } }

            await copy;
            var err = await errTask;
            try { await File.WriteAllTextAsync(Path.Combine(folder, "auditor-stderr.log"), err); } catch { }
            var data = ms.ToArray();
            try { await File.WriteAllBytesAsync(Path.Combine(folder, "auditor.json"), data); } catch { }

            if (timedOut)
                return new RunResult(null, $"Claude took longer than {(int)Timeout.TotalSeconds} seconds, so it was stopped.");
            return new RunResult(data, null);
        }
        finally
        {
            if (id is { } sid2) { lock (RunningLock) Running.Remove(sid2); }
            p.Dispose();
        }
    }

    /// A .cmd/.bat shim (like npm's claude.cmd) can't be started directly with
    /// UseShellExecute=false, so run it through cmd.exe /c, keeping the arguments.
    private static void WrapBatchShim(ProcessStartInfo psi)
    {
        var ext = Path.GetExtension(psi.FileName);
        if (!ext.Equals(".cmd", StringComparison.OrdinalIgnoreCase) && !ext.Equals(".bat", StringComparison.OrdinalIgnoreCase))
            return;
        var shim = psi.FileName;
        var args = psi.ArgumentList.ToList();
        psi.FileName = Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe";
        psi.ArgumentList.Clear();
        psi.ArgumentList.Add("/c");
        psi.ArgumentList.Add(shim);
        foreach (var a in args) psi.ArgumentList.Add(a);
    }

    /// launchd-style clean environment: drop the parent session's Claude Code
    /// variables so they don't confuse the CLI, and add the saved token if any.
    private static ProcessStartInfo NewStartInfo(string path, string tokenFile)
    {
        var psi = new ProcessStartInfo(path)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
        };
        foreach (var key in psi.Environment.Keys.ToList())
            if (key.StartsWith("CLAUDE_CODE", StringComparison.OrdinalIgnoreCase)
                || key.Equals("CLAUDECODE", StringComparison.OrdinalIgnoreCase)
                || key.StartsWith("ANTHROPIC_", StringComparison.OrdinalIgnoreCase))
                psi.Environment.Remove(key);
        psi.Environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1";
        try
        {
            if (File.Exists(tokenFile))
            {
                var token = File.ReadAllText(tokenFile).Trim();
                if (token.Length > 0) psi.Environment["CLAUDE_CODE_OAUTH_TOKEN"] = token;
            }
        }
        catch { }
        return psi;
    }
}
