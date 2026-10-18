namespace TaxCore;

/// How reliably you've met your deadlines lately. It decides whether you can ask for more time.
public readonly struct TrackRecord
{
    /// Proof accepted before the deadline.
    public int OnTime { get; init; }
    /// Proof accepted after the deadline (the computer was locked first).
    public int Late { get; init; }
    /// Overdue right now with no accepted proof.
    public int Missed { get; init; }
    /// Extensions granted in the last 7 days.
    public int ExtensionsThisWeek { get; init; }

    public int Finished => OnTime + Late;

    /// Share of deadlines met. Excused tasks don't count either way.
    public double OnTimeRate
    {
        get
        {
            var counted = OnTime + Late + Missed;
            return counted == 0 ? 0 : (double)OnTime / counted;
        }
    }

    public static TrackRecord Of(IEnumerable<TaxTask> tasks, DateTimeOffset now)
    {
        var list = tasks as IList<TaxTask> ?? tasks.ToList();
        int onTime = 0, late = 0, missed = 0;
        var since = now - ExtensionPolicy.Window;
        foreach (var task in list)
        {
            if (task.DueDate <= since) continue;
            switch (task.Status)
            {
                case TaskStatus.Proven: onTime++; break;
                case TaskStatus.ProvenLate: late++; break;
                case TaskStatus.Pending when task.DueDate <= now: missed++; break;
            }
        }
        var weekAgo = now - TimeSpan.FromDays(7);
        var extCount = list.SelectMany(t => t.Extensions ?? new())
            .Count(e => e.Decision == ExtensionDecision.Granted && e.RequestedAt > weekAgo);
        return new TrackRecord { OnTime = onTime, Late = late, Missed = missed, ExtensionsThisWeek = extCount };
    }
}

/// The limits on asking for more time. Claude judges the reason; these are enforced no matter what it says.
public static class ExtensionPolicy
{
    public const int MaxHours = 12;
    public static readonly TimeSpan Window = TimeSpan.FromDays(30);
    public const int MinimumFinished = 5;
    public const double MinimumOnTimeRate = 0.8;
    public const int PerWeek = 2;
    /// The shortest reason worth sending.
    public const int MinimumReason = 30;

    /// null when you can ask for more time on this task; otherwise why not.
    public static string? WhyNot(TaxTask task, TrackRecord record, bool enabled, DateTimeOffset now)
    {
        if (!enabled) return "Your guardian has turned off requests for more time.";
        if (!task.IsPending) return "This task is already finished.";
        if (task.DueDate <= now) return "You can only ask before the deadline.";
        // A request Claude couldn't answer doesn't count; anything else does, so there's no asking again.
        if ((task.Extensions ?? new()).Any(e => e.Decision != ExtensionDecision.Error))
            return "You've already asked for more time on this task.";
        if (record.Finished < MinimumFinished)
            return $"You need at least {MinimumFinished} finished tasks in the last 30 days first. You have {record.Finished}.";
        if (record.OnTimeRate < MinimumOnTimeRate)
            return $"{(int)Math.Round(record.OnTimeRate * 100)}% of your recent deadlines were met. It needs to be at least {(int)(MinimumOnTimeRate * 100)}%.";
        if (record.ExtensionsThisWeek >= PerWeek)
            return $"You've already had {PerWeek} extensions in the last 7 days.";
        return null;
    }

    /// Never more than asked, never more than the maximum, never negative.
    public static int ClampedHours(int granted, int asked) => Math.Max(0, Math.Min(Math.Min(granted, asked), MaxHours));
}
