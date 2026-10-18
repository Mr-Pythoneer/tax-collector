using System.Text;

namespace TaxCore;

/// Plain JSON files in one folder. On Windows this is %LOCALAPPDATA%\TaxCollector;
/// TAXCOLLECTOR_DATA_DIR points it elsewhere for testing.
public sealed class Store
{
    public string Dir { get; }

    public Store(string? dir = null)
    {
        if (dir != null)
            Dir = dir;
        else if (Environment.GetEnvironmentVariable("TAXCOLLECTOR_DATA_DIR") is { Length: > 0 } env)
            Dir = Environment.ExpandEnvironmentVariables(env);
        else
            Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TaxCollector");
        Directory.CreateDirectory(Dir);
    }

    private string TasksPath => Path.Combine(Dir, "tasks.json");
    private string SettingsPath => Path.Combine(Dir, "settings.json");
    private string GuardianPath => Path.Combine(Dir, "guardian.json");
    private string RecurringPath => Path.Combine(Dir, "recurring.json");
    public string LogPath => Path.Combine(Dir, "events.log");
    public string ProofsRoot => Path.Combine(Dir, "proofs");

    public List<TaxTask> LoadTasks() => Load<List<TaxTask>>(TasksPath) ?? new();
    public void SaveTasks(List<TaxTask> tasks) => Save(tasks, TasksPath);

    public Settings LoadSettings() => Load<Settings>(SettingsPath) ?? new();
    public void SaveSettings(Settings settings) => Save(settings, SettingsPath);

    public GuardianRecord? LoadGuardian() => Load<GuardianRecord>(GuardianPath);
    public void SaveGuardian(GuardianRecord record) => Save(record, GuardianPath);

    public List<RecurringTask> LoadRecurring()
    {
        var list = Load<List<RecurringTask>>(RecurringPath) ?? new();
        foreach (var s in list) s.Normalise();
        return list;
    }
    public void SaveRecurring(List<RecurringTask> series) => Save(series, RecurringPath);

    public string ProofFolder(Guid task, Guid submission)
    {
        var url = Path.Combine(ProofsRoot, task.ToString(), submission.ToString());
        Directory.CreateDirectory(url);
        return url;
    }

    public void Log(string message, DateTimeOffset? at = null)
    {
        var line = $"{(at ?? DateTimeOffset.Now):yyyy-MM-ddTHH:mm:sszzz}  {Sanitise(message)}\n";
        try { File.AppendAllText(LogPath, line, Encoding.UTF8); } catch { /* best effort */ }
    }

    public List<string> RecentLog(int lines = 200)
    {
        try
        {
            var all = File.ReadAllText(LogPath, Encoding.UTF8).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            return all.Reverse().Take(lines).ToList();
        }
        catch { return new(); }
    }

    /// Log lines are single lines: strip the newlines an injected value might carry.
    private static string Sanitise(string s) => s.Replace("\r", " ").Replace("\n", " ");

    private T? Load<T>(string path) where T : class
    {
        if (!File.Exists(path)) return null;
        try
        {
            return Json.Decode<T>(File.ReadAllText(path, Encoding.UTF8));
        }
        catch (Exception ex)
        {
            // Keep the unreadable file instead of silently overwriting it next save.
            try { File.Copy(path, path + $".corrupt-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}"); } catch { }
            Log($"could not read {Path.GetFileName(path)}: {ex.Message}");
            return null;
        }
    }

    private void Save<T>(T value, string path)
    {
        try
        {
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, Json.Encode(value), Encoding.UTF8);
            File.Move(tmp, path, overwrite: true);
        }
        catch { /* best effort */ }
    }
}
