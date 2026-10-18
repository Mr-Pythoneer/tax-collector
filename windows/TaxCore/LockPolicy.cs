namespace TaxCore;

public sealed class LockState
{
    public List<TaxTask> Overdue { get; }
    /// Tasks paid late whose penalty is still running.
    public List<TaxTask> Penalties { get; }
    public DateTimeOffset? OverrideUntil { get; }

    public LockState(List<TaxTask>? overdue = null, List<TaxTask>? penalties = null, DateTimeOffset? overrideUntil = null)
    {
        Overdue = overdue ?? new();
        Penalties = penalties ?? new();
        OverrideUntil = overrideUntil;
    }

    public bool OwesSomething => Overdue.Count > 0 || Penalties.Count > 0;
    public bool IsLocked => OwesSomething && OverrideUntil == null;

    /// When the lock ends by itself (only possible when nothing is overdue, just penalties).
    public DateTimeOffset? PenaltyEndsAt
    {
        get
        {
            if (Overdue.Count > 0) return null;
            DateTimeOffset? max = null;
            foreach (var t in Penalties)
                if (t.Status is TaskStatus.ProvenLate pl && (max == null || pl.PenaltyEndsAt > max))
                    max = pl.PenaltyEndsAt;
            return max;
        }
    }
}

public static class LockPolicy
{
    /// Inside this window before the deadline, a task is locked in.
    public static readonly TimeSpan FreezeWindow = TimeSpan.FromHours(24);
    /// Right after creating a task you can still fix typos, even if it's due soon.
    public static readonly TimeSpan CreationGrace = TimeSpan.FromMinutes(5);
    /// The longest a check that started before the deadline holds the lock off once
    /// the deadline has passed.
    public static readonly TimeSpan CheckGrace = TimeSpan.FromMinutes(5);

    public static LockState State(IEnumerable<TaxTask> tasks, DateTimeOffset? overrideUntil, DateTimeOffset now)
    {
        var list = tasks as IList<TaxTask> ?? tasks.ToList();
        var overdue = list.Where(t => IsOverdue(t, now)).ToList();
        var penalties = list.Where(t => IsInPenalty(t, now)).ToList();
        var ov = overrideUntil is { } u && u > now ? u : (DateTimeOffset?)null;
        return new LockState(overdue, penalties, ov);
    }

    public static bool IsOverdue(TaxTask task, DateTimeOffset now)
    {
        if (!task.IsPending || task.DueDate > now) return false;
        return !(task.HasCheckInFlightFromBeforeDue && now < task.DueDate + CheckGrace);
    }

    public static bool IsInPenalty(TaxTask task, DateTimeOffset now) =>
        task.Status is TaskStatus.ProvenLate pl && pl.PenaltyEndsAt > now;

    /// Whether the task can be edited or deleted without the guardian code.
    public static bool IsFrozen(TaxTask task, DateTimeOffset now)
    {
        if (IsInPenalty(task, now)) return true;
        if (!task.IsPending) return false;
        if (now - task.CreatedAt < CreationGrace) return false;
        return task.DueDate - now <= FreezeWindow;
    }

    /// Moving a deadline earlier only makes things stricter, so that's always allowed.
    /// Anything else on a frozen task needs the guardian.
    public static bool CanEditWithoutGuardian(TaxTask original, TaxTask edited, DateTimeOffset now)
    {
        if (!IsFrozen(original, now)) return true;
        return edited.Title == original.Title
            && edited.Details == original.Details
            && edited.DueDate <= original.DueDate;
    }

    public static bool CanDeleteWithoutGuardian(TaxTask task, DateTimeOffset now) => !IsFrozen(task, now);

    /// What a task becomes once its proof is accepted.
    public static TaskStatus StatusAfterAccepting(TaxTask task, DateTimeOffset submittedAt, DateTimeOffset acceptedAt,
                                                  int penaltyMinutes)
    {
        if (submittedAt <= task.DueDate) return new TaskStatus.Proven(submittedAt);
        var end = acceptedAt + TimeSpan.FromMinutes(Math.Max(0, penaltyMinutes));
        return new TaskStatus.ProvenLate(submittedAt, end);
    }

    /// The clock can only go forward as far as Tax Collector is concerned.
    public static DateTimeOffset EffectiveNow(DateTimeOffset systemNow, DateTimeOffset? lastSeen) =>
        lastSeen is { } seen ? (systemNow > seen ? systemNow : seen) : systemNow;

    /// Seconds to wait after the nth wrong guardian code (n starts at 1). First three are free.
    public static TimeSpan GuardianCooldown(int afterFailures)
    {
        if (afterFailures < 3) return TimeSpan.Zero;
        return TimeSpan.FromSeconds(Math.Min(3600, 30 * Math.Pow(2, afterFailures - 3)));
    }
}
