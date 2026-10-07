<#
.SYNOPSIS
    FGN (First Gen Net) - Windows 11 Debloat, Remove and Harden (UNATTENDED)
.DESCRIPTION
    Run it and walk away: there is no menu and no question. Every step either runs or is
    skipped automatically, and the log says which and why.

    What it does (17 sections - see the SECTIONS list in the script):
       1  Remove consumer apps (Xbox, Spotify, social apps, Teams chat, Copilot, Dev Home ...)
       2-5  Ads/suggestions, telemetry level, noisy scheduled tasks, taskbar clutter
       6  AI features: Recall, Copilot (removed), AI-powered search, Edge sidebar
       7-10  Low-risk and medium-value tweaks, extra tweaks, unused services
      11  Bluetooth: adapter(s) and services disabled
      12  Startup programs report (list only)
      13  OneDrive uninstalled for ALL user profiles
      14  Microsoft Store removed
      15  Windows Subsystem for Linux removed
      16  Microsoft Edge removed
      17  Remote Desktop Connection removed (the outgoing client)

    SAFE BY DEFAULT: the questions the interactive version used to ask are now decided
    automatically. Anything that could hurt a user is SKIPPED and listed in the summary:
      - Edge is left alone if no other web browser is installed       (-AllowNoBrowser overrides)
      - OneDrive is left alone for a profile with cloud-only files or Desktop/Documents/
        Pictures backup, because removal would strand those files   (-IncludeRisky overrides)
      - Bluetooth is left alone if it would remove the only keyboard   (-AllowInputLoss overrides)
      - Remote Desktop Connection is left alone while it is running   (-CloseRunning overrides)
    User files are never deleted. Windows Update and Defender are untouched.

.PARAMETER Skip
    Sections to leave out, for example  -Skip 13,16
.PARAMETER Only
    Run only these sections, for example  -Only 6,7
.PARAMETER IncludeRisky
    OneDrive: also remove it for profiles whose cloud-only files or folder backup would be stranded.
.PARAMETER AllowNoBrowser
    Edge: remove it even when no other browser is installed.
.PARAMETER AllowInputLoss
    Bluetooth: disable it even when that removes the only keyboard.
.PARAMETER NoManualOneDriveRemoval
    OneDrive: do not fall back to a manual removal when OneDrive's own uninstallers fail.
.PARAMETER CloseRunning
    Remote Desktop Connection: close it if it is running instead of skipping.
.PARAMETER RestartWhenDone
    Restart the PC (60-second warning, cancel with: shutdown /a) after everything has finished.
.PARAMETER WaitAtEnd
    Wait for Enter before closing the window (useful when started by double-click).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\FGN-Win11-Debloat-Auto.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\FGN-Win11-Debloat-Auto.ps1 -Skip 13,16 -RestartWhenDone
.NOTES
    Author: Visai / FGN IT Support
    Target: Windows 11 Pro 23H2 / 24H2 / 25H2, Windows PowerShell 5.1.
    Asks Windows for administrator rights itself (you only see the normal UAC prompt).
    The log is saved to the Desktop of the account running it.
    To undo Bluetooth later: .\FGN-Disable-Bluetooth.ps1 -Enable
#>

param(
    [string[]]$Skip,
    [string[]]$Only,
    [switch]$IncludeRisky,
    [switch]$AllowNoBrowser,
    [switch]$AllowInputLoss,
    [switch]$NoManualOneDriveRemoval,
    [switch]$CloseRunning,
    [switch]$RestartWhenDone,
    [switch]$WaitAtEnd
)

function New-FGNElevationArgs {
    # The command line used to restart this script with administrator rights, keeping the same options
    param($Bound, [string]$ScriptPath)
    $List = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'))
    foreach ($Key in $Bound.Keys) {
        $Val = $Bound[$Key]
        if ($Val -is [System.Management.Automation.SwitchParameter]) {
            if ($Val.IsPresent) { $List += "-$Key" }
        } elseif ($Val -is [array]) {
            $List += "-$Key"
            $List += ('"' + ((@($Val) | ForEach-Object { "$_" }) -join ',') + '"')
        } else {
            $List += "-$Key"
            $List += ('"' + $Val + '"')
        }
    }
    return $List
}

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    if (-not $PSCommandPath) {
        Write-Host "Save this script to a file and run it again (it needs administrator rights)." -ForegroundColor Red
        exit 1
    }
    Write-Host "Administrator rights are needed - restarting elevated. Accept the Windows prompt." -ForegroundColor Cyan
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList (New-FGNElevationArgs -Bound $PSBoundParameters -ScriptPath $PSCommandPath)
    } catch {
        Write-Host "Could not get administrator rights: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit
}

$ErrorActionPreference = 'SilentlyContinue'
$LogPath = "$env:USERPROFILE\Desktop\FGN-Debloat-Auto-Log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$script:LogLines = @()

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
    $script:LogLines += $line
}

# ---------------------------------------------------------------------------
# APP SCAN / REMOVE HELPERS
# Every app removal goes through these: SCAN first (installed for any user,
# and provisioned for new users), remove only what is found, then VERIFY.
# ---------------------------------------------------------------------------
function Find-FGNApp {
    param(
        [Parameter(Mandatory)][string]$Name,
        $ProvisionedList   # optional pre-fetched list, avoids re-querying for every app
    )

    if ($null -eq $ProvisionedList) {
        $ProvisionedList = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    }

    $Installed   = @(Get-AppxPackage -Name $Name -AllUsers -ErrorAction SilentlyContinue)
    $Provisioned = @($ProvisionedList | Where-Object { $_.DisplayName -like $Name })

    [pscustomobject]@{
        Name        = $Name
        Installed   = $Installed
        Provisioned = $Provisioned
        Found       = ($Installed.Count -gt 0 -or $Provisioned.Count -gt 0)
    }
}

function Remove-FGNApp {
    param(
        [Parameter(Mandatory)][string]$Name,
        $ProvisionedList
    )

    # 1. SCAN - does this app exist at all?
    $Scan = Find-FGNApp -Name $Name -ProvisionedList $ProvisionedList
    if (-not $Scan.Found) {
        Write-Log "  [NOT FOUND] $Name - nothing to remove, skipped"
        return
    }
    Write-Log "  [FOUND] $Name (installed: $($Scan.Installed.Count), provisioned: $($Scan.Provisioned.Count))"

    # 2. REMOVE - installed copies first, then the provisioned copy so it does
    #    not come back for newly created users
    foreach ($Pkg in $Scan.Installed) {
        try {
            Remove-AppxPackage -Package $Pkg.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            Write-Log "    Could not remove installed package $($Pkg.PackageFullName): $($_.Exception.Message)"
        }
    }
    foreach ($Prov in $Scan.Provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $Prov.PackageName -ErrorAction Stop | Out-Null
        } catch {
            Write-Log "    Could not remove provisioned package $($Prov.PackageName): $($_.Exception.Message)"
        }
    }

    # 3. VERIFY - rescan to confirm it is really gone
    $After = Find-FGNApp -Name $Name
    if ($After.Found) {
        Write-Log "  [FAILED] $Name is still present after removal attempt (may be protected on this build)"
    } else {
        Write-Log "  [REMOVED] $Name"
    }
}

function Get-FGNCopilotEntries {
    # Copilot can be installed as a regular program (not an app package). It then shows
    # in the Windows uninstall list, e.g. "C:\Program Files (x86)\Microsoft\Copilot\...\copilot_setup.exe --uninstall ..."
    $Roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $Found = @()
    foreach ($Root in $Roots) {
        $Found += @(Get-ChildItem -Path $Root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -like "*Copilot*" -and $_.DisplayName -notlike "GitHub*" -and $_.UninstallString })
    }
    @($Found | Sort-Object UninstallString -Unique)
}

# ---------------------------------------------------------------------------
# EDGE REMOVAL HELPERS (used by Section 16)
# Methods come from the public-domain EdgeRemover by he3als (Unlicense) and
# ave9858's UninstallEdge gist (CC0). Same logic as FGN-Remove-Edge.ps1.
# ---------------------------------------------------------------------------
$EdgeBaseKey = 'HKLM:\SOFTWARE' + $(if ([Environment]::Is64BitOperatingSystem) { '\WOW6432Node' }) + '\Microsoft'
$EdgeUwpPath = "$([Environment]::GetFolderPath('Windows'))\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
$EdgeProductId = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
$script:EdgeStoppedServices = @()

function Get-FGNEdgeEntries {
    # The browser itself is listed as exactly "Microsoft Edge" (not Edge Update / WebView2)
    $Roots = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $Found = @()
    foreach ($Root in $Roots) {
        $Found += @(Get-ChildItem -Path $Root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -eq "Microsoft Edge" -and $_.UninstallString })
    }
    @($Found | Sort-Object UninstallString -Unique)
}

function Get-FGNEdgeLauncher {
    # The Edge launcher file - present only while the browser is installed
    $Path = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (Test-Path $Path) { return $Path }
    $null
}

function Test-FGNEdgeGone {
    return ((@(Get-FGNEdgeEntries).Count -eq 0) -and -not (Get-FGNEdgeLauncher))
}

function Get-FGNOtherBrowsers {
    $Apps = [ordered]@{
        "chrome.exe"  = "Google Chrome"
        "firefox.exe" = "Mozilla Firefox"
        "brave.exe"   = "Brave"
        "opera.exe"   = "Opera"
        "vivaldi.exe" = "Vivaldi"
    }
    $Found = @()
    foreach ($Exe in $Apps.Keys) {
        foreach ($Hive in @("HKLM", "HKCU")) {
            if (Test-Path "${Hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Exe") {
                $Found += $Apps[$Exe]
                break
            }
        }
    }
    @($Found)
}

function Split-FGNCommand {
    # Splits a registry UninstallString into program + arguments
    param([string]$Cmd)
    $Cmd = $Cmd.Trim()
    if ($Cmd.StartsWith('"')) {
        $End = $Cmd.IndexOf('"', 1)
        [pscustomobject]@{ Exe = $Cmd.Substring(1, $End - 1); Arguments = $Cmd.Substring($End + 1).Trim() }
    } else {
        $Space = $Cmd.IndexOf(' ')
        if ($Space -lt 0) {
            [pscustomobject]@{ Exe = $Cmd; Arguments = "" }
        } else {
            [pscustomobject]@{ Exe = $Cmd.Substring(0, $Space); Arguments = $Cmd.Substring($Space + 1).Trim() }
        }
    }
}

function Get-FGNEdgeExitMeaning {
    param([int]$Code)
    switch ($Code) {
        0       { "success" }
        93      { "refused - one of the installer's checks failed" }
        532     { "refused - the installer did not accept how it was launched" }
        default { "see the verification step - it decides success, not the code" }
    }
}

function Stop-FGNEdgeProcesses {
    # Stops anything running FROM the Edge browser / Edge Update folders. WebView2 Runtime
    # processes (EdgeWebView folder) are left alone so other apps keep working.
    $Roots = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\"
        "${env:ProgramFiles(x86)}\Microsoft\EdgeCore\"
        "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate\"
    )
    $Procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $ProcPath = $_.Path
        $ProcPath -and (@($Roots | Where-Object { $ProcPath -like "$_*" }).Count -gt 0)
    })
    if ($Procs.Count -gt 0) {
        $Procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Log "    Stopped $($Procs.Count) Edge process(es): $((@($Procs | Select-Object -ExpandProperty ProcessName -Unique)) -join ', ')"
        Start-Sleep -Seconds 2
    }

    # Edge services (Edge Update etc.) can hold Edge files open - pause them (restarted afterwards)
    $Svcs = @(Get-Service -Name '*edge*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Microsoft Edge*' -and $_.Status -eq 'Running' })
    foreach ($Svc in $Svcs) {
        Stop-Service -Name $Svc.Name -Force -ErrorAction SilentlyContinue
        if ($script:EdgeStoppedServices -notcontains $Svc.Name) { $script:EdgeStoppedServices += $Svc.Name }
        Write-Log "    Paused service: $($Svc.Name)"
    }
}

function Restore-FGNPausedEdgeServices {
    # Edge Update also keeps the WebView2 Runtime updated, so always start it again
    foreach ($Name in $script:EdgeStoppedServices) {
        if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
            Start-Service -Name $Name -ErrorAction SilentlyContinue
            Write-Log "  Restarted service: $Name"
        }
    }
    $script:EdgeStoppedServices = @()
}

function Add-FGNInstallerLog {
    # Edge's installer writes why it refused into msedge_installer.log - copy the newest part into our log
    param([datetime]$Since)
    $Candidates = @()
    foreach ($Dir in @($env:TEMP, "$env:SystemRoot\Temp", "$env:SystemRoot\SystemTemp")) {
        $Candidates += @(Get-ChildItem -Path $Dir -Filter "msedge_installer.log" -ErrorAction SilentlyContinue)
    }
    $Candidates += @(Get-ChildItem -Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\*\Installer" -Filter "*.log" -ErrorAction SilentlyContinue)
    $Latest = $Candidates | Where-Object { $_.LastWriteTime -ge $Since } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $Latest) {
        Write-Log "  (no fresh Edge installer log found in Temp, Windows\Temp or the Installer folder)"
        return
    }
    Write-Log "  Edge installer log: $($Latest.FullName)"
    foreach ($Line in @(Get-Content -LiteralPath $Latest.FullName -Tail 40 -ErrorAction SilentlyContinue)) {
        Write-Log "    | $Line"
    }
}

function Invoke-FGNEdgeMethod {
    param([int]$Method, [string]$Command)

    $Parts = Split-FGNCommand $Command
    $SetupArgs = $Parts.Arguments
    $ClientKey = "$EdgeBaseKey\EdgeUpdate\ClientState\$EdgeProductId"
    $DevKey = "$EdgeBaseKey\EdgeUpdateDev"
    $MarkerExe = Join-Path $EdgeUwpPath "MicrosoftEdge.exe"
    $EnvPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

    $CreatedDevKey = $false
    $CreatedMarkerDir = $false
    $CreatedMarkerFile = $false
    $FakeDllhost = $null
    $WindirChanged = $false
    $OrigWindirRaw = $null
    $OrigProcWindir = $env:windir
    $ExitCode = $null

    try {
        # Preparation shared by all methods: experiment flag + hidden AllowUninstall flag
        if ($null -ne (Get-ItemProperty -Path $ClientKey -Name "experiment_control_labels" -ErrorAction SilentlyContinue)) {
            Remove-ItemProperty -Path $ClientKey -Name "experiment_control_labels" -Force -ErrorAction Stop
            Write-Log "    Cleared the Edge experiment flag"
        }
        if (-not (Test-Path $DevKey)) {
            New-Item -Path $DevKey -Force -ErrorAction Stop | Out-Null
            $CreatedDevKey = $true
        }
        Set-ItemProperty -Path $DevKey -Name "AllowUninstall" -Value "" -Type String -Force -ErrorAction Stop
        Write-Log "    Set the AllowUninstall flag"

        # Methods 1 and 3: make the installer think the old Edge (UWP) is still installed
        if ($Method -eq 1 -or $Method -eq 3) {
            if (-not (Test-Path $MarkerExe)) {
                if (-not (Test-Path $EdgeUwpPath)) {
                    New-Item -Path $EdgeUwpPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    $CreatedMarkerDir = $true
                }
                New-Item -Path $MarkerExe -ItemType File -Force -ErrorAction Stop | Out-Null
                $CreatedMarkerFile = $true
            }
            Write-Log "    Placed the legacy-Edge marker file"
        }

        # Method 3: launch through a copy of cmd.exe that is named dllhost.exe
        if ($Method -eq 3) {
            $TempRoot = "$env:SystemRoot\SystemTemp"
            if (-not (Test-Path $TempRoot)) {
                $TempRoot = (New-Item "$env:SystemRoot\Temp\$([guid]::NewGuid().Guid)" -ItemType Directory -ErrorAction Stop).FullName
            }
            $FakeDllhost = Join-Path $TempRoot "dllhost.exe"
            Copy-Item "$env:SystemRoot\System32\cmd.exe" -Destination $FakeDllhost -Force -ErrorAction Stop
            Write-Log "    Prepared the launcher: $FakeDllhost"
        }

        # Method 2: the installer allows uninstall when 'windir' is not defined. Blank it for the
        # duration of the uninstall only; the original value is restored in the 'finally' block.
        if ($Method -eq 2) {
            $Key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
            $OrigWindirRaw = $Key.GetValue('windir', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $Key.Close()
            if ([string]::IsNullOrEmpty($OrigWindirRaw)) { $OrigWindirRaw = '%SystemRoot%' }
            $WindirChanged = $true
            Set-ItemProperty -Path $EnvPath -Name 'windir' -Value '' -Type ExpandString -ErrorAction Stop
            $env:windir = [System.Environment]::GetEnvironmentVariable('windir', [System.EnvironmentVariableTarget]::Machine)
            Write-Log "    Temporarily cleared the 'windir' variable (will be restored: $OrigWindirRaw)"
        }

        # Run the uninstall
        if (-not $SetupArgs.Contains('--force-uninstall')) { $SetupArgs += ' --force-uninstall' }
        if ($Method -eq 3) {
            Write-Log "    Running (via launcher): $($Parts.Exe) $SetupArgs"
            $Proc = Start-Process -FilePath $FakeDllhost -ArgumentList "/c `"$($Parts.Exe)`" $SetupArgs" -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        } else {
            Write-Log "    Running: $($Parts.Exe) $SetupArgs"
            $Proc = Start-Process -FilePath $Parts.Exe -ArgumentList $SetupArgs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        }
        $ExitCode = $Proc.ExitCode
        Write-Log "    Installer finished: exit code $ExitCode - $(Get-FGNEdgeExitMeaning $ExitCode)"
    } catch {
        Write-Log "    Could not complete this method: $($_.Exception.Message)"
    } finally {
        # Restore 'windir' FIRST - it affects the whole system while it is blank
        if ($WindirChanged) {
            Set-ItemProperty -Path $EnvPath -Name 'windir' -Value $OrigWindirRaw -Type ExpandString -ErrorAction SilentlyContinue
            $env:windir = $OrigProcWindir
            $Check = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
            $Now = $Check.GetValue('windir', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $Check.Close()
            Write-Log "    'windir' restored to: $Now"
        }
        # Remove every temporary item this function created
        if ($CreatedMarkerFile) { Remove-Item -LiteralPath $MarkerExe -Force -ErrorAction SilentlyContinue }
        if ($CreatedMarkerDir)  { Remove-Item -LiteralPath $EdgeUwpPath -Force -ErrorAction SilentlyContinue }
        if ($FakeDllhost)       { Remove-Item -LiteralPath $FakeDllhost -Force -ErrorAction SilentlyContinue }
        if ($CreatedDevKey) {
            Remove-Item -Path $DevKey -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $DevKey -Name "AllowUninstall" -ErrorAction SilentlyContinue
        }
        Write-Log "    Temporary helper items removed"
    }
    return $ExitCode
}

# ---------------------------------------------------------------------------
# ONEDRIVE REMOVAL HELPERS (used by Section 13)
# Same logic as FGN-Remove-OneDrive.ps1. OneDrive is installed PER USER, so this
# handles every profile: this account and any machine-wide install are removed
# directly; other users get a one-time RunOnce job that runs OneDrive's own
# uninstaller in THEIR session at next sign-in. User files are never deleted.
# ---------------------------------------------------------------------------
$OneDriveCurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$OneDriveMachineRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
$OneDriveUninstallSubPath = "Software\Microsoft\Windows\CurrentVersion\Uninstall"
$OneDriveAllowManualRemoval = -not $NoManualOneDriveRemoval   # unattended: fall back to a manual removal if OneDrive's own uninstallers fail

function Format-FGNExitCode {
    # Negative exit codes are Windows HRESULTs - show them in hex (for example 0x8004069B)
    param([int]$Code)
    if ($Code -lt 0) { return ('{0} (0x{1:X8})' -f $Code, [BitConverter]::ToUInt32([BitConverter]::GetBytes($Code), 0)) }
    return "$Code"
}

function Invoke-FGNUserHive {
    # Runs a script block against a user's registry hive: the live one if that user is signed in,
    # otherwise their NTUSER.DAT is loaded temporarily and unloaded afterwards.
    param([string]$Sid, [string]$ProfilePath, [scriptblock]$Action, [object[]]$ArgumentList = @())
    $Temp = $null
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$Sid") {
        $Root = "Registry::HKEY_USERS\$Sid"
    } else {
        $HiveFile = Join-Path $ProfilePath 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $HiveFile)) { return $null }
        $Temp = 'FGN_OD_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        & reg.exe load "HKU\$Temp" $HiveFile 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $Root = "Registry::HKEY_USERS\$Temp"
    }
    try {
        & $Action $Root @ArgumentList
    } finally {
        if ($Temp) {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$Temp" 2>$null | Out-Null
        }
    }
}

function Get-FGNOneDriveProfiles {
    $List = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($Key in @(Get-ChildItem -Path $List -ErrorAction SilentlyContinue)) {
        $Sid = $Key.PSChildName
        if ($Sid -notmatch '^S-1-(5-21|12-1)-') { continue }
        $Path = (Get-ItemProperty -Path $Key.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { continue }
        [pscustomobject]@{
            Sid       = $Sid
            Name      = (Split-Path -Path $Path -Leaf)
            Path      = $Path
            IsCurrent = ($Sid -eq $OneDriveCurrentSid)
        }
    }
}

function Get-FGNOneDriveEntries {
    # OneDrive is listed as "Microsoft OneDrive" in the uninstall list (the key name varies)
    param([string[]]$Roots, [string]$Scope)
    $Found = @()
    foreach ($Root in $Roots) {
        $Found += @(Get-ChildItem -Path $Root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -eq 'Microsoft OneDrive' -and $_.UninstallString } |
            ForEach-Object {
                [pscustomobject]@{
                    Scope           = $Scope
                    Version         = $_.DisplayVersion
                    UninstallString = $_.UninstallString
                }
            })
    }
    @($Found)
}

function Get-FGNOneDriveFolderRisk {
    # Does a OneDrive folder hold files, and are any of them cloud-only placeholders?
    # (checks up to 20,000 files so a huge folder cannot make the scan crawl)
    param([string]$Path)
    $First = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    $Cloud = $null
    if ($First) {
        # 0x1000 Offline, 0x40000 RecallOnOpen, 0x400000 RecallOnDataAccess = Files On-Demand placeholders
        $Cloud = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Select-Object -First 20000 |
            Where-Object { ([int]$_.Attributes -band 0x441000) -ne 0 } |
            Select-Object -First 1
    }
    [pscustomobject]@{ Path = $Path; HasFiles = [bool]$First; CloudOnly = [bool]$Cloud }
}

function Get-FGNOneDriveProfileReport {
    param($UserProfile)

    $Data = Invoke-FGNUserHive -Sid $UserProfile.Sid -ProfilePath $UserProfile.Path -Action {
        param($Root)

        $Accounts = @()
        foreach ($A in @(Get-ChildItem -Path "$Root\Software\Microsoft\OneDrive\Accounts" -ErrorAction SilentlyContinue)) {
            $Email = (Get-ItemProperty -Path $A.PSPath -ErrorAction SilentlyContinue).UserEmail
            if ($Email) { $Accounts += "$($A.PSChildName): $Email" }
        }

        # Desktop / Documents / Pictures redirected into OneDrive ("folder backup")
        $Kfm = @()
        $Shell = Get-ItemProperty -Path "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
        foreach ($Name in @('Desktop', 'Personal', 'My Pictures')) {
            $Value = $Shell.$Name
            if ($Value -and $Value -like '*OneDrive*') { $Kfm += $Name }
        }

        $Entries = @(Get-FGNOneDriveEntries -Roots @("$Root\$OneDriveUninstallSubPath") -Scope User)
        [pscustomobject]@{ Accounts = $Accounts; Kfm = $Kfm; Entries = $Entries }
    }

    $Folders = @()
    foreach ($Dir in @(Get-ChildItem -LiteralPath $UserProfile.Path -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
        $Folders += Get-FGNOneDriveFolderRisk -Path $Dir.FullName
    }
    $ExePresent = Test-Path -LiteralPath (Join-Path $UserProfile.Path 'AppData\Local\Microsoft\OneDrive\OneDrive.exe')

    if ($null -eq $Data) {
        return [pscustomobject]@{
            Profile = $UserProfile; HiveOk = $false; Accounts = @(); Kfm = @(); Entries = @()
            Folders = $Folders; ExePresent = $ExePresent; Installed = $ExePresent
        }
    }
    [pscustomobject]@{
        Profile    = $UserProfile
        HiveOk     = $true
        Accounts   = @($Data.Accounts)
        Kfm        = @($Data.Kfm)
        Entries    = @($Data.Entries)
        Folders    = $Folders
        ExePresent = $ExePresent
        Installed  = (@($Data.Entries).Count -gt 0 -or $ExePresent)
    }
}

function Get-FGNOneDriveRiskReasons {
    param($Report)
    $Reasons = @()
    if (@($Report.Accounts).Count -gt 0) { $Reasons += "signed in ($(@($Report.Accounts) -join '; '))" }
    if (@($Report.Kfm).Count -gt 0)      { $Reasons += "folder backup is on for: $(@($Report.Kfm) -join ', ')" }
    foreach ($F in @($Report.Folders)) {
        if ($F.CloudOnly)     { $Reasons += "cloud-only files in '$($F.Path)'" }
        elseif ($F.HasFiles)  { $Reasons += "files in '$($F.Path)'" }
    }
    @($Reasons)
}

function Stop-FGNOneDriveProcesses {
    # Only this account's processes, unless a machine-wide install is being removed
    param([bool]$AllUsers)
    $Names = @('OneDrive', 'OneDriveSetup', 'FileCoAuth', 'FileSyncHelper', 'OneDriveStandaloneUpdater')
    $Procs = @(Get-Process -Name $Names -IncludeUserName -ErrorAction SilentlyContinue)
    if (-not $AllUsers) { $Procs = @($Procs | Where-Object { $_.UserName -like "*\$env:USERNAME" }) }
    if ($Procs.Count -gt 0) {
        $Procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Log "  Stopped $($Procs.Count) OneDrive process(es)"
        Start-Sleep -Seconds 2
    }
}

function New-FGNOneDriveRunOnceCommand {
    # The command stored in another user's RunOnce key: closes OneDrive, then runs ITS OWN uninstaller
    param([string]$Exe, [string]$Arguments)
    $SafeExe = $Exe.Replace("'", "''")
    $SafeArgs = $Arguments.Replace("'", "''")
    $Inner = "Stop-Process -Name OneDrive,FileCoAuth -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; " +
             "Start-Process -FilePath '$SafeExe' -ArgumentList '$SafeArgs' -Wait"
    return 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "' + $Inner + '"'
}

function Protect-FGNOneDriveFolders {
    # Deny "delete" on the OneDrive folders while the uninstaller runs (the same protection winutil uses)
    param($Folders, [bool]$Apply)
    foreach ($F in @($Folders)) {
        if (-not (Test-Path -LiteralPath $F.Path)) { continue }
        if ($Apply) {
            & icacls.exe $F.Path /deny "*S-1-5-32-544:(D,DC)" | Out-Null
        } else {
            & icacls.exe $F.Path /remove:d "*S-1-5-32-544" | Out-Null
        }
    }
}

function Get-FGNLockingProcesses {
    # This account's processes that are running from, or have loaded a file from, a folder
    param([string]$Folder)
    $Found = @()
    foreach ($P in @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue)) {
        if ($P.Id -eq $PID) { continue }
        if ($P.UserName -notlike "*\$env:USERNAME") { continue }
        $Hit = $false
        try {
            if ($P.Path -and $P.Path -like "$Folder\*") {
                $Hit = $true
            } elseif (@($P.Modules | Where-Object { $_.FileName -like "$Folder\*" }).Count -gt 0) {
                $Hit = $true
            }
        } catch { }
        if ($Hit) { $Found += $P }
    }
    @($Found)
}

function Remove-FGNLockedDirectory {
    # Deletes a folder; if something is holding files open, finds and stops those programs and retries.
    # Returns $false if the folder is still there afterwards.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    for ($Try = 1; $Try -le 3; $Try++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Log "    Removed: $Path"
            return $true
        }
        $Holders = @(Get-FGNLockingProcesses -Folder $Path)
        if ($Holders.Count -gt 0) {
            Write-Log "    In use by: $((@($Holders | ForEach-Object { $_.ProcessName } | Select-Object -Unique)) -join ', ') - stopping them"
            $Holders | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Set-FGNDeleteAtSignIn {
    # Last resort for files that stay locked: delete them the next time this user signs in
    param($UserProfile, [string[]]$Paths)
    $Command = 'cmd.exe /c ' + ((@($Paths | ForEach-Object { 'rd /s /q "' + $_ + '"' })) -join ' & ')
    [void](Invoke-FGNUserHive -Sid $UserProfile.Sid -ProfilePath $UserProfile.Path -ArgumentList @($Command) -Action {
        param($Root, $DeleteCommand)
        $Key = "$Root\Software\Microsoft\Windows\CurrentVersion\RunOnce"
        if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
        New-ItemProperty -Path $Key -Name 'FGN-OneDriveLeftovers' -Value $DeleteCommand -PropertyType String -Force | Out-Null
    })
}

function Get-FGNOneDriveUninstallAttempts {
    # The ordered list of ways to uninstall, without repeats:
    #   1. the uninstall command Windows registered
    #   2. the OneDrive setup program that ships with Windows
    #   3. any other OneDrive version folder in the user's profile (newest first) - useful when the
    #      registered one is broken
    param([string[]]$Registered, [string]$UserOneDrivePath, [string[]]$SystemSetups)
    $List = New-Object System.Collections.ArrayList
    $Seen = @{}

    foreach ($Cmd in @($Registered)) {
        $P = Split-FGNCommand $Cmd
        $Key = $P.Exe.Replace('/', '\').ToLowerInvariant()
        if ($Seen.ContainsKey($Key)) { continue }
        $Seen[$Key] = $true
        $Args2 = if ($P.Arguments) { $P.Arguments } else { '/uninstall' }
        [void]$List.Add([pscustomobject]@{ Label = 'registered uninstaller'; Exe = $P.Exe; Arguments = $Args2 })
    }
    foreach ($Setup in @($SystemSetups)) {
        if (-not (Test-Path -LiteralPath $Setup)) { continue }
        $Key = $Setup.Replace('/', '\').ToLowerInvariant()
        if ($Seen.ContainsKey($Key)) { continue }
        $Seen[$Key] = $true
        [void]$List.Add([pscustomobject]@{ Label = 'setup program shipped with Windows'; Exe = $Setup; Arguments = '/uninstall' })
    }
    $Versions = @(Get-ChildItem -LiteralPath $UserOneDrivePath -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending)
    foreach ($Dir in $Versions) {
        $Setup = Join-Path $Dir.FullName 'OneDriveSetup.exe'
        if (-not (Test-Path -LiteralPath $Setup)) { continue }
        $Key = $Setup.Replace('/', '\').ToLowerInvariant()
        if ($Seen.ContainsKey($Key)) { continue }
        $Seen[$Key] = $true
        [void]$List.Add([pscustomobject]@{ Label = "OneDrive version $($Dir.Name)"; Exe = $Setup; Arguments = '/uninstall' })
    }
    @($List)
}

function Test-FGNOneDriveRegistered {
    # Does Windows still list OneDrive as installed (for this account / machine-wide)?
    param($UserProfile, [bool]$CheckMachine)
    $UserCount = Invoke-FGNUserHive -Sid $UserProfile.Sid -ProfilePath $UserProfile.Path -Action {
        param($Root)
        @(Get-FGNOneDriveEntries -Roots @("$Root\$OneDriveUninstallSubPath") -Scope User).Count
    }
    $MachineCount = 0
    if ($CheckMachine) { $MachineCount = @(Get-FGNOneDriveEntries -Roots $OneDriveMachineRoots -Scope Machine).Count }
    return (([int]$UserCount -gt 0) -or ($MachineCount -gt 0))
}

function Wait-FGNOneDriveRemoved {
    # The uninstaller can take a little while after it returns
    param($UserProfile, [bool]$CheckMachine)
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Test-FGNOneDriveRegistered -UserProfile $UserProfile -CheckMachine $CheckMachine)) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Invoke-FGNOneDriveManualRemoval {
    # Only used when OneDrive's own uninstallers cannot run. Removes the program, its Installed-apps
    # entry and autostart for this account. It NEVER touches the user's OneDrive folder or files.
    param($UserProfile)
    Write-Log "  Manual removal for '$($UserProfile.Name)' (OneDrive's own uninstaller could not run)..."

    Invoke-FGNUserHive -Sid $UserProfile.Sid -ProfilePath $UserProfile.Path -Action {
        param($Root)
        foreach ($Name in @('OneDrive', 'OneDriveSetup')) {
            Remove-ItemProperty -Path "$Root\Software\Microsoft\Windows\CurrentVersion\Run" -Name $Name -ErrorAction SilentlyContinue
        }
        # the Installed-apps entry (its key name varies, so match on the display name)
        foreach ($Key in @(Get-ChildItem -Path "$Root\$OneDriveUninstallSubPath" -ErrorAction SilentlyContinue)) {
            $Name = (Get-ItemProperty -Path $Key.PSPath -ErrorAction SilentlyContinue).DisplayName
            if ($Name -eq 'Microsoft OneDrive') { Remove-Item -Path $Key.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
        # File Explorer sidebar entry added for this user
        Remove-Item -Path "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Recurse -Force -ErrorAction SilentlyContinue
    } | Out-Null
    Write-Log "    Removed OneDrive's autostart, Installed-apps entry and Explorer sidebar entry"
}

function Invoke-FGNOneDriveCleanup {
    # Runs only AFTER OneDrive has really been uninstalled (or removed manually)
    param($Report, [bool]$HasMachineWide, [bool]$KeepSharedData)
    $UserProfile = $Report.Profile
    $LocalOneDrive = "$($UserProfile.Path)\AppData\Local\Microsoft\OneDrive"

    # Unregister OneDrive's Explorer extension so its files are no longer locked
    $Dlls = @()
    $Dlls += @(Get-ChildItem -Path "$LocalOneDrive\*\FileSyncShell64.dll" -Force -ErrorAction SilentlyContinue)
    $Dlls += @(Get-ChildItem -Path "$env:ProgramFiles\Microsoft OneDrive\*\FileSyncShell64.dll" -Force -ErrorAction SilentlyContinue)
    foreach ($Dll in $Dlls) {
        Start-Process -FilePath "$env:SystemRoot\System32\regsvr32.exe" -ArgumentList "/u /s `"$($Dll.FullName)`"" -Wait -ErrorAction SilentlyContinue
        Write-Log "  Unregistered Explorer extension: $($Dll.FullName)"
    }

    # Leftover program folders (programs holding them open are found and stopped, then it retries)
    Write-Log "  Cleaning leftovers..."
    $Leftovers = @(
        $LocalOneDrive
        "$($UserProfile.Path)\AppData\Local\OneDrive"
        "$env:SystemDrive\OneDriveTemp"
    )
    if (-not $KeepSharedData) { $Leftovers += "$env:ProgramData\Microsoft OneDrive" }
    if ($HasMachineWide) { $Leftovers += "$env:ProgramFiles\Microsoft OneDrive" }
    $Stuck = @()
    foreach ($Path in $Leftovers) {
        if (-not (Remove-FGNLockedDirectory -Path $Path)) { $Stuck += $Path }
    }
    if ($Stuck.Count -gt 0) {
        Set-FGNDeleteAtSignIn -UserProfile $UserProfile -Paths $Stuck
        foreach ($Path in $Stuck) { Write-Log "    [NOTE] $Path is still locked - it will be deleted the next time this user signs in" }
    }

    # Start-menu shortcut, per-user registry and scheduled tasks
    $Lnk = "$($UserProfile.Path)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"
    if (Test-Path -LiteralPath $Lnk) { Remove-Item -LiteralPath $Lnk -Force -ErrorAction SilentlyContinue; Write-Log "    Removed: $Lnk" }
    Invoke-FGNUserHive -Sid $UserProfile.Sid -ProfilePath $UserProfile.Path -Action {
        param($Root)
        Remove-Item -Path "$Root\Software\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
    } | Out-Null

    foreach ($Task in @(Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue)) {
        # tasks named with another user's SID belong to that user - leave them
        if ($Task.TaskName -match 'S-1-(5-21|12-1)-[\d-]+' -and $Task.TaskName -notlike "*$($UserProfile.Sid)*") { continue }
        Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "    Removed scheduled task: $($Task.TaskName)"
    }

    # An EMPTY OneDrive folder is removed; one with files is kept untouched
    $RemovedEmpty = $false
    foreach ($F in @($Report.Folders)) {
        if (-not (Test-Path -LiteralPath $F.Path)) { continue }
        $Left = Get-ChildItem -LiteralPath $F.Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Left) {
            Write-Log "    [KEPT] $($F.Path) still holds files - left untouched"
        } else {
            Remove-Item -LiteralPath $F.Path -Force -ErrorAction SilentlyContinue
            Write-Log "    Removed empty folder: $($F.Path)"
            $RemovedEmpty = $true
        }
    }
    if ($RemovedEmpty) {
        Invoke-FGNUserHive -Sid $UserProfile.Sid -ProfilePath $UserProfile.Path -Action {
            param($Root)
            foreach ($Name in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
                Remove-ItemProperty -Path "$Root\Environment" -Name $Name -ErrorAction SilentlyContinue
            }
        } | Out-Null
    }
}

function Invoke-FGNOneDriveCurrentRemoval {
    # Removes OneDrive for the machine-wide install and for the account running the script.
    # Result is left in $script:OneDriveRemovalStatus: Removed | Manual | Failed
    param($Report, [bool]$HasMachineWide, [bool]$KeepSharedData)

    $UserProfile = $Report.Profile
    $script:OneDriveRemovalStatus = 'Failed'
    Stop-FGNOneDriveProcesses -AllUsers $HasMachineWide

    # the uninstall commands Windows registered: machine-wide first, then this account's own
    $Registered = @()
    foreach ($E in @(Get-FGNOneDriveEntries -Roots $OneDriveMachineRoots -Scope Machine)) { $Registered += $E.UninstallString }
    foreach ($E in @($Report.Entries)) { $Registered += $E.UninstallString }

    $SystemSetups = @()
    if (-not $HasMachineWide) { $SystemSetups = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") }
    $Attempts = @(Get-FGNOneDriveUninstallAttempts -Registered $Registered -UserOneDrivePath "$($UserProfile.Path)\AppData\Local\Microsoft\OneDrive" -SystemSetups $SystemSetups)

    if ($Attempts.Count -eq 0) {
        Write-Log "  No OneDrive uninstaller could be found"
    }

    $Removed = $false
    Protect-FGNOneDriveFolders -Folders $Report.Folders -Apply $true
    try {
        foreach ($A in $Attempts) {
            Write-Log "  Attempt: $($A.Label)"
            Write-Log "    $($A.Exe) $($A.Arguments)"
            if (-not (Test-Path -LiteralPath $A.Exe)) {
                Write-Log "    That file no longer exists - this OneDrive install is damaged. Skipping it."
                continue
            }
            try {
                $Proc = Start-Process -FilePath $A.Exe -ArgumentList $A.Arguments -Wait -PassThru -ErrorAction Stop
                Write-Log "    Uninstaller finished (exit code $(Format-FGNExitCode $Proc.ExitCode))"
            } catch {
                Write-Log "    Could not run it: $($_.Exception.Message)"
                continue
            }
            if (Wait-FGNOneDriveRemoved -UserProfile $UserProfile -CheckMachine $HasMachineWide) {
                $Removed = $true
                Write-Log "    OneDrive is no longer registered - the uninstall worked"
                break
            }
            Write-Log "    OneDrive is still registered after this attempt"
        }
    } finally {
        Protect-FGNOneDriveFolders -Folders $Report.Folders -Apply $false
    }

    if ($Removed) {
        $script:OneDriveRemovalStatus = 'Removed'
    } elseif ($HasMachineWide) {
        Write-Log "  [FAILED] The machine-wide install could not be uninstalled. Nothing else was changed."
        return
    } else {
        # OneDrive's own uninstallers cannot run on this PC - remove it manually (never touches the user's files)
        if (-not $OneDriveAllowManualRemoval) {
            Write-Log "  [FAILED] OneDrive's own uninstallers failed and manual removal is turned off (-NoManualOneDriveRemoval). Nothing was cleaned up."
            return
        }
        Write-Log "  OneDrive's own uninstallers failed - removing it manually (its program, Installed-apps entry and autostart; never your files)"
        Invoke-FGNOneDriveManualRemoval -UserProfile $UserProfile
        $script:OneDriveRemovalStatus = 'Manual'
    }

    Invoke-FGNOneDriveCleanup -Report $Report -HasMachineWide $HasMachineWide -KeepSharedData $KeepSharedData
}

function Set-FGNOneDriveOtherProfileRunOnce {
    # Adds a one-time uninstall job to ANOTHER user's registry; it runs in their session at next sign-in
    param($Report)
    $UserProfile = $Report.Profile

    # Prefer that user's own registered uninstaller; otherwise use the setup program Windows ships
    $Exe = $null
    $Arguments = '/uninstall'
    foreach ($E in @($Report.Entries)) {
        $Parts = Split-FGNCommand $E.UninstallString
        if ($Parts.Exe) {
            $Exe = $Parts.Exe
            if ($Parts.Arguments) { $Arguments = $Parts.Arguments }
            break
        }
    }
    if (-not $Exe) {
        foreach ($Setup in @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe")) {
            if (Test-Path -LiteralPath $Setup) { $Exe = $Setup; break }
        }
    }
    if (-not $Exe) { return $false }

    $Command = New-FGNOneDriveRunOnceCommand -Exe $Exe -Arguments $Arguments
    $Result = Invoke-FGNUserHive -Sid $UserProfile.Sid -ProfilePath $UserProfile.Path -ArgumentList @($Command) -Action {
        param($Root, $RunOnceCommand)
        $Key = "$Root\Software\Microsoft\Windows\CurrentVersion\RunOnce"
        if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
        New-ItemProperty -Path $Key -Name 'FGN-RemoveOneDrive' -Value $RunOnceCommand -PropertyType String -Force | Out-Null
        $true
    }
    return [bool]$Result
}

function Clear-FGNOneDriveDefaultProfileRun {
    # New users get OneDrive installed at first sign-in through this entry in the Default profile
    $DefaultPath = "$env:SystemDrive\Users\Default"
    $Result = Invoke-FGNUserHive -Sid 'S-0-0-FGN-DEFAULT' -ProfilePath $DefaultPath -Action {
        param($Root)
        $Run = "$Root\Software\Microsoft\Windows\CurrentVersion\Run"
        if ($null -ne (Get-ItemProperty -Path $Run -Name 'OneDriveSetup' -ErrorAction SilentlyContinue)) {
            Remove-ItemProperty -Path $Run -Name 'OneDriveSetup' -Force -ErrorAction SilentlyContinue
            'removed'
        } else {
            'absent'
        }
    }
    return $Result
}

# ---------------------------------------------------------------------------
# BLUETOOTH HELPERS (used by Section 11)
# Same logic and the same saved-state file as FGN-Disable-Bluetooth.ps1, so
# that script's -Enable switch can put everything back.
# ---------------------------------------------------------------------------
$BtStateDir = "$env:ProgramData\FGN"
$BtStatePath = Join-Path $BtStateDir 'Bluetooth-State.json'
$BtServiceDefaults = [ordered]@{
    'bthserv'              = 3   # Bluetooth Support Service
    'BthAvctpSvc'          = 3   # AVCTP service (Bluetooth audio/remote control)
    'BTAGService'          = 3   # Bluetooth Audio Gateway Service
    'BluetoothUserService' = 3   # Bluetooth User Support Service (per-user template)
}

function Get-FGNBtRole {
    # What kind of Bluetooth device node is this? (decided from its instance ID)
    #   Radio          the adapter itself (USB / PCI / ACPI ...)       <- what gets disabled
    #   Enumerator     Windows' own Bluetooth enumerators (BTH\...)
    #   PairedDevice   a paired phone/headset/keyboard (BTHENUM\DEV_ / BTHLE\DEV_)
    #   ProfileService a service of a paired device
    param([string]$InstanceId)
    if ($InstanceId -match '^(BTHENUM|BTHLE)\\DEV_') { return 'PairedDevice' }
    if ($InstanceId -match '^(BTHENUM|BTHLE)\\')     { return 'ProfileService' }
    if ($InstanceId -match '^BTH\\')                 { return 'Enumerator' }
    return 'Radio'
}

function Test-FGNBtInputId {
    # A Bluetooth keyboard/mouse shows up as a HID device whose ID carries the Bluetooth HID service ID
    param([string]$InstanceId)
    return [bool]($InstanceId -match '^HID\\\{0000(1124|1812)-0000-1000-8000-00805F9B34FB\}')
}

function Test-FGNBtDeviceDisabled {
    param($Device)
    return (($Device.ConfigManagerErrorCode -eq 22) -or ($Device.Problem -eq 'CM_PROB_DISABLED'))
}

function Get-FGNBtInputSummary {
    # Keyboards and pointing devices as Windows reports them. One list per kind is split into
    # Bluetooth (HID over Bluetooth) and everything else, so the two counts always add up.
    $Keyboards = @(Get-CimInstance -ClassName Win32_Keyboard -ErrorAction SilentlyContinue)
    $Pointers  = @(Get-CimInstance -ClassName Win32_PointingDevice -ErrorAction SilentlyContinue)

    $BtKeyboards = @($Keyboards | Where-Object { Test-FGNBtInputId $_.PNPDeviceID })
    $BtMice      = @($Pointers  | Where-Object { Test-FGNBtInputId $_.PNPDeviceID })

    [pscustomobject]@{
        BtKeyboards    = $BtKeyboards
        BtMice         = $BtMice
        NonBtKeyboards = @($Keyboards | Where-Object { -not (Test-FGNBtInputId $_.PNPDeviceID) -and $_.PNPDeviceID -notmatch '^BTH' }).Count
        NonBtPointers  = @($Pointers  | Where-Object { -not (Test-FGNBtInputId $_.PNPDeviceID) -and $_.PNPDeviceID -notmatch '^BTH' }).Count
    }
}

function Get-FGNBtServiceStart {
    param([string]$Name)
    $Key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $Key)) { return $null }
    return (Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue).Start
}

function Set-FGNBtServiceStart {
    param([string]$Name, [int]$Value)
    $Key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $Key)) { return $false }
    Set-ItemProperty -LiteralPath $Key -Name Start -Value $Value -Type DWord -ErrorAction Stop
    return $true
}

function Read-FGNBtState {
    if (-not (Test-Path -LiteralPath $BtStatePath)) { return $null }
    try { return (Get-Content -LiteralPath $BtStatePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-FGNBtState {
    # Records ORIGINAL values only: anything already recorded is kept, so re-running never overwrites the original
    param($Services, $Devices)
    $Old = Read-FGNBtState
    $Svc = @(); $Dev = @()
    if ($Old) { $Svc = @($Old.Services); $Dev = @($Old.Devices) }
    foreach ($S in @($Services)) { if (@($Svc | Where-Object { $_.Name -eq $S.Name }).Count -eq 0) { $Svc += $S } }
    foreach ($D in @($Devices))  { if (@($Dev | Where-Object { $_.InstanceId -eq $D.InstanceId }).Count -eq 0) { $Dev += $D } }
    if (-not (Test-Path -LiteralPath $BtStateDir)) { New-Item -Path $BtStateDir -ItemType Directory -Force | Out-Null }
    [pscustomobject]@{
        Saved    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Services = $Svc
        Devices  = $Dev
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $BtStatePath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# REMOTE DESKTOP CONNECTION HELPER (used by Section 17)
# ---------------------------------------------------------------------------
$RdcMinimumBuild = 22631   # Windows 11 23H2 - the first version where Microsoft supports uninstalling it

function Test-FGNRdcRemovalSupported {
    param([int]$Build)
    return ($Build -ge $RdcMinimumBuild)
}

# ---------------------------------------------------------------------------
# AUTOMATIC DECISIONS (these replace the questions the interactive version asked)
# ---------------------------------------------------------------------------
function Get-FGNOneDriveStrandReasons {
    # Removing OneDrive would strand a user's data when Desktop/Documents/Pictures are backed up into
    # it, or when files exist only in the cloud (they become unreadable until OneDrive is set up again)
    param($Report)
    $Reasons = @()
    if (@($Report.Kfm).Count -gt 0) { $Reasons += "folder backup is on for: $(@($Report.Kfm) -join ', ')" }
    foreach ($F in @($Report.Folders)) {
        if ($F.CloudOnly) { $Reasons += "cloud-only files in '$($F.Path)'" }
    }
    @($Reasons)
}

function Select-FGNOneDriveTargets {
    param($Installed, [bool]$IncludeRisky)
    $Targets = @(); $Excluded = @()
    foreach ($R in @($Installed)) {
        if ($IncludeRisky -or @(Get-FGNOneDriveStrandReasons -Report $R).Count -eq 0) { $Targets += $R } else { $Excluded += $R }
    }
    [pscustomobject]@{ Targets = $Targets; Excluded = $Excluded }
}

function Get-FGNSectionSelection {
    # Which sections run, from -Only / -Skip (values may be given as 13,16 or "13 16")
    param([string[]]$AllKeys, [string[]]$Only, [string[]]$Skip)
    $OnlyList = @(@($Only) | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })
    $SkipList = @(@($Skip) | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })
    $Enabled = @()
    foreach ($Key in $AllKeys) {
        if ($OnlyList.Count -gt 0 -and $OnlyList -notcontains $Key) { continue }
        if ($SkipList -contains $Key) { continue }
        $Enabled += $Key
    }
    [pscustomobject]@{
        Enabled     = $Enabled
        UnknownOnly = @($OnlyList | Where-Object { $AllKeys -notcontains $_ })
        UnknownSkip = @($SkipList | Where-Object { $AllKeys -notcontains $_ })
    }
}

# ---------------------------------------------------------------------------
# SECTIONS - everything runs unattended. Leave sections out with  -Skip 13,16  (or -Only 6,7),
# or change Enabled below.
# ---------------------------------------------------------------------------
$Sections = [ordered]@{
    "1"  = @{ Name = "Remove consumer UWP bloatware (Xbox, Spotify, social apps, Teams chat, Copilot, Dev Home ...)"; Enabled = $true }
    "2"  = @{ Name = "Disable ads / suggestions / tips";                                  Enabled = $true }
    "3"  = @{ Name = "Reduce telemetry to Basic level";                                   Enabled = $true }
    "4"  = @{ Name = "Disable non-essential scheduled tasks (CEIP, error reporting)";     Enabled = $true }
    "5"  = @{ Name = "Clean up taskbar/start menu (Widgets, Meet Now, Chat icon)";        Enabled = $true }
    "6"  = @{ Name = "Disable AI features (Recall, Copilot, AI-powered search, Edge sidebar)"; Enabled = $true }
    "7"  = @{ Name = "Low-risk tweaks (OneDrive autostart, Fast Startup, Game Bar, etc.)"; Enabled = $true }
    "8"  = @{ Name = "Medium-value tweaks (SysMain, Delivery Optimization, Remote Assist)"; Enabled = $true }
    "9"  = @{ Name = "Extra tweaks (DiagTrack, WAP Push, Cloud Clipboard, Shared Exp, WiFi Sense, Ink)"; Enabled = $true }
    "10" = @{ Name = "Disable unused services (Fax, Downloaded Maps, Retail Demo, Insider)"; Enabled = $true }
    "11" = @{ Name = "Disable Bluetooth (adapter + services; skipped if it would remove the only keyboard)"; Enabled = $true }
    "12" = @{ Name = "Startup Programs Report (list only - does NOT disable anything)";   Enabled = $true }
    "13" = @{ Name = "Uninstall OneDrive for all profiles (skips profiles whose files would be stranded)"; Enabled = $true }
    "14" = @{ Name = "Remove Microsoft Store (inbox apps can no longer update via Store)"; Enabled = $true }
    "15" = @{ Name = "Remove Windows Subsystem for Linux (skipped if distros/Docker found)"; Enabled = $true }
    "16" = @{ Name = "Remove Microsoft Edge (skipped if no other browser is installed)";  Enabled = $true }
    "17" = @{ Name = "Remove Remote Desktop Connection (skipped while it is running; restart finishes it)"; Enabled = $true }
}

$Selection = Get-FGNSectionSelection -AllKeys @($Sections.Keys) -Only $Only -Skip $Skip
foreach ($Key in @($Sections.Keys)) { $Sections[$Key].Enabled = ($Selection.Enabled -contains $Key) }

Write-Log "=== FGN Windows 11 Debloat (unattended) started ==="
Write-Log "Running as: $env:USERDOMAIN\$env:USERNAME"
foreach ($Unknown in @($Selection.UnknownOnly + $Selection.UnknownSkip)) { Write-Log "  [WARNING] There is no section '$Unknown' (sections are 1-17)" }
Write-Log "Sections that will run: $((@($Sections.Keys | Where-Object { $Sections[$_].Enabled })) -join ', ')"
$SkippedByRequest = @($Sections.Keys | Where-Object { -not $Sections[$_].Enabled })
if ($SkippedByRequest.Count -gt 0) { Write-Log "Left out on request (-Skip / -Only): $($SkippedByRequest -join ', ')" }

# ---------------------------------------------------------------------------
# SECTION 1: REMOVE CONSUMER BLOATWARE (UWP APPS)
# ---------------------------------------------------------------------------
if ($Sections["1"].Enabled) {
    Write-Log "Section 1: Removing consumer UWP bloatware apps..."

    $AppsToRemove = @(
        "Clipchamp.Clipchamp"
        "*Copilot*"                           # Copilot app + older Copilot provider package
        "*DevHome*"                           # Dev Home (package name differs between builds)
        "Microsoft.OutlookForWindows"         # New Outlook - comment out if clients use it with Microsoft 365
        "MicrosoftWindows.CrossDevice"        # Cross Device Experience Host
        "Microsoft.BingNews"
        "Microsoft.BingWeather"
        "Microsoft.BingSearch"
        "Microsoft.GamingApp"
        "Microsoft.GetHelp"
        "Microsoft.Getstarted"
        "Microsoft.MicrosoftOfficeHub"
        "Microsoft.MicrosoftSolitaireCollection"
        "Microsoft.MixedReality.Portal"
        "Microsoft.People"
        "Microsoft.PowerAutomateDesktop"
        "Microsoft.Todos"
        "Microsoft.WindowsAlarms"
        "Microsoft.WindowsFeedbackHub"
        "Microsoft.WindowsMaps"
        "Microsoft.WindowsSoundRecorder"
        "Microsoft.Xbox.TCUI"
        "Microsoft.XboxApp"
        "Microsoft.XboxGameOverlay"
        "Microsoft.XboxGamingOverlay"
        "Microsoft.XboxIdentityProvider"
        "Microsoft.XboxSpeechToTextOverlay"
        "Microsoft.YourPhone"
        "Microsoft.ZuneMusic"
        "Microsoft.ZuneVideo"
        "MicrosoftCorporationII.MicrosoftFamily"
        "MicrosoftCorporationII.QuickAssist"  # comment out if remote-support tool is needed
        "MSTeams"                             # Teams (24H2 name) - comment out if clients use Teams for work
        "MicrosoftTeams"                      # Teams (older name)
        "SpotifyAB.SpotifyMusic"
        "Disney.37853FC22B2CE"
        "*.Facebook*"
        "*.TikTok*"
        "*.Instagram*"
        "*.Twitter*"
    )

    # PHASE 1 - SCAN: check which of these apps actually exist on this machine
    Write-Log "  Phase 1: scanning for installed/provisioned apps..."
    $ProvisionedList = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    $FoundApps = @()
    foreach ($App in $AppsToRemove) {
        if ((Find-FGNApp -Name $App -ProvisionedList $ProvisionedList).Found) {
            $FoundApps += $App
        }
    }
    $NotFoundCount = $AppsToRemove.Count - $FoundApps.Count
    Write-Log "  Scan result: $($FoundApps.Count) found, $NotFoundCount not present (will be skipped)"

    # PHASE 2 - REMOVE: only the apps found above, each one re-checked and verified
    if ($FoundApps.Count -gt 0) {
        Write-Log "  Phase 2: removing found apps..."
        $ProvisionedList = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        foreach ($App in $FoundApps) {
            Remove-FGNApp -Name $App -ProvisionedList $ProvisionedList
        }
    } else {
        Write-Log "  Nothing to remove - machine is already clean for this list"
    }
    # NOTE: Microsoft Store, Calculator, Notepad, Photos, and Snipping Tool
    # are deliberately NOT included here - commonly needed on business machines.
} else {
    Write-Log "Section 1: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 2: DISABLE ADS / SUGGESTIONS / TIPS
# ---------------------------------------------------------------------------
if ($Sections["2"].Enabled) {
    Write-Log "Section 2: Disabling consumer suggestions, ads, and tips..."

    $RegSettings = @(
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338388Enabled"; Value = 0 },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled"; Value = 0 },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353694Enabled"; Value = 0 },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0 },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SystemPaneSuggestionsEnabled"; Value = 0 },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SoftLandingEnabled"; Value = 0 },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_IrisRecommendations"; Value = 0 },
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsConsumerFeatures"; Value = 1 },
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableSoftLanding"; Value = 1 },
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableThirdPartySuggestions"; Value = 1 }
    )

    foreach ($Setting in $RegSettings) {
        if (-not (Test-Path $Setting.Path)) {
            New-Item -Path $Setting.Path -Force | Out-Null
        }
        New-ItemProperty -Path $Setting.Path -Name $Setting.Name -Value $Setting.Value -PropertyType DWord -Force | Out-Null
        Write-Log "  Set $($Setting.Path)\$($Setting.Name) = $($Setting.Value)"
    }
} else {
    Write-Log "Section 2: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 3: REDUCE TELEMETRY
# ---------------------------------------------------------------------------
if ($Sections["3"].Enabled) {
    Write-Log "Section 3: Reducing telemetry to Basic level..."

    # Telemetry level: 0 = Security (Enterprise/Education only), 1 = Basic
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Log "  Telemetry set to Basic (1)"

    New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Advertising ID disabled"

    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
} else {
    Write-Log "Section 3: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 4: DISABLE NON-ESSENTIAL SCHEDULED TASKS
# ---------------------------------------------------------------------------
if ($Sections["4"].Enabled) {
    Write-Log "Section 4: Disabling non-essential scheduled tasks..."

    $TasksToDisable = @(
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater"
        "\Microsoft\Windows\Autochk\Proxy"
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector"
        "\Microsoft\Windows\Feedback\Siuf\DmClient"
        "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
        "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
        "\Microsoft\Windows\PI\Sqm-Tasks"
    )

    foreach ($Task in $TasksToDisable) {
        $TaskName = Split-Path $Task -Leaf
        $TaskPath = Split-Path $Task -Parent
        $Existing = Get-ScheduledTask -TaskName $TaskName -TaskPath "$TaskPath\" -ErrorAction SilentlyContinue
        if ($Existing) {
            Disable-ScheduledTask -TaskName $TaskName -TaskPath "$TaskPath\" -ErrorAction SilentlyContinue | Out-Null
            Write-Log "  Disabled task: $Task"
        }
    }
    # NOTE: Windows Update tasks, Defender scan tasks, and BITS-related tasks
    # are deliberately left untouched.
} else {
    Write-Log "Section 4: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 5: CLEAN UP TASKBAR / START MENU
# ---------------------------------------------------------------------------
if ($Sections["5"].Enabled) {
    Write-Log "Section 5: Cleaning taskbar/start menu clutter..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -PropertyType DWord -Force | Out-Null

    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarMn" -Value 0 -PropertyType DWord -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "HideSCAMeetNow" -Value 1 -PropertyType DWord -Force | Out-Null

    Write-Log "  Taskbar cleanup complete"
} else {
    Write-Log "Section 5: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 6: DISABLE AI FEATURES (RECALL, COPILOT, AI-POWERED SEARCH)
# ---------------------------------------------------------------------------
if ($Sections["6"].Enabled) {
    Write-Log "Section 6: Disabling AI features (Recall, Copilot, AI search)..."

    # --- Disable Windows Recall (Copilot+ PCs only; harmless no-op on other hardware) ---
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "AllowRecallEnablement" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Recall disabled via policy (no-op if hardware unsupported)"

    # Turn off Recall snapshot storage/search for the current user, if present
    $RecallPath = "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI"
    New-Item -Path $RecallPath -Force | Out-Null
    New-ItemProperty -Path $RecallPath -Name "DisableAIDataAnalysis" -Value 1 -PropertyType DWord -Force | Out-Null

    # --- Disable Copilot ---
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowCopilotButton" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Copilot disabled and taskbar button hidden"

    # Remove Copilot packages if present (scan first; older and newer package names).
    # Also listed in Section 1 - safe to overlap, a second pass just logs NOT FOUND.
    Remove-FGNApp -Name "*Copilot*"

    # Copilot is also installed as a regular program (not an app package) - the AppX scan
    # above cannot see it. Close it, then run the uninstall command Windows registered for it.
    Get-Process -Name "mscopilot", "Copilot" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $CopilotEntries = @(Get-FGNCopilotEntries)
    if ($CopilotEntries.Count -eq 0) {
        Write-Log "  [NOT FOUND] Copilot in the uninstall list - nothing to run"
    } else {
        foreach ($Entry in $CopilotEntries) {
            Write-Log "  [FOUND] Copilot program: $($Entry.DisplayName) v$($Entry.DisplayVersion)"
            Write-Log "          Running: $($Entry.UninstallString)"
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c $($Entry.UninstallString)" -Wait -WindowStyle Hidden
        }
        Start-Sleep -Seconds 3
        if (@(Get-FGNCopilotEntries).Count -eq 0) {
            Write-Log "  [REMOVED] Copilot program"
        } else {
            Write-Log "  [FAILED] Copilot still listed after uninstall - restart and run FGN-Remove-Copilot.ps1 -ScanOnly to see why"
        }
    }

    # Edge's sidebar is where Copilot lives inside the browser - turn the sidebar off by policy
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "HubsSidebarEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Edge sidebar (Copilot) disabled by policy"

    # --- Disable AI-powered / web-blended Windows Search ---
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "ConnectedSearchUseWeb" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "CortanaConsent" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  AI-powered/web-blended search disabled (local search unaffected)"

    # --- Disable Click to Do (Copilot+ screen-aware AI feature, if present) ---
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\ClickToDo" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\ClickToDo" -Name "DisableClickToDo" -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Log "  Click to Do disabled (no-op if hardware unsupported)"

    Write-Log "  NOTE: Recall/Click to Do only apply to Copilot+ PCs (NPU required)."
    Write-Log "        These settings are safe no-ops on standard hardware."
} else {
    Write-Log "Section 6: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 7: LOW-RISK TWEAKS
# ---------------------------------------------------------------------------
if ($Sections["7"].Enabled) {
    Write-Log "Section 7: Applying low-risk tweaks..."

    # --- Disable OneDrive auto-start/sync (does not uninstall OneDrive) ---
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableFileSyncNGSC" -Value 1 -PropertyType DWord -Force | Out-Null
    Get-ScheduledTask -TaskName "OneDrive*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    $OneDriveRun = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Get-ItemProperty -Path $OneDriveRun -Name "OneDrive" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $OneDriveRun -Name "OneDrive" -Force -ErrorAction SilentlyContinue
    }
    Write-Log "  OneDrive auto-start/sync disabled (app still installed, not removed)"

    # --- Disable Fast Startup (Hiberboot) ---
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Fast Startup disabled"

    # --- Disable Game Bar / Game DVR background recording ---
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Game Bar / Game DVR disabled"

    # --- Disable Sticky Keys / Filter Keys popup prompts ---
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Value "506" -Force
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "Flags" -Value "122" -Force
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name "Flags" -Value "58" -Force
    Write-Log "  Sticky/Filter/Toggle Keys prompts disabled"

    # --- Disable lock screen tips and Spotlight ads ---
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "RotatingLockScreenEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "RotatingLockScreenOverlayEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Lock screen tips/Spotlight ads disabled"

    # --- Disable hibernation (desktops only - SKIP if this is a laptop) ---
    $IsLaptop = (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    if (-not $IsLaptop) {
        powercfg /hibernate off
        Write-Log "  Hibernation disabled (desktop detected, frees hiberfil.sys disk space)"
    } else {
        Write-Log "  Hibernation left ON (laptop/battery detected - skipped for safety)"
    }
} else {
    Write-Log "Section 7: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 8: MEDIUM-VALUE TWEAKS (Print Spooler intentionally excluded -
# staff rely on it for printing, so it is left fully untouched)
# ---------------------------------------------------------------------------
if ($Sections["8"].Enabled) {
    Write-Log "Section 8: Applying medium-value tweaks..."

    # --- SysMain (Superfetch) - test on a couple machines before wide rollout ---
    $SysMain = Get-Service -Name "SysMain" -ErrorAction SilentlyContinue
    if ($SysMain -and $SysMain.Status -eq 'Running') {
        Stop-Service -Name "SysMain" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "SysMain" -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Log "  SysMain (Superfetch) disabled"
    }

    # --- Delivery Optimization: restrict to LAN only, do not disable Update itself ---
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Log "  Delivery Optimization restricted to LAN peers only (Windows Update itself unaffected)"

    # --- Remote Assistance (legacy) - NOT Remote Desktop, safe to disable ---
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name "fAllowToGetHelp" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Remote Assistance disabled (Remote Desktop unaffected)"

    Write-Log "  NOTE: Print Spooler intentionally left untouched - staff rely on it for printing."
} else {
    Write-Log "Section 8: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 9: EXTRA TWEAKS (DiagTrack, WAP Push, Cloud Clipboard, Shared
# Experiences, Wi-Fi Sense, Ink Workspace). Remote Registry, Background Apps,
# and full Windows Error Reporting service disable are intentionally
# excluded per FGN review.
# ---------------------------------------------------------------------------
if ($Sections["9"].Enabled) {
    Write-Log "Section 9: Applying extra tweaks..."

    # --- Disable DiagTrack (Connected User Experiences and Telemetry) service ---
    $DiagTrack = Get-Service -Name "DiagTrack" -ErrorAction SilentlyContinue
    if ($DiagTrack -and $DiagTrack.Status -eq 'Running') {
        Stop-Service -Name "DiagTrack" -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Log "  DiagTrack (telemetry) service disabled"

    # --- Disable dmwappushsvc (WAP Push Message Routing) ---
    $DmWap = Get-Service -Name "dmwappushservice" -ErrorAction SilentlyContinue
    if ($DmWap -and $DmWap.Status -eq 'Running') {
        Stop-Service -Name "dmwappushservice" -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name "dmwappushservice" -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Log "  dmwappushsvc (WAP Push) service disabled"

    # --- Disable Cloud Clipboard sync (local clipboard history unaffected) ---
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Clipboard" -Name "CloudClipboardAutomaticUpload" -Value 0 -PropertyType DWord -Force | Out-Null
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "AllowCrossDeviceClipboard" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Cloud Clipboard sync disabled (local clipboard history unaffected)"

    # --- Disable Shared Experiences / Nearby Sharing ---
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableCdp" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP" -Name "NearShareChannelUserAuthzPolicy" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Shared Experiences / Nearby Sharing disabled"

    # --- Disable Wi-Fi Sense / auto-connect to open hotspots & shared networks ---
    New-Item -Path "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config" -Name "AutoConnectAllowedOEM" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Wi-Fi Sense / auto-connect to open hotspots disabled"

    # --- Hide Windows Ink Workspace (safe if fleet has no touch/pen hardware) ---
    New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\PenWorkspace" -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\PenWorkspace" -Name "PenWorkspaceButtonDesiredVisibility" -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "  Windows Ink Workspace hidden"

    Write-Log "  NOTE: Remote Registry, Background Apps, and full WER service disable"
    Write-Log "        are intentionally excluded from this script per FGN review."
} else {
    Write-Log "Section 9: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 10: DISABLE UNUSED SERVICES (fixed list, safe on virtually any
# office machine - Fax, Downloaded Maps, Retail Demo, Windows Insider)
# ---------------------------------------------------------------------------
if ($Sections["10"].Enabled) {
    Write-Log "Section 10: Disabling unused services..."

    $ServicesToDisable = @(
        @{ Name = "Fax";                 Label = "Fax service" }
        @{ Name = "MapsBroker";          Label = "Downloaded Maps Manager" }
        @{ Name = "RetailDemo";          Label = "Retail Demo Service" }
        @{ Name = "wisvc";               Label = "Windows Insider Service" }
    )

    foreach ($Svc in $ServicesToDisable) {
        $Service = Get-Service -Name $Svc.Name -ErrorAction SilentlyContinue
        if ($Service) {
            if ($Service.Status -eq 'Running') {
                Stop-Service -Name $Svc.Name -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $Svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "  Disabled: $($Svc.Label)"
        }
    }
} else {
    Write-Log "Section 10: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 11: DISABLE BLUETOOTH (scan first)
# Disables the Bluetooth adapter(s) and the Bluetooth services. The original settings are
# saved to C:\ProgramData\FGN\Bluetooth-State.json so FGN-Disable-Bluetooth.ps1 -Enable can
# undo it. SKIPPED automatically when a Bluetooth keyboard is connected and no other
# keyboard exists (it could leave the PC without a way to type).
# ---------------------------------------------------------------------------
if ($Sections["11"].Enabled) {
    Write-Log "Section 11: Disabling Bluetooth (scan first)..."

    $BtAll = @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue)
    $BtRadios = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { (Get-FGNBtRole $_.InstanceId) -eq 'Radio' })
    $BtPaired = @($BtAll | Where-Object { (Get-FGNBtRole $_.InstanceId) -eq 'PairedDevice' })

    if ($BtRadios.Count -eq 0) { Write-Log "  No Bluetooth adapter is present on this PC" }
    foreach ($BtRadio in $BtRadios) {
        Write-Log "  Adapter: $($BtRadio.FriendlyName) | $(if (Test-FGNBtDeviceDisabled $BtRadio) { 'already disabled' } else { $BtRadio.Status })"
    }
    if ($BtPaired.Count -gt 0) { Write-Log "  Paired Bluetooth devices: $($BtPaired.Count)" }

    $BtInputs = Get-FGNBtInputSummary
    foreach ($BtKeyboard in @($BtInputs.BtKeyboards)) { Write-Log "  Bluetooth KEYBOARD connected now: $($BtKeyboard.Name)" }
    foreach ($BtMouse in @($BtInputs.BtMice))         { Write-Log "  Bluetooth MOUSE connected now: $($BtMouse.Name)" }
    Write-Log "  Non-Bluetooth keyboards: $($BtInputs.NonBtKeyboards) | non-Bluetooth pointing devices: $($BtInputs.NonBtPointers)"

    $BtProceed = $true
    if (@($BtInputs.BtKeyboards).Count -gt 0 -and $BtInputs.NonBtKeyboards -eq 0) {
        if ($AllowInputLoss) {
            Write-Log "  [WARNING] A Bluetooth keyboard is the only keyboard - disabling Bluetooth anyway (-AllowInputLoss)"
        } else {
            $BtProceed = $false
            Write-Log "  [SKIPPED] A Bluetooth keyboard is connected and no other keyboard was found - Bluetooth left on so the PC is not left without a keyboard (plug in a USB keyboard and run again, or use -AllowInputLoss)"
        }
    } elseif (@($BtInputs.BtMice).Count -gt 0 -or @($BtInputs.BtKeyboards).Count -gt 0) {
        Write-Log "  [NOTE] A connected Bluetooth keyboard/mouse will stop working (other input devices exist)"
    }

    if ($BtProceed) {
        # save the ORIGINAL settings first (a re-run never overwrites them)
        $BtSvcRecord = @()
        foreach ($BtName in $BtServiceDefaults.Keys) {
            $BtStart = Get-FGNBtServiceStart $BtName
            if ($null -ne $BtStart -and [int]$BtStart -ne 4) { $BtSvcRecord += [pscustomobject]@{ Name = $BtName; Start = [int]$BtStart } }
        }
        $BtDevRecord = @($BtRadios | Where-Object { -not (Test-FGNBtDeviceDisabled $_) } |
            ForEach-Object { [pscustomobject]@{ InstanceId = $_.InstanceId; FriendlyName = $_.FriendlyName } })
        Save-FGNBtState -Services $BtSvcRecord -Devices $BtDevRecord
        Write-Log "  Original settings saved to $BtStatePath"

        foreach ($BtRadio in $BtRadios) {
            if (Test-FGNBtDeviceDisabled $BtRadio) { continue }
            try {
                Disable-PnpDevice -InstanceId $BtRadio.InstanceId -Confirm:$false -ErrorAction Stop
                Write-Log "  Disabled adapter: $($BtRadio.FriendlyName)"
            } catch {
                Write-Log "  [FAILED] Could not disable adapter $($BtRadio.FriendlyName): $($_.Exception.Message)"
            }
        }
        foreach ($BtName in $BtServiceDefaults.Keys) {
            if ($null -eq (Get-FGNBtServiceStart $BtName)) { continue }
            foreach ($BtSvc in @(Get-Service -Name "$BtName*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Stopped' })) {
                Stop-Service -Name $BtSvc.Name -Force -ErrorAction SilentlyContinue
            }
            try {
                [void](Set-FGNBtServiceStart -Name $BtName -Value 4)
            } catch {
                Write-Log "  [FAILED] Could not disable service $BtName : $($_.Exception.Message)"
            }
        }

        # verify
        Start-Sleep -Seconds 3
        $BtStillOn = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { (Get-FGNBtRole $_.InstanceId) -eq 'Radio' -and -not (Test-FGNBtDeviceDisabled $_) })
        $BtSvcStillOn = @()
        foreach ($BtName in $BtServiceDefaults.Keys) {
            $BtStart = Get-FGNBtServiceStart $BtName
            if ($null -ne $BtStart -and [int]$BtStart -ne 4) { $BtSvcStillOn += $BtName }
        }
        if ($BtStillOn.Count -eq 0 -and $BtSvcStillOn.Count -eq 0) {
            Write-Log "  [DISABLED] Bluetooth is off (undo: .\FGN-Disable-Bluetooth.ps1 -Enable)"
        } else {
            if ($BtStillOn.Count -gt 0)    { Write-Log "  [FAILED] Adapter(s) still enabled: $((@($BtStillOn | ForEach-Object { $_.FriendlyName })) -join ', ') - a restart may finish it" }
            if ($BtSvcStillOn.Count -gt 0) { Write-Log "  [FAILED] Services still enabled: $($BtSvcStillOn -join ', ')" }
        }
    }
} else {
    Write-Log "Section 11: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 12: STARTUP PROGRAMS REPORT (read-only - lists everything set to
# run at startup so a tech can review and manually disable anything
# unnecessary. Does NOT auto-disable, since startup items vary per machine
# and may include business-critical software.)
# ---------------------------------------------------------------------------
if ($Sections["12"].Enabled) {
    Write-Log "Section 12: Generating startup programs report..."

    $ReportPath = "$env:USERPROFILE\Desktop\FGN-Startup-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    "FGN Startup Programs Report - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $ReportPath
    "=================================================================" | Out-File -FilePath $ReportPath -Append
    "" | Out-File -FilePath $ReportPath -Append

    try {
        $StartupItems = Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop |
            Select-Object Name, Command, Location, User

        if ($StartupItems) {
            foreach ($Item in $StartupItems) {
                "Name:     $($Item.Name)"     | Out-File -FilePath $ReportPath -Append
                "Command:  $($Item.Command)"  | Out-File -FilePath $ReportPath -Append
                "Location: $($Item.Location)" | Out-File -FilePath $ReportPath -Append
                "User:     $($Item.User)"     | Out-File -FilePath $ReportPath -Append
                "-----------------------------------------------------------------" | Out-File -FilePath $ReportPath -Append
            }
            Write-Log "  Startup report generated: $ReportPath ($($StartupItems.Count) items found)"
        } else {
            "No startup items found." | Out-File -FilePath $ReportPath -Append
            Write-Log "  No startup items found"
        }
    } catch {
        Write-Log "  Could not generate startup report: $($_.Exception.Message)"
    }

    Write-Log "  NOTE: This is a REPORT ONLY. Review $ReportPath and disable"
    Write-Log "        unnecessary items manually via Task Manager > Startup Apps,"
    Write-Log "        since startup software varies per machine."
} else {
    Write-Log "Section 12: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 13: UNINSTALL ONEDRIVE FOR ALL PROFILES (scan first, no questions)
# - Scans every profile: signed-in accounts, Desktop/Documents/Pictures backup,
#   OneDrive folders with files, cloud-only files.
# - A profile is SKIPPED automatically when removal would strand its data (cloud-only
#   files or folder backup). Use -IncludeRisky to remove it anyway. Signed-in accounts and
#   ordinary synced files do not block removal: the files stay on disk and in the cloud.
# - Machine-wide install and this account: uninstalled directly (registered uninstaller,
#   then the setup program shipped with Windows, then other OneDrive version folders).
#   Clean-up happens ONLY after a successful uninstall; if every uninstaller fails it falls
#   back to a manual removal (OneDrive's program only - never the user's files).
# - Other profiles: a one-time job runs OneDrive's own uninstaller at their next sign-in.
# - The Default profile entry is removed so NEW users do not get OneDrive.
# - A OneDrive folder that holds files is never deleted.
# ---------------------------------------------------------------------------
if ($Sections["13"].Enabled) {
    Write-Log "Section 13: Uninstalling OneDrive (scan first)..."

    # Step 1: scan
    $ODMachineEntries = @(Get-FGNOneDriveEntries -Roots $OneDriveMachineRoots -Scope Machine)
    $ODHasMachineWide = ($ODMachineEntries.Count -gt 0) -or (Test-Path -LiteralPath "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe")
    if ($ODHasMachineWide) {
        Write-Log "  [FOUND] Machine-wide OneDrive install (Program Files) - removing it affects every user"
    } else {
        Write-Log "  No machine-wide OneDrive install"
    }

    $ODReports = @()
    foreach ($ODUserProfile in @(Get-FGNOneDriveProfiles)) {
        $ODReports += Get-FGNOneDriveProfileReport -UserProfile $ODUserProfile
    }
    foreach ($ODReport in $ODReports) {
        $ODTag = if ($ODReport.Profile.IsCurrent) { ' (account running this script)' } else { '' }
        if (-not $ODReport.HiveOk) {
            Write-Log "  Profile '$($ODReport.Profile.Name)'$ODTag : registry could not be read (in use) - $(if ($ODReport.Installed) { 'OneDrive files present' } else { 'no OneDrive files found' })"
            continue
        }
        if (-not $ODReport.Installed) {
            Write-Log "  Profile '$($ODReport.Profile.Name)'$ODTag : OneDrive not installed"
            continue
        }
        Write-Log "  [FOUND] Profile '$($ODReport.Profile.Name)'$ODTag : OneDrive installed"
        $ODReasons = @(Get-FGNOneDriveRiskReasons -Report $ODReport)
        if ($ODReasons.Count -gt 0) {
            foreach ($ODReason in $ODReasons) { Write-Log "          RISK: $ODReason" }
        } else {
            Write-Log "          No sign-in, folder backup or synced files found"
        }
    }

    $ODInstalled = @($ODReports | Where-Object { $_.Installed })

    if ($ODInstalled.Count -eq 0 -and -not $ODHasMachineWide) {
        Write-Log "  [NOT FOUND] OneDrive is not installed for any user - only the Default profile entry will be cleaned"
    } else {
        # profiles whose data would be stranded are skipped unless -IncludeRisky was given
        $ODSelection = Select-FGNOneDriveTargets -Installed $ODInstalled -IncludeRisky ([bool]$IncludeRisky)
        $ODTargets = @($ODSelection.Targets)
        $ODExcluded = @($ODSelection.Excluded)
        foreach ($ODReport in $ODExcluded) {
            Write-Log "  [SKIPPED] Profile '$($ODReport.Profile.Name)' left alone: removing OneDrive would strand its data ($((@(Get-FGNOneDriveStrandReasons -Report $ODReport)) -join '; ')). Back the files up, or run with -IncludeRisky."
        }
        if ($IncludeRisky -and @($ODInstalled | Where-Object { @(Get-FGNOneDriveStrandReasons -Report $_).Count -gt 0 }).Count -gt 0) {
            Write-Log "  [WARNING] -IncludeRisky: removing OneDrive even for profiles with cloud-only files or folder backup"
        }

        # a machine-wide install serves every user, so it is only removed when nobody using it was left out
        $ODRemoveMachineWide = $ODHasMachineWide -and ($ODExcluded.Count -eq 0)
        if ($ODHasMachineWide -and -not $ODRemoveMachineWide) {
            Write-Log "  [SKIPPED] Machine-wide install kept because some profiles were left out"
        }

        if ($ODTargets.Count -eq 0 -and -not $ODRemoveMachineWide) {
            Write-Log "  Nothing selected to remove"
        } else {
            $ODWho = @($ODTargets | ForEach-Object { $_.Profile.Name })
            if ($ODRemoveMachineWide) { $ODWho += 'machine-wide install' }
            Write-Log "  OneDrive will be removed for: $($ODWho -join ', ')"

            # the machine-wide install and the account running the script
            $ODCurrentReport = @($ODTargets | Where-Object { $_.Profile.IsCurrent }) | Select-Object -First 1
            if ($null -ne $ODCurrentReport -or $ODRemoveMachineWide) {
                if ($null -eq $ODCurrentReport) {
                    $ODCurrentReport = @($ODReports | Where-Object { $_.Profile.IsCurrent }) | Select-Object -First 1
                }
                Write-Log "  Removing OneDrive for this account$(if ($ODRemoveMachineWide) { ' and the machine-wide install' })..."
                $ODOthersRemain = @($ODInstalled | Where-Object { -not $_.Profile.IsCurrent }).Count -gt 0
                Invoke-FGNOneDriveCurrentRemoval -Report $ODCurrentReport -HasMachineWide $ODRemoveMachineWide -KeepSharedData $ODOthersRemain

                # verify: Windows must no longer list OneDrive and it must not be running
                $ODStillListed = Test-FGNOneDriveRegistered -UserProfile $ODCurrentReport.Profile -CheckMachine $ODRemoveMachineWide
                $ODStillRunning = @(Get-Process -Name OneDrive -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like "*\$env:USERNAME" }).Count -gt 0
                $ODLeftoverFiles = Test-Path -LiteralPath "$($ODCurrentReport.Profile.Path)\AppData\Local\Microsoft\OneDrive"
                if (-not $ODStillListed -and -not $ODStillRunning) {
                    $ODHow = if ($script:OneDriveRemovalStatus -eq 'Manual') { ' (manual removal)' } else { '' }
                    Write-Log "  [REMOVED] OneDrive for '$($ODCurrentReport.Profile.Name)'$(if ($ODRemoveMachineWide) { ' and machine-wide' })$ODHow"
                    if ($ODLeftoverFiles) { Write-Log "  Some locked program files remain and will be deleted at the next sign-in (restart recommended)" }
                } else {
                    Write-Log "  [FAILED] OneDrive is still present (listed as installed: $ODStillListed, running: $ODStillRunning)"
                    if ($script:OneDriveRemovalStatus -eq 'Failed') { Write-Log "  No clean-up was done, so OneDrive is exactly as it was." }
                }
            }

            # other profiles run OneDrive's own uninstaller at their next sign-in
            $ODOtherTargets = @($ODTargets | Where-Object { -not $_.Profile.IsCurrent })
            if ($ODOtherTargets.Count -gt 0) {
                Write-Log "  Scheduling OneDrive removal for other profiles (runs at their next sign-in)..."
                foreach ($ODReport in $ODOtherTargets) {
                    if (Set-FGNOneDriveOtherProfileRunOnce -Report $ODReport) {
                        Write-Log "  [SCHEDULED] '$($ODReport.Profile.Name)' - OneDrive uninstalls the next time they sign in"
                    } else {
                        Write-Log "  [FAILED] Could not schedule '$($ODReport.Profile.Name)' (their registry could not be opened)"
                    }
                }
            }
        }
    }

    # stop NEW users getting OneDrive at first sign-in
    $ODDefaultResult = Clear-FGNOneDriveDefaultProfileRun
    switch ($ODDefaultResult) {
        'removed' { Write-Log "  [REMOVED] OneDrive auto-install entry from the Default profile (new users will not get OneDrive)" }
        'absent'  { Write-Log "  [NOT FOUND] No OneDrive auto-install entry in the Default profile - nothing to remove" }
        default   { Write-Log "  [SKIPPED] The Default profile registry could not be opened" }
    }
} else {
    Write-Log "Section 13: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 14: REMOVE MICROSOFT STORE (scan first)
# Inbox apps (Photos, Notepad, Calculator, Terminal...) can no longer update
# through the Store afterwards. winget and App Installer are separate packages.
# ---------------------------------------------------------------------------
if ($Sections["14"].Enabled) {
    Write-Log "Section 14: Removing Microsoft Store (scan first)..."
    Remove-FGNApp -Name "Microsoft.WindowsStore"
    Remove-FGNApp -Name "Microsoft.StorePurchaseApp"
    Write-Log "  NOTE: if the Store is needed again later, 'wsreset -i' can usually reinstall it (test on one machine first)"
} else {
    Write-Log "Section 14: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 15: REMOVE WINDOWS SUBSYSTEM FOR LINUX (scan first)
# Linux distros keep their files inside .vhdx disks and Docker Desktop depends
# on WSL 2, so this section SKIPS entirely if either is found.
# Virtual Machine Platform is left alone (other features rely on it).
# ---------------------------------------------------------------------------
if ($Sections["15"].Enabled) {
    Write-Log "Section 15: Removing Windows Subsystem for Linux (scan first)..."

    # SCAN 1 - distro disks and Docker Desktop
    $DistroDisks = @(
        Get-ChildItem "C:\Users\*\AppData\Local\Packages\*\LocalState\ext4.vhdx" -ErrorAction SilentlyContinue
        Get-ChildItem "C:\Users\*\AppData\Local\wsl\*\ext4.vhdx" -ErrorAction SilentlyContinue
    )
    $DockerDesktop = Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

    if ($DistroDisks.Count -gt 0 -or $DockerDesktop) {
        Write-Log "  [SKIPPED] WSL data or Docker Desktop found - WSL not removed to protect user data/workloads"
        foreach ($Disk in $DistroDisks) { Write-Log "    Distro disk: $($Disk.FullName)" }
        if ($DockerDesktop) { Write-Log "    Docker Desktop is installed (it depends on WSL 2)" }
    } else {
        # SCAN 2 - Store-delivered WSL package
        Remove-FGNApp -Name "MicrosoftCorporationII.WindowsSubsystemForLinux"

        # SCAN 3 - Windows optional feature
        $WslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
        if (-not $WslFeature) {
            Write-Log "  [NOT FOUND] WSL optional feature could not be queried on this machine"
        } elseif ("$($WslFeature.State)" -ne "Enabled") {
            Write-Log "  [NOT ENABLED] WSL optional feature is already off - nothing to disable"
        } else {
            Write-Log "  [FOUND] WSL optional feature is enabled - disabling..."
            Disable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -NoRestart -ErrorAction SilentlyContinue | Out-Null
            $After = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
            if ("$($After.State)" -eq "Enabled") {
                Write-Log "  [FAILED] WSL optional feature is still enabled"
            } else {
                Write-Log "  [REMOVED] WSL optional feature disabled (restart required to finish)"
            }
        }
    }
} else {
    Write-Log "Section 15: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 16: REMOVE MICROSOFT EDGE (scan first, no questions)
# Uses Edge's own uninstaller. Three methods are tried in turn until one works
# (see the helper block above). SKIPPED automatically when no other web browser is
# installed (override: -AllowNoBrowser). The WebView2 Runtime and Edge Update are left
# in place - many apps depend on them.
# ---------------------------------------------------------------------------
if ($Sections["16"].Enabled) {
    Write-Log "Section 16: Removing Microsoft Edge (scan first)..."

    $EdgeEntries = @(Get-FGNEdgeEntries)
    $EdgeLauncher = Get-FGNEdgeLauncher
    $EdgeOtherBrowsers = @(Get-FGNOtherBrowsers)

    if ($EdgeEntries.Count -eq 0 -and -not $EdgeLauncher) {
        Write-Log "  [NOT FOUND] Microsoft Edge is not installed - nothing to remove"
    } else {
        foreach ($EdgeEntry in $EdgeEntries) {
            Write-Log "  [FOUND] Microsoft Edge v$($EdgeEntry.DisplayVersion)"
        }
        if ($EdgeEntries.Count -eq 0) { Write-Log "  [FOUND] Edge launcher present: $EdgeLauncher" }
        if ($EdgeOtherBrowsers.Count -gt 0) {
            Write-Log "  Other browsers installed: $($EdgeOtherBrowsers -join ', ')"
        } else {
            Write-Log "  [WARNING] No other web browser found (Chrome, Firefox, Brave, Opera, Vivaldi)"
        }

        # Safety (replaces the old questions): never leave a PC without a browser
        $EdgeProceed = $true
        if ($EdgeOtherBrowsers.Count -eq 0) {
            if ($AllowNoBrowser) {
                Write-Log "  [WARNING] No other web browser is installed - removing Edge anyway (-AllowNoBrowser)"
            } else {
                $EdgeProceed = $false
            }
        }

        if (-not $EdgeProceed) {
            Write-Log "  [SKIPPED] Edge left in place because no other web browser is installed - install Chrome or Firefox and run again (or use -AllowNoBrowser)"
        } else {
            $EdgeStart = Get-Date
            $EdgeGone = $false

            # Edge installed from an .msi (for example by winget) must be removed that way first
            $EdgeMsiEntries = @($EdgeEntries | Where-Object { $_.UninstallString -like '*MsiExec.exe*' })
            if ($EdgeMsiEntries.Count -gt 0) {
                Write-Log "  Edge was installed with Windows Installer (.msi) - removing that first..."
                Stop-FGNEdgeProcesses
                foreach ($EdgeMsi in $EdgeMsiEntries) {
                    if ($EdgeMsi.PSChildName -match '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
                        Write-Log "    msiexec /qn /X$($EdgeMsi.PSChildName)"
                        Start-Process -FilePath "msiexec.exe" -ArgumentList "/qn /X$($EdgeMsi.PSChildName) REBOOT=ReallySuppress /norestart" -Wait
                    }
                }
                Start-Sleep -Seconds 3
                $EdgeGone = Test-FGNEdgeGone
                if ($EdgeGone) { Write-Log "  [REMOVED] Microsoft Edge (via .msi uninstall)" }
            }

            # Edge's own uninstall command
            $EdgeCmd = $null
            if (-not $EdgeGone) {
                foreach ($EdgeEntry in @(Get-FGNEdgeEntries)) {
                    $EdgeParts = Split-FGNCommand $EdgeEntry.UninstallString
                    if ([System.IO.Path]::IsPathRooted($EdgeParts.Exe) -and (Test-Path -LiteralPath $EdgeParts.Exe -PathType Leaf)) {
                        $EdgeCmd = $EdgeEntry.UninstallString.Trim()
                        break
                    }
                }
                if (-not $EdgeCmd) {
                    $EdgeSetup = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue |
                        Sort-Object { [version]($_.FullName -replace '.*\\Application\\([\d\.]+)\\Installer\\setup\.exe', '$1') } |
                        Select-Object -Last 1
                    if ($EdgeSetup) {
                        $EdgeCmd = '"' + $EdgeSetup.FullName + '" --uninstall --msedge --system-level --channel=stable --verbose-logging'
                    }
                }
            }

            if (-not $EdgeGone) {
                if (-not $EdgeCmd) {
                    Write-Log "  [FAILED] Could not find Edge's installer to run"
                } else {
                    $EdgeMethod = 0
                    while (-not $EdgeGone -and $EdgeMethod -lt 3) {
                        $EdgeMethod++
                        $EdgeMethodName = @('', 'legacy-Edge marker', 'windir removed', 'launcher + marker')[$EdgeMethod]
                        Write-Log "  Method $EdgeMethod of 3 ($EdgeMethodName)"
                        Stop-FGNEdgeProcesses
                        [void](Invoke-FGNEdgeMethod -Method $EdgeMethod -Command $EdgeCmd)

                        # the installer can take a little while after it returns
                        for ($EdgeWait = 0; $EdgeWait -lt 8; $EdgeWait++) {
                            if (Test-FGNEdgeGone) { $EdgeGone = $true; break }
                            Start-Sleep -Seconds 3
                        }
                        if ($EdgeGone) {
                            Write-Log "  [REMOVED] Microsoft Edge using method $EdgeMethod ($EdgeMethodName)"
                        } else {
                            Write-Log "  Method $EdgeMethod did not remove Edge"
                        }
                    }
                }
            }
            Restore-FGNPausedEdgeServices

            if ($EdgeGone -or (Test-FGNEdgeGone)) {
                Write-Log "  Microsoft Edge is gone (restart recommended)"
                foreach ($EdgeLnk in @(
                    "$([Environment]::GetFolderPath('Desktop'))\Microsoft Edge.lnk"
                    "$([Environment]::GetFolderPath('CommonDesktopDirectory'))\Microsoft Edge.lnk"
                    "$([Environment]::GetFolderPath('CommonPrograms'))\Microsoft Edge.lnk"
                )) {
                    if (Test-Path -LiteralPath $EdgeLnk) {
                        Remove-Item -LiteralPath $EdgeLnk -Force -ErrorAction SilentlyContinue
                        Write-Log "  Removed shortcut: $EdgeLnk"
                    }
                }
            } else {
                Write-Log "  [FAILED] Edge is still present after all methods"
                Write-Log "  Why the installer refused (from its own log):"
                Add-FGNInstallerLog -Since $EdgeStart.AddSeconds(-5)
            }
        }
    }
    Write-Log "  NOTE: Edge WebView2 Runtime and Edge Update are left installed on purpose. Windows Update can bring Edge back."
} else {
    Write-Log "Section 16: skipped on request"
}

# ---------------------------------------------------------------------------
# SECTION 17: REMOVE REMOTE DESKTOP CONNECTION (scan first, no questions)
# Uses Microsoft's documented command for Windows 11 23H2 and later: mstsc.exe /uninstall.
# Removes the OUTGOING client for all users (and the RemoteApp and Desktop Connections
# control panel); the setting that lets other PCs connect IN is not touched.
# SKIPPED automatically while Remote Desktop Connection is running (override: -CloseRunning).
# Windows finishes the removal at the next restart, and the command is started WITHOUT
# waiting for Windows' own "restart now?" box so the rest of the run is never blocked.
# ---------------------------------------------------------------------------
if ($Sections["17"].Enabled) {
    Write-Log "Section 17: Removing Remote Desktop Connection (scan first)..."

    $RdcPath = "$env:SystemRoot\System32\mstsc.exe"
    $RdcBuild = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).CurrentBuild

    if (-not (Test-FGNRdcRemovalSupported -Build $RdcBuild)) {
        Write-Log "  [SKIPPED] Windows build $RdcBuild is older than 23H2 - Microsoft only supports removing Remote Desktop Connection from 23H2 (build $RdcMinimumBuild)"
    } elseif (-not (Test-Path -LiteralPath $RdcPath)) {
        Write-Log "  [NOT FOUND] Remote Desktop Connection is not installed - nothing to remove"
    } else {
        Write-Log "  [FOUND] Remote Desktop Connection ($RdcPath)"
        $RdcProceed = $true
        $RdcRunning = @(Get-Process -Name mstsc -ErrorAction SilentlyContinue)
        if ($RdcRunning.Count -gt 0) {
            if ($CloseRunning) {
                $RdcRunning | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-Log "  [WARNING] Remote Desktop Connection was running - closed it (-CloseRunning)"
                Start-Sleep -Seconds 2
            } else {
                $RdcProceed = $false
                Write-Log "  [SKIPPED] Remote Desktop Connection is running (a remote session may be open) - close it and run again, or use -CloseRunning"
            }
        }

        if ($RdcProceed) {
            Write-Log "  Running: mstsc.exe /uninstall (not waiting for Windows' restart prompt)"
            try {
                Start-Process -FilePath $RdcPath -ArgumentList '/uninstall' -ErrorAction Stop
                $RdcGone = $false
                for ($RdcWait = 0; $RdcWait -lt 6; $RdcWait++) {
                    Start-Sleep -Seconds 3
                    if (-not (Test-Path -LiteralPath $RdcPath)) { $RdcGone = $true; break }
                }
                if ($RdcGone) {
                    Write-Log "  [REMOVED] Remote Desktop Connection is gone"
                } else {
                    Write-Log "  [PENDING RESTART] Remote Desktop Connection removal is queued - Windows finishes it at the next restart (reinstall later: https://go.microsoft.com/fwlink/?linkid=2247659 for 64-bit)"
                }
            } catch {
                Write-Log "  [FAILED] Could not start the uninstall: $($_.Exception.Message)"
            }
        }
    }
} else {
    Write-Log "Section 17: skipped on request"
}

# ---------------------------------------------------------------------------
# RESTART EXPLORER TO APPLY UI CHANGES
# ---------------------------------------------------------------------------
Write-Log "Restarting Explorer to apply UI changes..."
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Process explorer

Write-Log "=== FGN Windows 11 Debloat (unattended) completed ==="
Write-Log "Log saved to: $LogPath"

# ---------------------------------------------------------------------------
# SUMMARY - everything that needs a person's attention, in one place
# ---------------------------------------------------------------------------
$SummaryDone = @($script:LogLines | Where-Object { $_ -match '\[(REMOVED|DISABLED)\]' })
$SummaryAttention = @($script:LogLines | Where-Object { $_ -match '\[(SKIPPED|FAILED|WARNING|PENDING RESTART|SCHEDULED)\]' })
$SummaryText = @()
$SummaryText += "================ SUMMARY ================"
$SummaryText += "Removed / disabled: $($SummaryDone.Count) item(s)"
if ($SummaryAttention.Count -gt 0) {
    $SummaryText += "Needs attention ($($SummaryAttention.Count)):"
    foreach ($Line in $SummaryAttention) { $SummaryText += "  $($Line.Substring(21))" }
} else {
    $SummaryText += "Nothing needs attention."
}
$SummaryText += "Restart the PC to finish: Edge, OneDrive leftovers, Remote Desktop Connection and WSL are completed during a restart."
foreach ($Line in $SummaryText) {
    $Color = if ($Line -like 'Needs attention*' -or $Line -like '  *') { 'Yellow' } else { 'Cyan' }
    Write-Host $Line -ForegroundColor $Color
}
Add-Content -Path $LogPath -Value ""
Add-Content -Path $LogPath -Value $SummaryText

if ($RestartWhenDone) {
    Write-Log "Restarting in 60 seconds (-RestartWhenDone). To cancel: shutdown /a"
    & shutdown.exe /r /t 60 /c "FGN setup finished - restarting to complete the changes. To cancel run: shutdown /a"
}
if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
