namespace TaxCore;

/// A running app resolved to a trustworthy identity by the Windows enforcement
/// layer. Nothing here can be forged by renaming a file on disk:
///   - PackageFamily comes from the OS's MSIX/AppX identity.
///   - VerifiedPublisher is set only when WinVerifyTrust accepts the signature.
///   - ImageName is the PE's embedded OriginalFilename when present (so a copy
///     of notepad.exe renamed to winword.exe still reports "notepad.exe"),
///     falling back to the on-disk file name only for unsigned files.
public sealed record AppIdentity(
    string ImageName,
    string? PackageFamily = null,
    string? VerifiedPublisher = null,
    bool IsSystemCritical = false)
{
    public string ImageLower => ImageName.ToLowerInvariant();
}

/// A Win32 app allowed only when its embedded OriginalFilename and its verified
/// Authenticode publisher both match. Publisher is matched as a case-insensitive
/// substring of the signer's subject.
public sealed record SignedApp(string ImageName, string PublisherContains);

/// The lock allowlist for Windows. Apps are allowed by identity, never by the
/// name of the file on disk. MSIX family names and publisher subjects marked
/// "verify in the VM" are best-effort defaults; confirm the real values against
/// the installed apps and adjust.
public static class Allowlist
{
    /// MSIX / AppX package families kept open during a lock (OS-reported identity).
    public static readonly string[] AllowedPackageFamilies =
    {
        // new Teams and new Outlook have stable, well-known family names.
        "MSTeams_8wekyb3d8bbwe",
        "Microsoft.OutlookForWindows_8wekyb3d8bbwe",
        // Arc for Windows ships as an MSIX. Family name: verify in the VM.
        "TheBrowserCompany.Arc",
    };

    /// Win32 apps kept open during a lock, by (OriginalFilename, publisher substring).
    public static readonly SignedApp[] AllowedSignedApps =
    {
        new("winword.exe",  "Microsoft Corporation"),
        new("excel.exe",    "Microsoft Corporation"),
        new("powerpnt.exe", "Microsoft Corporation"),
        new("outlook.exe",  "Microsoft Corporation"),
        new("onenote.exe",  "Microsoft Corporation"),
        new("onedrive.exe", "Microsoft Corporation"),
        new("zoom.exe",     "Zoom Video Communications"),
        // Claude desktop and VooV Meeting: publisher subjects to verify in the VM.
        new("claude.exe",   "Anthropic"),
        new("wemeetapp.exe", "Tencent"),
    };

    /// OS tools always allowed, even during a lock. They must also be Microsoft-signed
    /// (RequireMicrosoft) so a forged OriginalFilename on an unsigned file can't pose as them.
    public static readonly (string Image, bool RequireMicrosoft)[] AlwaysAllowed =
    {
        ("taskmgr.exe", true),        // Task Manager — the Windows stand-in for Activity Monitor
        ("explorer.exe", true),       // the shell / file browser
        ("snippingtool.exe", true),   // Snipping Tool
        ("consent.exe", true),        // the UAC admin prompt
        ("credentialuibroker.exe", true),
        ("logonui.exe", true),
    };

    /// Closed during a lock even though they're Microsoft-signed: a student mustn't
    /// slip out through a terminal or the Settings app.
    public static readonly string[] BlockedDuringLock =
    {
        "cmd.exe",
        "powershell.exe",
        "pwsh.exe",
        "windowsterminal.exe",
        "wt.exe",
        "conhost.exe",
        "systemsettings.exe",
        "systemsettingsbroker.exe",
    };

    /// Processes that must never be touched: the shell's own helpers and our own app.
    /// The Windows layer marks these IsSystemCritical.
    public static readonly string[] SystemCritical =
    {
        "dwm.exe",
        "sihost.exe",
        "startmenuexperiencehost.exe",
        "searchhost.exe",
        "shellexperiencehost.exe",
        "applicationframehost.exe",   // the UWP host — kill the real app behind it, not this
        "textinputhost.exe",
        "ctfmon.exe",
        "lockapp.exe",
    };

    public static bool IsSystemCriticalImage(string imageName) =>
        SystemCritical.Contains(imageName.ToLowerInvariant());

    /// Whether this app stays open during a lock. `extra` holds the identity tokens
    /// the guardian added (a package family, a publisher subject, or an image name);
    /// any match keeps the app open, so the guardian is always the final word.
    public static bool IsAllowed(AppIdentity app, IEnumerable<string> extra, string? selfImage = null)
    {
        var image = app.ImageLower;
        if (selfImage != null && image == selfImage.ToLowerInvariant()) return true;
        if (app.IsSystemCritical || IsSystemCriticalImage(image)) return true;

        // Guardian override wins over everything below, including the blocked-during-lock list.
        var extras = extra as ICollection<string> ?? extra.ToList();
        if (extras.Count > 0)
        {
            if (app.PackageFamily != null && extras.Contains(app.PackageFamily)) return true;
            if (extras.Contains(image)) return true;
            if (app.VerifiedPublisher is { } vp && extras.Any(e => vp.Contains(e, StringComparison.OrdinalIgnoreCase)))
                return true;
        }

        foreach (var (img, requireMs) in AlwaysAllowed)
            if (image == img && (!requireMs || PublisherIsMicrosoft(app.VerifiedPublisher)))
                return true;

        if (BlockedDuringLock.Contains(image)) return false;

        if (app.PackageFamily is { } fam && AllowedPackageFamilies.Any(f => FamilyMatches(fam, f)))
            return true;

        if (app.VerifiedPublisher != null)
            foreach (var s in AllowedSignedApps)
                if (image == s.ImageName &&
                    app.VerifiedPublisher.Contains(s.PublisherContains, StringComparison.OrdinalIgnoreCase))
                    return true;

        return false;
    }

    private static bool PublisherIsMicrosoft(string? publisher) =>
        publisher != null && publisher.Contains("Microsoft Corporation", StringComparison.OrdinalIgnoreCase);

    /// Exact family, or a package whose family starts with an allowed prefix
    /// (handles the Arc family whose exact suffix we confirm in the VM).
    private static bool FamilyMatches(string family, string allowed) =>
        family.Equals(allowed, StringComparison.OrdinalIgnoreCase)
        || family.StartsWith(allowed + "_", StringComparison.OrdinalIgnoreCase)
        || (!allowed.Contains('_') && family.StartsWith(allowed, StringComparison.OrdinalIgnoreCase));
}
