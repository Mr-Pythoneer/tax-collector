using System.Diagnostics;
using System.Security.Cryptography.X509Certificates;
using TaxCore;

namespace TaxCollector;

/// Turns a top-level window into a trustworthy TaxCore.AppIdentity: the real
/// process behind ApplicationFrameHost for UWP apps, the MSIX package family,
/// the Authenticode publisher (only when the signature verifies), and the PE's
/// embedded OriginalFilename (so a renamed file can't pose as an allowed app).
internal static class IdentityResolver
{
    // Verifying a signature and reading version info is dear; cache by file path.
    private static readonly Dictionary<string, (string? Publisher, string? OriginalName)> Cache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object CacheLock = new();

    /// (pid to act on, identity). pid 0 when the window has no resolvable process.
    public static (uint Pid, AppIdentity Identity) Resolve(IntPtr hWnd)
    {
        Interop.GetWindowThreadProcessId(hWnd, out var pid);
        if (pid == 0) return (0, new AppIdentity("", IsSystemCritical: true));

        var path = ProcessImagePath(pid);
        var baseName = path is null ? "" : Path.GetFileName(path);

        // UWP apps are hosted by ApplicationFrameHost; find the real app behind the frame.
        if (baseName.Equals("ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase))
        {
            var real = RealUwpProcess(hWnd, pid);
            if (real is { } r)
            {
                pid = r;
                path = ProcessImagePath(pid);
                baseName = path is null ? "" : Path.GetFileName(path);
            }
        }

        var family = PackageFamilyName(pid);
        var (publisher, originalName) = SignatureInfo(path);
        var image = (originalName ?? baseName);
        var critical = Allowlist.IsSystemCriticalImage(image) || Allowlist.IsSystemCriticalImage(baseName);
        return (pid, new AppIdentity(image, family, publisher, critical));
    }

    private static uint? RealUwpProcess(IntPtr frameWindow, uint hostPid)
    {
        uint found = 0;
        Interop.EnumChildWindows(frameWindow, (child, _) =>
        {
            Interop.GetWindowThreadProcessId(child, out var childPid);
            if (childPid != 0 && childPid != hostPid) { found = childPid; return false; }
            return true;
        }, IntPtr.Zero);
        return found == 0 ? null : found;
    }

    public static string? ProcessImagePath(uint pid)
    {
        var h = Interop.OpenProcess(Interop.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var buf = new System.Text.StringBuilder(1024);
            uint size = (uint)buf.Capacity;
            return Interop.QueryFullProcessImageName(h, 0, buf, ref size) ? buf.ToString() : null;
        }
        finally { Interop.CloseHandle(h); }
    }

    private static string? PackageFamilyName(uint pid)
    {
        var h = Interop.OpenProcess(Interop.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            uint len = 0;
            var rc = Interop.GetPackageFamilyName(h, ref len, null);
            if (rc == Interop.APPMODEL_ERROR_NO_PACKAGE || len == 0) return null;
            var buf = new System.Text.StringBuilder((int)len);
            rc = Interop.GetPackageFamilyName(h, ref len, buf);
            return rc == 0 ? buf.ToString().TrimEnd('\0') : null;
        }
        finally { Interop.CloseHandle(h); }
    }

    private static (string? Publisher, string? OriginalName) SignatureInfo(string? path)
    {
        if (path is null || !File.Exists(path)) return (null, null);
        lock (CacheLock)
            if (Cache.TryGetValue(path, out var hit)) return hit;

        string? publisher = null, original = null;
        try
        {
            var info = FileVersionInfo.GetVersionInfo(path);
            if (!string.IsNullOrWhiteSpace(info.OriginalFilename)) original = info.OriginalFilename;
        }
        catch { }

        try
        {
            if (Interop.VerifyTrust(path))
            {
#pragma warning disable SYSLIB0057, SYSLIB0026
                using var cert = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057, SYSLIB0026
                publisher = cert.Subject; // e.g. "CN=Microsoft Corporation, O=..., C=US"
            }
        }
        catch { }

        var result = (publisher, original);
        lock (CacheLock) Cache[path] = result;
        return result;
    }
}
