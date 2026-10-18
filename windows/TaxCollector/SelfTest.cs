using System.Text;
using TaxCore;

namespace TaxCollector;

/// Headless self-test (TAXCOLLECTOR_SELFTEST=1), the Windows counterpart of the
/// Mac app's SelfTest. It drives the AppModel through its features with a fake
/// `claude` so it never touches a real account, and writes a PASS/FAIL report.
/// Use a throwaway TAXCOLLECTOR_DATA_DIR.
internal static class SelfTest
{
    public static int RunAndReport()
    {
        var dataDir = Environment.GetEnvironmentVariable("TAXCOLLECTOR_DATA_DIR");
        var temp = false;
        if (string.IsNullOrEmpty(dataDir))
        {
            dataDir = Path.Combine(Path.GetTempPath(), "tc-selftest-" + Guid.NewGuid());
            Environment.SetEnvironmentVariable("TAXCOLLECTOR_DATA_DIR", dataDir);
            temp = true;
        }
        var (report, failures) = Run(new Store(dataDir));
        try { File.WriteAllText(Path.Combine(dataDir, "selftest.txt"), report); } catch { }
        Console.WriteLine(report);
        if (temp) { try { Directory.Delete(dataDir, true); } catch { } }
        return failures == 0 ? 0 : 1;
    }

    private static (string, int) Run(Store store)
    {
        var lines = new List<string>();
        var failures = 0;
        void Check(string name, bool ok, string detail = "")
        {
            if (ok) lines.Add($"PASS  {name}");
            else { failures++; lines.Add($"FAIL  {name}{(detail.Length == 0 ? "" : ": " + detail)}"); }
        }
        bool Wait(Func<bool> done, double seconds = 20)
        {
            var deadline = DateTime.UtcNow.AddSeconds(seconds);
            while (!done() && DateTime.UtcNow < deadline) Thread.Sleep(150);
            return done();
        }

        var dir = store.Dir;
        var model = new AppModel(store, dryRun: true);
        TaxTask? Newest(string title) => model.Tasks.LastOrDefault(t => t.Title == title);

        // Guardian
        model.SetupGuardian("abcdef");
        Check("guardian: wrong code refused", model.CheckGuardian("nope-1") == GuardianCheck.Wrong);
        model.CheckGuardian("nope-2");
        Check("guardian: third wrong code starts a cooldown", model.CheckGuardian("nope-3") == GuardianCheck.CoolingDown);
        Check("guardian: even the right code waits out the cooldown", model.CheckGuardian("abcdef") == GuardianCheck.CoolingDown);
        model.Settings.GuardianFailures = 0; model.Settings.GuardianLockedUntil = null;
        Check("guardian: right code accepted", model.CheckGuardian("abcdef") == GuardianCheck.Ok);
        model.ChangeGuardianCode("ghijkl");
        Check("guardian: new code works", model.CheckGuardian("ghijkl") == GuardianCheck.Ok);
        Check("guardian: old code no longer works", model.CheckGuardian("abcdef") == GuardianCheck.Wrong);
        model.Settings.GuardianFailures = 0; model.Settings.GuardianLockedUntil = null;

        // Add / edit / delete
        model.AddTask("Far away", "", DateTimeOffset.Now.AddDays(3));
        if (Newest("Far away") is { } far)
        {
            var later = far.Clone(); later.DueDate = far.DueDate.AddDays(1);
            Check("edit: a task days away can be pushed back", model.SaveEdit(later) == EditResult.Saved);
            Check("delete: a task days away can be deleted", model.Delete(far.Id) == EditResult.Saved);
        }
        else Check("add: task saved", false);

        model.AddTask("Soon", "", DateTimeOffset.Now.AddHours(2));
        var si = model.Tasks.FindIndex(t => t.Title == "Soon");
        if (si >= 0)
        {
            Check("edit: a new task can be fixed during the grace", !model.IsFrozen(model.Tasks[si]));
            model.Tasks[si].CreatedAt = DateTimeOffset.Now.AddMinutes(-10);
            var soon = model.Tasks[si];
            var later = soon.Clone(); later.DueDate = soon.DueDate.AddHours(1);
            Check("edit: inside 24 hours, pushing it back needs the guardian", model.SaveEdit(later) == EditResult.NeedsGuardian);
            var earlier = soon.Clone(); earlier.DueDate = soon.DueDate.AddMinutes(-10);
            Check("edit: inside 24 hours, moving it earlier is fine", model.SaveEdit(earlier) == EditResult.Saved);
            Check("delete: inside 24 hours needs the guardian", model.Delete(soon.Id) == EditResult.NeedsGuardian);
            Check("delete: the guardian can delete it", model.Delete(soon.Id, guardianApproved: true) == EditResult.Saved);
        }

        // Warnings
        var warned = new List<Guid>();
        model.OnWarning = (t, _) => warned.Add(t.Id);
        model.AddTask("In four minutes", "", DateTimeOffset.Now.AddMinutes(4));
        model.Tick();
        Check("warning: fires inside the last 5 minutes", Newest("In four minutes") is { } w && warned.Contains(w.Id));
        model.OnWarning = (_, _) => { };
        if (Newest("In four minutes") is { } fm) model.Delete(fm.Id, guardianApproved: true);

        // Lock, unlock, excuse
        model.AddTask("Already late", "", DateTimeOffset.Now.AddSeconds(-60));
        model.Tick();
        Check("lock: an overdue task locks the PC", model.Lock.IsLocked);
        Check("lock: the enforcer is running", model.Enforcer.IsActive);
        model.Unlock(1);
        Check("guardian: unlock pauses the lock", !model.Lock.IsLocked && model.Settings.OverrideUntil != null);
        model.EndUnlock();
        Check("guardian: ending the unlock locks again", model.Lock.IsLocked);
        if (Newest("Already late") is { } late) model.Excuse(late.Id);
        model.Tick();
        Check("guardian: excusing the task unlocks", !model.Lock.IsLocked);
        Check("lock: the enforcer stops when unlocked", !model.Enforcer.IsActive);

        // Late proof and the penalty
        model.SetPenalty(1);
        model.AddTask("Late homework", "", DateTimeOffset.Now.AddSeconds(-120));
        if (Newest("Late homework") is { } lh)
        {
            model.ApproveLatestProof(lh.Id);
            model.Tick();
            Check("penalty: late proof is accepted as late", model.Task(lh.Id)?.Status is TaskStatus.ProvenLate);
            Check("penalty: the PC stays locked during the penalty", model.Lock.IsLocked && model.Lock.Overdue.Count == 0);
            model.Excuse(lh.Id);
            model.Tick();
            Check("penalty: excusing ends it", !model.Lock.IsLocked);
        }
        model.SetPenalty(30);

        // Clock guard
        model.Settings.LastSeen = DateTimeOffset.Now.AddHours(1);
        model.Tick();
        Check("clock: winding the clock back doesn't move time back", model.Now >= DateTimeOffset.Now.AddMinutes(50));
        model.ResetClockGuard();
        Check("clock: the guardian can reset it", Math.Abs((model.Now - DateTimeOffset.Now).TotalSeconds) < 5);

        // Proof checking with fake claude
        var proofFile = Path.Combine(dir, "selftest-proof.txt");
        File.WriteAllText(proofFile, "All ten problems done.");
        TaxTask? Submit(string title, string claude)
        {
            model.Settings.ClaudePath = claude;
            model.AddTask(title, "Problems 1-10", DateTimeOffset.Now.AddDays(1));
            if (Newest(title) is not { } t) return null;
            model.SubmitProof(t.Id, "done", new List<string> { proofFile });
            Wait(() => model.Task(t.Id)?.Proofs.LastOrDefault()?.Verdict != null);
            return model.Task(t.Id);
        }

        var accepted = Submit("Proof accepted", FakeClaude(dir, "claude-accept", """{"verdict":"accept","reason":"Shows all ten.","checklist":["Do 1-5","Do 6-10"]}"""));
        Check("proof: accepted proof marks the task done", accepted?.Status is TaskStatus.Proven, accepted?.Status?.ToString() ?? "null");
        Check("proof: the file was copied into the proof folder",
            accepted is { } a && a.Proofs.LastOrDefault() is { } p
            && File.Exists(Path.Combine(store.ProofFolder(a.Id, p.Id), "selftest-proof.txt")));
        Check("proof: Claude's checklist is kept", accepted?.Checklist?.Select(c => c.Text).SequenceEqual(new[] { "Do 1-5", "Do 6-10" }) == true);

        model.Settings.ClaudePath = FakeClaude(dir, "claude-written", """{"verdict":"accept","reason":"Specific.","checklist":["Play No. 41"]}""");
        model.AddTask("Written proof", "Playing test: No. 41", DateTimeOffset.Now.AddDays(1));
        if (Newest("Written proof") is { } wp)
        {
            model.SubmitProof(wp.Id, "Played No. 41 for the class this morning; lost the beat once in bar 12 and got 4/5.", new List<string>());
            Wait(() => model.Task(wp.Id)?.Proofs.LastOrDefault()?.Verdict != null);
            var afterW = model.Task(wp.Id);
            Check("proof: a written account with no files is accepted",
                afterW?.Proofs.LastOrDefault() is { Attachments.Count: 0, Verdict: Verdict.Accepted } && afterW?.IsPending == false);
        }

        var rejected = Submit("Proof rejected", FakeClaude(dir, "claude-reject", """{"verdict":"reject","reason":"Blank page."}"""));
        Check("proof: rejected proof leaves the task due", rejected?.IsPending == true && rejected?.Proofs.LastOrDefault()?.Verdict == Verdict.Rejected);

        var broken = Submit("Proof broken", Path.Combine(dir, "no-such-claude.cmd"));
        Check("proof: a missing Claude is reported, task stays due",
            broken?.IsPending == true && broken?.Proofs.LastOrDefault()?.Verdict == Verdict.Error,
            broken?.Proofs.LastOrDefault()?.Reason ?? "");

        // Cancel a check: the proof counts for nothing, the late answer is ignored
        var slowAccept = FakeClaude(dir, "claude-slow-accept", """{"verdict":"accept","reason":"Fine."}""", sleepSec: 3);
        model.Settings.ClaudePath = slowAccept;
        model.AddTask("Proof cancelled", "Problems 1-10", DateTimeOffset.Now.AddDays(1));
        if (Newest("Proof cancelled") is { } pc)
        {
            model.SubmitProof(pc.Id, "done", new List<string> { proofFile });
            var sid = model.Task(pc.Id)?.Proofs.LastOrDefault()?.Id;
            Check("cancel: the check is running", sid is { } s && model.Checking.Contains(s));
            if (sid is { } s2) model.CancelCheck(pc.Id, s2);
            Check("cancel: the proof is withdrawn and the task stays due",
                model.Task(pc.Id)?.Proofs.Count == 0 && model.Task(pc.Id)?.IsPending == true && model.Checking.Count == 0);
            Thread.Sleep(4500);
            Check("cancel: Claude's late answer doesn't pass it",
                model.Task(pc.Id)?.IsPending == true && model.Task(pc.Id)?.Proofs.Count == 0);
        }

        // Interrupted check comes back as an error on reload
        var hanging = new TaxTask("Interrupted", DateTimeOffset.Now.AddDays(1), DateTimeOffset.Now,
            proofs: new List<ProofSubmission> { new() { SubmittedAt = DateTimeOffset.Now } });
        model.Tasks.Add(hanging);
        store.SaveTasks(model.Tasks);
        var reopened = new AppModel(store, dryRun: true);
        Check("proof: an interrupted check comes back as an error",
            reopened.Task(hanging.Id)?.Proofs.LastOrDefault()?.Verdict == Verdict.Error);
        model.Delete(hanging.Id, guardianApproved: true);

        // More time
        var savedTasks = model.Tasks.ToList();
        model.Tasks = new();
        model.AddTask("Too soon", "", DateTimeOffset.Now.AddHours(2));
        if (Newest("Too soon") is { } ts)
        {
            Check("more time: refused without a track record", model.ExtensionWhyNot(ts)?.Contains("at least") == true);
            model.RequestExtension(ts.Id, 6, "I have a fever of 39 and the nurse sent me home.");
            Check("more time: a refused request isn't recorded", model.Task(ts.Id)?.Extensions == null);
        }
        for (var n = 1; n <= 5; n++)
        {
            model.AddTask($"Record {n}", "", DateTimeOffset.Now.AddHours(1));
            if (Newest($"Record {n}") is { } rt) model.ApproveLatestProof(rt.Id);
        }
        Check("more time: five on-time tasks make you eligible", model.TrackRecord.OnTime == 5 && model.TrackRecord.OnTimeRate == 1);

        model.Settings.ClaudePath = FakeClaude(dir, "claude-grant", """{"decision":"grant","hours":20,"reason":"Being sick is a real reason."}""");
        model.AddTask("Granted", "", DateTimeOffset.Now.AddHours(2));
        if (Newest("Granted") is { } gt)
        {
            var before = gt.DueDate;
            Check("more time: allowed with a good record", model.ExtensionWhyNot(gt) == null);
            model.RequestExtension(gt.Id, 6, "I have a fever of 39 and the nurse sent me home.");
            Wait(() => model.Task(gt.Id)?.Extensions?.LastOrDefault()?.Decision != null);
            var afterG = model.Task(gt.Id);
            Check("more time: granted, never more than asked",
                afterG?.Extensions?.LastOrDefault()?.HoursGranted == 6 && Math.Abs((afterG!.DueDate - before).TotalHours - 6) < 0.01);
            Check("more time: one request per task", model.ExtensionWhyNot(afterG!)?.Contains("already asked") == true);
        }

        model.Settings.ClaudePath = FakeClaude(dir, "claude-deny", """{"decision":"deny","hours":0,"reason":"That's putting it off."}""");
        model.AddTask("Denied", "", DateTimeOffset.Now.AddHours(2));
        if (Newest("Denied") is { } dt)
        {
            var before = dt.DueDate;
            model.RequestExtension(dt.Id, 4, "I was busy all evening and didn't get to it at all.");
            Wait(() => model.Task(dt.Id)?.Extensions?.LastOrDefault()?.Decision != null);
            Check("more time: a denied request leaves the deadline alone",
                model.Task(dt.Id)?.Extensions?.LastOrDefault()?.Decision == ExtensionDecision.Denied && model.Task(dt.Id)?.DueDate == before);
        }
        model.Tasks = savedTasks;
        store.SaveTasks(model.Tasks);
        model.Tick();

        // Allowlist
        model.AllowApp("code.exe");
        Check("allowlist: the guardian can add an app",
            Allowlist.IsAllowed(new AppIdentity("code.exe"), model.Settings.ExtraAllowedApps));
        model.DisallowApp("code.exe");
        Check("allowlist: and remove it",
            !Allowlist.IsAllowed(new AppIdentity("code.exe"), model.Settings.ExtraAllowedApps));

        // Repeats
        model.Settings.OverrideUntil = DateTimeOffset.Now.AddMinutes(10);
        var tomorrow = DateTimeOffset.Now.AddDays(1);
        model.AddRecurring("Repeat: homework", "Exercises", RepeatUnit.Weeks, 1,
            new[] { (int)tomorrow.DayOfWeek + 1 }, 8 * 60, tomorrow);
        var seriesId = model.Recurring.FirstOrDefault(s => s.Title == "Repeat: homework")?.Id;
        List<TaxTask> Copies() => model.Tasks.Where(t => t.SeriesId != null && t.SeriesId == seriesId).ToList();
        Check("repeat: the first copy is out", Copies().Count == 1);
        if (Copies().FirstOrDefault() is { } first)
        {
            var fi = model.Tasks.FindIndex(t => t.Id == first.Id);
            model.Tasks[fi].Status = new TaskStatus.Proven(model.Now);
            model.Tick();
            Check("repeat: paying early doesn't bring the next one forward", Copies().Count == 1);
            model.Settings.LastSeen = first.DueDate.AddMinutes(1);
            model.Tick();
            Check("repeat: after the deadline, next week's copy appears", Copies().Count == 2);
            if (seriesId is { } sidv) model.StopRepeating(sidv);
            model.Tick();
            Check("repeat: stopping keeps the copies already out",
                model.Recurring.Count == 0 && model.Store.LoadRecurring().Count == 0 && Copies().Count == 2);
        }
        foreach (var t in Copies()) model.Delete(t.Id, guardianApproved: true);
        model.ResetClockGuard();
        model.Settings.OverrideUntil = null;
        model.Tick();

        // Storage
        var saved = store.LoadTasks();
        Check("storage: tasks on disk match the app", saved.Select(t => t.Id).ToHashSet().SetEquals(model.Tasks.Select(t => t.Id)));

        lines.Add("");
        lines.Add(failures == 0 ? $"All {lines.Count - 1} self-test checks passed." : $"{failures} failed.");
        return (string.Join("\n", lines), failures);
    }

    /// Writes a fake `claude` as a .cmd that prints a canned result envelope,
    /// optionally after a short sleep (to exercise cancellation).
    private static string FakeClaude(string dir, string name, string inner, int sleepSec = 0)
    {
        var jsonPath = Path.Combine(dir, name + ".json");
        var envelope = "{\"type\":\"result\",\"is_error\":false,\"result\":\"" + inner.Replace("\"", "\\\"") + "\"}";
        File.WriteAllText(jsonPath, envelope);
        var cmdPath = Path.Combine(dir, name + ".cmd");
        var sb = new StringBuilder();
        sb.AppendLine("@echo off");
        if (sleepSec > 0) sb.AppendLine($"ping -n {sleepSec + 1} 127.0.0.1 >nul");
        sb.AppendLine($"type \"{jsonPath}\"");
        File.WriteAllText(cmdPath, sb.ToString());
        return cmdPath;
    }
}
