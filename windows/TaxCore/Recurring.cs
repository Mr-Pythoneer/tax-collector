namespace TaxCore;

/// How a repeating task counts: every N days, or every N weeks on chosen days.
public enum RepeatUnit { Days, Weeks }

/// A task that comes back on a schedule — homework for a class you have every
/// Monday, or something every 4 days.
///
/// Only one copy is out at a time. The next appears once the current copy's
/// deadline has passed, however early you paid it, so finishing early doesn't
/// bring next week's work forward. Each copy is an ordinary task with its own
/// proof and the usual 24-hour lock-in.
public sealed class RecurringTask
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Details { get; set; } = "";
    public RepeatUnit Unit { get; set; } = RepeatUnit.Weeks;
    /// Every this many days or weeks.
    public int Interval { get; set; } = 1;
    /// For weeks: the days it's due, as Swift-style weekdays (1 = Sunday … 7 = Saturday).
    public HashSet<int> Weekdays { get; set; } = new();
    /// The time it's due, in minutes after midnight.
    public int MinuteOfDay { get; set; }
    /// The first day it can be due. Every N days counts from here, N weeks from this week.
    public DateTimeOffset StartDate { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    /// When the copy that's out now is due. The next copy appears once this has passed.
    public DateTimeOffset? CurrentDue { get; set; }

    public const int MaxDays = 365;
    public const int MaxWeeks = 52;

    public RecurringTask() { }

    public RecurringTask(string title, int minuteOfDay, DateTimeOffset createdAt, string details = "",
                         RepeatUnit unit = RepeatUnit.Weeks, int interval = 1, IEnumerable<int>? weekdays = null,
                         DateTimeOffset? startDate = null, DateTimeOffset? currentDue = null)
    {
        Title = title;
        Details = details;
        Unit = unit;
        Interval = Math.Max(1, Math.Min(interval, unit == RepeatUnit.Days ? MaxDays : MaxWeeks));
        Weekdays = new(weekdays ?? Enumerable.Empty<int>());
        MinuteOfDay = minuteOfDay;
        StartDate = startDate ?? createdAt;
        CreatedAt = createdAt;
        CurrentDue = currentDue;
    }

    public RecurringTask Clone() => new()
    {
        Id = Id, Title = Title, Details = Details, Unit = Unit, Interval = Interval,
        Weekdays = new(Weekdays), MinuteOfDay = MinuteOfDay, StartDate = StartDate,
        CreatedAt = CreatedAt, CurrentDue = CurrentDue,
    };

    /// Normalises fields that loaded from disk (older files, out-of-range intervals).
    public void Normalise()
    {
        Interval = Math.Max(1, Math.Min(Interval, Unit == RepeatUnit.Days ? MaxDays : MaxWeeks));
        if (StartDate == default) StartDate = CreatedAt;
    }

    /// The first deadline after `date`.
    public DateTimeOffset? NextDue(DateTimeOffset date, Cal? calendar = null)
    {
        var cal = calendar ?? Cal.Current;
        int hour = MinuteOfDay / 60, minute = MinuteOfDay % 60;
        var start = cal.StartOfDay(StartDate);
        switch (Unit)
        {
            case RepeatUnit.Days:
            {
                var today = cal.StartOfDay(date);
                var elapsed = cal.DayDiff(start, today);
                var step = Math.Max(0, elapsed / Interval);
                for (var i = 0; i < 3; i++)
                {
                    var day = cal.AddDays(start, step * Interval);
                    var due = cal.SetTime(day, hour, minute);
                    if (due > date) return due;
                    step += 1;
                }
                return null;
            }
            default: // Weeks
            {
                if (Weekdays.Count == 0) return null;
                var firstWeek = cal.WeekStart(start);
                var day = start > cal.StartOfDay(date) ? start : cal.StartOfDay(date);
                for (var i = 0; i < 7 * Interval + 8; i++)
                {
                    if (Weekdays.Contains(cal.Weekday(day)))
                    {
                        var week = cal.WeekStart(day);
                        var days = cal.DayDiff(firstWeek, week);
                        if (days / 7 % Interval == 0)
                        {
                            var due = cal.SetTime(day, hour, minute);
                            if (due > date) return due;
                        }
                    }
                    day = cal.AddDays(day, 1);
                }
                return null;
            }
        }
    }

    /// "Every Monday at 8:30 AM", "Every 4 days at 9:00 PM",
    /// "Every 2 weeks on Monday and Wednesday at 3:00 PM".
    public string Schedule(Cal? calendar = null)
    {
        var cal = calendar ?? Cal.Current;
        var time = cal.ShortTime(MinuteOfDay);
        switch (Unit)
        {
            case RepeatUnit.Days:
                return Interval == 1 ? $"Every day at {time}" : $"Every {Interval} days at {time}";
            default:
                if (Interval == 1)
                {
                    if (IsEveryDay) return $"Every day at {time}";
                    if (IsWeekdays) return $"Every weekday at {time}";
                    return $"Every {DayNames(cal)} at {time}";
                }
                var days = IsEveryDay ? "every day" : IsWeekdays ? "weekdays" : DayNames(cal);
                return $"Every {Interval} weeks on {days} at {time}";
        }
    }

    private bool IsEveryDay => Weekdays.Count == 7 && Enumerable.Range(1, 7).All(Weekdays.Contains);
    private bool IsWeekdays => Weekdays.Count == 5 && Enumerable.Range(2, 5).All(Weekdays.Contains);

    /// "Monday", "Monday and Wednesday", "Monday, Wednesday and Friday", in the
    /// order this calendar's week starts.
    private string DayNames(Cal cal)
    {
        // Swift: (firstWeekday-1+i)%7+1 with firstWeekday 1=Sun..7=Sat.
        // Here FirstWeekday is DayOfWeek (Sun=0), i.e. Swift's firstWeekday minus 1.
        var order = Enumerable.Range(0, 7)
            .Select(i => ((int)cal.FirstWeekday + i) % 7 + 1)
            .Where(Weekdays.Contains)
            .ToList();
        var names = order.Select(cal.WeekdayName).ToList();
        if (names.Count <= 2) return string.Join(" and ", names);
        return string.Join(", ", names.Take(names.Count - 1)) + " and " + names[^1];
    }
}

public static class Recurrence
{
    /// The first moment after `date` that falls on one of `weekdays` at `minuteOfDay`: an every-week repeat.
    public static DateTimeOffset? NextDue(DateTimeOffset date, IEnumerable<int> weekdays, int minuteOfDay, Cal? calendar = null)
    {
        var series = new RecurringTask("", minuteOfDay, date, weekdays: weekdays, startDate: DateTimeOffset.MinValue);
        return series.NextDue(date, calendar);
    }

    /// The copies that should be out by `now`, and the series with their new current
    /// deadlines. A series whose current copy isn't due yet gets nothing. After a long
    /// gap only the next copy appears, never a backlog of missed ones.
    public static (List<TaxTask> Tasks, List<RecurringTask> Series) NewCopies(
        IEnumerable<RecurringTask> series, DateTimeOffset now, Cal? calendar = null)
    {
        var updated = series.Select(s => s.Clone()).ToList();
        var tasks = new List<TaxTask>();
        foreach (var s in updated)
        {
            if (s.CurrentDue is { } current && current > now) continue;
            var due = s.NextDue(now, calendar);
            if (due == null) continue;
            var copy = new TaxTask(s.Title, due.Value, now, details: s.Details) { SeriesId = s.Id };
            tasks.Add(copy);
            s.CurrentDue = due;
        }
        return (tasks, updated);
    }
}
