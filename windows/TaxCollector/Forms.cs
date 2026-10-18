using System.ComponentModel;
using TaxCore;

namespace TaxCollector;

/// Shared formatting helpers.
internal static class Fmt
{
    public static string DateTime(DateTimeOffset d) => d.LocalDateTime.ToString("ddd d MMM, h:mm tt");
    public static string Time(DateTimeOffset d) => d.LocalDateTime.ToString("h:mm tt");

    public static string Span(TimeSpan t)
    {
        if (t < TimeSpan.Zero) t = TimeSpan.Zero;
        if (t.TotalHours >= 24) return $"{(int)t.TotalDays}d {t.Hours}h";
        if (t.TotalHours >= 1) return $"{(int)t.TotalHours}h {t.Minutes}m";
        if (t.TotalMinutes >= 1) return $"{(int)t.TotalMinutes}m";
        return $"{(int)t.TotalSeconds}s";
    }
}

/// The main task list.
internal sealed class MainForm : Form
{
    private readonly AppModel _model;
    private readonly ListView _list = new();
    private readonly Label _status = new();
    private readonly Panel _setup = new();

    public MainForm(AppModel model)
    {
        _model = model;
        Text = "Tax Collector";
        Width = 720; Height = 640;
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9f);

        _status.Dock = DockStyle.Top; _status.Height = 46; _status.Padding = new Padding(12, 10, 12, 6);
        _status.Font = new Font("Segoe UI", 11f, FontStyle.Bold);

        _setup.Dock = DockStyle.Top; _setup.Height = 56; _setup.BackColor = Color.FromArgb(255, 248, 225);
        _setup.Padding = new Padding(12, 8, 12, 8); _setup.Visible = false;
        var setupLabel = new Label { Text = "Finish setup so Tax Collector keeps running and can lock the PC.", AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft };
        var setupBtn = new Button { Text = "Finish setup", Dock = DockStyle.Right, Width = 120 };
        setupBtn.Click += (_, _) => FinishSetup();
        _setup.Controls.Add(setupLabel); _setup.Controls.Add(setupBtn);

        _list.Dock = DockStyle.Fill; _list.View = View.Details; _list.FullRowSelect = true; _list.MultiSelect = false;
        _list.Columns.Add("Task", 300); _list.Columns.Add("Due", 180); _list.Columns.Add("Status", 200);
        _list.DoubleClick += (_, _) => SubmitForSelected();

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, Padding = new Padding(8) };
        var newTask = new Button { Text = "New Task…", Width = 110, Height = 30 };
        newTask.Click += (_, _) => { using var f = new NewTaskForm(_model); f.ShowDialog(this); Refresh2(); };
        var proof = new Button { Text = "Submit Proof…", Width = 130, Height = 30 };
        proof.Click += (_, _) => SubmitForSelected();
        var guardian = new Button { Text = "Guardian…", Width = 110, Height = 30 };
        guardian.Click += (_, _) => { using var f = new GuardianForm(_model); f.ShowDialog(this); Refresh2(); };
        var log = new Button { Text = "Activity Log…", Width = 120, Height = 30 };
        log.Click += (_, _) => ShowLog();
        buttons.Controls.AddRange(new Control[] { newTask, proof, guardian, log });

        Controls.Add(_list);
        Controls.Add(buttons);
        Controls.Add(_setup);
        Controls.Add(_status);
        Refresh2();
    }

    public bool SetupNeeded;

    public void Refresh2()
    {
        _setup.Visible = SetupNeeded;
        _status.Text = StatusText();
        _list.BeginUpdate();
        _list.Items.Clear();
        foreach (var t in _model.PendingTasks)
        {
            var item = new ListViewItem(t.Title) { Tag = t.Id };
            item.SubItems.Add(Fmt.DateTime(t.DueDate));
            item.SubItems.Add(StatusOf(t));
            if (LockPolicy.IsOverdue(t, _model.Now)) item.ForeColor = Color.Firebrick;
            _list.Items.Add(item);
        }
        foreach (var t in _model.SettledTasks.Take(30))
        {
            var item = new ListViewItem(t.Title) { Tag = t.Id, ForeColor = Color.Gray };
            item.SubItems.Add(Fmt.DateTime(t.DueDate));
            item.SubItems.Add(StatusOf(t));
            _list.Items.Add(item);
        }
        _list.EndUpdate();
    }

    private string StatusText()
    {
        if (_model.Lock.IsLocked)
        {
            if (_model.Lock.Overdue.Count > 0) return $"Locked: {_model.Lock.Overdue.Count} overdue";
            if (_model.Lock.PenaltyEndsAt is { } end) return $"Late penalty until {Fmt.Time(end)}";
        }
        if (_model.Lock.OverrideUntil is { } u) return $"Unlocked by your guardian until {Fmt.Time(u)}";
        if (_model.NextDue is { } n) return $"Next: {n.Title}, due {Fmt.DateTime(n.DueDate)}";
        return "Nothing due";
    }

    private string StatusOf(TaxTask t)
    {
        switch (t.Status)
        {
            case TaskStatus.Proven: return "Paid";
            case TaskStatus.ProvenLate pl: return _model.Now < pl.PenaltyEndsAt ? $"Late penalty until {Fmt.Time(pl.PenaltyEndsAt)}" : "Paid (late)";
            case TaskStatus.Excused: return "Excused";
        }
        if (LockPolicy.IsOverdue(t, _model.Now)) return "Overdue";
        var checking = t.Proofs.Any(p => p.Verdict == null);
        if (checking) return "Checking…";
        var last = t.Proofs.LastOrDefault();
        if (last is { Verdict: Verdict.Rejected }) return "Rejected — try again";
        if (last is { Verdict: Verdict.Error }) return "Couldn't check";
        return $"Due in {Fmt.Span(t.DueDate - _model.Now)}";
    }

    private void SubmitForSelected()
    {
        var id = SelectedId();
        if (id is { } tid && _model.Task(tid) is { IsPending: true }) { using var f = new ProofForm(_model, tid); f.ShowDialog(this); Refresh2(); }
    }

    private Guid? SelectedId() => _list.SelectedItems.Count > 0 && _list.SelectedItems[0].Tag is Guid g ? g : null;

    private void FinishSetup()
    {
        var err = Setup.FinishSetup();
        if (err == null) { MessageBox.Show(this, "Tax Collector is installed and running.", "Setup"); SetupNeeded = false; Refresh2(); }
        else MessageBox.Show(this, err, "Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    private void ShowLog()
    {
        using var f = new Form { Text = "Activity Log", Width = 640, Height = 480, StartPosition = FormStartPosition.CenterParent };
        var box = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font("Consolas", 9f) };
        box.Lines = _model.Store.RecentLog(300).ToArray();
        f.Controls.Add(box);
        f.ShowDialog(this);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        else base.OnFormClosing(e);
    }
}

/// New task, with optional repeats.
internal sealed class NewTaskForm : Form
{
    private readonly AppModel _model;
    private readonly TextBox _title = new() { Width = 360 };
    private readonly TextBox _details = new() { Width = 360, Height = 80, Multiline = true, ScrollBars = ScrollBars.Vertical };
    private readonly DateTimePicker _dueDate = new() { Format = DateTimePickerFormat.Short, Width = 140 };
    private readonly DateTimePicker _dueTime = new() { Format = DateTimePickerFormat.Time, ShowUpDown = true, Width = 100 };
    private readonly CheckBox _repeats = new() { Text = "Repeats" };
    private readonly ComboBox _unit = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 120 };
    private readonly NumericUpDown _interval = new() { Minimum = 1, Maximum = 365, Value = 1, Width = 60 };
    private readonly Label _unitLabel = new() { AutoSize = true };
    private readonly FlowLayoutPanel _weekdays = new() { Width = 360, Height = 28, FlowDirection = FlowDirection.LeftToRight };
    private readonly CheckBox[] _days = new CheckBox[7];

    public NewTaskForm(AppModel model)
    {
        _model = model;
        Text = "New Task";
        Width = 440; Height = 440; StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        Font = new Font("Segoe UI", 9f);

        var now = DateTime.Now.AddHours(1);
        _dueDate.Value = now.Date; _dueTime.Value = now;
        _unit.Items.AddRange(new object[] { "weeks", "days" }); _unit.SelectedIndex = 0;
        _unit.SelectedIndexChanged += (_, _) => UpdateRepeatUi();

        // Day checkboxes, Sunday..Saturday (Swift weekday 1..7).
        var names = new[] { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        for (var i = 0; i < 7; i++) { _days[i] = new CheckBox { Text = names[i], AutoSize = true, Tag = i + 1 }; _weekdays.Controls.Add(_days[i]); }

        _repeats.CheckedChanged += (_, _) => UpdateRepeatUi();

        var y = 14;
        void Row(string label, Control c, int h = 26)
        {
            Controls.Add(new Label { Text = label, Left = 14, Top = y + 3, AutoSize = true });
            c.Left = 120; c.Top = y; Controls.Add(c); y += h + 8;
        }
        Row("Title", _title);
        Row("Details", _details, 80);
        var dueRow = new FlowLayoutPanel { Left = 120, Top = y, Width = 280, Height = 28 };
        dueRow.Controls.Add(_dueDate); dueRow.Controls.Add(_dueTime); Controls.Add(dueRow); Controls.Add(new Label { Text = "Due", Left = 14, Top = y + 3, AutoSize = true }); y += 36;
        Controls.Add(_repeats); _repeats.Left = 120; _repeats.Top = y; _repeats.AutoSize = true; y += 32;
        var rep = new FlowLayoutPanel { Left = 120, Top = y, Width = 290, Height = 28 };
        rep.Controls.Add(new Label { Text = "Every", AutoSize = true, Top = 4 }); rep.Controls.Add(_interval); rep.Controls.Add(_unit);
        Controls.Add(rep); y += 34;
        Controls.Add(_weekdays); _weekdays.Left = 120; _weekdays.Top = y; y += 34;

        var ok = new Button { Text = "Add", DialogResult = DialogResult.OK, Left = 240, Top = y, Width = 80 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Left = 330, Top = y, Width = 80 };
        ok.Click += (_, _) => Commit();
        Controls.Add(ok); Controls.Add(cancel);
        AcceptButton = ok; CancelButton = cancel;
        UpdateRepeatUi();
    }

    private void UpdateRepeatUi()
    {
        var on = _repeats.Checked;
        _interval.Enabled = on; _unit.Enabled = on;
        var weekly = _unit.SelectedIndex == 0;
        _weekdays.Enabled = on && weekly;
        _interval.Maximum = weekly ? 52 : 365;
    }

    private DateTimeOffset Due()
    {
        var d = _dueDate.Value.Date; var t = _dueTime.Value.TimeOfDay;
        return new DateTimeOffset(d + t, TimeZoneInfo.Local.GetUtcOffset(d + t));
    }

    private void Commit()
    {
        if (string.IsNullOrWhiteSpace(_title.Text)) { DialogResult = DialogResult.None; MessageBox.Show(this, "Give the task a title."); return; }
        if (!_repeats.Checked) { _model.AddTask(_title.Text, _details.Text, Due()); return; }
        var unit = _unit.SelectedIndex == 0 ? RepeatUnit.Weeks : RepeatUnit.Days;
        var weekdays = _days.Where(c => c.Checked).Select(c => (int)c.Tag!).ToList();
        if (unit == RepeatUnit.Weeks && weekdays.Count == 0) { DialogResult = DialogResult.None; MessageBox.Show(this, "Pick at least one day."); return; }
        var minuteOfDay = _dueTime.Value.Hour * 60 + _dueTime.Value.Minute;
        _model.AddRecurring(_title.Text, _details.Text, unit, (int)_interval.Value, weekdays, minuteOfDay, Due());
    }
}

/// Submit proof: files or a written account, with Cancel Check while Claude runs.
internal sealed class ProofForm : Form
{
    private readonly AppModel _model;
    private readonly Guid _taskId;
    private readonly RadioButton _filesMode = new() { Text = "Evidence files", Checked = true, AutoSize = true };
    private readonly RadioButton _writtenMode = new() { Text = "Written account", AutoSize = true };
    private readonly ListBox _files = new() { Width = 380, Height = 90 };
    private readonly TextBox _note = new() { Width = 380, Height = 90, Multiline = true, ScrollBars = ScrollBars.Vertical };
    private readonly Label _state = new() { AutoSize = false, Width = 380, Height = 40 };
    private readonly Button _submit = new() { Text = "Submit", Width = 90 };
    private readonly Button _cancelCheck = new() { Text = "Cancel Check", Width = 110, Visible = false };
    private Guid? _submissionId;
    private readonly List<string> _picked = new();

    public ProofForm(AppModel model, Guid taskId)
    {
        _model = model; _taskId = taskId;
        var task = model.Task(taskId);
        Text = $"Submit Proof — {task?.Title}";
        Width = 440; Height = 420; StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        Font = new Font("Segoe UI", 9f);

        var modeRow = new FlowLayoutPanel { Left = 16, Top = 12, Width = 400, Height = 26 };
        modeRow.Controls.Add(_filesMode); modeRow.Controls.Add(_writtenMode);
        _filesMode.CheckedChanged += (_, _) => UpdateMode();
        Controls.Add(modeRow);

        _files.Left = 16; _files.Top = 44; Controls.Add(_files);
        var add = new Button { Text = "Add files…", Left = 16, Top = 140, Width = 100 };
        add.Click += (_, _) => AddFiles();
        Controls.Add(add);

        _note.Left = 16; _note.Top = 44; _note.Visible = false; Controls.Add(_note);
        Controls.Add(new Label { Text = "A written account is only for things a file can't show.", Left = 16, Top = 140, AutoSize = true, Visible = false, Tag = "noteHint" });

        _state.Left = 16; _state.Top = 230; _state.ForeColor = Color.DimGray; Controls.Add(_state);

        _submit.Left = 16; _submit.Top = 300; _submit.Click += (_, _) => Submit();
        _cancelCheck.Left = 116; _cancelCheck.Top = 300; _cancelCheck.Click += (_, _) => CancelCheck();
        var close = new Button { Text = "Close", Left = 326, Top = 300, Width = 90, DialogResult = DialogResult.Cancel };
        Controls.Add(_submit); Controls.Add(_cancelCheck); Controls.Add(close);
        CancelButton = close;

        _model.OnChanged += Refresh2;
        FormClosed += (_, _) => _model.OnChanged -= Refresh2;
        UpdateMode();
    }

    private void UpdateMode()
    {
        var files = _filesMode.Checked;
        _files.Visible = files;
        _note.Visible = !files;
        foreach (Control c in Controls) if (c is Button b && b.Text == "Add files…") b.Visible = files;
    }

    private void AddFiles()
    {
        using var dlg = new OpenFileDialog { Multiselect = true, Title = "Choose evidence files" };
        if (dlg.ShowDialog(this) == DialogResult.OK)
            foreach (var f in dlg.FileNames) { _picked.Add(f); _files.Items.Add(Path.GetFileName(f)); }
    }

    private void Submit()
    {
        if (_filesMode.Checked && _picked.Count == 0) { MessageBox.Show(this, "Add at least one file, or switch to a written account."); return; }
        if (!_filesMode.Checked && _note.Text.Trim().Length < Auditor.MinimumWrittenProof)
        { MessageBox.Show(this, $"Write at least {Auditor.MinimumWrittenProof} characters describing what you did."); return; }
        _model.SubmitProof(_taskId, _filesMode.Checked ? "" : _note.Text, _filesMode.Checked ? _picked : new List<string>());
        _submissionId = _model.LatestProof(_taskId)?.Id;
        _submit.Enabled = false;
        Refresh2();
    }

    private void CancelCheck()
    {
        if (_submissionId is { } sid) _model.CancelCheck(_taskId, sid);
        _submit.Enabled = true;
        Refresh2();
    }

    private void Refresh2()
    {
        if (_submissionId is not { } sid) { _state.Text = ""; _cancelCheck.Visible = false; return; }
        var proof = _model.Task(_taskId)?.Proofs.FirstOrDefault(p => p.Id == sid);
        var checking = proof != null && proof.Verdict == null;
        _cancelCheck.Visible = checking;
        if (checking) { _state.Text = "Checking with Claude…"; return; }
        _state.Text = proof?.Verdict switch
        {
            Verdict.Accepted or Verdict.GuardianApproved => "Accepted. " + proof.Reason,
            Verdict.Rejected => "Rejected. " + proof.Reason,
            Verdict.Error => "Couldn't check: " + proof.Reason,
            _ => "",
        };
        _submit.Enabled = true;
    }
}

/// Guardian gate, then the settings the parent controls.
internal sealed class GuardianForm : Form
{
    private readonly AppModel _model;

    public GuardianForm(AppModel model)
    {
        _model = model;
        Text = "Guardian";
        Width = 460; Height = 520; StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        Font = new Font("Segoe UI", 9f);
        if (_model.Guardian == null) ShowSetCode(); else ShowGate();
    }

    private void Clear() => Controls.Clear();

    private void ShowSetCode()
    {
        Clear();
        Controls.Add(new Label { Text = "Set a guardian code (at least 6 characters). Only a parent should know it.", Left = 16, Top = 16, Width = 420, Height = 40 });
        var a = new TextBox { Left = 16, Top = 64, Width = 300, UseSystemPasswordChar = true };
        var b = new TextBox { Left = 16, Top = 96, Width = 300, UseSystemPasswordChar = true, PlaceholderText = "Repeat" };
        Controls.Add(a); Controls.Add(b);
        var ok = new Button { Text = "Set code", Left = 16, Top = 132, Width = 110 };
        ok.Click += (_, _) =>
        {
            if (a.Text.Length < Guardian.MinimumLength) { MessageBox.Show(this, "At least 6 characters."); return; }
            if (a.Text != b.Text) { MessageBox.Show(this, "The codes don't match."); return; }
            _model.SetupGuardian(a.Text);
            ShowSettings();
        };
        Controls.Add(ok);
    }

    private void ShowGate()
    {
        Clear();
        Controls.Add(new Label { Text = "Enter the guardian code.", Left = 16, Top = 16, AutoSize = true });
        var code = new TextBox { Left = 16, Top = 44, Width = 300, UseSystemPasswordChar = true };
        Controls.Add(code);
        var msg = new Label { Left = 16, Top = 104, Width = 420, ForeColor = Color.Firebrick, AutoSize = false, Height = 40 };
        Controls.Add(msg);
        var ok = new Button { Text = "Unlock panel", Left = 16, Top = 72, Width = 120 };
        ok.Click += (_, _) =>
        {
            switch (_model.CheckGuardian(code.Text))
            {
                case GuardianCheck.Ok: ShowSettings(); break;
                case GuardianCheck.CoolingDown:
                    msg.Text = _model.GuardianCooldownUntil is { } u ? $"Too many tries. Wait until {Fmt.Time(u)}." : "Too many tries."; break;
                default: msg.Text = "Wrong code."; break;
            }
            code.Clear();
        };
        Controls.Add(ok);
        AcceptButton = ok;
    }

    private void ShowSettings()
    {
        Clear();
        var y = 14;
        Label Head(string t) { var l = new Label { Text = t, Left = 14, Top = y, AutoSize = true, Font = new Font("Segoe UI", 10f, FontStyle.Bold) }; Controls.Add(l); y += 26; return l; }

        Head("Lock");
        if (_model.Lock.IsLocked || _model.Lock.OverrideUntil != null)
        {
            var unlock = new Button { Text = "Unlock for 1 hour", Left = 16, Top = y, Width = 150 };
            unlock.Click += (_, _) => { _model.Unlock(1); MessageBox.Show(this, "Unlocked for 1 hour."); };
            var end = new Button { Text = "End unlock", Left = 176, Top = y, Width = 110 };
            end.Click += (_, _) => { _model.EndUnlock(); MessageBox.Show(this, "Unlock ended."); };
            Controls.Add(unlock); Controls.Add(end); y += 38;
        }

        Head("Late penalty (minutes)");
        var penalty = new NumericUpDown { Left = 16, Top = y, Width = 80, Minimum = 0, Maximum = 1440, Value = _model.Settings.PenaltyMinutes };
        penalty.ValueChanged += (_, _) => _model.SetPenalty((int)penalty.Value);
        Controls.Add(penalty); y += 36;

        var ext = new CheckBox { Text = "Allow requests for more time", Left = 14, Top = y, AutoSize = true, Checked = _model.Settings.ExtensionsEnabled };
        ext.CheckedChanged += (_, _) => _model.SetExtensionsEnabled(ext.Checked);
        Controls.Add(ext); y += 32;

        Head("A task");
        var tasks = _model.PendingTasks.ToList();
        var pick = new ComboBox { Left = 16, Top = y, Width = 300, DropDownStyle = ComboBoxStyle.DropDownList };
        foreach (var t in tasks) pick.Items.Add(t.Title);
        if (pick.Items.Count > 0) pick.SelectedIndex = 0;
        Controls.Add(pick); y += 32;
        var excuse = new Button { Text = "Excuse", Left = 16, Top = y, Width = 90 };
        excuse.Click += (_, _) => { if (pick.SelectedIndex >= 0) { _model.Excuse(tasks[pick.SelectedIndex].Id); MessageBox.Show(this, "Excused."); } };
        var approve = new Button { Text = "Approve proof", Left = 112, Top = y, Width = 120 };
        approve.Click += (_, _) => { if (pick.SelectedIndex >= 0) { _model.ApproveLatestProof(tasks[pick.SelectedIndex].Id); MessageBox.Show(this, "Approved."); } };
        Controls.Add(excuse); Controls.Add(approve); y += 40;

        Head("Allowed apps (identity: image name, package family, or publisher)");
        var allowList = new ListBox { Left = 16, Top = y, Width = 300, Height = 70 };
        foreach (var a in _model.Settings.ExtraAllowedApps) allowList.Items.Add(a);
        Controls.Add(allowList); y += 76;
        var allowBox = new TextBox { Left = 16, Top = y, Width = 200 };
        var addAllow = new Button { Text = "Allow", Left = 222, Top = y, Width = 70 };
        addAllow.Click += (_, _) => { if (allowBox.Text.Trim().Length > 0) { _model.AllowApp(allowBox.Text.Trim()); allowList.Items.Add(allowBox.Text.Trim()); allowBox.Clear(); } };
        var removeAllow = new Button { Text = "Remove", Left = 298, Top = y, Width = 80 };
        removeAllow.Click += (_, _) => { if (allowList.SelectedItem is string s) { _model.DisallowApp(s); allowList.Items.Remove(s); } };
        Controls.Add(allowBox); Controls.Add(addAllow); Controls.Add(removeAllow); y += 40;

        var change = new Button { Text = "Change code…", Left = 16, Top = y, Width = 120 };
        change.Click += (_, _) => ShowSetCode();
        var reset = new Button { Text = "Reset clock guard", Left = 146, Top = y, Width = 140 };
        reset.Click += (_, _) => { _model.ResetClockGuard(); MessageBox.Show(this, "Clock guard reset."); };
        var uninstall = new Button { Text = "Uninstall", Left = 296, Top = y, Width = 90, ForeColor = Color.Firebrick };
        uninstall.Click += (_, _) =>
        {
            if (MessageBox.Show(this, "Remove Tax Collector from this PC?", "Uninstall", MessageBoxButtons.YesNo) == DialogResult.Yes)
            { Setup.Uninstall(); _model.Store.Log("GUARDIAN uninstalled Tax Collector"); Application.Exit(); }
        };
        Controls.Add(change); Controls.Add(reset); Controls.Add(uninstall);
    }
}

/// The lock screen. Topmost, cannot be closed by the student while locked.
internal sealed class LockForm : Form
{
    private readonly AppModel _model;
    private readonly Label _heading = new();
    private readonly ListBox _overdue = new();
    private readonly Label _closed = new();

    public LockForm(AppModel model)
    {
        _model = model;
        Text = "Tax Collector — Locked";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        ControlBox = false; MaximizeBox = false; MinimizeBox = false;
        TopMost = true; StartPosition = FormStartPosition.CenterScreen;
        Width = 640; Height = 520; BackColor = Color.White;
        Font = new Font("Segoe UI", 10f);

        _heading.Dock = DockStyle.Top; _heading.Height = 70; _heading.Padding = new Padding(20, 16, 20, 8);
        _heading.Font = new Font("Segoe UI", 15f, FontStyle.Bold);
        _heading.Text = "Your PC is locked";

        _overdue.Left = 20; _overdue.Top = 90; _overdue.Width = 590; _overdue.Height = 200;

        _closed.Left = 20; _closed.Top = 300; _closed.Width = 590; _closed.Height = 80; _closed.ForeColor = Color.DimGray;

        var submit = new Button { Text = "Submit Proof…", Left = 20, Top = 400, Width = 160, Height = 36 };
        submit.Click += (_, _) => SubmitForSelected();
        var guardian = new Button { Text = "Ask a parent…", Left = 190, Top = 400, Width = 160, Height = 36 };
        guardian.Click += (_, _) => { using var f = new GuardianForm(_model); f.ShowDialog(this); };

        Controls.Add(_overdue); Controls.Add(_closed); Controls.Add(submit); Controls.Add(guardian); Controls.Add(_heading);
        Refresh2();
    }

    public void Refresh2()
    {
        var items = _model.Lock.Overdue.Concat(_model.Lock.Penalties).ToList();
        _overdue.BeginUpdate();
        _overdue.Items.Clear();
        foreach (var t in _model.Lock.Overdue) _overdue.Items.Add($"Overdue — {t.Title} (was due {Fmt.DateTime(t.DueDate)})");
        foreach (var t in _model.Lock.Penalties)
            if (t.Status is TaskStatus.ProvenLate pl) _overdue.Items.Add($"Late penalty — {t.Title} (until {Fmt.Time(pl.PenaltyEndsAt)})");
        _overdue.EndUpdate();
        if (_overdue.Items.Count > 0 && _overdue.SelectedIndex < 0) _overdue.SelectedIndex = 0;
        _closed.Text = _model.ClosedApps.Count == 0 ? "" : "Closed: " + string.Join(", ", _model.ClosedApps.Take(8));
        _heading.Text = _model.Lock.Overdue.Count > 0 ? "Your PC is locked" : "Late penalty — almost done";
    }

    private void SubmitForSelected()
    {
        var overdue = _model.Lock.Overdue;
        if (overdue.Count == 0) return;
        var idx = Math.Max(0, Math.Min(_overdue.SelectedIndex, overdue.Count - 1));
        using var f = new ProofForm(_model, overdue[idx].Id);
        f.ShowDialog(this);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // The student can't dismiss the lock; only the app closes it when unlocked.
        if (_model.Lock.IsLocked && e.CloseReason == CloseReason.UserClosing) e.Cancel = true;
        else base.OnFormClosing(e);
    }
}
