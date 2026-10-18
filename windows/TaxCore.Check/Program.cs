// Runs the TaxCore checks: the Windows counterpart of `swift run taxcore-check`.
// Plain console app so it runs on the Mac. `dotnet run --project windows/TaxCore.Check`.
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using TaxCore;
using TaskStatus = TaxCore.TaskStatus;

var runner = new Runner();
Checks.Register(runner);
return runner.Run();

sealed class Runner
{
    public int Failures;
    public string Current = "";
    public readonly List<(string Name, Action Body)> List = new();

    public void Add(string name, Action body) => List.Add((name, body));

    public void Expect(bool condition, [CallerLineNumber] int line = 0)
    {
        if (!condition) { Failures++; Console.WriteLine($"  FAIL {Current} (line {line})"); }
    }

    public int Run()
    {
        foreach (var (name, body) in List)
        {
            Current = name;
            try { body(); }
            catch (Exception ex) { Failures++; Console.WriteLine($"  THREW {name}: {ex.Message}"); }
        }
        Console.WriteLine(Failures == 0
            ? $"All {List.Count} checks passed."
            : $"{Failures} failure(s) in {List.Count} checks.");
        return Failures == 0 ? 0 : 1;
    }
}

static class Checks
{
    static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
    static TimeSpan Hours(double h) => TimeSpan.FromHours(h);

    static TaxTask Task(TimeSpan due, TimeSpan? created = null, TaskStatus? status = null, List<ProofSubmission>? proofs = null)
        => new("Essay", T0 + due, T0 + (created ?? -Hours(72)), status: status, proofs: proofs);

    static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);
    static byte[] Env(string inner)
        => Utf8($$"""{"type":"result","is_error":false,"result":"{{inner.Replace("\"", "\\\"")}}"}""");

    public static void Register(Runner r)
    {
        void C(string name, Action body) => r.Add(name, body);

        // MARK: Lock rules
        C("Lock.nothingDueMeansUnlocked", () =>
            r.Expect(!LockPolicy.State(new[] { Task(Hours(2)) }, null, T0).IsLocked));
        C("Lock.overduePendingLocks", () =>
        {
            var s = LockPolicy.State(new[] { Task(-TimeSpan.FromSeconds(60)) }, null, T0);
            r.Expect(s.IsLocked); r.Expect(s.Overdue.Count == 1);
        });
        C("Lock.dueExactlyNowLocks", () =>
            r.Expect(LockPolicy.State(new[] { Task(TimeSpan.Zero) }, null, T0).IsLocked));
        C("Lock.checkInFlightHoldsOffBriefly", () =>
        {
            var t = Task(-TimeSpan.FromSeconds(60));
            t.Proofs = new() { new ProofSubmission { SubmittedAt = T0 - TimeSpan.FromSeconds(120) } };
            r.Expect(!LockPolicy.IsOverdue(t, T0));
            r.Expect(LockPolicy.IsOverdue(t, t.DueDate + LockPolicy.CheckGrace + TimeSpan.FromSeconds(1)));
            t.Proofs = new() { new ProofSubmission { SubmittedAt = T0 - TimeSpan.FromSeconds(30) } };
            r.Expect(LockPolicy.IsOverdue(t, T0));
        });
        C("Lock.recheckAfterDeadlineDoesNotLift", () =>
        {
            var t = Task(-TimeSpan.FromSeconds(60));
            t.Proofs = new() { new ProofSubmission { SubmittedAt = T0 - TimeSpan.FromSeconds(120), RecheckedAt = T0 - TimeSpan.FromSeconds(30) } };
            r.Expect(LockPolicy.IsOverdue(t, T0));
            t.Proofs[0].RecheckedAt = T0 - TimeSpan.FromSeconds(90);
            r.Expect(!LockPolicy.IsOverdue(t, T0));
            // The field survives a round trip, and files without it still load.
            var json = Json.Encode(t.Proofs[0]);
            r.Expect(Json.Decode<ProofSubmission>(json)!.RecheckedAt != null);
            var old = """{"id":"4D1C8B0E-7F4A-4C11-9E2B-1A2B3C4D5E6F","submittedAt":"2027-01-15T08:00:00+00:00","note":"","attachments":[],"reason":""}""";
            r.Expect(Json.Decode<ProofSubmission>(old)!.RecheckedAt == null);
        });
        C("Lock.provenAndExcusedDoNotLock", () =>
        {
            var tasks = new[]
            {
                Task(-TimeSpan.FromSeconds(60), status: new TaskStatus.Proven(T0 - TimeSpan.FromSeconds(120))),
                Task(-TimeSpan.FromSeconds(60), status: new TaskStatus.Excused(T0)),
            };
            r.Expect(!LockPolicy.State(tasks, null, T0).IsLocked);
        });
        C("Lock.penaltyLocksUntilItEnds", () =>
        {
            var late = Task(-Hours(1), status: new TaskStatus.ProvenLate(T0 - TimeSpan.FromSeconds(60), T0 + TimeSpan.FromSeconds(600)));
            var during = LockPolicy.State(new[] { late }, null, T0);
            r.Expect(during.IsLocked);
            r.Expect(during.PenaltyEndsAt == T0 + TimeSpan.FromSeconds(600));
            r.Expect(!LockPolicy.State(new[] { late }, null, T0 + TimeSpan.FromSeconds(601)).IsLocked);
        });
        C("Lock.guardianOverrideUnlocksUntilItExpires", () =>
        {
            var tasks = new[] { Task(-TimeSpan.FromSeconds(60)) };
            var ov = T0 + Hours(1);
            r.Expect(!LockPolicy.State(tasks, ov, T0).IsLocked);
            r.Expect(LockPolicy.State(tasks, ov, ov).IsLocked);
        });
        C("Lock.proofBeforeDueHoldsWhileChecking", () =>
        {
            var inFlight = new ProofSubmission { SubmittedAt = T0 - TimeSpan.FromSeconds(120), Attachments = new() { "a.png" } };
            r.Expect(!LockPolicy.State(new[] { Task(-TimeSpan.FromSeconds(60), proofs: new() { inFlight }) }, null, T0).IsLocked);
            var lateInFlight = new ProofSubmission { SubmittedAt = T0 - TimeSpan.FromSeconds(10), Attachments = new() { "a.png" } };
            r.Expect(LockPolicy.State(new[] { Task(-TimeSpan.FromSeconds(60), proofs: new() { lateInFlight }) }, null, T0).IsLocked);
        });
        C("Lock.acceptingOnTimeVersusLate", () =>
        {
            var t = Task(TimeSpan.Zero);
            r.Expect(LockPolicy.StatusAfterAccepting(t, T0 - TimeSpan.FromSeconds(5), T0 + TimeSpan.FromSeconds(30), 30)
                == new TaskStatus.Proven(T0 - TimeSpan.FromSeconds(5)));
            var late = LockPolicy.StatusAfterAccepting(t, T0 + TimeSpan.FromSeconds(60), T0 + TimeSpan.FromSeconds(90), 30);
            r.Expect(late == new TaskStatus.ProvenLate(T0 + TimeSpan.FromSeconds(60), T0 + TimeSpan.FromSeconds(90 + 1800)));
        });

        // MARK: Edit window
        C("Edit.farAwayTaskIsEditable", () =>
        {
            var t = Task(Hours(48));
            r.Expect(!LockPolicy.IsFrozen(t, T0));
            var later = t.Clone(); later.DueDate = t.DueDate + Hours(24);
            r.Expect(LockPolicy.CanEditWithoutGuardian(t, later, T0));
            r.Expect(LockPolicy.CanDeleteWithoutGuardian(t, T0));
        });
        C("Edit.inside24HoursIsFrozen", () =>
        {
            var t = Task(Hours(23));
            r.Expect(LockPolicy.IsFrozen(t, T0));
            var pushed = t.Clone(); pushed.DueDate = t.DueDate + TimeSpan.FromSeconds(60);
            r.Expect(!LockPolicy.CanEditWithoutGuardian(t, pushed, T0));
            var renamed = t.Clone(); renamed.Title = "Nothing";
            r.Expect(!LockPolicy.CanEditWithoutGuardian(t, renamed, T0));
            r.Expect(!LockPolicy.CanDeleteWithoutGuardian(t, T0));
        });
        C("Edit.movingEarlierIsAlwaysAllowed", () =>
        {
            var t = Task(Hours(3));
            var sooner = t.Clone(); sooner.DueDate = t.DueDate - Hours(1);
            r.Expect(LockPolicy.CanEditWithoutGuardian(t, sooner, T0));
        });
        C("Edit.freshTaskHasTypoGrace", () =>
        {
            var t = Task(Hours(1), created: -TimeSpan.FromSeconds(60));
            r.Expect(!LockPolicy.IsFrozen(t, T0));
            r.Expect(LockPolicy.IsFrozen(t, T0 + LockPolicy.CreationGrace));
        });
        C("Edit.finishedTasksCanBeDeleted", () =>
            r.Expect(LockPolicy.CanDeleteWithoutGuardian(Task(Hours(1), status: new TaskStatus.Proven(T0)), T0)));
        C("Edit.taskInPenaltyIsFrozen", () =>
        {
            var t = Task(-Hours(1), status: new TaskStatus.ProvenLate(T0, T0 + TimeSpan.FromSeconds(600)));
            r.Expect(!LockPolicy.CanDeleteWithoutGuardian(t, T0));
        });

        // MARK: Clock and guardian
        C("Clock.cannotGoBackwards", () =>
        {
            var seen = T0 + Hours(5);
            r.Expect(LockPolicy.EffectiveNow(T0, seen) == seen);
            r.Expect(LockPolicy.EffectiveNow(T0, null) == T0);
            r.Expect(LockPolicy.EffectiveNow(seen + TimeSpan.FromSeconds(1), seen) == seen + TimeSpan.FromSeconds(1));
        });
        C("Guardian.codeVerifies", () =>
        {
            var record = Guardian.MakeRecord("correct-horse", iterations: 1000);
            r.Expect(Guardian.Verify("correct-horse", record));
            r.Expect(!Guardian.Verify("correct-hors", record));
            r.Expect(!Guardian.Verify("", record));
            r.Expect(record.Hash.Length == 32);
        });
        C("Guardian.saltDiffersEachTime", () =>
        {
            var a = Guardian.MakeRecord("123456", iterations: 1000);
            var b = Guardian.MakeRecord("123456", iterations: 1000);
            r.Expect(!a.Salt.SequenceEqual(b.Salt));
            r.Expect(!a.Hash.SequenceEqual(b.Hash));
        });
        C("Guardian.wrongCodesBackOff", () =>
        {
            r.Expect(LockPolicy.GuardianCooldown(2) == TimeSpan.Zero);
            r.Expect(LockPolicy.GuardianCooldown(3) == TimeSpan.FromSeconds(30));
            r.Expect(LockPolicy.GuardianCooldown(4) == TimeSpan.FromSeconds(60));
            r.Expect(LockPolicy.GuardianCooldown(20) == TimeSpan.FromSeconds(3600));
        });
        C("Guardian.matchesMacScheme", () =>
        {
            // Same salt + iterations must give the same key as the Mac's PBKDF2-SHA256.
            var salt = Convert.FromHexString("000102030405060708090a0b0c0d0e0f");
            var key = Guardian.Derive("hunter2", salt, 1000);
            r.Expect(key.Length == 32);
            // Stable across runs (regression guard on the KDF parameters).
            r.Expect(Guardian.Derive("hunter2", salt, 1000).SequenceEqual(key));
            r.Expect(!Guardian.Derive("hunter3", salt, 1000).SequenceEqual(key));
        });

        // MARK: Allowlist (Windows, by identity not file name)
        C("Allow.listedAppsAllowed", () =>
        {
            r.Expect(Allowlist.IsAllowed(new AppIdentity("winword.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("onedrive.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("zoom.exe", VerifiedPublisher: "Zoom Video Communications, Inc."), Array.Empty<string>()));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("anything.exe", PackageFamily: "MSTeams_8wekyb3d8bbwe"), Array.Empty<string>()));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("taskmgr.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("explorer.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
        });
        C("Allow.othersBlocked", () =>
        {
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("evil.exe"), Array.Empty<string>()));
            // Notepad is Microsoft-signed but not on the list.
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("notepad.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("calc.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("mspaint.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
        });
        C("Allow.renamedExeNotAllowed", () =>
        {
            // An allowed name with no verified publisher (an unsigned copy) is refused.
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("winword.exe", VerifiedPublisher: null), Array.Empty<string>()));
            // A spoofed OriginalFilename on an unsigned binary posing as an OS tool is refused.
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("taskmgr.exe", VerifiedPublisher: null), Array.Empty<string>()));
            // Wrong publisher for the name is refused.
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("zoom.exe", VerifiedPublisher: "Totally Legit Co"), Array.Empty<string>()));
        });
        C("Allow.terminalsAndSettingsClosed", () =>
        {
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("powershell.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("cmd.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("wt.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
            r.Expect(!Allowlist.IsAllowed(new AppIdentity("systemsettings.exe", VerifiedPublisher: "Microsoft Corporation"), Array.Empty<string>()));
        });
        C("Allow.guardianExtrasAndSelf", () =>
        {
            r.Expect(Allowlist.IsAllowed(new AppIdentity("code.exe", VerifiedPublisher: "Microsoft Corporation"), new[] { "code.exe" }));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("game.exe"), new[] { "game.exe" }));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("thing.exe", PackageFamily: "Some.Game_abc"), new[] { "Some.Game_abc" }));
            // The guardian can even re-open a terminal if they choose to.
            r.Expect(Allowlist.IsAllowed(new AppIdentity("powershell.exe", VerifiedPublisher: "Microsoft Corporation"), new[] { "powershell.exe" }));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("taxcollector.exe"), Array.Empty<string>(), selfImage: "TaxCollector.exe"));
            // System-critical processes are never touched.
            r.Expect(Allowlist.IsAllowed(new AppIdentity("dwm.exe"), Array.Empty<string>()));
            r.Expect(Allowlist.IsAllowed(new AppIdentity("applicationframehost.exe"), Array.Empty<string>()));
        });

        // MARK: Persistence
        C("Persist.roundTripsTasksAndSettings", () =>
        {
            var proof = new ProofSubmission { SubmittedAt = T0, Note = "done", Attachments = new() { "a.png" }, Verdict = Verdict.Accepted, Reason = "ok" };
            var tasks = new List<TaxTask>
            {
                Task(Hours(1), status: new TaskStatus.ProvenLate(T0, T0 + TimeSpan.FromSeconds(60)), proofs: new() { proof }),
                new("Imported", T0, T0, source: new TaskSource.Blackbaud("abc")),
            };
            r.Expect(Json.Decode<List<TaxTask>>(Json.Encode(tasks)) is { } back && Json.Encode(back) == Json.Encode(tasks));

            var settings = new Settings { PenaltyMinutes = 5, OverrideUntil = T0, Appearance = "dark", ExtensionsEnabled = false };
            r.Expect(Json.Encode(Json.Decode<Settings>(Json.Encode(settings))!) == Json.Encode(settings));

            var record = Guardian.MakeRecord("123456", iterations: 1000, now: T0);
            var rec2 = Json.Decode<GuardianRecord>(Json.Encode(record))!;
            r.Expect(rec2.Salt.SequenceEqual(record.Salt) && rec2.Hash.SequenceEqual(record.Hash)
                     && rec2.Iterations == record.Iterations);
        });
        C("Persist.oldSettingsFileKeepsDefaults", () =>
        {
            var s = Json.Decode<Settings>("""{"penaltyMinutes":10}""")!;
            r.Expect(s.PenaltyMinutes == 10);
            r.Expect(s.ExtensionsEnabled);          // default true
            r.Expect(s.Appearance == "light");      // default
            r.Expect(s.ClaudeModel == "sonnet");    // default
        });
        C("Persist.oldTasksStillLoad", () =>
        {
            var json = """[{"id":"6F1C2C3E-0000-4000-8000-000000000001","title":"Old","details":"","dueDate":"2026-10-15T23:35:15+00:00","createdAt":"2026-10-15T23:00:00+00:00","source":{"manual":{}},"status":{"pending":{}},"proofs":[]}]""";
            var tasks = Json.Decode<List<TaxTask>>(json);
            r.Expect(tasks?.Count == 1);
            r.Expect(tasks![0].Checklist == null);
            r.Expect(tasks![0].BlackbaudMark == null);
            r.Expect(tasks![0].IsPending);
            r.Expect(!tasks![0].IsFromBlackbaud);
        });
        C("Persist.diskRoundTrip", () =>
        {
            var dir = Path.Combine(Path.GetTempPath(), "tc-test-" + Guid.NewGuid());
            try
            {
                var store = new Store(dir);
                var tasks = new List<TaxTask> { Task(Hours(1)), new("Imported", T0, T0, source: new TaskSource.Blackbaud("abc")) };
                store.SaveTasks(tasks);
                r.Expect(Json.Encode(store.LoadTasks()) == Json.Encode(tasks));
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        });

        // MARK: Auditor parsing
        C("Auditor.plainJSON", () =>
        {
            var x = Auditor.ParseVerdict("""{"verdict":"accept","reason":"All ten problems shown."}""");
            r.Expect(x.Verdict == Verdict.Accepted);
            r.Expect(x.Reason == "All ten problems shown.");
        });
        C("Auditor.fencedAndWrapped", () =>
            r.Expect(Auditor.ParseVerdict("Here you go:\n```json\n{\"verdict\": \"reject\", \"reason\": \"Blank page.\"}\n```").Verdict == Verdict.Rejected));
        C("Auditor.noVerdictIsError", () =>
        {
            r.Expect(Auditor.ParseVerdict("I think it's fine").Verdict == Verdict.Error);
            r.Expect(Auditor.ParseVerdict("""{"verdict":"maybe"}""").Verdict == Verdict.Error);
        });
        C("Auditor.cliEnvelope", () =>
        {
            var ok = """{"type":"result","is_error":false,"result":"{\"verdict\":\"accept\",\"reason\":\"ok\"}"}""";
            r.Expect(Auditor.Parse(Utf8(ok)).Verdict == Verdict.Accepted);
            var failed = """{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate"}""";
            var res = Auditor.Parse(Utf8(failed));
            r.Expect(res.Verdict == Verdict.Error);
            r.Expect(res.Reason.Contains("Failed to authenticate"));
            r.Expect(Auditor.Parse(Array.Empty<byte>()).Verdict == Verdict.Error);
        });
        C("Auditor.checklistParsed", () =>
        {
            var x = Auditor.ParseVerdict("""{"verdict":"accept","reason":"ok","checklist":["Answer 1-10"," ","Show work",3]}""");
            r.Expect(x.Checklist.SequenceEqual(new[] { "Answer 1-10", "Show work" }));
            var many = string.Join(",", Enumerable.Range(1, 20).Select(i => $"\"item {i}\""));
            r.Expect(Auditor.ParseVerdict($$"""{"verdict":"reject","checklist":[{{many}}]}""").Checklist.Count == Auditor.MaxChecklistItems);
            r.Expect(Auditor.ParseVerdict("""{"verdict":"accept"}""").Checklist.Count == 0);
        });
        C("Auditor.fallbackUsesListLines", () =>
        {
            var details = "Read chapter 4.\n- Answer questions 1-5\n- Write a summary\n2) Upload to OneDrive";
            r.Expect(Auditor.FallbackChecklist("HW", details).SequenceEqual(new[] { "Answer questions 1-5", "Write a summary", "Upload to OneDrive" }));
            r.Expect(Auditor.FallbackChecklist("Essay draft", "Write the draft.").SequenceEqual(new[] { "Essay draft" }));
        });

        // MARK: Written proof prompts
        C("Written.accountOnlyPromptSaysSo", () =>
        {
            var task = new TaxTask("Playing Test No.1", T0, T0, details: "Play No. 41.");
            var p = Auditor.Prompt(task, "Played No. 41 in class; missed the key change at bar 12.", Array.Empty<string>(), T0);
            r.Expect(p.Contains("EVIDENCE FILES: none"));
            r.Expect(p.Contains("Judge the written account"));
            r.Expect(p.Contains("missed the key change"));
            r.Expect(!p.Contains("Read every evidence file"));
        });
        C("Written.filesAreListedAsFullPaths", () =>
        {
            var task = new TaxTask("Playing Test", T0, T0);
            var p = Auditor.Prompt(task, "", new[] { "/tmp/proof/a.png", "/tmp/proof/b.pdf" }, T0);
            r.Expect(p.Contains("- /tmp/proof/a.png\n- /tmp/proof/b.pdf"));
            r.Expect(p.Contains("Read every evidence file"));
        });
        C("Written.rulesCoverWrittenProof", () =>
        {
            r.Expect(Auditor.SystemRules.Contains("When there are no files"));
            r.Expect(Auditor.MinimumWrittenProof >= 20);
        });

        // MARK: More time
        List<TaxTask> OnTime(int n) => Enumerable.Range(0, n)
            .Select(_ => Task(-Hours(24), created: -Hours(72), status: new TaskStatus.Proven(T0 - Hours(25)))).ToList();
        TaxTask Due(TimeSpan due, TaskStatus? status = null, List<Extension>? ext = null)
        {
            var t = new TaxTask("T", T0 + due, T0 - TimeSpan.FromDays(40), status: status);
            t.Extensions = ext;
            return t;
        }
        C("MoreTime.trackRecordCounts", () =>
        {
            var tasks = OnTime(4);
            tasks.Add(Due(-Hours(24), new TaskStatus.ProvenLate(T0, T0)));
            tasks.Add(Due(-TimeSpan.FromSeconds(60)));
            tasks.Add(Due(-Hours(24), new TaskStatus.Excused(T0)));
            tasks.Add(new TaxTask("old", T0 - TimeSpan.FromDays(40), T0 - TimeSpan.FromDays(41), status: new TaskStatus.Proven(T0 - TimeSpan.FromDays(41))));
            var rec = TrackRecord.Of(tasks, T0);
            r.Expect(rec.OnTime == 4 && rec.Late == 1 && rec.Missed == 1);
            r.Expect(Math.Abs(rec.OnTimeRate - 4.0 / 6.0) < 0.001);
        });
        C("MoreTime.needsAGoodRecord", () =>
        {
            var upcoming = Due(Hours(1));
            r.Expect(ExtensionPolicy.WhyNot(upcoming, TrackRecord.Of(OnTime(4), T0), true, T0)?.Contains("at least 5") == true);
            var mixed = OnTime(5);
            mixed.Add(Due(-Hours(24), new TaskStatus.ProvenLate(T0, T0)));
            mixed.Add(Due(-Hours(24), new TaskStatus.ProvenLate(T0, T0)));
            r.Expect(ExtensionPolicy.WhyNot(upcoming, TrackRecord.Of(mixed, T0), true, T0)?.Contains("71%") == true);
            r.Expect(ExtensionPolicy.WhyNot(upcoming, TrackRecord.Of(OnTime(5), T0), true, T0) == null);
        });
        C("MoreTime.hardLimits", () =>
        {
            var good = TrackRecord.Of(OnTime(6), T0);
            r.Expect(ExtensionPolicy.WhyNot(Due(Hours(1)), good, false, T0)?.Contains("guardian") == true);
            r.Expect(ExtensionPolicy.WhyNot(Due(-TimeSpan.FromSeconds(60)), good, true, T0)?.Contains("before the deadline") == true);
            r.Expect(ExtensionPolicy.WhyNot(Due(Hours(1), new TaskStatus.Proven(T0)), good, true, T0) != null);
            var asked = new Extension { RequestedAt = T0, HoursAsked = 3, Reason = "x", Decision = ExtensionDecision.Denied, PreviousDue = T0 };
            r.Expect(ExtensionPolicy.WhyNot(Due(Hours(1), ext: new() { asked }), good, true, T0)?.Contains("already asked") == true);
            var granted = new Extension { RequestedAt = T0 - Hours(1), HoursAsked = 6, Reason = "x", Decision = ExtensionDecision.Granted, HoursGranted = 6, PreviousDue = T0 };
            var busy = OnTime(6);
            busy.Add(Due(-Hours(24), new TaskStatus.Proven(T0), new() { granted }));
            busy.Add(Due(-Hours(24), new TaskStatus.Proven(T0), new() { granted }));
            r.Expect(ExtensionPolicy.WhyNot(Due(Hours(1)), TrackRecord.Of(busy, T0), true, T0)?.Contains("2 extensions") == true);
            r.Expect(ExtensionPolicy.ClampedHours(20, 8) == 8);
            r.Expect(ExtensionPolicy.ClampedHours(20, 30) == 12);
            r.Expect(ExtensionPolicy.ClampedHours(-3, 5) == 0);
        });
        C("MoreTime.claudesAnswerRead", () =>
        {
            var g = Auditor.ParseExtension(Env("""{"decision":"grant","hours":6,"reason":"Being sick is a real reason."}"""));
            r.Expect(g.Decision == ExtensionDecision.Granted && g.Hours == 6);
            var d = Auditor.ParseExtension(Env("""{"decision":"deny","hours":0,"reason":"That's procrastination."}"""));
            r.Expect(d.Decision == ExtensionDecision.Denied && d.Hours == 0);
            r.Expect(Auditor.ParseExtension(Env("""{"decision":"grant","hours":0,"reason":"?"}""")).Decision == ExtensionDecision.Denied);
            r.Expect(Auditor.ParseExtension(Array.Empty<byte>()).Decision == ExtensionDecision.Error);
            var p = Auditor.ExtensionPrompt(Due(Hours(2)), 6, "I have a fever of 39.", TrackRecord.Of(OnTime(5), T0), T0);
            r.Expect(p.Contains("Hours asked for: 6") && p.Contains("On time: 5") && p.Contains("fever"));
        });

        // MARK: Repeats
        var cal = new Cal(TimeZoneInfo.Utc, DayOfWeek.Monday, CultureInfo.GetCultureInfo("en-US"));
        DateTimeOffset At(int day, int hour, int minute = 0) => cal.Instant(2026, 10, day, hour, minute);
        RecurringTask Series(RepeatUnit unit, int interval, int[] weekdays, DateTimeOffset start) =>
            new("x", 8 * 60 + 30, start, unit: unit, interval: interval, weekdays: weekdays, startDate: start);
        C("Repeat.nextDueFindsTheRightDay", () =>
        {
            int mon = 2, wed = 4, half = 8 * 60 + 30;
            r.Expect(Recurrence.NextDue(At(19, 8), new[] { mon }, half, cal) == At(19, 8, 30));
            r.Expect(Recurrence.NextDue(At(19, 9), new[] { mon }, half, cal) == At(26, 8, 30));
            r.Expect(Recurrence.NextDue(At(19, 9), new[] { mon, wed }, half, cal) == At(21, 8, 30));
            r.Expect(Recurrence.NextDue(At(19, 8, 30), new[] { mon }, half, cal) == At(26, 8, 30));
            r.Expect(Recurrence.NextDue(At(19, 9), Array.Empty<int>(), 0, cal) == null);
        });
        C("Repeat.oneCopyAtATime", () =>
        {
            var series = new RecurringTask("Math: homework", 8 * 60 + 30, At(17, 12), weekdays: new[] { 2 });
            var first = Recurrence.NewCopies(new[] { series }, At(17, 12), cal);
            r.Expect(first.Tasks.Count == 1 && first.Tasks[0].DueDate == At(19, 8, 30) && first.Tasks[0].SeriesId == series.Id);
            r.Expect(first.Series[0].CurrentDue == At(19, 8, 30));
            r.Expect(Recurrence.NewCopies(first.Series, At(19, 8, 29), cal).Tasks.Count == 0);
            r.Expect(Recurrence.NewCopies(first.Series, At(19, 8, 31), cal).Tasks.Select(t => t.DueDate).SequenceEqual(new[] { At(26, 8, 30) }));
            var later = At(19, 9) + TimeSpan.FromDays(20);
            var gap = Recurrence.NewCopies(first.Series, later, cal);
            r.Expect(gap.Tasks.Count == 1 && gap.Tasks[0].DueDate > later);
        });
        C("Repeat.scheduleReads", () =>
        {
            string Text(int[] days) => new RecurringTask("x", 8 * 60 + 30, At(17, 12), weekdays: days).Schedule(cal);
            r.Expect(Text(new[] { 2 }) == "Every Monday at 8:30 AM");
            r.Expect(Text(new[] { 4, 2 }) == "Every Monday and Wednesday at 8:30 AM");
            r.Expect(Text(new[] { 2, 4, 6 }) == "Every Monday, Wednesday and Friday at 8:30 AM");
            r.Expect(Text(new[] { 1, 2 }) == "Every Monday and Sunday at 8:30 AM");
            r.Expect(Text(new[] { 2, 3, 4, 5, 6 }) == "Every weekday at 8:30 AM");
            r.Expect(Text(new[] { 1, 2, 3, 4, 5, 6, 7 }) == "Every day at 8:30 AM");
        });
        C("Repeat.everyFewDays", () =>
        {
            var s = Series(RepeatUnit.Days, 4, Array.Empty<int>(), At(19, 0));
            r.Expect(s.NextDue(At(19, 8), cal) == At(19, 8, 30));
            r.Expect(s.NextDue(At(19, 9), cal) == At(23, 8, 30));
            r.Expect(s.NextDue(At(22, 23), cal) == At(23, 8, 30));
            r.Expect(s.NextDue(At(23, 8, 30), cal) == At(27, 8, 30));
            r.Expect(Series(RepeatUnit.Days, 4, Array.Empty<int>(), At(25, 0)).NextDue(At(19, 9), cal) == At(25, 8, 30));
            r.Expect(Series(RepeatUnit.Days, 1, Array.Empty<int>(), At(19, 0)).NextDue(At(19, 9), cal) == At(20, 8, 30));
        });
        C("Repeat.everyFewWeeks", () =>
        {
            var mondays = Series(RepeatUnit.Weeks, 2, new[] { 2 }, At(19, 0));
            r.Expect(mondays.NextDue(At(19, 8), cal) == At(19, 8, 30));
            r.Expect(mondays.NextDue(At(19, 9), cal) == cal.Instant(2026, 11, 2, 8, 30));
            var twice = Series(RepeatUnit.Weeks, 2, new[] { 2, 4 }, At(19, 0));
            r.Expect(twice.NextDue(At(19, 9), cal) == At(21, 8, 30));
            r.Expect(twice.NextDue(At(21, 9), cal) == cal.Instant(2026, 11, 2, 8, 30));
            r.Expect(Series(RepeatUnit.Weeks, 2, new[] { 2, 4 }, At(21, 0)).NextDue(At(19, 9), cal) == At(21, 8, 30));
        });
        C("Repeat.customScheduleReads", () =>
        {
            string Text(RepeatUnit unit, int n, int[] days) => Series(unit, n, days, At(19, 0)).Schedule(cal);
            r.Expect(Text(RepeatUnit.Days, 1, Array.Empty<int>()) == "Every day at 8:30 AM");
            r.Expect(Text(RepeatUnit.Days, 4, Array.Empty<int>()) == "Every 4 days at 8:30 AM");
            r.Expect(Text(RepeatUnit.Weeks, 2, new[] { 2 }) == "Every 2 weeks on Monday at 8:30 AM");
            r.Expect(Text(RepeatUnit.Weeks, 3, new[] { 2, 4 }) == "Every 3 weeks on Monday and Wednesday at 8:30 AM");
            r.Expect(Text(RepeatUnit.Weeks, 2, new[] { 2, 3, 4, 5, 6 }) == "Every 2 weeks on weekdays at 8:30 AM");
            r.Expect(Series(RepeatUnit.Days, 0, Array.Empty<int>(), At(19, 0)).Interval == 1);
            r.Expect(Series(RepeatUnit.Weeks, 500, new[] { 2 }, At(19, 0)).Interval == RecurringTask.MaxWeeks);
        });
        C("Repeat.savesAndOldTasksStillLoad", () =>
        {
            var task = new TaxTask("x", T0, T0) { SeriesId = Guid.NewGuid() };
            r.Expect(Json.Decode<TaxTask>(Json.Encode(task))!.SeriesId == task.SeriesId);
            var series = new RecurringTask("x", 510, T0, weekdays: new[] { 2, 4 }, currentDue: T0);
            r.Expect(Json.Encode(Json.Decode<RecurringTask>(Json.Encode(series))!) == Json.Encode(series));
            // An older file with no unit/interval/startDate still loads with weekly defaults.
            var old = """{"id":"4D1C8B0E-7F4A-4C11-9E2B-1A2B3C4D5E6F","title":"Math","details":"","weekdays":[2],"minuteOfDay":510,"createdAt":"2026-01-01T00:00:00+00:00"}""";
            var loaded = Json.Decode<RecurringTask>(old)!; loaded.Normalise();
            r.Expect(loaded.Unit == RepeatUnit.Weeks && loaded.Interval == 1 && loaded.StartDate == loaded.CreatedAt);
            r.Expect(loaded.NextDue(At(19, 9), cal) == At(26, 8, 30));
        });

        // MARK: Last check
        C("LastCheck.onlyPaidBlackbaudTasksNeedIt", () =>
        {
            var t = new TaxTask("HW", T0, T0, source: new TaskSource.Blackbaud("x"));
            r.Expect(!t.NeedsLastCheck);
            t.Status = new TaskStatus.Proven(T0);
            r.Expect(t.NeedsLastCheck);
            t.Status = new TaskStatus.ProvenLate(T0, T0);
            r.Expect(t.NeedsLastCheck);
            t.LastCheckDoneAt = T0;
            r.Expect(!t.NeedsLastCheck);
            var manual = new TaxTask("HW", T0, T0) { Status = new TaskStatus.Proven(T0) };
            r.Expect(!manual.NeedsLastCheck);
        });

        // MARK: Agenda
        var ucal = new Cal(TimeZoneInfo.Utc, DayOfWeek.Sunday, CultureInfo.GetCultureInfo("en-US"));
        TaxTask ATask(string title, TimeSpan due, TaskStatus? status = null) =>
            new(title, T0 + due, T0 - TimeSpan.FromDays(3), status: status);
        C("Agenda.groupsAndRanks", () =>
        {
            var tasks = new List<TaxTask>
            {
                ATask("later today", Hours(2)),
                ATask("overdue b", -TimeSpan.FromSeconds(60)),
                ATask("next week", TimeSpan.FromDays(7)),
                ATask("soon today", TimeSpan.FromSeconds(600)),
                ATask("overdue a", -Hours(2)),
                ATask("paid", Hours(1), new TaskStatus.Proven(T0)),
                ATask("fee", -Hours(1), new TaskStatus.ProvenLate(T0, T0 + TimeSpan.FromSeconds(900))),
            };
            var s = Agenda.Sections(tasks, T0, ucal);
            r.Expect(s[0].Kind is AgendaSection.SectionKind.LateFee);
            r.Expect(s[1].Kind is AgendaSection.SectionKind.Overdue);
            r.Expect(s[1].Tasks.Select(t => t.Title).SequenceEqual(new[] { "overdue a", "overdue b" }));
            var days = s.Skip(2).ToList();
            r.Expect(days.SelectMany(d => d.Tasks).Select(t => t.Title).SequenceEqual(new[] { "soon today", "later today", "next week" }));
            r.Expect(days.Count >= 2);
            r.Expect(!s.SelectMany(x => x.Tasks).Any(t => t.Title == "paid"));
        });
    }
}
