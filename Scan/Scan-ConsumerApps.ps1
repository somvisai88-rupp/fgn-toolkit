# FGN.Title: Consumer apps (newly installed Windows 11 24H2)
# FGN.Description: Xbox, Spotify, news and weather, Teams chat, Copilot, social apps and other consumer apps that come with a fresh install
# FGN.Order: 1
# FGN.ReportTag: Consumer
# FGN.Audience: new
# FGN.MinBuild: 26100
# FGN.Needs: Lib\FGN-Common.ps1, Data\consumer-app-list.json, Data\PromoKeywords.txt

<#
.SYNOPSIS
    FGN Toolkit - Scan consumer apps (READ-ONLY)
.DESCRIPTION
    For a newly installed Windows 11 24H2 (or 25H2) PC. Compares the Store apps and the installed
    programs on this PC with the FGN list in Data\consumer-app-list.json. It changes nothing.

      - An app on the list with action "remove"      -> REMOVE
      - An app on the list with action "ask-client"  -> ASK CLIENT
      - An app on the list with action "keep"        -> KEEP
      - A third-party Store app that is NOT listed   -> NEW (blocked from removal)

    Each entry in the list says HOW the app is removed (its "method"): appx for a Store app,
    uninstall for an installed program that has its own uninstaller, command for your own command.
    The removal script follows the method written in the list.

    A NEW app cannot be removed until someone researches it and adds it to Data\consumer-app-list.json.
    Every scan that finds NEW apps also writes Reports\FGN-NewApps-<computer>-<date>.json with an entry
    ready to fill in for each one. Change "action" to remove, keep or ask-client, write the reason, and
    paste the entry into the "apps" list of Data\consumer-app-list.json.

    If the list file has a mistake (a missing comma, for example) the scan stops and says which line.
    Microsoft's own apps that are not on this list (Calculator, Photos, Edge ...) are rated by Scan-MicrosoftApps.ps1.
.PARAMETER OutputFolder
    Where the report and CSV are saved.
.PARAMETER ShowAll
    Also list the apps on the FGN list that are not present, and the apps rated KEEP.
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

# ===========================================================================
Start-FGNScanReport -ScanName 'Consumer apps' -FileTag 'Consumer' -OutputFolder $OutputFolder -ShowAll:$ShowAll -NoCsv:$NoCsv

$List = Import-FGNConsumerList
if (-not $List.Ok) {
    Write-FGNScanHeader 'THE CONSUMER APP LIST HAS A PROBLEM'
    foreach ($ListError in $List.Errors) { Write-FGNScan "  $ListError" 'Red' }
    Write-FGNScan ''
    Write-FGNScan 'Fix Data\consumer-app-list.json and run the scan again. Nothing was scanned or changed.' 'Red'
    if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
    exit 1
}

$Packages = @(Get-FGNStorePackageList)
$Programs = @(Get-FGNInstalledPrograms -IncludeSystemComponents)
$PromoPattern = Get-FGNPromoPattern
$Handled = @()
$HandledPrograms = @()

Write-FGNScanHeader 'APPS ON THE FGN LIST (Data\consumer-app-list.json)'
foreach ($Entry in @($List.Entries)) {
    $MethodText = $Entry.Method
    if (-not $MethodText) { $MethodText = 'no method' }
    $Hits = @()
    if ($Entry.Package) {
        $Hits += @($Packages | Where-Object { ($_.Name -like $Entry.Package) -and -not (Test-FGNLikeAny -Name $_.Name -Patterns $Entry.Exclude) -and ($Handled -notcontains $_.Name) } |
            ForEach-Object { [pscustomobject]@{ Kind = 'Store'; Name = $_.Name; Target = $_.Name; Detail = (Get-FGNPackageDetail -Package $_); Protected = $_.Protected } })
    }
    if ($Entry.Program) {
        $Hits += @($Programs | Where-Object { ($_.Name -like $Entry.Program) -and -not (Test-FGNLikeAny -Name $_.Name -Patterns $Entry.Exclude) -and ($HandledPrograms -notcontains "$($_.Name)|$($_.Version)") } |
            ForEach-Object {
                $ProgramDetail = "v$($_.Version)"
                if ($_.Publisher) { $ProgramDetail += ", $($_.Publisher)" }
                [pscustomobject]@{ Kind = 'Program'; Name = $_.Name; Target = "$($_.Name)|$($_.Version)"; Detail = $ProgramDetail; Protected = $false }
            })
    }
    if ($Hits.Count -eq 0) {
        Add-FGNScanRow -Category 'Known app' -Item $Entry.Name -Status 'Not present' -Verdict 'NONE'
        continue
    }
    foreach ($Hit in $Hits) {
        if ($Hit.Kind -eq 'Store') { $Handled += $Hit.Name } else { $HandledPrograms += $Hit.Target }
        $ItemName = $Hit.Name
        if ($Entry.Name -and $Entry.Name -ne $Hit.Name) { $ItemName = "$($Entry.Name) ($($Hit.Name))" }
        $Why = $Entry.Reason
        if ($Entry.Risk) { $Why += " [risk: $($Entry.Risk)]" }
        if ($Entry.Action -ne 'keep') { $Why += " [method: $MethodText]" }
        if ($Entry.Action -eq 'keep') {
            Add-FGNScanRow -Category 'Known app' -Item $ItemName -Detail $Hit.Detail -Verdict 'KEEP' -Reason $Why -Kind $Hit.Kind -Target $Hit.Target -Quiet
        } elseif ($Hit.Protected) {
            Add-FGNScanRow -Category 'Known app' -Item $ItemName -Detail $Hit.Detail -Verdict 'REVIEW' -Kind $Hit.Kind -Target $Hit.Target `
                -Reason "$Why Windows marks this package as part of the system, so removing it may fail."
        } elseif ($Entry.Action -eq 'ask-client') {
            Add-FGNScanRow -Category 'Known app' -Item $ItemName -Detail $Hit.Detail -Verdict 'ASK CLIENT' -Reason $Why -Kind $Hit.Kind -Target $Hit.Target
        } else {
            Add-FGNScanRow -Category 'Known app' -Item $ItemName -Detail $Hit.Detail -Verdict 'REMOVE' -Reason $Why -Kind $Hit.Kind -Target $Hit.Target
        }
    }
}

Write-FGNScanHeader 'NEW APPS - NOT ON THE LIST YET (blocked from removal)'
$NewRows = @()
$Unknown = @($Packages | Where-Object { -not $_.Microsoft -and -not $_.Protected -and $Handled -notcontains $_.Name } | Sort-Object Name)
if ($Unknown.Count -eq 0) {
    Write-FGNScan '  None. Every third-party Store app on this PC is already on the list.' 'Green'
}
foreach ($App in $Unknown) {
    $Why = 'Not on the list. Find out what it is, then add it to Data\consumer-app-list.json as remove, keep or ask-client.'
    if ($PromoPattern -and ($App.Name -match $PromoPattern)) {
        $Why = 'Not on the list. Its name looks like promo or trial software - research it, then add it to Data\consumer-app-list.json.'
    }
    Add-FGNScanRow -Category 'New app' -Item $App.Name -Detail (Get-FGNPackageDetail -Package $App) -Verdict 'NEW' -Reason $Why -Kind 'Store' -Target $App.Name
    $NewRows += $Script:FGNScan.Rows[$Script:FGNScan.Rows.Count - 1]
}
$NewFile = Write-FGNNewAppsFile -Rows $NewRows
if ($NewFile) {
    Write-FGNScan ''
    Write-FGNScan "  Ready-to-fill entries for these apps: $NewFile" 'White'
}
Write-FGNScan '  Microsoft apps that are not consumer apps (Calculator, Photos, Edge, OneDrive ...) are rated by the Microsoft apps scan.' 'DarkGray'

Complete-FGNScanReport -NextHint 'Next   : pick the apps to remove from the list, or add the NEW apps to the list first.'
if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
