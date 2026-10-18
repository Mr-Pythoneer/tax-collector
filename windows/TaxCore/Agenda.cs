namespace TaxCore;

/// The task list as a planner: what's charging a late fee, what's overdue, then
/// one section per day.
public sealed class AgendaSection
{
    public abstract record SectionKind
    {
        public sealed record LateFee : SectionKind;
        public sealed record Overdue : SectionKind;
        /// The start of that day.
        public sealed record Day(DateTimeOffset Start) : SectionKind;
    }

    public SectionKind Kind { get; }
    /// Soonest due first.
    public List<TaxTask> Tasks { get; }

    public AgendaSection(SectionKind kind, List<TaxTask> tasks)
    {
        Kind = kind;
        Tasks = tasks;
    }
}

public static class Agenda
{
    /// Owed tasks ranked by when they're due, grouped by day. Settled tasks aren't included.
    public static List<AgendaSection> Sections(IEnumerable<TaxTask> tasks, DateTimeOffset now, Cal? calendar = null)
    {
        var cal = calendar ?? Cal.Current;
        var list = tasks as IList<TaxTask> ?? tasks.ToList();

        Comparison<TaxTask> byDue = (a, b) =>
            a.DueDate != b.DueDate
                ? a.DueDate.CompareTo(b.DueDate)
                : string.Compare(a.Title, b.Title, StringComparison.CurrentCulture);

        var sections = new List<AgendaSection>();

        var lateFee = list.Where(t => LockPolicy.IsInPenalty(t, now)).ToList();
        lateFee.Sort(byDue);
        if (lateFee.Count > 0) sections.Add(new AgendaSection(new AgendaSection.SectionKind.LateFee(), lateFee));

        var pending = list.Where(t => t.IsPending).ToList();
        pending.Sort(byDue);
        var overdue = pending.Where(t => t.DueDate <= now).ToList();
        if (overdue.Count > 0) sections.Add(new AgendaSection(new AgendaSection.SectionKind.Overdue(), overdue));

        var dayOrder = new List<DateTimeOffset>();
        var days = new Dictionary<DateTimeOffset, List<TaxTask>>();
        foreach (var task in pending.Where(t => t.DueDate > now))
        {
            var day = cal.StartOfDay(task.DueDate);
            if (!days.ContainsKey(day)) { days[day] = new(); dayOrder.Add(day); }
            days[day].Add(task);
        }
        foreach (var day in dayOrder) sections.Add(new AgendaSection(new AgendaSection.SectionKind.Day(day), days[day]));
        return sections;
    }

    /// Your own typed-in tasks have no course, so the whole title leads. (Blackbaud
    /// import, which splits "Course - CODE - Section: Title", is out of scope on Windows.)
    public static (string? Course, string Title) CourseAndTitle(TaxTask task) => (null, task.Title);
}
