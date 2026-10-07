# FGN Toolkit - shared helpers.
# Dot-sourced by FGN-Menu.ps1 and by every script in the Scan folder. Do not run this file by itself.

$script:FGNToolkitVersion = '1.0.0'
$script:FGNToolkitRoot = Split-Path -Parent $PSScriptRoot
$script:FGNDataFolder = Join-Path $script:FGNToolkitRoot 'Data'
$script:FGNScan = $null
# Windows infrastructure packages (frameworks, runtimes) - never worth listing
$script:FGNFrameworkPattern = '^(Microsoft\.(NET\.|VCLibs|UI\.Xaml|WindowsAppRuntime|Services\.Store)|Windows\.)'
$script:FGNVerdicts = @('REMOVE', 'OPTIONAL', 'UPDATE', 'REVIEW', 'ASK CLIENT', 'CHECK', 'NEW', 'KEEP', 'NOT RATED')

# ---------------------------------------------------------------------------
# Administrator rights
# ---------------------------------------------------------------------------
function Test-FGNAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-FGNElevationArgs {
    # The command line used to restart a script with administrator rights, keeping the same options
    param($Bound, [string]$ScriptPath, [string[]]$ExtraSwitches = @())
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
    foreach ($Extra in $ExtraSwitches) {
        if ($List -notcontains $Extra) { $List += $Extra }
    }
    return $List
}

function Request-FGNAdmin {
    # Does nothing when already elevated; otherwise restarts the calling script elevated and ends this copy
    param($Bound, [string]$ScriptPath, [string[]]$ExtraSwitches = @())
    if (Test-FGNAdmin) { return }
    if (-not $ScriptPath) {
        Write-Host 'Save this script to a file and run it again (it needs administrator rights).' -ForegroundColor Red
        exit 1
    }
    Write-Host 'Administrator rights are needed - restarting elevated. Accept the Windows prompt.' -ForegroundColor Cyan
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (New-FGNElevationArgs -Bound $Bound -ScriptPath $ScriptPath -ExtraSwitches $ExtraSwitches)
    } catch {
        Write-Host "Could not get administrator rights: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit
}

# ---------------------------------------------------------------------------
# Windows information (used by the menu and by every report)
# ---------------------------------------------------------------------------
function Get-FGNWindowsInfo {
    $Os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $Key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $Age = $null
    if ($Os -and $Os.InstallDate) { $Age = [int]((Get-Date) - $Os.InstallDate).TotalDays }
    [pscustomobject]@{
        Caption        = ("$($Os.Caption)").Replace('Microsoft ', '')
        DisplayVersion = "$($Key.DisplayVersion)"
        Build          = [int]$Key.CurrentBuild
        Ubr            = "$($Key.UBR)"
        InstallAgeDays = $Age
    }
}

# ---------------------------------------------------------------------------
# Data files (Data\ folder) - the lists the scans use, editable without touching any script
# ---------------------------------------------------------------------------
function Import-FGNData {
    param([string]$Name)
    $Path = Join-Path $script:FGNDataFolder $Name
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Missing data file: $Path" -ForegroundColor Red
        return @()
    }
    return @(Import-Csv -LiteralPath $Path -Encoding UTF8)
}

function Get-FGNPromoPattern {
    # Data\PromoKeywords.txt: one keyword per line (lines starting with # are comments)
    $Path = Join-Path $script:FGNDataFolder 'PromoKeywords.txt'
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $Words = @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($Words.Count -eq 0) { return $null }
    return ($Words -join '|')
}

function ConvertTo-FGNVerdict {
    param([string]$Text)
    $Clean = "$Text".Trim().ToUpper()
    if ($script:FGNVerdicts -contains $Clean) { return $Clean }
    return 'REVIEW'
}

function Test-FGNLikeAny {
    param([string]$Name, [string[]]$Patterns)
    foreach ($Pattern in @($Patterns)) {
        if ($Pattern -and ($Name -like $Pattern)) { return $true }
    }
    return $false
}

function Test-FGNVersionBelow {
    # True when the installed version is lower than the minimum. Unreadable versions are never flagged.
    param([string]$Installed, [string]$Minimum)
    if (-not $Minimum) { return $false }
    $Found = [regex]::Match("$Installed", '\d+(\.\d+){0,3}')
    if (-not $Found.Success) { return $false }
    $Text = $Found.Value
    if ($Text -notmatch '\.') { $Text += '.0' }
    try { return ([version]$Text -lt [version]$Minimum) } catch { return $false }
}

# ---------------------------------------------------------------------------
# Consumer app list (Data\consumer-app-list.json)
# ---------------------------------------------------------------------------
function Find-FGNJsonProblem {
    # Finds the usual hand-editing mistakes in a JSON text and says which line: a missing comma,
    # an extra comma before ] or }, a quote that is not closed, brackets that do not match, comments.
    # Returns $null when none of these is found.
    param([string]$Text)
    $Stack = New-Object System.Collections.ArrayList
    $Line = 1
    $InString = $false
    $Escape = $false
    $StringLine = 0
    $Last = ''
    $LastLine = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $C = [string]$Text[$i]
        if ($InString) {
            if ($Escape) { $Escape = $false }
            elseif ($C -ceq '\') { $Escape = $true }
            elseif ($C -ceq '"') { $InString = $false; $Last = '"'; $LastLine = $Line }
            elseif ($C -ceq "`n") { return "line ${StringLine}: a quoted text is not closed (a closing quote is missing)" }
            continue
        }
        if ($C -ceq "`n") { $Line++; continue }
        if ($C -ceq ' ' -or $C -ceq "`t" -or $C -ceq "`r") { continue }
        if ($C -ceq '/' -and ($i + 1) -lt $Text.Length -and (([string]$Text[$i + 1]) -ceq '/' -or ([string]$Text[$i + 1]) -ceq '*')) {
            return "line ${Line}: comments are not allowed in a JSON file"
        }
        if (@(0x2018, 0x2019, 0x201C, 0x201D) -contains [int][char]$C) {
            return "line ${Line}: a curly quote was found. Use plain straight quotes in a JSON file"
        }
        $AfterValue = ($Last -ne '' -and $Last -ne '{' -and $Last -ne '[' -and $Last -ne ',' -and $Last -ne ':')
        if ($C -ceq '"') {
            if ($AfterValue) { return "line ${LastLine}: a comma is missing at the end of this line" }
            $InString = $true
            $StringLine = $Line
            continue
        }
        if ($C -ceq '{' -or $C -ceq '[') {
            if ($AfterValue) { return "line ${LastLine}: a comma is missing at the end of this line" }
            [void]$Stack.Add([pscustomobject]@{ Char = $C; Line = $Line })
            $Last = $C
            $LastLine = $Line
            continue
        }
        if ($C -ceq '}' -or $C -ceq ']') {
            if ($Last -eq ',') { return "line ${LastLine}: there is an extra comma before the closing $C" }
            if ($Stack.Count -eq 0) { return "line ${Line}: unexpected $C" }
            $Open = $Stack[$Stack.Count - 1]
            $Stack.RemoveAt($Stack.Count - 1)
            if (($Open.Char -ceq '{') -ne ($C -ceq '}')) { return "line ${Line}: $C does not match the $($Open.Char) opened on line $($Open.Line)" }
            $Last = $C
            $LastLine = $Line
            continue
        }
        $Last = $C
        $LastLine = $Line
    }
    if ($InString) { return "line ${StringLine}: a quoted text is not closed" }
    if ($Stack.Count -gt 0) {
        $Open = $Stack[$Stack.Count - 1]
        return "line $($Open.Line): $($Open.Char) is never closed"
    }
    return $null
}

function Import-FGNConsumerList {
    # Reads and checks Data\consumer-app-list.json. Ok is false (with a list of Errors) when anything is wrong,
    # so a typo never leads to a wrong removal.
    $Path = Join-Path $script:FGNDataFolder 'consumer-app-list.json'
    $Result = [pscustomobject]@{ Ok = $false; Path = $Path; Entries = @(); Errors = @() }
    if (-not (Test-Path -LiteralPath $Path)) {
        $Result.Errors = @("The file is missing: $Path")
        return $Result
    }
    $Text = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).TrimStart([char]0xFEFF)
    $Problem = Find-FGNJsonProblem -Text $Text
    if ($Problem) {
        $Result.Errors = @("Data\consumer-app-list.json, $Problem")
        return $Result
    }
    try {
        $Json = $Text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $Result.Errors = @("Data\consumer-app-list.json is not valid JSON: $($_.Exception.Message)")
        return $Result
    }
    if ($null -eq $Json -or $null -eq $Json.apps) {
        $Result.Errors = @('Data\consumer-app-list.json has no "apps" list.')
        return $Result
    }
    $Actions = @('remove', 'keep', 'ask-client')
    $Methods = @('appx', 'uninstall', 'command')
    $Errors = @()
    $Entries = @()
    $Seen = @{}
    $Index = 0
    foreach ($App in @($Json.apps)) {
        $Index++
        $Label = "Entry $Index"
        if ($App.name) { $Label += " ($($App.name))" } elseif ($App.package) { $Label += " ($($App.package))" } elseif ($App.program) { $Label += " ($($App.program))" }
        $Package = "$($App.package)".Trim()
        $Program = "$($App.program)".Trim()
        $Method = "$($App.method)".Trim().ToLower()
        $Command = "$($App.command)".Trim()
        $Action = "$($App.action)".Trim().ToLower()
        if (-not "$($App.name)".Trim()) { $Errors += "$Label has no name." }
        if ($Actions -notcontains $Action) {
            $Errors += "$Label has the action '$($App.action)'. Use remove, keep or ask-client (review is only used in the new-apps file)."
        }
        if (-not "$($App.reason)".Trim()) { $Errors += "$Label has no reason. Write one short line saying why." }
        if ($Action -eq 'keep') {
            if (-not $Package -and -not $Program) { $Errors += "$Label needs a package (Store app) or a program (installed program) so the scan can recognise it." }
            if ($Method -and $Methods -notcontains $Method) { $Errors += "$Label has the method '$($App.method)'. Use appx, uninstall or command." }
        } else {
            if (-not $Method) {
                $Errors += "$Label has no method. Use appx (Store app), uninstall (installed program) or command (your own command)."
            } elseif ($Methods -notcontains $Method) {
                $Errors += "$Label has the method '$($App.method)'. Use appx, uninstall or command."
            } elseif ($Method -eq 'appx') {
                if (-not $Package) { $Errors += "$Label uses the method appx, so it needs a package (the Store package name)." }
                if ($Program) { $Errors += "$Label uses the method appx, so use package and not program." }
            } else {
                if (-not $Program) { $Errors += "$Label uses the method $Method, so it needs a program (the name shown in Installed apps; * works as a wildcard)." }
                if ($Package) { $Errors += "$Label uses the method $Method, so use program and not package." }
                if ($Method -eq 'command' -and -not $Command) { $Errors += "$Label uses the method command, so it needs a command." }
            }
        }
        $Key = "$Method|$Package|$Program".ToLower()
        if ($Seen.ContainsKey($Key)) { $Errors += "$Label repeats entry $($Seen[$Key]) (same method and package or program)." }
        else { $Seen[$Key] = $Index }
        $Exclude = @(@($App.exclude) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        $Entries += [pscustomobject]@{
            Name       = "$($App.name)".Trim()
            Action     = $Action
            Method     = $Method
            Package    = $Package
            Program    = $Program
            Exclude    = $Exclude
            SilentArgs = "$($App.silentArgs)".Trim()
            Command    = $Command
            Reason     = "$($App.reason)".Trim()
            Risk       = "$($App.risk)".Trim()
            Added      = "$($App.added)".Trim()
        }
    }
    $Result.Entries = $Entries
    $Result.Errors = $Errors
    $Result.Ok = ($Errors.Count -eq 0)
    return $Result
}

function Find-FGNConsumerEntry {
    # The entry for a Store app (matched on package). The first matching entry wins.
    param($List, [string]$Name)
    foreach ($Entry in @($List.Entries)) {
        if (-not $Entry.Package) { continue }
        if (($Name -like $Entry.Package) -and -not (Test-FGNLikeAny -Name $Name -Patterns $Entry.Exclude)) { return $Entry }
    }
    return $null
}

function Find-FGNConsumerProgramEntry {
    # The entry for an installed program (matched on the name shown in Installed apps). The first matching entry wins.
    param($List, [string]$Name)
    foreach ($Entry in @($List.Entries)) {
        if (-not $Entry.Program) { continue }
        if (($Name -like $Entry.Program) -and -not (Test-FGNLikeAny -Name $Name -Patterns $Entry.Exclude)) { return $Entry }
    }
    return $null
}

function Write-FGNNewAppsFile {
    # Writes the NEW apps from a scan as ready-to-fill entries. Copy each one into Data\consumer-app-list.json,
    # change "action" to remove, keep or ask-client, write the reason, and check the method (appx = Store app).
    param($Rows)
    $Rows = @($Rows)
    if ($Rows.Count -eq 0) { return $null }
    $Folder = Split-Path -Parent $script:FGNScan.ReportPath
    $Path = Join-Path $Folder ('FGN-NewApps-{0}-{1}.json' -f $script:FGNScan.Computer, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $Today = Get-Date -Format 'yyyy-MM-dd'
    $Entries = @()
    foreach ($Row in $Rows) {
        $Entries += [ordered]@{ name = "$($Row.Item)"; action = 'review'; method = 'appx'; package = "$($Row.Target)"; reason = ''; risk = ''; added = $Today }
    }
    $Json = ConvertTo-Json -InputObject @{ apps = @($Entries) } -Depth 4
    try {
        Set-Content -LiteralPath $Path -Value $Json -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $null
    }
    return $Path
}

# ---------------------------------------------------------------------------
# Installed software
# ---------------------------------------------------------------------------
function Test-FGNMicrosoftPackageName {
    param([string]$Name)
    return ($Name -match '^(Microsoft\.|MicrosoftWindows\.|MicrosoftCorporationII\.|Windows\.|MSTeams$|Clipchamp\.)')
}

function Get-FGNStorePackageList {
    # One entry per Store/app package name: installed for any user and/or in the Windows image
    # (provisioned = every NEW account gets it). Frameworks and language resource packages are left out.
    param($ProvisionedList)
    if ($null -eq $ProvisionedList) { $ProvisionedList = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue }
    $ProvisionedList = @($ProvisionedList)
    # A package that no user account has installed (for example only "Paused" for the system account) is a
    # left-over registration, not an installed app. Find-FGNApp uses the same rule when removing.
    $Installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        if ($_.IsFramework -or $_.IsResourcePackage) { return $false }
        $States = @($_.PackageUserInformation)
        ($States.Count -eq 0) -or (@($States | Where-Object { "$($_.InstallState)" -eq 'Installed' }).Count -gt 0)
    })
    $Names = @(@($Installed | ForEach-Object { $_.Name }) + @($ProvisionedList | ForEach-Object { $_.DisplayName }) |
        Where-Object { $_ -and $_ -notmatch $script:FGNFrameworkPattern } | Sort-Object -Unique)
    foreach ($Name in $Names) {
        $Inst = @($Installed | Where-Object { $_.Name -eq $Name })
        $Prov = @($ProvisionedList | Where-Object { $_.DisplayName -eq $Name })
        $Users = @($Inst | ForEach-Object { $_.PackageUserInformation } |
            Where-Object { $_ -and "$($_.InstallState)" -eq 'Installed' } |
            ForEach-Object { if ($_.UserSecurityId.UserName) { "$($_.UserSecurityId.UserName)" } else { "$($_.UserSecurityId)" } } |
            Sort-Object -Unique)
        $Version = ''
        if ($Inst.Count -gt 0) { $Version = "$($Inst[0].Version)" } elseif ($Prov.Count -gt 0) { $Version = "$($Prov[0].Version)" }
        $Protected = ($Inst.Count -gt 0) -and (@($Inst | Where-Object { $_.NonRemovable -or "$($_.SignatureKind)" -eq 'System' }).Count -gt 0)
        [pscustomobject]@{
            Name        = $Name
            Version     = $Version
            Installed   = ($Inst.Count -gt 0)
            Provisioned = ($Prov.Count -gt 0)
            Users       = ($Users -join ', ')
            Protected   = $Protected
            Microsoft   = (Test-FGNMicrosoftPackageName -Name $Name)
        }
    }
}

function Get-FGNPackageDetail {
    param($Package)
    $Parts = @()
    if ($Package.Installed) {
        $Text = "installed v$($Package.Version)"
        if ($Package.Users) { $Text += " for $($Package.Users)" }
        $Parts += $Text
    }
    if ($Package.Provisioned) { $Parts += 'in the Windows image (new accounts would get it)' }
    return ($Parts -join '; ')
}

function Get-FGNInstalledPrograms {
    # Programs shown in Windows "Installed apps" (the uninstall list), without updates and hidden components.
    # -IncludeSystemComponents also lists the entries Windows hides from that screen.
    param([switch]$IncludeSystemComponents)
    $Roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $Seen = @{}
    foreach ($Root in $Roots) {
        foreach ($Key in @(Get-ChildItem -Path $Root -ErrorAction SilentlyContinue)) {
            $Props = Get-ItemProperty -Path $Key.PSPath -ErrorAction SilentlyContinue
            if (-not $Props -or -not $Props.DisplayName) { continue }
            if ((-not $IncludeSystemComponents -and $Props.SystemComponent -eq 1) -or $Props.ParentKeyName -or $Props.ParentDisplayName) { continue }
            $Id = "$($Props.DisplayName)|$($Props.DisplayVersion)"
            if ($Seen.ContainsKey($Id)) { continue }
            $Seen[$Id] = $true
            [pscustomobject]@{
                Name           = "$($Props.DisplayName)"
                Version        = "$($Props.DisplayVersion)"
                Publisher      = "$($Props.Publisher)"
                Uninstall      = "$($Props.UninstallString)"
                QuietUninstall = "$($Props.QuietUninstallString)"
            }
        }
    }
}

function Get-FGNCopilotEntries {
    # Copilot can be installed as a regular program (not an app package). It then shows
    # in the Windows uninstall list, e.g. "C:\Program Files (x86)\Microsoft\Copilot\...\copilot_setup.exe --uninstall ..."
    $Roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $Found = @()
    foreach ($Root in $Roots) {
        $Found += @(Get-ChildItem -Path $Root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -like '*Copilot*' -and $_.DisplayName -notlike 'GitHub*' -and $_.UninstallString })
    }
    @($Found | Sort-Object UninstallString -Unique)
}

# ---------------------------------------------------------------------------
# Scan reports: one text report + one CSV per scan, same CSV columns for every scan and every PC.
# Kind + Target tell a removal script what an item is: Store (app package name), Program (name|version),
# Copilot (program name) or Component (OneDrive, Store, WSL, Edge, RDC).
# ---------------------------------------------------------------------------
function Get-FGNReportFolder {
    # Reports\ next to the toolkit (handy on a USB stick); falls back to the Desktop when that is not writable
    param([string]$Requested)
    $Candidates = @()
    if ($Requested) { $Candidates += $Requested }
    $Candidates += (Join-Path $script:FGNToolkitRoot 'Reports')
    $Candidates += [Environment]::GetFolderPath('Desktop')
    foreach ($Folder in $Candidates) {
        try {
            if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null }
            $Probe = Join-Path $Folder ('.fgn-write-test-' + [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $Probe -Value 'x' -ErrorAction Stop
            Remove-Item -LiteralPath $Probe -Force -ErrorAction SilentlyContinue
            return $Folder
        } catch {
            continue
        }
    }
    return [Environment]::GetFolderPath('Desktop')
}

function Write-FGNScan {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    if ($script:FGNScan) { Add-Content -LiteralPath $script:FGNScan.ReportPath -Value $Text -Encoding UTF8 }
}

function Write-FGNScanHeader {
    param([string]$Title)
    Write-FGNScan ''
    Write-FGNScan ('--- ' + $Title + ' ' + ('-' * [Math]::Max(3, 66 - $Title.Length))) 'Cyan'
}

function Get-FGNVerdictColor {
    param([string]$Verdict)
    switch ($Verdict) {
        'REMOVE'     { 'Yellow' }
        'OPTIONAL'   { 'White' }
        'NEW'        { 'Gray' }
        'UPDATE'     { 'Cyan' }
        'REVIEW'     { 'Magenta' }
        'ASK CLIENT' { 'Magenta' }
        'CHECK'      { 'Magenta' }
        'KEEP'       { 'Green' }
        default      { 'Gray' }
    }
}

function Start-FGNScanReport {
    param([string]$ScanName, [string]$FileTag, [string]$OutputFolder, [switch]$ShowAll, [switch]$NoCsv)
    $Folder = Get-FGNReportFolder -Requested $OutputFolder
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Computer = $env:COMPUTERNAME
    $script:FGNScan = [pscustomobject]@{
        Name       = $ScanName
        Computer   = $Computer
        ReportPath = Join-Path $Folder "FGN-Scan-$FileTag-$Computer-$Stamp.txt"
        CsvPath    = Join-Path $Folder "FGN-Scan-$FileTag-$Computer-$Stamp.csv"
        ShowAll    = [bool]$ShowAll
        NoCsv      = [bool]$NoCsv
        Rows       = New-Object System.Collections.ArrayList
    }
    $Win = Get-FGNWindowsInfo
    Write-FGNScan '=================================================================' 'Cyan'
    Write-FGNScan " FGN - $ScanName scan (read-only: nothing is changed)" 'Cyan'
    Write-FGNScan '=================================================================' 'Cyan'
    Write-FGNScan "Computer : $Computer"
    Write-FGNScan "Windows  : $($Win.Caption) $($Win.DisplayVersion), build $($Win.Build).$($Win.Ubr)"
    if ($null -ne $Win.InstallAgeDays) { Write-FGNScan "Installed: $($Win.InstallAgeDays) day(s) ago" }
    Write-FGNScan "Run by   : $env:USERDOMAIN\$env:USERNAME"
    Write-FGNScan "Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Write-FGNScan 'Verdicts : REMOVE, OPTIONAL, UPDATE, REVIEW, ASK CLIENT, CHECK, NEW, KEEP, NOT RATED  (NEW = not in the FGN list yet)'
}

function Write-FGNNewRow {
    # NEW = not in the FGN list yet and blocked from removal. The label is highlighted
    # (orange in Windows Terminal, a light bar in the classic blue console); the rest is grey.
    param([string]$Rest, [string]$Indent = '  ')
    Write-Host ($Indent + '[NEW       ]') -NoNewline -ForegroundColor Black -BackgroundColor DarkYellow
    Write-Host (' ' + $Rest) -ForegroundColor Gray
}

function Write-FGNScanRow {
    param($Row)
    if ($Row.Status -ne 'Present') {
        Write-FGNScan ("  [ --       ] {0} (not present)" -f $Row.Item) 'DarkGray'
        return
    }
    $Line = "  [{0}] {1}" -f $Row.Verdict.PadRight(10), $Row.Item
    if ($Row.Detail) { $Line += " - $($Row.Detail)" }
    if ($Row.Verdict -eq 'NEW') {
        Write-FGNNewRow -Rest ($Line.Substring(15))
        if ($script:FGNScan) { Add-Content -LiteralPath $script:FGNScan.ReportPath -Value $Line -Encoding UTF8 }
    } else {
        Write-FGNScan $Line (Get-FGNVerdictColor -Verdict $Row.Verdict)
    }
    if ($Row.Reason) { Write-FGNScan ("               " + $Row.Reason) 'DarkGray' }
}

function Add-FGNScanRow {
    # Status: Present / Not present.  Quiet rows go to the CSV only (unless the scan was run with -ShowAll).
    param(
        [string]$Category,
        [string]$Item,
        [string]$Detail = '',
        [string]$Status = 'Present',
        [string]$Verdict = 'NOT RATED',
        [string]$Reason = '',
        [string]$Kind = '',
        [string]$Target = '',
        [switch]$Quiet
    )
    $Scan = $script:FGNScan
    $Row = [pscustomobject]@{
        Computer = $Scan.Computer
        Scan     = $Scan.Name
        Category = $Category
        Item     = $Item
        Detail   = $Detail
        Status   = $Status
        Verdict  = $Verdict
        Reason   = $Reason
        Kind     = $Kind
        Target   = $Target
    }
    [void]$Scan.Rows.Add($Row)
    $Show = $false
    if ($Status -eq 'Present') { $Show = (-not $Quiet) -or $Scan.ShowAll } else { $Show = $Scan.ShowAll }
    if ($Show) { Write-FGNScanRow -Row $Row }
}

function Complete-FGNScanReport {
    param([string]$NextHint = '')
    $Scan = $script:FGNScan
    $Present = @($Scan.Rows | Where-Object { $_.Status -eq 'Present' })
    Write-FGNScan ''
    Write-FGNScan '================================ SUMMARY ================================' 'Cyan'
    foreach ($Verdict in $script:FGNVerdicts) {
        $Count = @($Present | Where-Object { $_.Verdict -eq $Verdict }).Count
        if ($Count -gt 0) { Write-FGNScan ("  {0} : {1}" -f $Verdict.PadRight(10), $Count) (Get-FGNVerdictColor -Verdict $Verdict) }
    }
    $Attention = @($Present | Where-Object { @('UPDATE', 'REVIEW', 'ASK CLIENT', 'CHECK', 'NEW') -contains $_.Verdict })
    if ($Attention.Count -gt 0) {
        Write-FGNScan ''
        Write-FGNScan 'Needs a decision:' 'Magenta'
        foreach ($Row in $Attention) {
            Write-FGNScan ("  - [{0}] {1}: {2}" -f $Row.Verdict, $Row.Item, $Row.Reason) 'Magenta'
        }
    }
    Write-FGNScan ''
    Write-FGNScan 'Nothing was changed on this PC.' 'Green'
    Write-FGNScan "Report : $($Scan.ReportPath)"
    if (-not $Scan.NoCsv) {
        $Scan.Rows | Export-Csv -LiteralPath $Scan.CsvPath -NoTypeInformation -Encoding UTF8
        Write-FGNScan "CSV    : $($Scan.CsvPath)"
    }
    if ($NextHint) { Write-FGNScan $NextHint }
}

# ---------------------------------------------------------------------------
# Removal log (used by the scripts in the Remove folder)
# ---------------------------------------------------------------------------
$script:FGNLog = $null

function Write-FGNLog {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    if ($script:FGNLog) { Add-Content -LiteralPath $script:FGNLog.Path -Value $Text -Encoding UTF8 }
}

function Start-FGNRemoveLog {
    param([string]$Name, [string]$FileTag, [switch]$DryRun)
    $Folder = Get-FGNReportFolder
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:FGNLog = [pscustomobject]@{
        Name    = $Name
        DryRun  = [bool]$DryRun
        Path    = Join-Path $Folder "FGN-Remove-$FileTag-$env:COMPUTERNAME-$Stamp.txt"
        Results = New-Object System.Collections.ArrayList
    }
    $Mode = 'REMOVING'
    if ($DryRun) { $Mode = 'DRY RUN - nothing will be changed' }
    Write-FGNLog '=================================================================' 'Cyan'
    Write-FGNLog " FGN - Remove $Name ($Mode)" 'Cyan'
    Write-FGNLog '=================================================================' 'Cyan'
    Write-FGNLog "Computer : $env:COMPUTERNAME"
    Write-FGNLog "Run by   : $env:USERDOMAIN\$env:USERNAME"
    Write-FGNLog "Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Write-FGNLog ''
}

function Add-FGNRemoveResult {
    # Result: REMOVED, FAILED, NOT FOUND, SKIPPED, WOULD REMOVE, RAN
    param([string]$Item, [string]$Result, [string]$Detail = '')
    if ($script:FGNLog) { [void]$script:FGNLog.Results.Add([pscustomobject]@{ Item = $Item; Result = $Result; Detail = $Detail }) }
    $Color = 'Gray'
    if ($Result -eq 'REMOVED' -or $Result -eq 'RAN') { $Color = 'Green' }
    elseif ($Result -eq 'FAILED') { $Color = 'Red' }
    elseif ($Result -eq 'WOULD REMOVE') { $Color = 'Yellow' }
    elseif ($Result -eq 'SKIPPED') { $Color = 'Magenta' }
    $Line = "  [{0}] {1}" -f $Result.PadRight(12), $Item
    if ($Detail) { $Line += " - $Detail" }
    Write-FGNLog $Line $Color
}

function Complete-FGNRemoveLog {
    $Results = @($script:FGNLog.Results)
    Write-FGNLog ''
    Write-FGNLog '================================ SUMMARY ================================' 'Cyan'
    foreach ($Name in @('REMOVED', 'RAN', 'WOULD REMOVE', 'FAILED', 'SKIPPED', 'NOT FOUND')) {
        $Count = @($Results | Where-Object { $_.Result -eq $Name }).Count
        if ($Count -gt 0) { Write-FGNLog ("  {0} : {1}" -f $Name.PadRight(12), $Count) }
    }
    if (@($Results | Where-Object { $_.Result -eq 'FAILED' }).Count -gt 0) {
        Write-FGNLog 'Some items failed. A restart may be needed first; run the scan again to see what is left.' 'Yellow'
    }
    Write-FGNLog 'Run the scan again to confirm the result.'
    Write-FGNLog "Log    : $($script:FGNLog.Path)"
}

# ---------------------------------------------------------------------------
# Removal helpers
# ---------------------------------------------------------------------------
function Find-FGNApp {
    # Is this Store app installed for any user, or provisioned (every NEW account would get it)?
    param(
        [Parameter(Mandatory)][string]$Name,
        $ProvisionedList
    )
    if ($null -eq $ProvisionedList) { $ProvisionedList = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue }
    $Installed = @(Get-AppxPackage -Name $Name -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        $States = @($_.PackageUserInformation)
        ($States.Count -eq 0) -or (@($States | Where-Object { "$($_.InstallState)" -eq 'Installed' }).Count -gt 0)
    })
    $Provisioned = @($ProvisionedList | Where-Object { $_.DisplayName -like $Name })
    [pscustomobject]@{
        Name        = $Name
        Installed   = $Installed
        Provisioned = $Provisioned
        Found       = ($Installed.Count -gt 0 -or $Provisioned.Count -gt 0)
    }
}

function Remove-FGNStoreApp {
    # Scan first, close the app, remove the installed copies, then the provisioned copy, then verify.
    # Each step has a second method, and the result names exactly what is left and why.
    param([string]$Name, $ProvisionedList, [switch]$DryRun)
    $Scan = Find-FGNApp -Name $Name -ProvisionedList $ProvisionedList
    if (-not $Scan.Found) {
        Add-FGNRemoveResult -Item $Name -Result 'NOT FOUND' -Detail 'already gone'
        return
    }
    $Detail = "installed: $($Scan.Installed.Count), in the Windows image: $($Scan.Provisioned.Count)"
    if ($DryRun) {
        Add-FGNRemoveResult -Item $Name -Result 'WOULD REMOVE' -Detail $Detail
        return
    }
    $Problems = @()

    # An app that is open cannot be removed: close it first
    foreach ($Pkg in $Scan.Installed) {
        $Dir = "$($Pkg.InstallLocation)"
        if (-not $Dir) { continue }
        foreach ($Proc in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Dir, [StringComparison]::OrdinalIgnoreCase) })) {
            try { Stop-Process -Id $Proc.Id -Force -ErrorAction Stop } catch { }
        }
    }

    # Installed copies: for every user first, then for the current user only
    foreach ($Pkg in $Scan.Installed) {
        try {
            Remove-AppxPackage -Package $Pkg.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            $Problems += "all users: $($_.Exception.Message)"
            try { Remove-AppxPackage -Package $Pkg.PackageFullName -ErrorAction Stop }
            catch { $Problems += "current user: $($_.Exception.Message)" }
        }
    }

    # Provisioned copy: PowerShell first, then DISM
    foreach ($Prov in $Scan.Provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $Prov.PackageName -ErrorAction Stop | Out-Null
        } catch {
            $Problems += "image: $($_.Exception.Message)"
            try {
                $Out = & dism.exe /Online /Remove-ProvisionedAppxPackage /PackageName:$($Prov.PackageName) /NoRestart 2>&1
                if ($LASTEXITCODE -ne 0) { $Problems += "dism exit code $LASTEXITCODE" }
            } catch { $Problems += "dism: $($_.Exception.Message)" }
        }
    }

    # Still installed for some user? Remove it for each user account separately
    $After = Find-FGNApp -Name $Name
    foreach ($Pkg in $After.Installed) {
        foreach ($Info in @($Pkg.PackageUserInformation | Where-Object { "$($_.InstallState)" -eq 'Installed' })) {
            $Sid = "$($Info.UserSecurityId.Sid)"
            if (-not $Sid) { continue }
            try { Remove-AppxPackage -Package $Pkg.PackageFullName -User $Sid -ErrorAction Stop }
            catch { $Problems += "user ${Sid}: $($_.Exception.Message)" }
        }
    }

    # Verify (Windows can take a few seconds to finish)
    $After = Find-FGNApp -Name $Name
    $Wait = 0
    while ($After.Found -and $Wait -lt 3) {
        Start-Sleep -Seconds 2
        $Wait++
        $After = Find-FGNApp -Name $Name
    }
    if ($After.Found) {
        $Why = "still present: installed $($After.Installed.Count), in the Windows image $($After.Provisioned.Count)"
        $Seen = @()
        foreach ($Pkg in $After.Installed) {
            foreach ($Info in @($Pkg.PackageUserInformation)) { $Seen += "$($Info.UserSecurityId.Sid)=$($Info.InstallState)" }
        }
        if ($Seen.Count -gt 0) { $Why += ' [' + (($Seen | Select-Object -Unique) -join ', ') + ']' }
        $Unique = @($Problems | Select-Object -Unique | Select-Object -First 3)
        if ($Unique.Count -gt 0) { $Why += ' | ' + ($Unique -join ' | ') }
        else { $Why += ' | Windows reported no error (restart the PC and scan again)' }
        Add-FGNRemoveResult -Item $Name -Result 'FAILED' -Detail $Why
    } else {
        Add-FGNRemoveResult -Item $Name -Result 'REMOVED'
    }
}

function Split-FGNTarget {
    # "Name|Version" -> Name and Version
    param([string]$Target)
    $Bar = $Target.LastIndexOf('|')
    if ($Bar -lt 0) { return [pscustomobject]@{ Name = $Target; Version = '' } }
    [pscustomobject]@{ Name = $Target.Substring(0, $Bar); Version = $Target.Substring($Bar + 1) }
}

function Get-FGNUninstallPlan {
    # The command to run and whether it should work without any window.
    # Prefers the program's own quiet command; turns an MSI uninstall into a silent msiexec call.
    param($Program)
    $Quiet = "$($Program.QuietUninstall)".Trim()
    $Normal = "$($Program.Uninstall)".Trim()
    if ($Quiet) { return [pscustomobject]@{ Command = $Quiet; Silent = $true } }
    if ($Normal -match '(?i)msiexec(\.exe)?\s.*(?<guid>\{[0-9A-F-]{36}\})') {
        return [pscustomobject]@{ Command = ('msiexec.exe /x ' + $Matches['guid'] + ' /qn /norestart'); Silent = $true }
    }
    if ($Normal) { return [pscustomobject]@{ Command = $Normal; Silent = $false } }
    return $null
}

function Remove-FGNProgram {
    # SilentArgs: added to the program's own uninstall command when that command has no quiet mode.
    # Command: used instead of the program's uninstall command (method "command" in consumer-app-list.json).
    param([string]$Target, [string]$SilentArgs = '', [string]$Command = '', [switch]$DryRun)
    $Part = Split-FGNTarget -Target $Target
    $Label = "$($Part.Name) $($Part.Version)".Trim()
    $Found = @(Get-FGNInstalledPrograms -IncludeSystemComponents | Where-Object { $_.Name -eq $Part.Name -and ((-not $Part.Version) -or $_.Version -eq $Part.Version) })
    if ($Found.Count -eq 0) {
        Add-FGNRemoveResult -Item $Label -Result 'NOT FOUND' -Detail 'not in the installed programs list any more'
        return
    }
    foreach ($Program in $Found) {
        if ($Command) {
            $Plan = [pscustomobject]@{ Command = $Command; Silent = $true }
        } else {
            $Plan = Get-FGNUninstallPlan -Program $Program
            if ($Plan -and -not $Plan.Silent -and $SilentArgs) {
                $Plan = [pscustomobject]@{ Command = ($Plan.Command + ' ' + $SilentArgs); Silent = $true }
            }
        }
        if (-not $Plan) {
            Add-FGNRemoveResult -Item $Label -Result 'SKIPPED' -Detail 'Windows has no uninstall command registered for it'
            continue
        }
        $Mode = 'its own uninstall window may open'
        if ($Command) { $Mode = 'your own command' } elseif ($Plan.Silent) { $Mode = 'silent' }
        if ($DryRun) {
            Add-FGNRemoveResult -Item $Label -Result 'WOULD REMOVE' -Detail "${Mode}: $($Plan.Command)"
            continue
        }
        Write-FGNLog "  Uninstalling $Label ($Mode) ..." 'DarkGray'
        $Code = $null
        try {
            if ($Plan.Silent) {
                $Proc = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $Plan.Command + '"') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            } else {
                $Proc = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $Plan.Command + '"') -Wait -PassThru -ErrorAction Stop
            }
            $Code = $Proc.ExitCode
        } catch {
            Add-FGNRemoveResult -Item $Label -Result 'FAILED' -Detail $_.Exception.Message
            continue
        }
        Start-Sleep -Seconds 2
        $Still = @(Get-FGNInstalledPrograms -IncludeSystemComponents | Where-Object { $_.Name -eq $Program.Name -and $_.Version -eq $Program.Version })
        if ($Still.Count -eq 0) {
            $Note = ''
            if ($Code -eq 3010) { $Note = 'restart needed to finish' }
            Add-FGNRemoveResult -Item $Label -Result 'REMOVED' -Detail $Note
        } else {
            Add-FGNRemoveResult -Item $Label -Result 'FAILED' -Detail "still listed after the uninstaller finished (exit code $Code). It may have been cancelled, or may need a restart"
        }
    }
}

function Remove-FGNCopilotProgram {
    param([string]$Target, [switch]$DryRun)
    $Entries = @(Get-FGNCopilotEntries | Where-Object { $_.DisplayName -eq $Target })
    if ($Entries.Count -eq 0) {
        Add-FGNRemoveResult -Item $Target -Result 'NOT FOUND' -Detail 'not in the installed programs list any more'
        return
    }
    if ($DryRun) {
        Add-FGNRemoveResult -Item $Target -Result 'WOULD REMOVE' -Detail "runs: $($Entries[0].UninstallString)"
        return
    }
    Get-Process -Name 'mscopilot', 'Copilot' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($Entry in $Entries) {
        Write-FGNLog "  Running: $($Entry.UninstallString)" 'DarkGray'
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $($Entry.UninstallString)" -Wait -WindowStyle Hidden
    }
    Start-Sleep -Seconds 3
    if (@(Get-FGNCopilotEntries | Where-Object { $_.DisplayName -eq $Target }).Count -eq 0) {
        Add-FGNRemoveResult -Item $Target -Result 'REMOVED'
    } else {
        Add-FGNRemoveResult -Item $Target -Result 'FAILED' -Detail 'still listed after the uninstaller finished. Restart and scan again'
    }
}

function Invoke-FGNComponentRemoval {
    # Windows components (OneDrive, Store, WSL, Edge, Remote Desktop Connection) are removed by the matching
    # section of the unattended script in Tools\, so the same safety checks apply as the scan showed.
    param([string[]]$Targets, [switch]$DryRun)
    $Map = [ordered]@{ OneDrive = '13'; Store = '14'; WSL = '15'; Edge = '16'; RDC = '17' }
    $Auto = Join-Path $script:FGNToolkitRoot 'Tools\FGN-Win11-Debloat-Auto.ps1'
    $Sections = @()
    $Known = @()
    foreach ($Target in @($Targets | Select-Object -Unique)) {
        if (-not $Map.Contains($Target)) {
            Add-FGNRemoveResult -Item $Target -Result 'SKIPPED' -Detail 'unknown component'
            continue
        }
        $Known += $Target
        $Sections += $Map[$Target]
    }
    if ($Known.Count -eq 0) { return }
    if ($DryRun) {
        foreach ($Target in $Known) {
            Add-FGNRemoveResult -Item $Target -Result 'WOULD REMOVE' -Detail "runs section $($Map[$Target]) of the unattended script, which skips anything unsafe"
        }
        return
    }
    if (-not (Test-Path -LiteralPath $Auto)) {
        foreach ($Target in $Known) { Add-FGNRemoveResult -Item $Target -Result 'FAILED' -Detail 'Tools\FGN-Win11-Debloat-Auto.ps1 is missing' }
        return
    }
    Write-FGNLog ''
    Write-FGNLog ("Running the unattended script for: " + ($Known -join ', ') + " (sections " + ($Sections -join ',') + ")") 'Cyan'
    Write-FGNLog 'It skips anything unsafe (for example Edge without another browser, or a OneDrive profile with files that would be stranded). Its own log is saved on the Desktop.' 'DarkGray'
    Write-FGNLog ''
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Auto -Only ($Sections -join ',')
    $Code = $LASTEXITCODE
    Write-FGNLog ''
    foreach ($Target in $Known) {
        Add-FGNRemoveResult -Item $Target -Result 'RAN' -Detail "see the unattended script's summary above for what it removed or skipped (exit code $Code)"
    }
}

function Invoke-FGNRemoveRows {
    # Rows come from a scan CSV (columns Item, Verdict, Kind, Target ...). Handles = the kinds this script may remove.
    param($Rows, [string[]]$Handles, [switch]$DryRun)
    $Provisioned = $null
    $Seen = @{}
    $ComponentTargets = @()
    foreach ($Row in @($Rows)) {
        $Key = "$($Row.Kind)|$($Row.Target)"
        if ($Seen.ContainsKey($Key)) { continue }
        $Seen[$Key] = $true
        if ($Handles -notcontains $Row.Kind) {
            Add-FGNRemoveResult -Item $Row.Item -Result 'SKIPPED' -Detail "this removal script does not handle '$($Row.Kind)' items"
        } elseif ($Row.Kind -eq 'Store') {
            if ($null -eq $Provisioned) { $Provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) }
            Remove-FGNStoreApp -Name $Row.Target -ProvisionedList $Provisioned -DryRun:$DryRun
        } elseif ($Row.Kind -eq 'Program') {
            Remove-FGNProgram -Target $Row.Target -DryRun:$DryRun
        } elseif ($Row.Kind -eq 'Copilot') {
            Remove-FGNCopilotProgram -Target $Row.Target -DryRun:$DryRun
        } elseif ($Row.Kind -eq 'Component') {
            $ComponentTargets += $Row.Target
        } else {
            Add-FGNRemoveResult -Item $Row.Item -Result 'SKIPPED' -Detail "unknown kind '$($Row.Kind)'"
        }
    }
    if ($ComponentTargets.Count -gt 0) { Invoke-FGNComponentRemoval -Targets $ComponentTargets -DryRun:$DryRun }
}
