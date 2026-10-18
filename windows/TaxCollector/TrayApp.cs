using System.Runtime.InteropServices;
using TaxCore;

namespace TaxCollector;

/// Owns the tray icon, the model, the timer and the windows. Runs on the UI thread.
internal sealed class TrayApp : ApplicationContext
{
    private readonly AppModel _model;
    private readonly NotifyIcon _tray = new();
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 1000 };
    private readonly Form _pump = new() { ShowInTaskbar = false, FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual, Location = new Point(-5000, -5000), Size = new Size(1, 1) };
    private readonly bool _testing;
    private readonly bool _canQuit;
    private MainForm? _main;
    private LockForm? _lock;
    private Icon? _iconOpen, _iconLocked;

    public TrayApp(bool dryRun, bool testing, bool startedByTask)
    {
        _testing = testing;
        _canQuit = dryRun || testing || Environment.GetEnvironmentVariable("TAXCOLLECTOR_ALLOW_QUIT") == "1";
        _ = _pump.Handle; // force handle creation so background work can marshal back

        _model = new AppModel(new Store(), dryRun) { Post = a => { try { if (_pump.IsHandleCreated) _pump.BeginInvoke(a); } catch { } } };

        _iconOpen = MakeIcon(false);
        _iconLocked = MakeIcon(true);
        _tray.Icon = _iconOpen;
        _tray.Visible = true;
        _tray.Text = "Tax Collector";
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowMain(); };
        var menu = new ContextMenuStrip();
        menu.Opening += (_, _) => BuildMenu(menu);
        _tray.ContextMenuStrip = menu;

        _model.OnLockChange = LockChanged;
        _model.OnClosedApp = name => { ShowLockWindow(); Balloon(dryRun ? $"Test mode: would have closed {name}" : $"Closed {name}. Submit proof to unlock."); };
        _model.OnWarning = Warn;
        _model.OnPaid = t => Balloon($"Proof accepted: {t.Title}");
        _model.OnRecurred = t => Balloon($"{t.Title} is due again — {Fmt.DateTime(t.DueDate)}");
        _model.OnChanged = RefreshUi;

        var setupNeeded = !testing && !Setup.IsInstalled();
        _model.Start();

        if (!startedByTask || _model.Guardian == null || setupNeeded)
            ShowMain(setupNeeded);

        _timer.Tick += (_, _) => _model.Tick();
        _timer.Start();
    }

    private void BuildMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();
        menu.Items.Add(new ToolStripLabel(HeaderText()) { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        if (_model.Lock.IsLocked) menu.Items.Add("Submit Proof…", null, (_, _) => ShowLockWindow());
        menu.Items.Add("Open Tax Collector", null, (_, _) => ShowMain());
        menu.Items.Add("New Task…", null, (_, _) => { ShowMain(); using var f = new NewTaskForm(_model); f.ShowDialog(_main); _main?.Refresh2(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Guardian…", null, (_, _) => { using var f = new GuardianForm(_model); f.ShowDialog(_main); RefreshUi(); });
        if (_canQuit)
        {
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit (test mode)", null, (_, _) => { _model.Enforcer.Deactivate(); ExitThread(); });
        }
    }

    private string HeaderText()
    {
        if (_model.Lock.IsLocked)
        {
            if (_model.Lock.Overdue.Count > 0) return $"Locked: {_model.Lock.Overdue.Count} overdue";
            if (_model.Lock.PenaltyEndsAt is { } end) return $"Late penalty until {Fmt.Time(end)}";
        }
        if (_model.Lock.OverrideUntil is { } u) return $"Unlocked until {Fmt.Time(u)}";
        if (_model.NextDue is { } n) return $"Next: {n.Title}, due {Fmt.DateTime(n.DueDate)}";
        return "Nothing due";
    }

    private void ShowMain(bool setupNeeded = false)
    {
        if (_main == null || _main.IsDisposed)
        {
            _main = new MainForm(_model);
        }
        if (setupNeeded) _main.SetupNeeded = true;
        _main.Refresh2();
        _main.Show();
        _main.WindowState = FormWindowState.Normal;
        _main.Activate();
    }

    private void LockChanged(bool locked)
    {
        if (locked) { ShowLockWindow(); Balloon("Your PC is locked. Submit proof to unlock."); }
        else
        {
            _lock?.Close();
            _lock = null;
            Balloon(_model.Lock.OverrideUntil == null ? "Unlocked." : $"Unlocked by your guardian until {Fmt.Time(_model.Lock.OverrideUntil!.Value)}.");
        }
        RefreshUi();
    }

    private void ShowLockWindow()
    {
        if (!_model.Lock.IsLocked) return;
        if (_lock == null || _lock.IsDisposed) _lock = new LockForm(_model);
        _lock.Refresh2();
        _lock.Show();
        _lock.WindowState = FormWindowState.Normal;
        _lock.BringToFront();
        _lock.Activate();
    }

    private void Warn(TaxTask task, TimeSpan remaining)
    {
        var left = Fmt.Span(remaining);
        if (remaining <= TimeSpan.FromMinutes(5)) Balloon($"Locking in {left} unless \"{task.Title}\" has proof. Save your work.");
        else Balloon($"\"{task.Title}\" is due in {left}. Submit proof before then.");
    }

    private void RefreshUi()
    {
        _tray.Icon = _model.Lock.IsLocked ? _iconLocked : _iconOpen;
        var text = HeaderText();
        _tray.Text = text.Length > 62 ? text[..62] : text;
        if (_main is { Visible: true, IsDisposed: false }) _main.Refresh2();
        if (_lock is { IsDisposed: false }) _lock.Refresh2();
        if (_model.Lock.IsLocked) ShowLockWindow();
    }

    private void Balloon(string text)
    {
        if (_model.DryRun || _testing) { return; }
        try { _tray.ShowBalloonTip(4000, "Tax Collector", text, ToolTipIcon.Info); } catch { }
    }

    private static Icon MakeIcon(bool locked)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var br = new SolidBrush(locked ? Color.FromArgb(178, 34, 34) : Color.FromArgb(40, 90, 160));
            g.FillEllipse(br, 2, 2, 28, 28);
            using var f = new Font("Segoe UI", 15f, FontStyle.Bold, GraphicsUnit.Pixel);
            using var tb = new SolidBrush(Color.White);
            g.DrawString(locked ? "🔒" : "$", f, tb, new RectangleF(0, 3, 32, 28),
                new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
        }
        var h = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(h).Clone();
        DestroyIcon(h);
        return icon;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
            _iconOpen?.Dispose();
            _iconLocked?.Dispose();
            _pump.Dispose();
        }
        base.Dispose(disposing);
    }
}
