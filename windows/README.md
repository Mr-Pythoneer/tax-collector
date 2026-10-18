# Tax Collector for Windows

A Windows tray app with the same rules as the Mac version, written in C# on
.NET 10. It holds a student to their own deadlines: tasks need proof that the
local Claude CLI checks, and an overdue task locks the PC by closing every app
except an allowlist until proof is in. A parent's guardian code is the only
override.

Protocol for the parent link: [`docs/parent-link-v1.md`](../docs/parent-link-v1.md).

## Projects

- **`TaxCore`** — the rules engine, plain cross-platform .NET 10 (no UI, no
  Windows dependencies). Models and their JSON, the lock rules, repeats, the
  extension policy, the Claude prompts and answer parsing, the guardian
  PBKDF2-SHA256 hash (the same scheme as the Mac's `Sources/TaxCore/Guardian.swift`),
  and the parent-link cryptography (`ParentLink/LinkCrypto.cs`).
- **`TaxCore.Check`** — a console app that runs the rule checks and the
  `spec/vectors/v1.json` parent-link vectors. Runs on the Mac, the counterpart of
  `swift run taxcore-check`.
- **`TaxCollector`** — the WinForms tray app. Built on the Mac with
  `EnableWindowsTargeting`; runs on Windows only.

## Building on the Mac

The .NET SDK and all caches live on the external SSD so nothing large touches the
main drive. `windows/env.sh` sets the paths (`DOTNET_ROOT`, `NUGET_PACKAGES`,
`TC_ARTIFACTS`, …):

```bash
source windows/env.sh
dotnet build windows/TaxCore
dotnet run  --project windows/TaxCore.Check      # all checks + parent-link vectors
```

`windows/Directory.Build.props` sends build output to `TC_ARTIFACTS`
(`UseArtifactsOutput`) on the SSD.

## Publishing

Self-contained single-file, for both architectures, to the SSD. The first publish
of each architecture fetches the Windows runtime packs (~0.3–0.5 GB, to the SSD):

```bash
source windows/env.sh
dotnet publish windows/TaxCollector -c Release -r win-arm64 --self-contained -p:PublishSingleFile=true
dotnet publish windows/TaxCollector -c Release -r win-x64   --self-contained -p:PublishSingleFile=true
```

Output: `$TC_ARTIFACTS/publish/TaxCollector/release_win-arm64/TaxCollector.exe`
(and `…win-x64…`). The exe is unsigned, so SmartScreen asks "Run anyway". If
Defender complains, don't compress the single file (it isn't compressed here).

## On Windows

- **Setup** installs to `C:\Program Files\TaxCollector`; data goes in
  `%LOCALAPPDATA%\TaxCollector`. Finishing setup asks for a parent's admin
  approval once (a UAC prompt). The elevated step registers a scheduled task that
  runs the app **as the student** at logon and every minute (skip if already
  running, no time limit) — the elevated process is told the student's account, so
  it isn't confused with the admin who approved the prompt. A two-process
  named-mutex watchdog keeps a second copy guarding the first.
- **The student must be a Standard user.** The parent is an admin.
- **Proof checking** uses the `claude` CLI, found in
  `%USERPROFILE%\.local\bin\claude.exe`, then `%APPDATA%\npm\claude.cmd`, then
  `where claude`. The prompt always goes in through **stdin**.

### Enforcement

- Windows are watched with `SetWinEventHook` and swept every second (top-level,
  visible, un-cloaked, un-owned, not tool windows).
- Apps are allowed **by identity, never by file name**: the MSIX package family
  (Arc, new Teams, new Outlook), or the `WinVerifyTrust` publisher together with
  the PE's embedded OriginalFilename (Office, OneDrive, Zoom, Claude). A renamed
  exe is never treated as allowed.
- Always allowed: Task Manager, Explorer and the shell, the UAC prompt, Snipping
  Tool. Closed during a lock: Settings and terminals.
- UWP apps are resolved to the real process behind `ApplicationFrameHost`; the
  host is never killed.
- Apps are closed with `WM_CLOSE`, then the process tree is killed after 10 s.

The MSIX family names and publisher subjects in `TaxCore/Allowlist.cs` marked
"verify in the VM" are best-effort defaults; confirm them against the installed
apps.

## Test switches

The same as the Mac:

- `TAXCOLLECTOR_DATA_DIR` — use a throwaway data folder.
- `TAXCOLLECTOR_DRY_RUN=1` — log what would be closed instead of closing it.
- `TAXCOLLECTOR_SELFTEST=1` — run the headless self-test (uses a fake `claude`)
  and write `selftest.txt`.

## Parent link

The cryptography and wire format are ported in `TaxCore/ParentLink/LinkCrypto.cs`
and verified against `spec/vectors/v1.json` by `TaxCore.Check` (base64url,
HKDF-SHA256, AES-256-GCM boxes, ECDH P-256 link key, ECDSA raw r‖s signatures,
pairing slot/SAS, raw DEFLATE). The networked client (the long-poll loop against
the relay server, applying commands, building the state document and the pairing
UI) is the next step.

## The test VM

Tested in a Windows 11 ARM64 VM under UTM (QEMU engine) on the external SSD. See
`VM-SETUP.md` for the exact wizard and Windows-install steps.
