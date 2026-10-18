using System.Diagnostics;
using TaxCore;

namespace TaxCollector;

/// While active, closes every top-level app window that isn't allowed. Watches
/// for new/foreground windows with SetWinEventHook and also sweeps every second.
/// Must live on the UI thread (the WinForms message loop drives the hook and timer).
internal sealed class Enforcer
{
    /// Graceful WM_CLOSE first; kill the process tree if it's still around after this long.
    public static readonly TimeSpan ForceAfter = TimeSpan.FromSeconds(10);

    public bool IsActive { get; private set; }
    public bool DryRun { get; }

    public Func<AppIdentity, bool> IsAllowed { get; set; } = _ => true;
    /// Testing aid: when set, only apps whose image name or package family is in
    /// this set are ever closed, so a real lock can be exercised without closing
    /// everything else that's open.
    public HashSet<string>? OnlyTargets { get; set; }
    public Action<string> OnClosed { get; set; } = _ => { };
    public Action<string> Log { get; set; } = _ => { };

    private readonly uint _selfPid = (uint)Environment.ProcessId;
    private System.Windows.Forms.Timer? _timer;
    private Interop.WinEventDelegate? _winEvent;
    private IntPtr _hook;
    private readonly Dictionary<uint, DateTimeOffset> _askedToQuit = new();
    private readonly HashSet<uint> _dryRunSeen = new();

    public Enforcer(bool dryRun) => DryRun = dryRun;

    public void Activate()
    {
        if (IsActive) return;
        IsActive = true;
        _winEvent = OnWinEvent;
        _hook = Interop.SetWinEventHook(Interop.EVENT_SYSTEM_FOREGROUND, Interop.EVENT_OBJECT_SHOW,
            IntPtr.Zero, _winEvent, 0, 0, Interop.WINEVENT_OUTOFCONTEXT | Interop.WINEVENT_SKIPOWNPROCESS);
        _timer = new System.Windows.Forms.Timer { Interval = 1000 };
        _timer.Tick += (_, _) => Sweep();
        _timer.Start();
        Sweep();
    }

    public void Deactivate()
    {
        if (!IsActive) return;
        IsActive = false;
        _timer?.Stop();
        _timer?.Dispose();
        _timer = null;
        if (_hook != IntPtr.Zero) { Interop.UnhookWinEvent(_hook); _hook = IntPtr.Zero; }
        _winEvent = null;
        _askedToQuit.Clear();
        _dryRunSeen.Clear();
    }

    private void OnWinEvent(IntPtr hook, uint type, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (idObject != 0) return; // OBJID_WINDOW only
        Sweep();
    }

    public void Sweep()
    {
        if (!IsActive) return;

        // One pass over the top-level windows: collect windows to close, by process.
        var targets = new Dictionary<uint, (AppIdentity Identity, List<IntPtr> Windows)>();
        Interop.EnumWindows((hWnd, _) =>
        {
            if (!IsManagedTopLevel(hWnd)) return true;
            var (pid, identity) = IdentityResolver.Resolve(hWnd);
            if (pid == 0 || pid == _selfPid) return true;
            if (identity.IsSystemCritical) return true;
            if (IsAllowed(identity)) return true;
            if (OnlyTargets is { } only && !only.Contains(identity.ImageLower) &&
                (identity.PackageFamily == null || !only.Contains(identity.PackageFamily)))
                return true;
            if (!targets.TryGetValue(pid, out var entry))
            {
                entry = (identity, new List<IntPtr>());
                targets[pid] = entry;
            }
            entry.Windows.Add(hWnd);
            return true;
        }, IntPtr.Zero);

        var live = new HashSet<uint>();
        foreach (var p in Process.GetProcesses())
        {
            try { live.Add((uint)p.Id); } catch { }
            finally { p.Dispose(); }
        }
        foreach (var pid in _askedToQuit.Keys.ToList())
            if (!live.Contains(pid)) _askedToQuit.Remove(pid);

        foreach (var (pid, (identity, windows)) in targets)
            Collect(pid, identity, windows);
    }

    private static bool IsManagedTopLevel(IntPtr hWnd)
    {
        if (!Interop.IsWindowVisible(hWnd)) return false;
        if (Interop.GetWindow(hWnd, Interop.GW_OWNER) != IntPtr.Zero) return false;
        var ex = Interop.GetExStyle(hWnd);
        if ((ex & Interop.WS_EX_TOOLWINDOW) != 0) return false;
        if (Interop.DwmGetWindowAttribute(hWnd, Interop.DWMWA_CLOAKED, out var cloaked, sizeof(int)) == 0 && cloaked != 0)
            return false;
        return true;
    }

    private void Collect(uint pid, AppIdentity identity, List<IntPtr> windows)
    {
        var name = FriendlyName(pid, identity);
        var id = identity.PackageFamily ?? identity.ImageName;

        if (DryRun)
        {
            if (_dryRunSeen.Add(pid))
            {
                Log($"DRY RUN would close {name} ({id})");
                OnClosed(name);
            }
            return;
        }

        if (_askedToQuit.TryGetValue(pid, out var asked))
        {
            if (DateTimeOffset.UtcNow - asked >= ForceAfter)
            {
                try
                {
                    using var p = Process.GetProcessById((int)pid);
                    p.Kill(entireProcessTree: true);
                    Log($"FORCE-CLOSED {name} ({id})");
                }
                catch { /* already gone */ }
                _askedToQuit.Remove(pid);
            }
        }
        else
        {
            _askedToQuit[pid] = DateTimeOffset.UtcNow;
            foreach (var w in windows) Interop.PostMessage(w, Interop.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            Log($"CLOSED {name} ({id})");
            OnClosed(name);
        }
    }

    private static string FriendlyName(uint pid, AppIdentity identity)
    {
        try
        {
            using var p = Process.GetProcessById((int)pid);
            if (!string.IsNullOrEmpty(p.ProcessName)) return p.ProcessName;
        }
        catch { }
        var n = identity.ImageName;
        return n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? n[..^4] : n;
    }
}
