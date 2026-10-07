# FGN.Title: Installed apps (older Windows 11)
# FGN.Description: Everything people installed over time: programs and third-party Store apps, with old versions, remote tools and trial software flagged
# FGN.Order: 3
# FGN.ReportTag: Installed
# FGN.Audience: old
# FGN.MinBuild: 22000
# FGN.Needs: Lib\FGN-Common.ps1, Data\InstalledAppRules.csv, Data\PromoKeywords.txt

<#
.SYNOPSIS
    FGN Toolkit - Scan installed apps (READ-ONLY)
.DESCRIPTION
    For a Windows 11 PC that has been in use for a while. Lists every installed program (Windows
    "Installed apps" list, all users) and every third-party Store app, and rates each one with the
    rules in Data\InstalledAppRules.csv. It changes nothing.

    Rules are checked from the top of the file down and the first match wins:
      Pattern     a regular expression matched against the app name
      Verdict     KEEP, REMOVE, OPTIONAL, UPDATE, REVIEW, ASK CLIENT or CHECK
      MinVersion  optional: the app is UPDATE when its version is lower, otherwise KEEP
      Why         shown next to the app

    An app that matches no rule but contains a word from Data\PromoKeywords.txt is REVIEW.
    Anything else is NOT RATED: add a rule to rate it next time.

    Microsoft's own apps (Edge, OneDrive, Store apps) are covered by Scan-MicrosoftApps.ps1.
.PARAMETER OutputFolder
    Where the report and CSV are saved.
.PARAMETER ShowAll
    Also list the apps rated KEEP or NOT RATED, and the apps that are not present.
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

function Get-FGNRuleVerdict {
    # First matching rule wins; see Data\InstalledAppRules.csv
    param([string]$Name, [string]$Version, $Rules, [string]$PromoPattern)
    foreach ($Rule in @($Rules)) {
        if (-not $Rule.Pattern) { continue }
        $IsMatch = $false
        try { $IsMatch = ($Name -match $Rule.Pattern) } catch { continue }
        if (-not $IsMatch) { continue }
        if ($Rule.MinVersion) {
            if (Test-FGNVersionBelow -Installed $Version -Minimum $Rule.MinVersion) {
                return [pscustomobject]@{ Verdict = 'UPDATE'; Why = "Version $Version is older than $($Rule.MinVersion). $($Rule.Why)" }
            }
            return [pscustomobject]@{ Verdict = 'KEEP'; Why = "Version is $($Rule.MinVersion) or newer. Keep it updated." }
        }
        return [pscustomobject]@{ Verdict = (ConvertTo-FGNVerdict -Text $Rule.Verdict); Why = "$($Rule.Why)" }
    }
    if ($PromoPattern -and ($Name -match $PromoPattern)) {
        return [pscustomobject]@{ Verdict = 'REVIEW'; Why = 'Looks like trial or consumer software. No rule for it yet.' }
    }
    return [pscustomobject]@{ Verdict = 'NOT RATED'; Why = 'No rule for this app yet. Add one to Data\InstalledAppRules.csv' }
}

# ===========================================================================
Start-FGNScanReport -ScanName 'Installed apps' -FileTag 'Installed' -OutputFolder $OutputFolder -ShowAll:$ShowAll -NoCsv:$NoCsv

$Rules = @(Import-FGNData -Name 'InstalledAppRules.csv')
$PromoPattern = Get-FGNPromoPattern

# programs from the Windows "Installed apps" list (Edge and OneDrive belong to the Microsoft apps scan)
Write-FGNScanHeader 'INSTALLED PROGRAMS'
$Programs = @(Get-FGNInstalledPrograms | Where-Object { $_.Name -notmatch '^(Microsoft Edge|Microsoft OneDrive)' } | Sort-Object Name)
$Counts = @{}
foreach ($Program in $Programs) {
    $Result = Get-FGNRuleVerdict -Name $Program.Name -Version $Program.Version -Rules $Rules -PromoPattern $PromoPattern
    $Counts[$Result.Verdict] = 1 + [int]$Counts[$Result.Verdict]
    $Detail = "v$($Program.Version)"
    if ($Program.Publisher) { $Detail += ", $($Program.Publisher)" }
    $Quiet = (@('KEEP', 'NOT RATED') -contains $Result.Verdict)
    Add-FGNScanRow -Category 'Program' -Item $Program.Name -Detail $Detail -Verdict $Result.Verdict -Reason $Result.Why -Quiet:$Quiet -Kind 'Program' -Target "$($Program.Name)|$($Program.Version)"
}
Write-FGNScan ("  {0} program(s) found: {1} rated KEEP, {2} not rated. The full list is in the CSV (or run with -ShowAll)." -f $Programs.Count, [int]$Counts['KEEP'], [int]$Counts['NOT RATED']) 'Gray'

# third-party Store apps (installed for at least one user)
Write-FGNScanHeader 'THIRD-PARTY STORE APPS'
$StoreApps = @(Get-FGNStorePackageList | Where-Object { $_.Installed -and -not $_.Microsoft -and -not $_.Protected } | Sort-Object Name)
$StoreCounts = @{}
foreach ($StoreApp in $StoreApps) {
    $Result = Get-FGNRuleVerdict -Name $StoreApp.Name -Version $StoreApp.Version -Rules $Rules -PromoPattern $PromoPattern
    $StoreCounts[$Result.Verdict] = 1 + [int]$StoreCounts[$Result.Verdict]
    $Quiet = (@('KEEP', 'NOT RATED') -contains $Result.Verdict)
    Add-FGNScanRow -Category 'Store app' -Item $StoreApp.Name -Detail (Get-FGNPackageDetail -Package $StoreApp) -Verdict $Result.Verdict -Reason $Result.Why -Quiet:$Quiet -Kind 'Store' -Target $StoreApp.Name
}
Write-FGNScan ("  {0} third-party Store app(s) found: {1} rated KEEP, {2} not rated." -f $StoreApps.Count, [int]$StoreCounts['KEEP'], [int]$StoreCounts['NOT RATED']) 'Gray'

Complete-FGNScanReport -NextHint 'Next   : rate the NOT RATED apps by adding rules to Data\InstalledAppRules.csv, then scan again.'
if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
