using System.Text.Json;
using System.Text.Json.Serialization;

namespace TaxCore;

/// Where a task came from: typed in, or imported from a Blackbaud iCal feed
/// (keyed by the event's UID). Blackbaud import is out of scope for the Windows
/// port's app, but the type stays so saved data and the parent-link state match.
public abstract record TaskSource
{
    public sealed record Manual : TaskSource;
    public sealed record Blackbaud(string Uid) : TaskSource;

    public static readonly TaskSource ManualSource = new Manual();

    public bool IsBlackbaud => this is Blackbaud;
    public string? BlackbaudUid => (this as Blackbaud)?.Uid;
}

public enum Verdict { Accepted, Rejected, Error, GuardianApproved }

/// Claude's answer to a request for more time.
public enum ExtensionDecision { Granted, Denied, Error }

/// One proof the student sent, and how the check went.
public sealed class ProofSubmission
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset SubmittedAt { get; set; }
    public string Note { get; set; } = "";
    /// File names inside this submission's proof folder.
    public List<string> Attachments { get; set; } = new();
    /// null while the auditor is still checking.
    public Verdict? Verdict { get; set; }
    public string Reason { get; set; } = "";
    /// When you last asked for it to be checked again, after a check that couldn't finish.
    public DateTimeOffset? RecheckedAt { get; set; }

    [JsonIgnore]
    public bool IsAccepted => Verdict is TaxCore.Verdict.Accepted or TaxCore.Verdict.GuardianApproved;

    public ProofSubmission Clone() => new()
    {
        Id = Id, SubmittedAt = SubmittedAt, Note = Note, Attachments = new(Attachments),
        Verdict = Verdict, Reason = Reason, RecheckedAt = RecheckedAt,
    };
}

/// One thing the task asks for, ticked off in the last check.
public sealed class ChecklistItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    public bool Done { get; set; }

    public ChecklistItem() { }
    public ChecklistItem(string text, bool done = false) { Text = text; Done = done; }

    public ChecklistItem Clone() => new() { Id = Id, Text = Text, Done = Done };
}

/// A request for more time on a task, and how it went.
public sealed class Extension
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset RequestedAt { get; set; }
    public int HoursAsked { get; set; }
    /// Why the student asked.
    public string Reason { get; set; } = "";
    /// null while Claude is deciding.
    public ExtensionDecision? Decision { get; set; }
    public int HoursGranted { get; set; }
    /// Claude's explanation, to the student.
    public string Answer { get; set; } = "";
    public DateTimeOffset PreviousDue { get; set; }

    public Extension Clone() => new()
    {
        Id = Id, RequestedAt = RequestedAt, HoursAsked = HoursAsked, Reason = Reason,
        Decision = Decision, HoursGranted = HoursGranted, Answer = Answer, PreviousDue = PreviousDue,
    };
}

/// Where marking the assignment Completed in Blackbaud stands.
public abstract record BlackbaudMark
{
    public sealed record Working : BlackbaudMark;
    public sealed record Done(DateTimeOffset At) : BlackbaudMark;
    public sealed record Failed(string Reason) : BlackbaudMark;
}

/// The life of a task.
public abstract record TaskStatus
{
    public sealed record Pending : TaskStatus;
    public sealed record Proven(DateTimeOffset At) : TaskStatus;
    public sealed record ProvenLate(DateTimeOffset At, DateTimeOffset PenaltyEndsAt) : TaskStatus;
    public sealed record Excused(DateTimeOffset At) : TaskStatus;

    public static readonly TaskStatus PendingStatus = new Pending();
    public bool IsPending => this is Pending;
}

public sealed class TaxTask
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Details { get; set; } = "";
    public DateTimeOffset DueDate { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public TaskSource Source { get; set; } = TaskSource.ManualSource;
    public TaskStatus Status { get; set; } = TaskStatus.PendingStatus;
    public List<ProofSubmission> Proofs { get; set; } = new();
    /// Filled in when proof is accepted. null so older saved tasks still load.
    public List<ChecklistItem>? Checklist { get; set; }
    /// When you confirmed every checklist item.
    public DateTimeOffset? LastCheckDoneAt { get; set; }
    public BlackbaudMark? BlackbaudMark { get; set; }
    /// Requests for more time. null so older saved tasks still load.
    public List<Extension>? Extensions { get; set; }
    /// The repeating task this is one copy of.
    public Guid? SeriesId { get; set; }

    public TaxTask() { }

    public TaxTask(string title, DateTimeOffset dueDate, DateTimeOffset createdAt,
                   string details = "", TaskSource? source = null, TaskStatus? status = null,
                   List<ProofSubmission>? proofs = null)
    {
        Title = title;
        Details = details;
        DueDate = dueDate;
        CreatedAt = createdAt;
        Source = source ?? TaskSource.ManualSource;
        Status = status ?? TaskStatus.PendingStatus;
        Proofs = proofs ?? new();
    }

    [JsonIgnore] public bool IsPending => Status.IsPending;
    [JsonIgnore] public bool IsFromBlackbaud => Source.IsBlackbaud;

    /// Paid, but you haven't yet confirmed the checklist and had Blackbaud marked.
    [JsonIgnore]
    public bool NeedsLastCheck
    {
        get
        {
            if (!IsFromBlackbaud || LastCheckDoneAt != null) return false;
            return Status is TaskStatus.Proven or TaskStatus.ProvenLate;
        }
    }

    /// A proof sent in before the deadline that the auditor hasn't ruled on yet.
    /// While one exists the task doesn't count as overdue (for a few minutes at
    /// most, see LockPolicy.CheckGrace), so a slow check can't make you late.
    [JsonIgnore]
    public bool HasCheckInFlightFromBeforeDue =>
        Proofs.Any(p => p.Verdict == null && p.SubmittedAt <= DueDate && (p.RecheckedAt ?? p.SubmittedAt) <= DueDate)
        || (Extensions ?? new()).Any(e => e.Decision == null && e.RequestedAt <= DueDate);

    public TaxTask Clone() => new()
    {
        Id = Id, Title = Title, Details = Details, DueDate = DueDate, CreatedAt = CreatedAt,
        Source = Source, Status = Status,
        Proofs = Proofs.Select(p => p.Clone()).ToList(),
        Checklist = Checklist?.Select(c => c.Clone()).ToList(),
        LastCheckDoneAt = LastCheckDoneAt, BlackbaudMark = BlackbaudMark,
        Extensions = Extensions?.Select(e => e.Clone()).ToList(),
        SeriesId = SeriesId,
    };
}

public sealed class Settings
{
    public int PenaltyMinutes { get; set; } = 30;
    /// Apps the guardian added on top of the built-in allowlist (identity strings).
    public List<string> ExtraAllowedApps { get; set; } = new();
    public string ClaudePath { get; set; } = "";
    public string ClaudeModel { get; set; } = "sonnet";
    public DateTimeOffset? OverrideUntil { get; set; }
    /// Latest time this app has seen, so winding the clock back doesn't undo a deadline.
    public DateTimeOffset? LastSeen { get; set; }
    public int GuardianFailures { get; set; }
    public DateTimeOffset? GuardianLockedUntil { get; set; }
    /// "light" (default), "dark" or "system".
    public string Appearance { get; set; } = "light";
    /// Set just before setup hands over to the background copy.
    public bool JustSetUp { get; set; }
    /// Whether you can ask Claude for up to 12 more hours. Only the guardian can change it.
    public bool ExtensionsEnabled { get; set; } = true;

    public Settings Clone() => new()
    {
        PenaltyMinutes = PenaltyMinutes, ExtraAllowedApps = new(ExtraAllowedApps),
        ClaudePath = ClaudePath, ClaudeModel = ClaudeModel, OverrideUntil = OverrideUntil,
        LastSeen = LastSeen, GuardianFailures = GuardianFailures, GuardianLockedUntil = GuardianLockedUntil,
        Appearance = Appearance, JustSetUp = JustSetUp, ExtensionsEnabled = ExtensionsEnabled,
    };
}

// MARK: Tagged-union JSON converters (match the Mac's nested shape)

internal sealed class TaskSourceConverter : JsonConverter<TaskSource>
{
    public override TaskSource Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.TryGetProperty("blackbaud", out var bb))
            return new TaskSource.Blackbaud(bb.GetProperty("uid").GetString() ?? "");
        return TaskSource.ManualSource;
    }

    public override void Write(Utf8JsonWriter w, TaskSource value, JsonSerializerOptions o)
    {
        w.WriteStartObject();
        switch (value)
        {
            case TaskSource.Blackbaud b:
                w.WritePropertyName("blackbaud");
                w.WriteStartObject();
                w.WriteString("uid", b.Uid);
                w.WriteEndObject();
                break;
            default:
                w.WritePropertyName("manual");
                w.WriteStartObject();
                w.WriteEndObject();
                break;
        }
        w.WriteEndObject();
    }
}

internal sealed class TaskStatusConverter : JsonConverter<TaskStatus>
{
    public override TaskStatus Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.TryGetProperty("proven", out var p))
            return new TaskStatus.Proven(p.GetProperty("at").GetDateTimeOffset());
        if (root.TryGetProperty("provenLate", out var pl))
            return new TaskStatus.ProvenLate(pl.GetProperty("at").GetDateTimeOffset(),
                                             pl.GetProperty("penaltyEndsAt").GetDateTimeOffset());
        if (root.TryGetProperty("excused", out var e))
            return new TaskStatus.Excused(e.GetProperty("at").GetDateTimeOffset());
        return TaskStatus.PendingStatus;
    }

    public override void Write(Utf8JsonWriter w, TaskStatus value, JsonSerializerOptions o)
    {
        w.WriteStartObject();
        switch (value)
        {
            case TaskStatus.Proven p:
                w.WritePropertyName("proven");
                w.WriteStartObject();
                w.WriteString("at", p.At);
                w.WriteEndObject();
                break;
            case TaskStatus.ProvenLate pl:
                w.WritePropertyName("provenLate");
                w.WriteStartObject();
                w.WriteString("at", pl.At);
                w.WriteString("penaltyEndsAt", pl.PenaltyEndsAt);
                w.WriteEndObject();
                break;
            case TaskStatus.Excused e:
                w.WritePropertyName("excused");
                w.WriteStartObject();
                w.WriteString("at", e.At);
                w.WriteEndObject();
                break;
            default:
                w.WritePropertyName("pending");
                w.WriteStartObject();
                w.WriteEndObject();
                break;
        }
        w.WriteEndObject();
    }
}

internal sealed class BlackbaudMarkConverter : JsonConverter<BlackbaudMark>
{
    public override BlackbaudMark Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.TryGetProperty("done", out var d))
            return new BlackbaudMark.Done(d.GetProperty("at").GetDateTimeOffset());
        if (root.TryGetProperty("failed", out var f))
            return new BlackbaudMark.Failed(f.GetProperty("reason").GetString() ?? "");
        return new BlackbaudMark.Working();
    }

    public override void Write(Utf8JsonWriter w, BlackbaudMark value, JsonSerializerOptions o)
    {
        w.WriteStartObject();
        switch (value)
        {
            case BlackbaudMark.Done d:
                w.WritePropertyName("done");
                w.WriteStartObject();
                w.WriteString("at", d.At);
                w.WriteEndObject();
                break;
            case BlackbaudMark.Failed f:
                w.WritePropertyName("failed");
                w.WriteStartObject();
                w.WriteString("reason", f.Reason);
                w.WriteEndObject();
                break;
            default:
                w.WritePropertyName("working");
                w.WriteStartObject();
                w.WriteEndObject();
                break;
        }
        w.WriteEndObject();
    }
}
