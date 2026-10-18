using TaxCore;

namespace TaxCollector;

internal enum GuardianCheck { Ok, Wrong, CoolingDown }

internal enum EditResult { Saved, NeedsGuardian }

/// The app's state and rules, ported from Sources/TaxCollector/AppModel.swift,
/// minus Blackbaud import (out of scope on Windows). UI-thread affine: Tick() and
/// the mutating methods are called on the WinForms thread; async check results are
/// marshalled back through Post.
internal sealed class AppModel
{
    public const string TaskName = "TaxCollector";
    public static readonly TimeSpan[] WarningMarks =
        { TimeSpan.FromHours(24), TimeSpan.FromHours(1), TimeSpan.FromMinutes(15), TimeSpan.FromMinutes(5) };
    public const string SelfImage = "TaxCollector.exe";

    public Store Store { get; }
    public bool DryRun { get; }
    public List<TaxTask> Tasks;
    public Settings Settings;
    public GuardianRecord? Guardian;
    public DateTimeOffset Now;
    public LockState Lock = new();
    /// Names of apps closed during the current lock, newest first.
    public List<string> ClosedApps = new();
    public HashSet<Guid> Checking = new();
    public string AuditorStatus = "Checking…";
    public List<RecurringTask> Recurring;
    public readonly Enforcer Enforcer;

    // Events the UI hooks.
    public Action<bool> OnLockChange = _ => { };
    public Action<TaxTask, TimeSpan> OnWarning = (_, _) => { };
    public Action<string> OnClosedApp = _ => { };
    public Action<TaxTask> OnPaid = _ => { };
    public Action<TaxTask> OnRecurred = _ => { };
    public Action? OnChanged;
    /// Marshals an async result back onto the UI thread. Default runs inline (tests).
    public Action<Action> Post = a => a();

    private Dictionary<Guid, HashSet<int>> _warned = new();
    private DateTimeOffset _lastClockSave = DateTimeOffset.MinValue;
    private long _lastUptime = Environment.TickCount64;
    private bool _wasLocked;

    public string TokenFile => Path.Combine(Store.Dir, "claude-token");

    public AppModel(Store store, bool dryRun)
    {
        Store = store;
        DryRun = dryRun;
        Tasks = store.LoadTasks();
        Settings = store.LoadSettings();
        Guardian = store.LoadGuardian();
        Recurring = store.LoadRecurring();
        Enforcer = new Enforcer(dryRun);
        Now = LockPolicy.EffectiveNow(DateTimeOffset.Now, Settings.LastSeen);

        // A check that was running when the app died can't be left hanging.
        var interrupted = false;
        foreach (var t in Tasks)
            foreach (var p in t.Proofs.Where(p => p.Verdict == null))
            {
                p.Verdict = Verdict.Error;
                p.Reason = "The check was interrupted. Try again.";
                interrupted = true;
            }
        foreach (var t in Tasks)
            foreach (var e in (t.Extensions ?? new()).Where(e => e.Decision == null))
            {
                e.Decision = ExtensionDecision.Error;
                e.Answer = "The request was interrupted. You can ask again.";
                interrupted = true;
            }
        if (interrupted) store.SaveTasks(Tasks);

        Enforcer.IsAllowed = id => Allowlist.IsAllowed(id, Settings.ExtraAllowedApps, SelfImage);
        Enforcer.Log = m => Store.Log(m);
        Enforcer.OnClosed = name =>
        {
            ClosedApps.RemoveAll(n => n == name);
            ClosedApps.Insert(0, name);
            OnClosedApp(name);
        };
    }

    public void Start()
    {
        Store.Log($"START{(DryRun ? " (dry run)" : "")} pid {Environment.ProcessId}");
        Tick();
        RefreshAuditorStatus();
    }

    // MARK: Clock and lock

    public void Tick()
    {
        var uptime = Environment.TickCount64;
        var advanced = Now + TimeSpan.FromMilliseconds(Math.Max(0, uptime - _lastUptime));
        _lastUptime = uptime;
        var floor = Max(advanced, Settings.LastSeen ?? DateTimeOffset.MinValue);
        Now = LockPolicy.EffectiveNow(DateTimeOffset.Now, floor);

        if (Now - _lastClockSave >= TimeSpan.FromSeconds(30))
        {
            Settings.LastSeen = Now;
            Store.SaveSettings(Settings);
            _lastClockSave = Now;
        }

        BringBackRepeats();
        Lock = LockPolicy.State(Tasks, Settings.OverrideUntil, Now);
        if (Lock.IsLocked != _wasLocked)
        {
            _wasLocked = Lock.IsLocked;
            LockChanged();
        }
        CheckWarnings();
        OnChanged?.Invoke();
    }

    private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;

    private void LockChanged()
    {
        if (Lock.IsLocked)
        {
            ClosedApps.Clear();
            var due = string.Join(", ", Lock.Overdue.Concat(Lock.Penalties).Select(t => t.Title));
            Store.Log($"LOCK ON — overdue: {due}");
            Enforcer.Activate();
        }
        else
        {
            Store.Log(Lock.OverrideUntil != null ? "LOCK OFF — guardian unlock" : "LOCK OFF — proof accepted");
            Enforcer.Deactivate();
        }
        OnLockChange(Lock.IsLocked);
    }

    private void CheckWarnings()
    {
        foreach (var t in Tasks.Where(t => t.IsPending))
        {
            var remaining = t.DueDate - Now;
            if (remaining <= TimeSpan.Zero) continue;
            var crossed = Enumerable.Range(0, WarningMarks.Length).Where(i => remaining <= WarningMarks[i]).ToList();
            if (crossed.Count == 0) continue;
            var smallest = crossed[^1];
            var done = _warned.TryGetValue(t.Id, out var set) ? set : new HashSet<int>();
            if (done.Contains(smallest)) continue;
            foreach (var c in crossed) done.Add(c);
            _warned[t.Id] = done;
            OnWarning(t, remaining);
        }
    }

    // MARK: Queries

    public IEnumerable<TaxTask> PendingTasks =>
        Tasks.Where(t => t.IsPending || LockPolicy.IsInPenalty(t, Now)).OrderBy(t => t.DueDate);

    public IEnumerable<TaxTask> SettledTasks =>
        Tasks.Where(t => !t.IsPending && !LockPolicy.IsInPenalty(t, Now)).OrderByDescending(t => t.DueDate);

    public TaxTask? NextDue => Tasks.Where(t => t.IsPending).OrderBy(t => t.DueDate).FirstOrDefault();

    public TaxTask? Task(Guid id) => Tasks.FirstOrDefault(t => t.Id == id);

    public bool IsFrozen(TaxTask task) => LockPolicy.IsFrozen(task, Now);

    // MARK: Tasks

    public void AddTask(string title, string details, DateTimeOffset due)
    {
        var t = new TaxTask(title.Trim(), due, Now, details: details.Trim());
        Tasks.Add(t);
        Save();
        Store.Log($"TASK added \"{t.Title}\" due {t.DueDate:O}");
        Tick();
    }

    public void AddRecurring(string title, string details, RepeatUnit unit, int interval,
                             IEnumerable<int> weekdays, int minuteOfDay, DateTimeOffset? startDate = null)
    {
        var series = new RecurringTask(title.Trim(), minuteOfDay, Now, details: details.Trim(), unit: unit,
            interval: interval, weekdays: unit == RepeatUnit.Weeks ? weekdays : Enumerable.Empty<int>(),
            startDate: startDate ?? Now);
        Recurring.Add(series);
        Store.SaveRecurring(Recurring);
        Store.Log($"REPEAT added \"{series.Title}\": {series.Schedule()}");
        Tick();
    }

    public void StopRepeating(Guid seriesId)
    {
        var i = Recurring.FindIndex(s => s.Id == seriesId);
        if (i < 0) return;
        var series = Recurring[i];
        Recurring.RemoveAt(i);
        Store.SaveRecurring(Recurring);
        Store.Log($"REPEAT stopped \"{series.Title}\"");
    }

    public RecurringTask? Series(TaxTask task) =>
        task.SeriesId is { } id ? Recurring.FirstOrDefault(s => s.Id == id) : null;

    private void BringBackRepeats()
    {
        if (Recurring.Count == 0) return;
        var brandNew = Recurring.Where(s => s.CurrentDue == null).Select(s => s.Id).ToHashSet();
        var (copies, updated) = Recurrence.NewCopies(Recurring, Now);
        if (copies.Count == 0) return;
        Recurring = updated;
        Tasks.AddRange(copies);
        Store.SaveRecurring(Recurring);
        Save();
        foreach (var copy in copies)
        {
            Store.Log($"TASK repeated \"{copy.Title}\" due {copy.DueDate:O}");
            if (copy.SeriesId is { } id && !brandNew.Contains(id)) OnRecurred(copy);
        }
    }

    public EditResult SaveEdit(TaxTask edited, bool guardianApproved = false)
    {
        var i = Tasks.FindIndex(t => t.Id == edited.Id);
        if (i < 0) return EditResult.Saved;
        var original = Tasks[i];
        if (!guardianApproved && !LockPolicy.CanEditWithoutGuardian(original, edited, Now))
            return EditResult.NeedsGuardian;
        Tasks[i] = edited;
        if (edited.DueDate != original.DueDate) _warned.Remove(edited.Id);
        Save();
        Store.Log($"TASK edited \"{edited.Title}\" due {edited.DueDate:O}{(guardianApproved ? " (guardian)" : "")}");
        Tick();
        return EditResult.Saved;
    }

    public EditResult Delete(Guid id, bool guardianApproved = false)
    {
        var t = Task(id);
        if (t == null) return EditResult.Saved;
        if (!guardianApproved && !LockPolicy.CanDeleteWithoutGuardian(t, Now)) return EditResult.NeedsGuardian;
        Tasks.RemoveAll(x => x.Id == id);
        try { Directory.Delete(Path.Combine(Store.ProofsRoot, id.ToString()), true); } catch { }
        Save();
        Store.Log($"TASK deleted \"{t.Title}\"{(guardianApproved ? " (guardian)" : "")}");
        Tick();
        return EditResult.Saved;
    }

    // MARK: Proof

    public void SubmitProof(Guid taskId, string note, IReadOnlyList<string> files)
    {
        var i = Tasks.FindIndex(t => t.Id == taskId);
        if (i < 0) return;
        var submission = new ProofSubmission { SubmittedAt = Now, Note = note };
        var folder = Store.ProofFolder(taskId, submission.Id);
        var names = new List<string>();
        for (var n = 0; n < files.Count; n++)
        {
            var name = Path.GetFileName(files[n]).Replace("/", "-");
            if (names.Contains(name)) name = $"{n + 1}-{name}";
            try { File.Copy(files[n], Path.Combine(folder, name)); names.Add(name); }
            catch (Exception ex) { Store.Log($"PROOF could not copy {files[n]}: {ex.Message}"); }
        }
        submission.Attachments = names;
        Tasks[i].Proofs.Add(submission);
        Save();
        Store.Log($"PROOF sent for \"{Tasks[i].Title}\" with {names.Count} file(s)");
        RunCheck(taskId, submission.Id);
    }

    public void Recheck(Guid taskId, Guid submissionId)
    {
        var t = Task(taskId);
        var p = t?.Proofs.FirstOrDefault(p => p.Id == submissionId);
        if (p == null) return;
        p.Verdict = null;
        p.Reason = "";
        p.RecheckedAt = Now;
        Save();
        RunCheck(taskId, submissionId);
    }

    /// Takes a proof back while Claude is still checking it. It counts for nothing.
    public void CancelCheck(Guid taskId, Guid submissionId)
    {
        var ti = Tasks.FindIndex(t => t.Id == taskId);
        if (ti < 0) return;
        var si = Tasks[ti].Proofs.FindIndex(p => p.Id == submissionId);
        if (si < 0 || Tasks[ti].Proofs[si].Verdict != null) return;
        ProofRunner.Cancel(submissionId);
        Checking.Remove(submissionId);
        if (Tasks[ti].Proofs[si].RecheckedAt != null)
        {
            Tasks[ti].Proofs[si].Verdict = Verdict.Error;
            Tasks[ti].Proofs[si].Reason = "You cancelled the check.";
        }
        else
        {
            Tasks[ti].Proofs.RemoveAt(si);
            try { Directory.Delete(Store.ProofFolder(taskId, submissionId), true); } catch { }
        }
        Save();
        Store.Log($"PROOF cancelled for \"{Tasks[ti].Title}\" before Claude answered");
        Tick();
    }

    private void RunCheck(Guid taskId, Guid submissionId)
    {
        var t = Task(taskId);
        var submission = t?.Proofs.FirstOrDefault(p => p.Id == submissionId);
        if (t == null || submission == null) return;
        Checking.Add(submissionId);
        var folder = Store.ProofFolder(taskId, submissionId);
        var settings = Settings.Clone();
        var tokenFile = TokenFile;
        var taskCopy = t.Clone();
        var subCopy = submission.Clone();
        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            var outcome = await ProofRunner.Verify(taskCopy, subCopy, folder, settings, tokenFile);
            Post(() =>
            {
                Checking.Remove(submissionId);
                var proof = Task(taskId)?.Proofs.FirstOrDefault(p => p.Id == submissionId);
                if (proof == null || proof.Verdict != null) return; // cancelled or guardian-approved meanwhile
                Record(outcome.Verdict, outcome.Reason, outcome.Checklist, taskId, submissionId);
            });
        });
    }

    private void Record(Verdict verdict, string reason, List<string> checklist, Guid taskId, Guid submissionId)
    {
        var ti = Tasks.FindIndex(t => t.Id == taskId);
        if (ti < 0) return;
        var si = Tasks[ti].Proofs.FindIndex(p => p.Id == submissionId);
        if (si < 0) return;
        Tasks[ti].Proofs[si].Verdict = verdict;
        Tasks[ti].Proofs[si].Reason = reason;
        var accepted = verdict is Verdict.Accepted or Verdict.GuardianApproved;
        if (Tasks[ti].Checklist == null)
        {
            var items = checklist.Count == 0 && accepted
                ? Auditor.FallbackChecklist(Tasks[ti].Title, Tasks[ti].Details)
                : checklist;
            if (items.Count > 0) Tasks[ti].Checklist = items.Select(s => new ChecklistItem(s)).ToList();
        }
        if (accepted && Tasks[ti].IsPending)
            Tasks[ti].Status = LockPolicy.StatusAfterAccepting(
                Tasks[ti], Tasks[ti].Proofs[si].SubmittedAt, Now, Settings.PenaltyMinutes);
        Save();
        Store.Log($"PROOF {verdict.ToString().ToLowerInvariant()} for \"{Tasks[ti].Title}\": {reason}");
        if (accepted) OnPaid(Tasks[ti]);
        Tick();
    }

    public ProofSubmission? LatestProof(Guid taskId) => Task(taskId)?.Proofs.LastOrDefault();

    public void RefreshAuditorStatus()
    {
        var settings = Settings.Clone();
        var tokenFile = TokenFile;
        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            var status = await ProofRunner.AuthStatus(settings, tokenFile);
            Post(() => { AuditorStatus = status; OnChanged?.Invoke(); });
        });
    }

    public void SaveAuditorToken(string token)
    {
        var trimmed = token.Trim();
        try
        {
            if (trimmed.Length == 0) File.Delete(TokenFile);
            else File.WriteAllText(TokenFile, trimmed);
        }
        catch { }
        RefreshAuditorStatus();
    }

    public bool HasAuditorToken => File.Exists(TokenFile);

    // MARK: More time

    public TrackRecord TrackRecord => TaxCore.TrackRecord.Of(Tasks, Now);

    public string? ExtensionWhyNot(TaxTask task) =>
        ExtensionPolicy.WhyNot(task, TrackRecord, Settings.ExtensionsEnabled, Now);

    public void RequestExtension(Guid taskId, int hours, string reason)
    {
        var i = Tasks.FindIndex(t => t.Id == taskId);
        if (i < 0) return;
        var task = Tasks[i];
        if (ExtensionWhyNot(task) is { } why) { Store.Log($"EXTENSION refused for \"{task.Title}\": {why}"); return; }
        var asked = Math.Max(1, Math.Min(hours, ExtensionPolicy.MaxHours));
        var record = TrackRecord;
        var request = new Extension { RequestedAt = Now, HoursAsked = asked, Reason = reason, PreviousDue = task.DueDate };
        Tasks[i].Extensions = (Tasks[i].Extensions ?? new()).Append(request).ToList();
        Save();
        Store.Log($"EXTENSION asked for {asked}h on \"{task.Title}\"");
        var folder = Path.Combine(Store.Dir, "extensions", task.Id.ToString(), request.Id.ToString());
        var settings = Settings.Clone();
        var tokenFile = TokenFile;
        var taskCopy = task.Clone();
        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            var (decision, granted, answer) = await ProofRunner.DecideExtension(taskCopy, asked, reason, record, folder, settings, tokenFile);
            Post(() => RecordExtension(taskId, request.Id, decision, granted, answer));
        });
    }

    private void RecordExtension(Guid taskId, Guid requestId, ExtensionDecision decision, int granted, string answer)
    {
        var i = Tasks.FindIndex(t => t.Id == taskId);
        if (i < 0) return;
        var request = Tasks[i].Extensions?.FirstOrDefault(e => e.Id == requestId);
        if (request == null) return;
        var hours = decision == ExtensionDecision.Granted ? ExtensionPolicy.ClampedHours(granted, request.HoursAsked) : 0;
        request.Decision = hours > 0 ? ExtensionDecision.Granted : (decision == ExtensionDecision.Error ? ExtensionDecision.Error : ExtensionDecision.Denied);
        request.HoursGranted = hours;
        request.Answer = answer;
        if (hours > 0 && Tasks[i].IsPending)
        {
            Tasks[i].DueDate = request.PreviousDue + TimeSpan.FromHours(hours);
            _warned.Remove(taskId);
        }
        Save();
        var word = hours > 0 ? $"granted {hours}h" : (decision == ExtensionDecision.Error ? "couldn't be decided" : "denied");
        Store.Log($"EXTENSION {word} for \"{Tasks[i].Title}\": {answer}");
        Tick();
    }

    public Extension? LatestExtension(Guid taskId) => Task(taskId)?.Extensions?.LastOrDefault();

    public void SetExtensionsEnabled(bool enabled)
    {
        Settings.ExtensionsEnabled = enabled;
        Store.SaveSettings(Settings);
        Store.Log($"GUARDIAN turned requests for more time {(enabled ? "on" : "off")}");
    }

    // MARK: Checklist (shown after a proof is accepted)

    public void SetChecklistItem(Guid taskId, Guid item, bool done)
    {
        var ti = Tasks.FindIndex(t => t.Id == taskId);
        if (ti < 0 || Tasks[ti].LastCheckDoneAt != null) return;
        var ci = Tasks[ti].Checklist?.FindIndex(c => c.Id == item) ?? -1;
        if (ci < 0) return;
        Tasks[ti].Checklist![ci].Done = done;
        Save();
    }

    // MARK: Guardian

    public void SetupGuardian(string code)
    {
        var record = TaxCore.Guardian.MakeRecord(code, now: Now);
        Guardian = record;
        Store.SaveGuardian(record);
        Store.Log("GUARDIAN code set");
    }

    public GuardianCheck CheckGuardian(string code)
    {
        if (Settings.GuardianLockedUntil is { } until && until > Now) return GuardianCheck.CoolingDown;
        if (Guardian == null || !TaxCore.Guardian.Verify(code, Guardian))
        {
            Settings.GuardianFailures += 1;
            var wait = LockPolicy.GuardianCooldown(Settings.GuardianFailures);
            Settings.GuardianLockedUntil = wait > TimeSpan.Zero ? Now + wait : null;
            Store.SaveSettings(Settings);
            Store.Log($"GUARDIAN wrong code (#{Settings.GuardianFailures})");
            return Settings.GuardianLockedUntil != null ? GuardianCheck.CoolingDown : GuardianCheck.Wrong;
        }
        Settings.GuardianFailures = 0;
        Settings.GuardianLockedUntil = null;
        Store.SaveSettings(Settings);
        Store.Log("GUARDIAN opened the panel");
        return GuardianCheck.Ok;
    }

    public DateTimeOffset? GuardianCooldownUntil =>
        Settings.GuardianLockedUntil is { } u && u > Now ? u : null;

    public void Unlock(double hours)
    {
        Settings.OverrideUntil = Now + TimeSpan.FromHours(hours);
        Store.SaveSettings(Settings);
        Store.Log($"GUARDIAN unlocked for {hours}h");
        Tick();
    }

    public void EndUnlock()
    {
        Settings.OverrideUntil = null;
        Store.SaveSettings(Settings);
        Store.Log("GUARDIAN ended the unlock");
        Tick();
    }

    public void Excuse(Guid id)
    {
        var i = Tasks.FindIndex(t => t.Id == id);
        if (i < 0) return;
        Tasks[i].Status = new TaskStatus.Excused(Now);
        Save();
        Store.Log($"GUARDIAN excused \"{Tasks[i].Title}\"");
        Tick();
    }

    public void ApproveLatestProof(Guid id)
    {
        var i = Tasks.FindIndex(t => t.Id == id);
        if (i < 0) return;
        if (Tasks[i].Proofs.Count == 0)
            Tasks[i].Proofs.Add(new ProofSubmission { SubmittedAt = Now, Note = "Approved by guardian" });
        var sid = Tasks[i].Proofs[^1].Id;
        ProofRunner.Cancel(sid);
        Checking.Remove(sid);
        Record(Verdict.GuardianApproved, "Approved by your guardian.", new(), id, sid);
    }

    public void SetPenalty(int minutes)
    {
        Settings.PenaltyMinutes = Math.Max(0, minutes);
        Store.SaveSettings(Settings);
        Store.Log($"GUARDIAN set the late penalty to {Settings.PenaltyMinutes} min");
    }

    public void AllowApp(string identity)
    {
        if (Settings.ExtraAllowedApps.Contains(identity)) return;
        Settings.ExtraAllowedApps.Add(identity);
        Store.SaveSettings(Settings);
        Store.Log($"GUARDIAN allowed {identity}");
    }

    public void DisallowApp(string identity)
    {
        Settings.ExtraAllowedApps.RemoveAll(x => x == identity);
        Store.SaveSettings(Settings);
        Store.Log($"Removed {identity} from the allowlist");
        Enforcer.Sweep();
    }

    public void ChangeGuardianCode(string code)
    {
        SetupGuardian(code);
        Store.Log("GUARDIAN changed the code");
    }

    public void ResetClockGuard()
    {
        Settings.LastSeen = DateTimeOffset.Now;
        Now = DateTimeOffset.Now;
        Store.SaveSettings(Settings);
        Store.Log("GUARDIAN reset the clock guard");
        Tick();
    }

    public void SetAppearance(string appearance)
    {
        Settings.Appearance = appearance;
        Store.SaveSettings(Settings);
    }

    private void Save() => Store.SaveTasks(Tasks);
}
