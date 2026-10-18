using System.Text.Json;

namespace TaxCore;

/// How much a parent lock closes. `homework` keeps the allowed apps open; `all`
/// closes everything except the system and Tax Collector.
public enum LockStrength { Homework, All }

/// An app, by identity, with the name to show for it.
public sealed record AppRef(string Id, string Name);

/// A typed parent action (docs/parent-link-v1.md §7).
public abstract record ParentAction
{
    public sealed record Lock(DateTimeOffset? Until, LockStrength Strength, string? Note) : ParentAction;
    public sealed record Free(DateTimeOffset Until) : ParentAction;
    public sealed record Normal : ParentAction;
    public sealed record AddTask(Guid Id, string Title, string Details, DateTimeOffset Due) : ParentAction;
    public sealed record EditTask(Guid Id, string? Title, string? Details, DateTimeOffset? Due) : ParentAction;
    public sealed record DeleteTask(Guid Id) : ParentAction;
    public sealed record ExcuseTask(Guid Id) : ParentAction;
    public sealed record ApproveProof(Guid TaskId, Guid ProofId) : ParentAction;
    public sealed record AddRepeat(RecurringTask Repeat) : ParentAction;
    public sealed record StopRepeat(Guid Id) : ParentAction;
    public sealed record AllowApp(AppRef App) : ParentAction;
    public sealed record DisallowApp(AppRef App) : ParentAction;
    public sealed record BlockApp(AppRef App) : ParentAction;
    public sealed record UnblockApp(AppRef App) : ParentAction;
    public sealed record SetPenalty(int Minutes) : ParentAction;
    public sealed record SetExtensions(bool Enabled) : ParentAction;
    public sealed record Message(string Text) : ParentAction;
    public sealed record RemoveDevice(string Id) : ParentAction;
    public sealed record AllowGuardianSetup(DateTimeOffset Until) : ParentAction;

    /// The setting a command writes, for "the latest issued wins". null for one-off actions.
    public string? Setting => this switch
    {
        Lock or Free or Normal => "access",
        AllowApp a => "app:" + a.App.Id,
        DisallowApp a => "app:" + a.App.Id,
        BlockApp a => "app:" + a.App.Id,
        UnblockApp a => "app:" + a.App.Id,
        SetPenalty => "penalty",
        SetExtensions => "extensions",
        _ => null,
    };
}

/// One command from a parent's phone, after it passed the gate (§5.1, §7).
public sealed class ParentCommand
{
    public string Channel { get; init; } = "";
    public string Device { get; init; } = "";
    /// The phone's counter, `n`.
    public long Counter { get; init; }
    /// When the phone made it, in ms.
    public long IssuedAt { get; init; }
    public string Id { get; init; } = "";
    public string Type { get; init; } = "";
    /// null when this app doesn't know the type: answered "unsupported".
    public ParentAction? Action { get; set; }
}

public enum CommandRejection { BadBox, BadSignature, WrongTarget, Replayed, Stale, BadArgs, UnknownDevice }

public static class CommandRejectionExtensions
{
    public static string Wire(this CommandRejection r) => r switch
    {
        CommandRejection.BadBox => "bad_box",
        CommandRejection.BadSignature => "bad_signature",
        CommandRejection.WrongTarget => "wrong_target",
        CommandRejection.Replayed => "replayed",
        CommandRejection.Stale => "stale",
        CommandRejection.BadArgs => "bad_args",
        CommandRejection.UnknownDevice => "unknown_device",
        _ => "bad_args",
    };
}

/// Why the gate turned a command away. `Command` is set when the signature was
/// good, so the answer can name it.
public sealed record GateRejection(CommandRejection Reason, ParentCommand? Command = null);

/// The result of admitting a command: either an accepted command or a rejection.
public sealed class GateResult
{
    public ParentCommand? Command { get; }
    public GateRejection? Rejection { get; }
    public bool Ok => Rejection == null;

    private GateResult(ParentCommand? c, GateRejection? r) { Command = c; Rejection = r; }
    public static GateResult Accept(ParentCommand c) => new(c, null);
    public static GateResult Reject(CommandRejection r, ParentCommand? c = null) => new(null, new GateRejection(r, c));
}

public static class CommandGate
{
    /// How far the phone's clock and the server's receive time may disagree.
    public const long Freshness = 10 * 60 * 1000;

    public static readonly HashSet<string> Known = new()
    {
        "lock", "free", "normal", "addTask", "editTask", "deleteTask", "excuseTask", "approveProof",
        "addRepeat", "stopRepeat", "allowApp", "disallowApp", "blockApp", "unblockApp",
        "setPenalty", "setExtensions", "message", "removeDevice", "allowGuardianSetup",
    };

    /// Opens the box, checks the signature over the exact bytes, then the target,
    /// the counter and freshness. Nothing is applied here.
    public static GateResult Admit(byte[] box, byte[] linkKey, byte[] signKey, string channel, string device,
                                   long receivedAt, long lastCounter, Cal? calendar = null)
    {
        byte[] opened;
        try { opened = LinkCrypto.Open(box, linkKey, LinkCrypto.CommandAad(channel, device)); }
        catch (LinkCrypto.LinkException) { return GateResult.Reject(CommandRejection.BadBox); }
        if (opened.Length <= 64) return GateResult.Reject(CommandRejection.BadBox);

        var signature = opened[..64];
        var body = opened[64..];
        if (!LinkCrypto.IsValidSignature(signature, body, signKey)) return GateResult.Reject(CommandRejection.BadSignature);

        JsonElement f;
        try { f = JsonDocument.Parse(body).RootElement; }
        catch { return GateResult.Reject(CommandRejection.BadArgs); }
        if (f.ValueKind != JsonValueKind.Object) return GateResult.Reject(CommandRejection.BadArgs);

        if (Int(f, "v") != 1 || Str(f, "ch") is not { } ch || Str(f, "dev") is not { } dev
            || Int(f, "n") is not { } n || Int(f, "at") is not { } at
            || Str(f, "id") is not { } id || Str(f, "type") is not { } type)
            return GateResult.Reject(CommandRejection.BadArgs);

        var command = new ParentCommand { Channel = ch, Device = dev, Counter = n, IssuedAt = at, Id = id, Type = type };
        if (ch != channel || dev != device) return GateResult.Reject(CommandRejection.WrongTarget, command);
        if (n <= lastCounter) return GateResult.Reject(CommandRejection.Replayed, command);
        if (Math.Abs(receivedAt - at) > Freshness) return GateResult.Reject(CommandRejection.Stale, command);
        if (!Known.Contains(type)) return GateResult.Accept(command); // unsupported, but a valid command

        var args = f.TryGetProperty("args", out var a) && a.ValueKind == JsonValueKind.Object ? a : default;
        var action = Parse(type, args, calendar ?? Cal.Current);
        if (action == null) return GateResult.Reject(CommandRejection.BadArgs, command);
        command.Action = action;
        return GateResult.Accept(command);
    }

    /// The arguments of a known type, checked. null if they're wrong.
    public static ParentAction? Parse(string type, JsonElement args, Cal cal)
    {
        switch (type)
        {
            case "lock":
            {
                if (Str(args, "strength") is not { } sv || !TryStrength(sv, out var strength)) return null;
                DateTimeOffset? until = null;
                if (Has(args, "until") && !IsNull(args, "until"))
                {
                    if (Int(args, "until") is not { } ms) return null;
                    until = Date(ms);
                }
                var note = Str(args, "note");
                if ((note?.Length ?? 0) > 300) return null;
                return new ParentAction.Lock(until, strength, note);
            }
            case "free":
                return Int(args, "until") is { } f ? new ParentAction.Free(Date(f)) : null;
            case "normal":
                return new ParentAction.Normal();
            case "addTask":
            {
                if (!Obj(args, "task", out var task)) return null;
                if (Uuid(task, "id") is not { } id || Text(task, "title", 200) is not { } title || title.Length == 0
                    || Int(task, "due") is not { } due) return null;
                return new ParentAction.AddTask(id, title, Text(task, "details", 2000) ?? "", Date(due));
            }
            case "editTask":
            {
                if (Uuid(args, "id") is not { } id) return null;
                var title = Text(args, "title", 200);
                if (Has(args, "title") && string.IsNullOrEmpty(title)) return null;
                if (Has(args, "details") && Text(args, "details", 2000) == null) return null;
                if (Has(args, "due") && Int(args, "due") == null) return null;
                return new ParentAction.EditTask(id, title, Text(args, "details", 2000),
                    Int(args, "due") is { } d ? Date(d) : null);
            }
            case "deleteTask":
                return Uuid(args, "id") is { } d2 ? new ParentAction.DeleteTask(d2) : null;
            case "excuseTask":
                return Uuid(args, "id") is { } e2 ? new ParentAction.ExcuseTask(e2) : null;
            case "approveProof":
                return Uuid(args, "taskId") is { } tid && Uuid(args, "proofId") is { } pid
                    ? new ParentAction.ApproveProof(tid, pid) : null;
            case "addRepeat":
            {
                if (!Obj(args, "repeat", out var r)) return null;
                if (Uuid(r, "id") is not { } id || Text(r, "title", 200) is not { } title || title.Length == 0
                    || Str(r, "unit") is not { } us || !TryUnit(us, out var unit)
                    || Int(r, "interval") is not { } interval || interval < 1
                    || interval > (unit == RepeatUnit.Days ? RecurringTask.MaxDays : RecurringTask.MaxWeeks)
                    || Int(r, "minuteOfDay") is not { } minute || minute < 0 || minute >= 1440
                    || Day(r, "startDate", cal) is not { } start) return null;
                var weekdays = new HashSet<int>();
                if (r.TryGetProperty("weekdays", out var wd) && wd.ValueKind == JsonValueKind.Array)
                    foreach (var el in wd.EnumerateArray())
                        if (el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out var day)) weekdays.Add(day);
                if (!weekdays.All(d => d is >= 1 and <= 7) || (unit == RepeatUnit.Weeks && weekdays.Count == 0)) return null;
                return new ParentAction.AddRepeat(new RecurringTask(title, (int)minute, start,
                    details: Text(r, "details", 2000) ?? "", unit: unit, interval: (int)interval,
                    weekdays: unit == RepeatUnit.Weeks ? weekdays : Enumerable.Empty<int>(), startDate: start) { Id = id });
            }
            case "stopRepeat":
                return Uuid(args, "id") is { } s2 ? new ParentAction.StopRepeat(s2) : null;
            case "allowApp" or "disallowApp" or "blockApp" or "unblockApp":
            {
                if (!Obj(args, "app", out var a) || Text(a, "id", 300) is not { } id || id.Length == 0) return null;
                var app = new AppRef(id, Text(a, "name", 100) ?? id);
                return type switch
                {
                    "allowApp" => new ParentAction.AllowApp(app),
                    "disallowApp" => new ParentAction.DisallowApp(app),
                    "blockApp" => new ParentAction.BlockApp(app),
                    _ => new ParentAction.UnblockApp(app),
                };
            }
            case "setPenalty":
                return Int(args, "minutes") is { } m && m is >= 0 and <= 720 ? new ParentAction.SetPenalty((int)m) : null;
            case "setExtensions":
                return Bool(args, "enabled") is { } en ? new ParentAction.SetExtensions(en) : null;
            case "message":
            {
                var t = Text(args, "text", 300);
                return t != null && t.Trim().Length > 0 ? new ParentAction.Message(t) : null;
            }
            case "allowGuardianSetup":
                return Int(args, "until") is { } ms2 ? new ParentAction.AllowGuardianSetup(Date(ms2)) : null;
            case "removeDevice":
                return Str(args, "id") is { Length: > 0 } rid ? new ParentAction.RemoveDevice(rid) : null;
            default:
                return null;
        }
    }

    // MARK: Reading JSON strictly

    private static bool Has(JsonElement o, string k) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(k, out _);
    private static bool IsNull(JsonElement o, string k) =>
        o.ValueKind == JsonValueKind.Object && o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Null;

    private static long? Int(JsonElement o, string k)
    {
        if (o.ValueKind != JsonValueKind.Object || !o.TryGetProperty(k, out var v) || v.ValueKind != JsonValueKind.Number)
            return null;
        // Integer only: reject fractions, matching the Mac's strict reading.
        return v.TryGetInt64(out var n) && v.TryGetDouble(out var d) && Math.Floor(d) == d ? n : null;
    }

    private static bool? Bool(JsonElement o, string k)
    {
        if (o.ValueKind != JsonValueKind.Object || !o.TryGetProperty(k, out var v)) return null;
        return v.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };
    }

    private static string? Str(JsonElement o, string k) =>
        o.ValueKind == JsonValueKind.Object && o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;

    private static string? Text(JsonElement o, string k, int max)
    {
        var s = Str(o, k);
        return s != null && s.Length <= max ? s : null;
    }

    private static bool Obj(JsonElement o, string k, out JsonElement value)
    {
        if (o.ValueKind == JsonValueKind.Object && o.TryGetProperty(k, out value) && value.ValueKind == JsonValueKind.Object)
            return true;
        value = default;
        return false;
    }

    private static Guid? Uuid(JsonElement o, string k) =>
        Str(o, k) is { } s && Guid.TryParseExact(s, "D", out var g) ? g : null;

    private static DateTimeOffset Date(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms);

    /// "YYYY-MM-DD", the start of that day in the computer's time zone.
    private static DateTimeOffset? Day(JsonElement o, string k, Cal cal)
    {
        var s = Str(o, k);
        if (s == null || s.Length != 10) return null;
        var parts = s.Split('-');
        if (parts.Length != 3 || !int.TryParse(parts[0], out var y) || !int.TryParse(parts[1], out var mo)
            || !int.TryParse(parts[2], out var d)) return null;
        try { return cal.Instant(y, mo, d); } catch { return null; }
    }

    private static bool TryStrength(string s, out LockStrength v)
    {
        switch (s) { case "homework": v = LockStrength.Homework; return true; case "all": v = LockStrength.All; return true; }
        v = default; return false;
    }

    private static bool TryUnit(string s, out RepeatUnit v)
    {
        switch (s) { case "days": v = RepeatUnit.Days; return true; case "weeks": v = RepeatUnit.Weeks; return true; }
        v = default; return false;
    }
}
