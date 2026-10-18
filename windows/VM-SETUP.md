# The Windows 11 ARM test VM

Everything lives on the external SSD (`"/Volumes/ VideoGames"`, leading space),
reachable through `~/tc-ssd`:

```
~/tc-ssd/
  Apps/UTM.app                                  UTM 5.0.8, run from here
  ISO/Windows11_Client_arm64_en-us_26300_9457.iso   English (US) ARM64, build 26300.9457
  VM/                                           the .utm bundle goes here
  out/publish/TaxCollector/release_win-arm64/TaxCollector.exe   the build to test
  share/ssh/taxcollector_vm[.pub]               Mac→VM SSH key
```

**Never unplug the SSD while the VM is running.**

> The ISO is genuine English despite a hash-table quirk on Microsoft's page — see
> `~/tc-ssd/ISO/SHA256.txt`. (The page's published en-us hash is stale and does not
> match the file its own link serves; the ISO's volume label is `CCCOMA_A64FRE_EN-US_DV9`
> and `lang.ini` lists only `en-us`.)

---

## 1. Create the VM (UTM wizard — don't start it)

Open UTM from the SSD:

```bash
open ~/tc-ssd/Apps/UTM.app
```

1. **Create a New Virtual Machine** → **Virtualize** (UTM uses the QEMU backend for
   Windows automatically; Apple Virtualization can't run Windows).
2. **Operating System → Windows.**
   - Tick **Install Windows 10 or higher** (this turns on **TPM 2.0** and **Secure Boot**).
   - Leave **Import VHDX Image** unticked.
   - **Browse…** → `~/tc-ssd/ISO/Windows11_Client_arm64_en-us_26300_9457.iso`.
   - Keep **Install drivers and SPICE tools** ticked (adds the guest-tools ISO).
3. **Hardware:** 4 CPU cores, **8192 MB** RAM. Leave "Open GL Acceleration" off for
   stability.
4. **Storage:** **72 GB** (anything 64–80; it grows as used, it isn't pre-filled).
5. **Shared Directory:** skip (optional).
6. **Summary:** name it `TaxCollector Win11 ARM`. **Tick "Open VM Settings"** so you can
   confirm the network, but **do not start the VM yet.**
   - In Settings → **Network**, set **Network Mode = Shared Network**.
   - In Settings → **QEMU**, confirm it's the QEMU backend.
   - Save and close settings. **Do not press ▶.**

### Move the bundle to the SSD

UTM saves the VM on the internal drive by default. Move it to the SSD and reopen:

```bash
# Find it (usually under UTM's container) and move the whole .utm bundle:
mv ~/Library/Containers/com.utmapp.UTM/Data/Documents/"TaxCollector Win11 ARM.utm" ~/tc-ssd/VM/
```

Then in UTM: **File → Open…** → `~/tc-ssd/VM/TaxCollector Win11 ARM.utm`.
Right-click the VM → **Show in Finder** (or Edit → check the Drive paths) and confirm
the disk image inside the bundle is on the SSD. Delete the old entry if one lingers.

---

## 2. Install Windows (Skyler drives this)

Start the VM. **You accept Microsoft's licence and click through Setup yourself.**

- When you see **"Press any key to boot from CD/DVD",** press a key quickly. If it
  boots to a UEFI shell instead, type `exit`, then in the boot menu pick the DVD.
- Language/keyboard: English (United States). **Install now.** Accept the licence.
- Edition: **Windows 11 Pro** (or Home — Pro is easier for Standard-user testing).
- **Custom install** → the one unallocated disk → Next.
- **If there's no network** at the account step, press **Shift+F10** for a prompt and run:
  ```
  start ms-cxh:localonly
  ```
  (On older builds use `OOBE\BYPASSNRO` then **Continue with limited setup**.) This lets
  you make a **local account**.
  - If the mouse/keyboard or network don't work in Setup, open **Shift+F10** and install
    the guest drivers from the tools ISO with `pnputil /add-driver D:\…\*.inf /subdirs /install`
    (the SPICE/guest-tools ISO shows up as a second CD drive).
- **Create the admin account** first — e.g. user **`parent`**, with a password. This is the
  administrator.
- Finish setup to the desktop.

### Make the Standard "student" account

As `parent` (admin), open **Settings is closed during a lock, so do this now, before
installing Tax Collector**:

- Settings → Accounts → Other users → **Add account** → "I don't have this person's
  sign-in" → **Add a user without a Microsoft account** → username **`student`**, set a
  password. Leave it a **Standard user** (do *not* make it an Administrator).

---

## 3. After setup

As `parent` (admin), in an elevated PowerShell:

```powershell
# OpenSSH Server with key login
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
# Admins authenticate with this key file:
New-Item -ItemType Directory -Force "C:\ProgramData\ssh" | Out-Null
# Paste the Mac's public key (one line) into administrators_authorized_keys:
notepad C:\ProgramData\ssh\administrators_authorized_keys
```

The Mac's public key (from `~/tc-ssd/share/ssh/taxcollector_vm.pub`):

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMU03/bKouz0TDLRevfFVwR8jG+BFGmlCkgsf3mWm+u taxcollector-mac-to-vm
```

Fix the file's permissions (Windows is strict about this one):

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```

Find the VM's IP (Shared Network gives it something like `192.168.64.x`; the host is
`192.168.64.1`):

```powershell
ipconfig
```

### Copy a build in (from the Mac)

```bash
scp -i ~/tc-ssd/share/ssh/taxcollector_vm \
  "/Volumes/ VideoGames/TaxCollector.noindex/out/publish/TaxCollector/release_win-arm64/TaxCollector.exe" \
  parent@<VM-IP>:/Users/parent/Downloads/TaxCollector.exe
```

### Keep a clean copy of the disk

With the VM shut down, snapshot the disk cheaply (APFS clone):

```bash
cp -c ~/tc-ssd/VM/"TaxCollector Win11 ARM.utm"/Data/*.qcow2 ~/tc-ssd/VM/clean-after-install.qcow2
```

(UTM 5 also has a **Snapshots** tab for QEMU VMs — either works.)

### Run the app on the desktop as the student

The scheduled task the installer makes runs the app on the student's desktop. To launch
it by hand for a test, from an **interactive** scheduled task so it has a desktop:

```cmd
schtasks /Create /TN TC-Test /TR "C:\Program Files\TaxCollector\TaxCollector.exe --task" /SC ONCE /ST 23:59 /IT /RU student
schtasks /Run /TN TC-Test
```

---

## 4. What to test in the VM (signed in as `student`)

- **Setup** with the admin prompt (run `TaxCollector.exe` from Downloads → Finish setup →
  approve as `parent`). The app installs to `C:\Program Files\TaxCollector`, data in
  `%LOCALAPPDATA%\TaxCollector`, and a scheduled task appears.
- **Guardian code**: set it, wrong code three times starts a cooldown, right code opens the panel.
- **Tasks and repeats**: add a task; add a weekly repeat; the first copy appears.
- **Proof checking with a fake claude**: put a `claude.cmd` on PATH (or run
  `TaxCollector.exe --selftest` with `TAXCOLLECTOR_DATA_DIR` set — it uses its own fake and
  writes `selftest.txt`).
- **A lock closes Calculator, Notepad and Paint but not Explorer, Task Manager or an allowed
  app** (make a task overdue; confirm `calc`, `notepad`, `mspaint` close and Explorer /
  Task Manager stay). A **renamed exe** (copy `calc.exe` to `winword.exe` and run it) is still
  closed — allowlisting is by identity, not file name.
- **Survives being killed**: end `TaxCollector.exe` in Task Manager → the watchdog restarts it
  instantly; `taskkill /IM TaxCollector.exe /F /T` (both copies) → the scheduled task brings it
  back within 60 s.

Run the headless self-test too:

```cmd
set TAXCOLLECTOR_DATA_DIR=%TEMP%\tc-selftest
"C:\Program Files\TaxCollector\TaxCollector.exe" --selftest
type %TEMP%\tc-selftest\selftest.txt
```
