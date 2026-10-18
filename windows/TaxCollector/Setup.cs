using System.Diagnostics;
using System.Security.Principal;

namespace TaxCollector;

/// Installs Tax Collector so it survives being killed: a copy under Program Files
/// plus a scheduled task that runs it as the student at logon and every minute.
/// The install step runs elevated (a parent's admin approval); everything about
/// who it runs as is passed in explicitly, because when a standard user approves a
/// UAC prompt the elevated process is the admin, not the student.
internal static class Setup
{
    public const string TaskName = "TaxCollector";

    public static string InstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "TaxCollector");
    public static string InstallExe => Path.Combine(InstallDir, "TaxCollector.exe");

    public static string CurrentExe => Environment.ProcessPath ?? "";

    public static bool IsInProgramFiles =>
        CurrentExe.StartsWith(InstallDir + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    /// Set up, and the scheduled task points at the installed copy.
    public static bool IsInstalled()
    {
        try
        {
            var psi = new ProcessStartInfo("schtasks.exe")
            {
                RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
            };
            foreach (var a in new[] { "/Query", "/TN", TaskName, "/XML" }) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            var xml = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            return p.ExitCode == 0 && xml.Contains(InstallExe, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    /// Student side: copy into Program Files (via an elevated helper) and register
    /// the scheduled task. Returns null on success, else a message.
    public static string? FinishSetup()
    {
        try
        {
            var student = WindowsIdentity.GetCurrent().Name; // DOMAIN\user or PC\user
            var psi = new ProcessStartInfo(CurrentExe)
            {
                UseShellExecute = true,
                Verb = "runas", // UAC: a parent approves with admin credentials
            };
            psi.ArgumentList.Add("--install");
            psi.ArgumentList.Add(student);
            using var p = Process.Start(psi);
            p?.WaitForExit();
            if (p is { ExitCode: 0 }) return null;
            return "Setup was cancelled or didn't finish. A parent needs to approve the admin prompt.";
        }
        catch (Exception ex) { return ex.Message; }
    }

    /// Elevated side (admin): copy the app and register the task to run as `student`.
    public static int Install(string student)
    {
        try
        {
            Directory.CreateDirectory(InstallDir);
            var srcDir = Path.GetDirectoryName(CurrentExe)!;
            // Single-file publish is one exe; copy it (and any sibling files) into place.
            foreach (var file in Directory.GetFiles(srcDir))
            {
                var dest = Path.Combine(InstallDir, Path.GetFileName(file));
                try { File.Copy(file, dest, overwrite: true); } catch { }
            }

            var xmlPath = Path.Combine(Path.GetTempPath(), "taxcollector-task.xml");
            File.WriteAllText(xmlPath, TaskXml(student, InstallExe), new System.Text.UnicodeEncoding(false, true));

            if (!Run("schtasks.exe", new[] { "/Create", "/TN", TaskName, "/XML", xmlPath, "/F" }))
                return 2;
            // Start it now so the student doesn't have to log out and back in.
            Run("schtasks.exe", new[] { "/Run", "/TN", TaskName });
            try { File.Delete(xmlPath); } catch { }
            return 0;
        }
        catch { return 3; }
    }

    public static void Uninstall()
    {
        Run("schtasks.exe", new[] { "/Delete", "/TN", TaskName, "/F" });
    }

    /// Task Scheduler XML: runs as the student with an interactive token, at logon
    /// and every minute, skipping a run when one is already going, with no time limit.
    private static string TaskXml(string student, string exe) => $"""
        <?xml version="1.0" encoding="UTF-16"?>
        <Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
          <RegistrationInfo>
            <Description>Keeps Tax Collector running for the student.</Description>
          </RegistrationInfo>
          <Triggers>
            <LogonTrigger>
              <Enabled>true</Enabled>
              <UserId>{Xml(student)}</UserId>
              <Repetition>
                <Interval>PT1M</Interval>
                <StopAtDurationEnd>false</StopAtDurationEnd>
              </Repetition>
            </LogonTrigger>
            <BootTrigger>
              <Enabled>true</Enabled>
              <Repetition>
                <Interval>PT1M</Interval>
                <StopAtDurationEnd>false</StopAtDurationEnd>
              </Repetition>
            </BootTrigger>
          </Triggers>
          <Principals>
            <Principal id="Author">
              <UserId>{Xml(student)}</UserId>
              <LogonType>InteractiveToken</LogonType>
              <RunLevel>LeastPrivilege</RunLevel>
            </Principal>
          </Principals>
          <Settings>
            <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
            <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
            <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
            <AllowHardTerminate>true</AllowHardTerminate>
            <StartWhenAvailable>true</StartWhenAvailable>
            <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
            <AllowStartOnDemand>true</AllowStartOnDemand>
            <Enabled>true</Enabled>
            <Hidden>false</Hidden>
            <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
            <Priority>7</Priority>
          </Settings>
          <Actions Context="Author">
            <Exec>
              <Command>{Xml(exe)}</Command>
              <Arguments>--task</Arguments>
            </Exec>
          </Actions>
        </Task>
        """;

    private static string Xml(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    private static bool Run(string file, string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(file) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            p.WaitForExit(15000);
            return p.ExitCode == 0;
        }
        catch { return false; }
    }
}
