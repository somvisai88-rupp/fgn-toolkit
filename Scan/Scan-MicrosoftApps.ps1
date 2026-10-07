# FGN.Title: Microsoft apps (newly installed Windows 11 24H2)
# FGN.Description: Edge, OneDrive, Store, WSL, Remote Desktop Connection and every other Microsoft app, each rated keep or remove
# FGN.Order: 2
# FGN.ReportTag: Microsoft
# FGN.Audience: new
# FGN.MinBuild: 26100
# FGN.Needs: Lib\FGN-Common.ps1, Data\MicrosoftApps.csv, Data\consumer-app-list.json

<#
.SYNOPSIS
    FGN Toolkit - Scan Microsoft apps (READ-ONLY)
.DESCRIPTION
    For a newly installed Windows 11 24H2 (or 25H2) PC. Rates Microsoft's own software. It changes nothing.

    Part 1 - the Windows components FGN removes, each with its safety check:
      Edge                       REMOVE, but KEEP while no other web browser is installed
      OneDrive (every profile)   REMOVE, but REVIEW for a profile whose files would be stranded
      OneDrive sync component    CHECK when OneDrive looks removed but this package is still there
      Microsoft Store            REMOVE
      WSL                        REMOVE, but KEEP while Linux data or Docker Desktop exists
      Remote Desktop Connection  REMOVE, but REVIEW while it is running (incoming Remote Desktop is never touched)

    Part 2 - every other Microsoft Store app and Microsoft program, rated from Data\MicrosoftApps.csv.
    A Microsoft app that is not in that file yet is shown as REVIEW: add a row to rate it.

    Microsoft's consumer apps (Xbox, News, Copilot ...) are on Data\consumer-app-list.json and are rated by Scan-ConsumerApps.ps1.
.PARAMETER OutputFolder
    Where the report and CSV are saved.
.PARAMETER ShowAll
    Also list the items that are not present and the apps rated KEEP.
.PARAMETER NoCsv
    Do not write the CSV file.
.PARAMETER WaitAtEnd
    Wait for Enter before the window closes (added automatically when the script restarts itself elevated).
#>

param(
    [string]$OutputFolder,
    [switch]$ShowAll,
    [switch]$NoCsv,
    [switch]$WaitAtEnd
)

$LibPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Lib\FGN-Common.ps1'
if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Host "Cannot find $LibPath - run this script from inside the FGN-Toolkit folder." -ForegroundColor Red
    exit 1
}
try { . $LibPath } catch {
    Write-Host "The shared library Lib\FGN-Common.ps1 could not be loaded: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Request-FGNAdmin -Bound $PSBoundParameters -ScriptPath $PSCommandPath -ExtraSwitches @('-WaitAtEnd')
$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Detection copied from FGN-Win11-Debloat-Auto.ps1 (same logic as the removal script)
# ---------------------------------------------------------------------------
$OneDriveCurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$OneDriveMachineRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
$OneDriveUninstallSubPath = "Software\Microsoft\Windows\CurrentVersion\Uninstall"
$RdcMinimumBuild = 22631   # Windows 11 23H2 - the first version where Microsoft supports uninstalling it

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
function Test-FGNRdcRemovalSupported {
    param([int]$Build)
    return ($Build -ge $RdcMinimumBuild)
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

# ===========================================================================
Start-FGNScanReport -ScanName 'Microsoft apps' -FileTag 'Microsoft' -OutputFolder $OutputFolder -ShowAll:$ShowAll -NoCsv:$NoCsv

$Win = Get-FGNWindowsInfo
$Packages = @(Get-FGNStorePackageList)
$Programs = @(Get-FGNInstalledPrograms)
$ConsumerList = Import-FGNConsumerList
if (-not $ConsumerList.Ok) {
    Write-FGNScanHeader 'THE CONSUMER APP LIST HAS A PROBLEM'
    foreach ($ListError in $ConsumerList.Errors) { Write-FGNScan "  $ListError" 'Red' }
    Write-FGNScan 'Fix Data\consumer-app-list.json and run the scan again. Nothing was scanned or changed.' 'Red'
    if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
    exit 1
}
$ConsumerPatterns = @($ConsumerList.Entries | Where-Object { $_.Action -ne 'keep' } | ForEach-Object { $_.Package })
$Catalog = @(Import-FGNData -Name 'MicrosoftApps.csv')
$HandledNames = @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'MicrosoftCorporationII.WindowsSubsystemForLinux', 'Microsoft.OneDriveSync')

# ---------------------------------------------------------------- Edge
Write-FGNScanHeader 'MICROSOFT EDGE, WEBVIEW2 AND OTHER BROWSERS'
$EdgeEntries = @(Get-FGNEdgeEntries)
$EdgeLauncher = Get-FGNEdgeLauncher
$OtherBrowsers = @(Get-FGNOtherBrowsers)
if ($EdgeEntries.Count -eq 0 -and -not $EdgeLauncher) {
    Add-FGNScanRow -Category 'Edge' -Item 'Microsoft Edge' -Status 'Not present' -Verdict 'NONE'
} else {
    $EdgeDetail = 'launcher found'
    if ($EdgeEntries.Count -gt 0) { $EdgeDetail = "v$($EdgeEntries[0].DisplayVersion)" }
    if ($OtherBrowsers.Count -gt 0) {
        Add-FGNScanRow -Category 'Edge' -Item 'Microsoft Edge' -Detail $EdgeDetail -Verdict 'REMOVE' -Reason "FGN policy. Another browser is installed: $($OtherBrowsers -join ', ')" -Kind 'Component' -Target 'Edge'
    } else {
        Add-FGNScanRow -Category 'Edge' -Item 'Microsoft Edge' -Detail $EdgeDetail -Verdict 'KEEP' -Kind 'Component' -Target 'Edge' `
            -Reason 'No other web browser is installed, so Edge stays. Install Chrome or Firefox first, then remove Edge'
    }
}
foreach ($Browser in $OtherBrowsers) {
    Add-FGNScanRow -Category 'Edge' -Item $Browser -Verdict 'KEEP' -Reason 'Keeps the PC usable if Edge is removed'
}
foreach ($WebView in @($Programs | Where-Object { $_.Name -like '*WebView2*' })) {
    Add-FGNScanRow -Category 'Edge' -Item $WebView.Name -Detail "v$($WebView.Version)" -Verdict 'KEEP' -Reason 'Many apps depend on it. Never removed'
}

# ---------------------------------------------------------------- OneDrive
Write-FGNScanHeader 'ONEDRIVE, EVERY PROFILE'
$ODMachineEntries = @(Get-FGNOneDriveEntries -Roots $OneDriveMachineRoots -Scope Machine)
$ODHasMachineWide = ($ODMachineEntries.Count -gt 0) -or (Test-Path -LiteralPath "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe")
$ODReports = @()
foreach ($ODUserProfile in @(Get-FGNOneDriveProfiles)) {
    $ODReports += Get-FGNOneDriveProfileReport -UserProfile $ODUserProfile
}
$ODInstalled = @($ODReports | Where-Object { $_.Installed })
$ODSelection = Select-FGNOneDriveTargets -Installed $ODInstalled -IncludeRisky $false
$ODTargets = @($ODSelection.Targets)
$ODExcluded = @($ODSelection.Excluded)

if (-not $ODHasMachineWide -and $ODInstalled.Count -eq 0) {
    Add-FGNScanRow -Category 'OneDrive' -Item 'OneDrive' -Status 'Not present' -Verdict 'NONE'
}
if ($ODHasMachineWide) {
    $ODMachineVersion = ''
    if ($ODMachineEntries.Count -gt 0) { $ODMachineVersion = "v$($ODMachineEntries[0].Version), " }
    if ($ODExcluded.Count -eq 0) {
        Add-FGNScanRow -Category 'OneDrive' -Item 'OneDrive (machine-wide)' -Detail "${ODMachineVersion}serves every user" -Verdict 'REMOVE' -Reason 'FGN policy. Nobody using it would be left out' -Kind 'Component' -Target 'OneDrive'
    } else {
        Add-FGNScanRow -Category 'OneDrive' -Item 'OneDrive (machine-wide)' -Detail "${ODMachineVersion}serves every user" -Verdict 'KEEP' -Kind 'Component' -Target 'OneDrive' `
            -Reason 'Kept because some profiles would lose data (see below) and it serves every user'
    }
}
foreach ($ODReport in $ODInstalled) {
    $ProfileName = $ODReport.Profile.Name
    $Who = 'other account'
    if ($ODReport.Profile.IsCurrent) { $Who = 'account running the scan' }
    $RiskText = @(Get-FGNOneDriveRiskReasons -Report $ODReport) -join '; '
    if (-not $RiskText) { $RiskText = 'no sign-in, folder backup or synced files' }
    if (-not $ODReport.HiveOk) { $RiskText += ' (registry could not be read - the user is probably signed in)' }
    if ($ODTargets -contains $ODReport) {
        $When = 'removed at their next sign-in'
        if ($ODReport.Profile.IsCurrent) { $When = 'removed straight away' }
        Add-FGNScanRow -Category 'OneDrive' -Item "OneDrive - $ProfileName" -Detail "$Who; $RiskText" -Verdict 'REMOVE' -Reason "OneDrive's own uninstaller; $When. Their files are never deleted" -Kind 'Component' -Target 'OneDrive'
    } else {
        $Strand = @(Get-FGNOneDriveStrandReasons -Report $ODReport) -join '; '
        Add-FGNScanRow -Category 'OneDrive' -Item "OneDrive - $ProfileName" -Detail "$Who; $RiskText" -Verdict 'REVIEW' -Kind 'Component' -Target 'OneDrive' `
            -Reason "Removal would strand this user's data ($Strand). Back the files up first"
    }
}
$ODSync = @($Packages | Where-Object { $_.Name -eq 'Microsoft.OneDriveSync' }) | Select-Object -First 1
$ODSyncItem = 'OneDrive sync component (Microsoft.OneDriveSync)'
if ($ODSync) {
    if ($ODHasMachineWide -or $ODInstalled.Count -gt 0) {
        Add-FGNScanRow -Category 'OneDrive' -Item $ODSyncItem -Detail (Get-FGNPackageDetail -Package $ODSync) -Verdict 'KEEP' `
            -Reason 'Part of the OneDrive install. Scan again after OneDrive has been removed'
    } else {
        Add-FGNScanRow -Category 'OneDrive' -Item $ODSyncItem -Detail (Get-FGNPackageDetail -Package $ODSync) -Verdict 'CHECK' `
            -Reason 'OneDrive looks removed, but this sync component is still installed. Check that OneDrive does not start or appear in File Explorer'
    }
} else {
    Add-FGNScanRow -Category 'OneDrive' -Item $ODSyncItem -Status 'Not present' -Verdict 'NONE'
}

# ---------------------------------------------------------------- Store
Write-FGNScanHeader 'MICROSOFT STORE'
foreach ($StoreName in @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp')) {
    $StoreHit = @($Packages | Where-Object { $_.Name -eq $StoreName }) | Select-Object -First 1
    if ($StoreHit) {
        Add-FGNScanRow -Category 'Microsoft Store' -Item $StoreName -Detail (Get-FGNPackageDetail -Package $StoreHit) -Verdict 'REMOVE' -Kind 'Component' -Target 'Store' `
            -Reason 'FGN policy. Inbox apps (Photos, Notepad, Calculator, Terminal ...) can no longer update through the Store afterwards'
    } else {
        Add-FGNScanRow -Category 'Microsoft Store' -Item $StoreName -Status 'Not present' -Verdict 'NONE'
    }
}

# ---------------------------------------------------------------- WSL
Write-FGNScanHeader 'WINDOWS SUBSYSTEM FOR LINUX'
$WslDisks = @(
    Get-ChildItem "C:\Users\*\AppData\Local\Packages\*\LocalState\ext4.vhdx" -ErrorAction SilentlyContinue
    Get-ChildItem "C:\Users\*\AppData\Local\wsl\*\ext4.vhdx" -ErrorAction SilentlyContinue
)
$DockerDesktop = Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
$WslProtected = ($WslDisks.Count -gt 0) -or $DockerDesktop
foreach ($Disk in $WslDisks) {
    Add-FGNScanRow -Category 'WSL' -Item 'Linux distro disk' -Detail $Disk.FullName -Verdict 'KEEP' -Reason 'User data. WSL stays while this exists'
}
if ($DockerDesktop) {
    Add-FGNScanRow -Category 'WSL' -Item 'Docker Desktop' -Verdict 'KEEP' -Reason 'Depends on WSL 2. WSL stays while it is installed'
}
$WslVerdict = 'REMOVE'
$WslWhy = 'FGN policy'
if ($WslProtected) { $WslVerdict = 'KEEP'; $WslWhy = 'Kept because Linux data or Docker Desktop was found' }
$WslPackage = @($Packages | Where-Object { $_.Name -eq 'MicrosoftCorporationII.WindowsSubsystemForLinux' }) | Select-Object -First 1
if ($WslPackage) {
    Add-FGNScanRow -Category 'WSL' -Item 'WSL app package' -Detail (Get-FGNPackageDetail -Package $WslPackage) -Verdict $WslVerdict -Reason $WslWhy -Kind 'Component' -Target 'WSL'
} else {
    Add-FGNScanRow -Category 'WSL' -Item 'WSL app package' -Status 'Not present' -Verdict 'NONE'
}
$WslFeature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -ErrorAction SilentlyContinue
if ($WslFeature -and "$($WslFeature.State)" -eq 'Enabled') {
    Add-FGNScanRow -Category 'WSL' -Item 'WSL Windows feature' -Detail 'turned on' -Verdict $WslVerdict -Reason "$WslWhy. Removal turns the feature off" -Kind 'Component' -Target 'WSL'
} else {
    Add-FGNScanRow -Category 'WSL' -Item 'WSL Windows feature' -Status 'Not present' -Verdict 'NONE'
}

# ---------------------------------------------------------------- Remote Desktop Connection
Write-FGNScanHeader 'REMOTE DESKTOP CONNECTION'
$RdcPath = "$env:SystemRoot\System32\mstsc.exe"
if (Test-Path -LiteralPath $RdcPath) {
    $RdcRunning = @(Get-Process -Name mstsc -ErrorAction SilentlyContinue).Count -gt 0
    if (-not (Test-FGNRdcRemovalSupported -Build $Win.Build)) {
        Add-FGNScanRow -Category 'Remote Desktop' -Item 'Remote Desktop Connection' -Detail "Windows build $($Win.Build)" -Verdict 'KEEP' -Kind 'Component' -Target 'RDC' `
            -Reason "Microsoft only supports removing it from Windows 11 23H2 (build $RdcMinimumBuild)"
    } elseif ($RdcRunning) {
        Add-FGNScanRow -Category 'Remote Desktop' -Item 'Remote Desktop Connection' -Detail 'running right now' -Verdict 'REVIEW' -Kind 'Component' -Target 'RDC' `
            -Reason 'A remote session may be open. Close it before removing'
    } else {
        Add-FGNScanRow -Category 'Remote Desktop' -Item 'Remote Desktop Connection' -Verdict 'REMOVE' -Reason 'FGN policy. Outgoing client only; a restart finishes the removal' -Kind 'Component' -Target 'RDC'
    }
} else {
    Add-FGNScanRow -Category 'Remote Desktop' -Item 'Remote Desktop Connection' -Status 'Not present' -Verdict 'NONE'
}
$IncomingRdp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections
if ($null -ne $IncomingRdp) {
    $IncomingText = 'off'
    if ([int]$IncomingRdp -eq 0) { $IncomingText = 'ON - other PCs can connect to this one' }
    Add-FGNScanRow -Category 'Remote Desktop' -Item 'Incoming Remote Desktop' -Detail $IncomingText -Verdict 'KEEP' -Reason 'A separate setting. Never changed'
}

# ---------------------------------------------------------------- other Microsoft Store apps
Write-FGNScanHeader 'OTHER MICROSOFT STORE APPS (rated in Data\MicrosoftApps.csv)'
$StoreCatalog = @($Catalog | Where-Object { $_.Kind -eq 'Store' })
$KeepCount = 0
$StoreSeen = @()
foreach ($Package in @($Packages | Where-Object { $_.Microsoft -and $HandledNames -notcontains $_.Name } | Sort-Object Name)) {
    if (Test-FGNLikeAny -Name $Package.Name -Patterns $ConsumerPatterns) { continue }
    $StoreSeen += $Package.Name
    $Rule = $StoreCatalog | Where-Object { $Package.Name -like $_.Pattern } | Select-Object -First 1
    $Detail = Get-FGNPackageDetail -Package $Package
    if ($Rule) {
        $Verdict = ConvertTo-FGNVerdict -Text $Rule.Verdict
        if ($Verdict -eq 'KEEP') { $KeepCount++ }
        Add-FGNScanRow -Category 'Microsoft app' -Item $Package.Name -Detail $Detail -Verdict $Verdict -Reason $Rule.Why -Quiet:($Verdict -eq 'KEEP') -Kind 'Store' -Target $Package.Name
    } elseif ($Package.Protected) {
        $KeepCount++
        Add-FGNScanRow -Category 'Microsoft app' -Item $Package.Name -Detail $Detail -Verdict 'KEEP' -Reason 'Protected Windows component (cannot be removed)' -Quiet -Kind 'Store' -Target $Package.Name
    } else {
        Add-FGNScanRow -Category 'Microsoft app' -Item $Package.Name -Detail $Detail -Verdict 'REVIEW' -Reason 'Microsoft app that is not rated yet. Add a row to Data\MicrosoftApps.csv to rate it' -Kind 'Store' -Target $Package.Name
    }
}
foreach ($Row in $StoreCatalog) {
    if (@($StoreSeen | Where-Object { $_ -like $Row.Pattern }).Count -eq 0) {
        Add-FGNScanRow -Category 'Microsoft app' -Item $Row.Pattern -Status 'Not present' -Verdict 'NONE'
    }
}
Write-FGNScan ("  {0} Microsoft app(s) rated KEEP. They are in the CSV; run with -ShowAll to list them here." -f $KeepCount) 'Gray'

# ---------------------------------------------------------------- Microsoft programs
Write-FGNScanHeader 'MICROSOFT PROGRAMS (rated in Data\MicrosoftApps.csv)'
$ProgramCatalog = @($Catalog | Where-Object { $_.Kind -eq 'Program' })
$ProgramKeep = 0
foreach ($Program in @($Programs | Where-Object { $_.Publisher -match 'Microsoft' -and $_.Name -notmatch '^(Microsoft Edge|Microsoft OneDrive)' } | Sort-Object Name)) {
    $Rule = $ProgramCatalog | Where-Object { $Program.Name -like $_.Pattern } | Select-Object -First 1
    $Detail = "v$($Program.Version)"
    if ($Rule) {
        $Verdict = ConvertTo-FGNVerdict -Text $Rule.Verdict
        if ($Verdict -eq 'KEEP') { $ProgramKeep++ }
        Add-FGNScanRow -Category 'Microsoft program' -Item $Program.Name -Detail $Detail -Verdict $Verdict -Reason $Rule.Why -Quiet:($Verdict -eq 'KEEP') -Kind 'Program' -Target "$($Program.Name)|$($Program.Version)"
    } else {
        Add-FGNScanRow -Category 'Microsoft program' -Item $Program.Name -Detail $Detail -Verdict 'REVIEW' -Reason 'Microsoft program that is not rated yet. Add a row to Data\MicrosoftApps.csv to rate it' -Kind 'Program' -Target "$($Program.Name)|$($Program.Version)"
    }
}
Write-FGNScan ("  {0} Microsoft program(s) rated KEEP. They are in the CSV; run with -ShowAll to list them here." -f $ProgramKeep) 'Gray'

Complete-FGNScanReport -NextHint 'Next   : run the removal script when you are happy with the verdicts (it is not part of this menu yet).'
if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
