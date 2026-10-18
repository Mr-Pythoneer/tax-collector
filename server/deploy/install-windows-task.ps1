#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs the Tax Collector relay server whenever Windows starts, as a scheduled task.

.DESCRIPTION
    Registers the task "Tax Collector relay", which runs node.exe on server\server.mjs at startup,
    before anyone signs in, and starts it again within a minute if it ever stops.

    Account: the built-in LOCAL SERVICE, not SYSTEM and not a new user. It has the fewest rights of
    Windows' built-in accounts, there's no password to store or change, and it doesn't appear on
    the sign-in screen. It can read Program Files but can't change Windows, programs or anyone's
    files. This script lets it write one folder: the relay's data folder.

    Settings: %ProgramData%\TaxCollectorRelay\relay.env, made on the first run and kept after that.
              Edit it (for example to pin TC_SETUP_CODE), then run this script again.
    Data:     %ProgramData%\TaxCollectorRelay\data (the setup code and the computers' channels).

    It downloads nothing. Run it again after updating the files or Node.js: it replaces the task.
    To remove the task:  Unregister-ScheduledTask -TaskName 'Tax Collector relay'

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File "C:\Program Files\TaxCollectorRelay\server\deploy\install-windows-task.ps1"
#>
param(
    # The folder that holds server\ and parent\. Default: two folders up from this script.
    [string]$AppDir,
    # node.exe from Node.js 22 or newer. Default: the one on PATH.
    [string]$Node
)

$ErrorActionPreference = 'Stop'
$TaskName = 'Tax Collector relay'

# --- Check the files and Node.js
if (-not $AppDir) { $AppDir = Join-Path $PSScriptRoot '..\..' }
$AppDir = (Resolve-Path $AppDir).Path
$Server = Join-Path $AppDir 'server\server.mjs'
if (-not (Test-Path $Server)) { throw "No $Server here. Pass -AppDir with the folder that holds server and parent." }
if (-not $Node) { $Node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source }
if (-not $Node -or -not (Test-Path $Node)) { throw 'node.exe not found. Install Node.js LTS (22 or newer), or pass -Node.' }
$Version = & $Node --version
if ([int]($Version.TrimStart('v').Split('.')[0]) -lt 22) { throw "The relay needs Node.js 22 or newer; $Node is $Version." }
foreach ($Where in $Node, $AppDir) {
    # LOCAL SERVICE can't read inside people's user folders.
    if ($Where -like "$env:SystemDrive\Users\*") { throw "$Where is in a user folder. Install Node.js for all users and put the relay in Program Files." }
}

# --- Data folder and settings
$Base = Join-Path $env:ProgramData 'TaxCollectorRelay'
$Data = Join-Path $Base 'data'
$EnvFile = Join-Path $Base 'relay.env'
New-Item -ItemType Directory -Force -Path $Data | Out-Null
# Only SYSTEM (S-1-5-18), Administrators (S-1-5-32-544) and LOCAL SERVICE (S-1-5-19) can open it,
# and LOCAL SERVICE can change only data\. SIDs, so this works in any Windows language.
icacls $Base /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE) { throw "icacls couldn't set permissions on $Base." }
icacls $Data /grant:r '*S-1-5-19:(OI)(CI)M' | Out-Null
if ($LASTEXITCODE) { throw "icacls couldn't set permissions on $Data." }
if (-not (Test-Path $EnvFile)) {
    @(
        '# Settings for the Tax Collector relay (server\README.md). Run install-windows-task.ps1 again after a change.'
        'HOST=127.0.0.1'
        'PORT=8787'
        "TC_DATA_DIR=$Data"
        '# Pins the setup code, so computers can link again by themselves if the data folder is lost:'
        '# TC_SETUP_CODE=<your setup code>'
    ) | Set-Content -Path $EnvFile -Encoding ASCII
}

# --- Stop the old copy, then make or show the setup code while nothing else uses the data folder
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName }
Write-Host 'Setup code (type it into Tax Collector on each computer):'
& $Node "--env-file=$EnvFile" $Server --setup-code
if ($LASTEXITCODE) { throw 'The relay could not read or create its data folder.' }

# --- The task. It runs node.exe itself, with no wrapper, so stopping the task stops the relay.
# Paths are quoted because "Program Files" has a space; the working folder must not be quoted.
$Action = New-ScheduledTaskAction -Execute "`"$Node`"" -Argument "--env-file=`"$EnvFile`" `"$Server`"" -WorkingDirectory (Split-Path $Server)
# At startup, and then every minute: if the relay has stopped for any reason, it starts again.
# A copy that's already running isn't started twice (IgnoreNew).
$Triggers = @(
    New-ScheduledTaskTrigger -AtStartup
    New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
)
$Settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$Principal = New-ScheduledTaskPrincipal -UserId 'LOCALSERVICE' -LogonType ServiceAccount -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Triggers -Settings $Settings -Principal $Principal `
    -Description 'Tax Collector relay server (server\README.md).' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

# --- Check that it answers
$Port = 8787
$Line = Select-String -Path $EnvFile -Pattern '^\s*PORT\s*=\s*(\d+)' | Select-Object -Last 1
if ($Line) { $Port = $Line.Matches[0].Groups[1].Value }
foreach ($Attempt in 1..10) {
    Start-Sleep -Seconds 1
    try {
        if ((Invoke-RestMethod -UseBasicParsing -TimeoutSec 3 "http://127.0.0.1:$Port/v1/health").ok) {
            Write-Host "The relay is running on http://127.0.0.1:$Port. Next: HTTPS with Tailscale Funnel (server\README.md)."
            return
        }
    } catch { }
}
Write-Warning "The task is registered, but http://127.0.0.1:$Port/v1/health didn't answer. See 'Last Run Result' in Task Scheduler, or stop the task and run: & '$Node' --env-file='$EnvFile' '$Server'"
