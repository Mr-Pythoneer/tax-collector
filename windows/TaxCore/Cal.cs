using System.Globalization;

namespace TaxCore;

/// A small calendar, standing in for the bits of Swift's `Calendar` the rules use:
/// day and week boundaries in a timezone, with a chosen first day of the week.
/// Weekdays follow Swift's convention: 1 = Sunday … 7 = Saturday.
public readonly struct Cal
{
    public TimeZoneInfo Zone { get; }
    public DayOfWeek FirstWeekday { get; }
    public CultureInfo Culture { get; }

    public Cal(TimeZoneInfo? zone = null, DayOfWeek? firstWeekday = null, CultureInfo? culture = null)
    {
        Zone = zone ?? TimeZoneInfo.Local;
        Culture = culture ?? CultureInfo.CurrentCulture;
        FirstWeekday = firstWeekday ?? Culture.DateTimeFormat.FirstDayOfWeek;
    }

    public static Cal Current => new();

    /// Wall-clock date/time in this zone for an instant.
    public DateTime Wall(DateTimeOffset instant) => TimeZoneInfo.ConvertTime(instant, Zone).DateTime;

    /// The instant of a wall-clock moment in this zone.
    public DateTimeOffset Instant(int year, int month, int day, int hour = 0, int minute = 0)
    {
        var local = new DateTime(year, month, day, hour, minute, 0, DateTimeKind.Unspecified);
        return new DateTimeOffset(local, Zone.GetUtcOffset(local));
    }

    public DateTimeOffset StartOfDay(DateTimeOffset instant)
    {
        var d = Wall(instant).Date;
        return Instant(d.Year, d.Month, d.Day);
    }

    public DateTimeOffset SetTime(DateTimeOffset dayInstant, int hour, int minute)
    {
        var d = Wall(dayInstant).Date;
        return Instant(d.Year, d.Month, d.Day, hour, minute);
    }

    public DateTimeOffset AddDays(DateTimeOffset instant, int days)
    {
        var d = Wall(instant).Date.AddDays(days);
        return Instant(d.Year, d.Month, d.Day);
    }

    /// 1 = Sunday … 7 = Saturday, matching Swift's Calendar.component(.weekday).
    public int Weekday(DateTimeOffset instant) => (int)Wall(instant).DayOfWeek + 1;

    /// Start of the week (respecting FirstWeekday) containing this instant.
    public DateTimeOffset WeekStart(DateTimeOffset instant)
    {
        var d = Wall(instant).Date;
        int back = ((int)d.DayOfWeek - (int)FirstWeekday + 7) % 7;
        var start = d.AddDays(-back);
        return Instant(start.Year, start.Month, start.Day);
    }

    /// Whole calendar days from `a` to `b` (b - a), by local date.
    public int DayDiff(DateTimeOffset a, DateTimeOffset b)
    {
        var da = DateOnly.FromDateTime(Wall(a).Date);
        var db = DateOnly.FromDateTime(Wall(b).Date);
        return db.DayNumber - da.DayNumber;
    }

    public string ShortTime(int minuteOfDay)
    {
        var dt = new DateTime(2001, 1, 1, minuteOfDay / 60, minuteOfDay % 60, 0);
        // Normalise any narrow no-break space before AM/PM to a plain space.
        return dt.ToString("h:mm tt", Culture).Replace(' ', ' ').Replace(' ', ' ');
    }

    public string WeekdayName(int swiftWeekday) => Culture.DateTimeFormat.DayNames[(swiftWeekday - 1 + 7) % 7];
}
