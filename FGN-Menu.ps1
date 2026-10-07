<#
.SYNOPSIS
    FGN Toolkit - main menu
.DESCRIPTION
    Builds its menu from the folders next to it, so it only shows what is really there:

      FGN-Toolkit\
        FGN-Menu.ps1            this menu
        Run-FGN-Menu.cmd        double-click launcher
        Lib\                    shared code (not a menu item)
        Data\                   the lists the scans use (not a menu item)
        Reports\                scan reports, removal logs and your picks are saved here
        Tools\                  other scripts the toolkit calls (not a menu item)
        Scan\                   each .ps1 here that starts with an "FGN." header block is one menu item
        Remove\                 removal scripts: one per scan, used by the menu after you pick items

    Every folder that holds such scripts becomes a menu category, so a new folder appears by itself.
    A script is shown only when the script exists AND every file it lists in "FGN.Needs" exists:
    delete a script and its menu entry disappears.

    SCAN, PICK, REMOVE
      Choose a scan. When it finishes, the menu lists what it found in the terminal. Type the numbers
      to remove (for example 1,3,5-8, or R for everything rated REMOVE), check the list, and confirm.
      This only works for a scan that has a removal script in Remove\ (FGN.Removes matches the scan's
      FGN.ReportTag). A scan without one still runs; the menu says no removal script is available.
      Typing 2R instead of 2 picks from the last report of scan 2 without scanning again.

    The header block at the top of a script looks like this:
      # FGN.Title: Consumer apps (newly installed Windows 11 24H2)
      # FGN.Description: one line shown under the title
      # FGN.Order: 1                       position in the menu (lowest first)
      # FGN.Audience: new                  new or old - marks the best choice for this PC
      # FGN.MinBuild: 26100                warns when this PC's Windows build is lower
      # FGN.ReportTag: Consumer            names the scan's report, links it to its removal script
      # FGN.Needs: Lib\FGN-Common.ps1, Data\consumer-app-list.json
    A removal script has instead:
      # FGN.Menu: hidden                   keeps it out of the menu list
      # FGN.Removes: Consumer              the ReportTag of the scan it belongs to
      # FGN.Handles: Store, Copilot        the kinds of item it can remove

    Every script runs in its own process, so a problem in one cannot close the menu.
.PARAMETER List
    Print what the menu would show (and anything hidden, with the reason), then exit.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\FGN-Menu.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\FGN-Menu.ps1 -List
#>

param(
    [switch]$List
)

$ToolkitRoot = $PSScriptRoot
$LibPath = Join-Path $ToolkitRoot 'Lib\FGN-Common.ps1'
if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Host "The toolkit is incomplete: $LibPath is missing." -ForegroundColor Red
    exit 1
}
try { . $LibPath } catch {
    Write-Host "The shared library Lib\FGN-Common.ps1 could not be loaded: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if (-not $List) { Request-FGNAdmin -Bound $PSBoundParameters -ScriptPath $PSCommandPath }
$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Finding scripts
# ---------------------------------------------------------------------------
function Read-FGNScriptMeta {
    # Reads the "# FGN.Key: value" lines from the top of a script
    param([string]$Path)
    $Meta = @{}
    foreach ($Line in @(Get-Content -LiteralPath $Path -TotalCount 40 -ErrorAction SilentlyContinue)) {
        if ($Line -match '^\s*#\s*FGN\.(\w+)\s*:\s*(.*?)\s*$') { $Meta[$Matches[1]] = $Matches[2] }
    }
    return $Meta
}

function Get-FGNMetaNumber {
    param($Meta, [string]$Key, [int]$Default)
    if (-not $Meta.ContainsKey($Key)) { return $Default }
    $Parsed = 0
    if ([int]::TryParse($Meta[$Key], [ref]$Parsed)) { return $Parsed }
    return $Default
}

function Get-FGNMetaText {
    param($Meta, [string]$Key)
    if ($Meta.ContainsKey($Key)) { return $Meta[$Key] }
    return ''
}

function Get-FGNScriptInfo {
    # Every script that carries an FGN.Title header, in every folder except Lib, Data, Reports and Tools
    param([string]$Root)
    $NotMenuFolders = @('Lib', 'Data', 'Reports', 'Tools')
    foreach ($Folder in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $NotMenuFolders -notcontains $_.Name } | Sort-Object Name)) {
        foreach ($File in @(Get-ChildItem -LiteralPath $Folder.FullName -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $Meta = Read-FGNScriptMeta -Path $File.FullName
            if (-not $Meta.ContainsKey('Title')) { continue }
            $Missing = @()
            if ($Meta.ContainsKey('Needs')) {
                foreach ($Need in @(($Meta['Needs'] -split '\s*,\s*') | Where-Object { $_ })) {
                    if (-not (Test-Path -LiteralPath (Join-Path $Root $Need))) { $Missing += $Need }
                }
            }
            [pscustomobject]@{
                Category    = $Folder.Name
                Title       = $Meta['Title']
                Description = (Get-FGNMetaText -Meta $Meta -Key 'Description')
                Order       = (Get-FGNMetaNumber -Meta $Meta -Key 'Order' -Default 100)
                Audience    = (Get-FGNMetaText -Meta $Meta -Key 'Audience').ToLower()
                MinBuild    = (Get-FGNMetaNumber -Meta $Meta -Key 'MinBuild' -Default 0)
                Tag         = (Get-FGNMetaText -Meta $Meta -Key 'ReportTag')
                Removes     = (Get-FGNMetaText -Meta $Meta -Key 'Removes')
                Handles     = @((Get-FGNMetaText -Meta $Meta -Key 'Handles') -split '\s*,\s*' | Where-Object { $_ })
                Hidden      = ((Get-FGNMetaText -Meta $Meta -Key 'Menu').ToLower() -eq 'hidden')
                Path        = $File.FullName
                Missing     = $Missing
            }
        }
    }
}

function Get-FGNMenuItems {
    # Items = what the menu shows. Hidden = scripts that exist but are missing something they need.
    # Removers = removal scripts that are ready to use. RemoversMissing = removal scripts that are not.
    param([string]$Root)
    $All = @(Get-FGNScriptInfo -Root $Root)
    $Visible = @($All | Where-Object { -not $_.Hidden })
    [pscustomobject]@{
        Items           = @($Visible | Where-Object { $_.Missing.Count -eq 0 } | Sort-Object Category, Order, Title)
        Hidden          = @($Visible | Where-Object { $_.Missing.Count -gt 0 })
        Removers        = @($All | Where-Object { $_.Removes -and $_.Missing.Count -eq 0 })
        RemoversMissing = @($All | Where-Object { $_.Removes -and $_.Missing.Count -gt 0 })
    }
}

function Get-FGNRemoverFor {
    param($Discovery, [string]$Tag)
    if (-not $Tag) { return $null }
    return (@($Discovery.Removers | Where-Object { $_.Removes -eq $Tag }) | Select-Object -First 1)
}

function Get-FGNItemTags {
    param($Item, $Win, [bool]$Fresh, $Discovery)
    $Tags = @()
    if ($Item.Audience -eq 'new' -and $Fresh) { $Tags += 'suggested: this PC looks newly installed' }
    if ($Item.Audience -eq 'old' -and -not $Fresh) { $Tags += 'suggested: this PC has been in use for a while' }
    if ($Item.MinBuild -gt 0 -and $Win.Build -lt $Item.MinBuild) { $Tags += "made for Windows build $($Item.MinBuild) or later - this PC is build $($Win.Build)" }
    if ($Item.Tag) {
        if (Get-FGNRemoverFor -Discovery $Discovery -Tag $Item.Tag) { $Tags += 'removal available: pick items to remove after the scan' }
        else { $Tags += 'no removal script for this scan' }
    }
    return $Tags
}

# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------
function Show-FGNBanner {
    param($Win, [bool]$Fresh)
    Clear-Host
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ("   FGN Toolkit {0}" -f $script:FGNToolkitVersion) -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ("  Computer : {0}" -f $env:COMPUTERNAME)
    Write-Host ("  Windows  : {0} {1}, build {2}" -f $Win.Caption, $Win.DisplayVersion, $Win.Build)
    if ($null -ne $Win.InstallAgeDays) {
        $Note = ''
        if ($Fresh) { $Note = ' (looks like a new install)' }
        Write-Host ("  Installed: {0} day(s) ago{1}" -f $Win.InstallAgeDays, $Note)
    }
    Write-Host ''
}

function Read-FGNChoice {
    param([string]$Prompt)
    return ("$(Read-Host $Prompt)").Trim()
}

function Invoke-FGNMenuItem {
    param($Item)
    Write-Host ''
    Write-Host ("Running: " + $Item.Title) -ForegroundColor Cyan
    Write-Host ''
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Item.Path
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host ("The script stopped with exit code {0}." -f $LASTEXITCODE) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Pick items from a scan and remove them
# ---------------------------------------------------------------------------
function Get-FGNLatestScanCsv {
    param([string]$Tag)
    $Folder = Get-FGNReportFolder
    return (@(Get-ChildItem -LiteralPath $Folder -Filter "FGN-Scan-$Tag-$env:COMPUTERNAME-*.csv" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending) | Select-Object -First 1)
}

function ConvertFrom-FGNSelection {
    # "1,3,5-8" -> 1,3,5,6,7,8. Ok is false when the text is not understood or a number is out of range.
    param([string]$Text, [int]$Max)
    $Picked = @()
    foreach ($Part in @($Text -split '[,;\s]+' | Where-Object { $_ })) {
        if ($Part -match '^(\d+)-(\d+)$') {
            $From = [int]$Matches[1]
            $To = [int]$Matches[2]
            if ($From -gt $To) { return [pscustomobject]@{ Ok = $false; Numbers = @() } }
            for ($n = $From; $n -le $To; $n++) { $Picked += $n }
        } elseif ($Part -match '^\d+$') {
            $Picked += [int]$Part
        } else {
            return [pscustomobject]@{ Ok = $false; Numbers = @() }
        }
    }
    foreach ($n in $Picked) {
        if ($n -lt 1 -or $n -gt $Max) { return [pscustomobject]@{ Ok = $false; Numbers = @() } }
    }
    return [pscustomobject]@{ Ok = $true; Numbers = @($Picked | Sort-Object -Unique) }
}

function Get-FGNVerdictRank {
    param([string]$Verdict)
    $Order = @('REMOVE', 'OPTIONAL', 'REVIEW', 'ASK CLIENT', 'UPDATE', 'CHECK', 'NOT RATED', 'KEEP')
    $Index = [array]::IndexOf($Order, $Verdict)
    if ($Index -lt 0) { return 99 }
    return $Index
}

function Start-FGNPickAndRemove {
    param($Item, $Discovery)
    $Remover = Get-FGNRemoverFor -Discovery $Discovery -Tag $Item.Tag
    if (-not $Remover) {
        Write-Host ''
        Write-Host ("No removal script is available for '{0}'." -f $Item.Title) -ForegroundColor Yellow
        $Broken = @($Discovery.RemoversMissing | Where-Object { $_.Removes -eq $Item.Tag }) | Select-Object -First 1
        if ($Broken) { Write-Host ("  Its removal script is there but is missing: {0}" -f ($Broken.Missing -join ', ')) -ForegroundColor Yellow }
        else { Write-Host ("  The scan is read-only. To enable removal, add a script to the Remove folder with the header line: # FGN.Removes: " + $Item.Tag) -ForegroundColor DarkGray }
        return
    }
    $Csv = Get-FGNLatestScanCsv -Tag $Item.Tag
    if (-not $Csv) {
        Write-Host ''
        Write-Host 'No report from this scan was found on this PC. Run the scan first.' -ForegroundColor Yellow
        return
    }
    $AllRows = @(Import-Csv -LiteralPath $Csv.FullName -Encoding UTF8 | Where-Object { $_.Status -eq 'Present' })
    $NewRows = @($AllRows | Where-Object { $_.Verdict -eq 'NEW' })
    $Rows = @($AllRows | Where-Object { $_.Kind -and ($Remover.Handles -contains $_.Kind) -and $_.Verdict -ne 'NEW' })
    if (@($AllRows | Where-Object { $_.Kind }).Count -eq 0 -and $AllRows.Count -gt 0) {
        Write-Host ''
        Write-Host 'This report was made by an older version and has no removal information. Run the scan again.' -ForegroundColor Yellow
        return
    }
    $Default = @('REMOVE', 'OPTIONAL', 'REVIEW', 'ASK CLIENT')
    $ShowMore = $false
    $Message = ''
    while ($true) {
        $View = @()
        foreach ($Row in $Rows) {
            if ($ShowMore -or ($Default -contains $Row.Verdict)) {
                $View += [pscustomobject]@{ Rank = (Get-FGNVerdictRank -Verdict $Row.Verdict); Category = $Row.Category; Item = $Row.Item; Row = $Row }
            }
        }
        $View = @($View | Sort-Object Rank, Category, Item)
        Clear-Host
        Write-Host ("  {0}  -  from the scan on {1}" -f $Item.Title, $Csv.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) -ForegroundColor Cyan
        Write-Host ''
        if ($View.Count -eq 0) {
            Write-Host '  Nothing on this report is ready to remove.' -ForegroundColor Green
        }
        for ($i = 0; $i -lt $View.Count; $i++) {
            $Row = $View[$i].Row
            $Line = "  {0,3}. [{1}] {2}" -f ($i + 1), $Row.Verdict.PadRight(10), $Row.Item
            if ($Row.Detail) { $Line += " - $($Row.Detail)" }
            Write-Host $Line -ForegroundColor (Get-FGNVerdictColor -Verdict $Row.Verdict)
            if ($Row.Reason) { Write-Host ("        " + $Row.Reason) -ForegroundColor DarkGray }
        }
        if ($NewRows.Count -gt 0) {
            Write-Host ''
            Write-Host ("  NEW - not on the FGN list yet ({0}). These cannot be removed until they are added to the list:" -f $NewRows.Count) -ForegroundColor White
            foreach ($NewRow in $NewRows) {
                $NewText = $NewRow.Item
                if ($NewRow.Detail) { $NewText += " - $($NewRow.Detail)" }
                Write-FGNNewRow -Rest $NewText -Indent '       '
            }
            Write-Host '       Research each one, then add it to Data\consumer-app-list.json (the scan saved ready-to-fill entries in the Reports folder).' -ForegroundColor DarkGray
        }
        $Hidden = $Rows.Count - $View.Count
        Write-Host ''
        if ($Hidden -gt 0) { Write-Host ("  ({0} more item(s) rated KEEP, UPDATE, CHECK or NOT RATED are not shown - type M to show them)" -f $Hidden) -ForegroundColor DarkGray }
        if ($ShowMore) { Write-Host '  (showing every item that can be removed - type M to hide the KEEP / UPDATE / CHECK / NOT RATED ones again)' -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host '  Type the numbers to remove, for example  1,3,5-8'
        Write-Host '  R = everything rated REMOVE      M = show / hide more      B = back'
        if ($Message) { Write-Host ''; Write-Host ("  " + $Message) -ForegroundColor Yellow }
        $Message = ''
        Write-Host ''
        $Choice = Read-FGNChoice -Prompt 'Pick'
        if ($Choice -match '^[Bb]$') { return }
        if ($Choice -match '^[Mm]$') { $ShowMore = -not $ShowMore; continue }
        $Chosen = @()
        if ($Choice -match '^[Rr]$') {
            $Chosen = @($View | Where-Object { $_.Row.Verdict -eq 'REMOVE' } | ForEach-Object { $_.Row })
            if ($Chosen.Count -eq 0) { $Message = 'Nothing in the list is rated REMOVE.'; continue }
        } elseif ($Choice) {
            $Parsed = ConvertFrom-FGNSelection -Text $Choice -Max $View.Count
            if (-not $Parsed.Ok) { $Message = "I did not understand '$Choice'. Use numbers from the list, like 1,3,5-8."; continue }
            $Chosen = @($Parsed.Numbers | ForEach-Object { $View[$_ - 1].Row })
        } else {
            continue
        }

        # check the picks, then confirm
        Write-Host ''
        Write-Host ("  You picked {0} item(s):" -f $Chosen.Count) -ForegroundColor White
        foreach ($Row in $Chosen) {
            Write-Host ("    - [{0}] {1}" -f $Row.Verdict, $Row.Item) -ForegroundColor (Get-FGNVerdictColor -Verdict $Row.Verdict)
        }
        $Against = @($Chosen | Where-Object { @('KEEP', 'UPDATE', 'CHECK', 'NOT RATED') -contains $_.Verdict })
        if ($Against.Count -gt 0) {
            Write-Host ''
            Write-Host ("  Warning: {0} of these are NOT rated for removal (KEEP, UPDATE, CHECK or NOT RATED)." -f $Against.Count) -ForegroundColor Red
        }
        Write-Host ''
        Write-Host '  Y = remove them now      D = dry run (show what would happen, change nothing)      N = go back'
        $Confirm = Read-FGNChoice -Prompt 'Confirm'
        if ($Confirm -notmatch '^[YyDd]$') { continue }

        $SelFile = Join-Path (Get-FGNReportFolder) ("FGN-Selected-{0}-{1}-{2}.csv" -f $Item.Tag, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $Chosen | Export-Csv -LiteralPath $SelFile -NoTypeInformation -Encoding UTF8
        $RunArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Remover.Path, '-ItemsFile', $SelFile)
        if ($Confirm -match '^[Dd]$') { $RunArgs += '-DryRun' }
        Write-Host ''
        & powershell.exe @RunArgs
        Write-Host ''
        [void](Read-Host 'Press Enter to continue')
        return
    }
}

function Show-FGNCategory {
    param([string]$Category, $Win, [bool]$Fresh)
    while ($true) {
        $Discovery = Get-FGNMenuItems -Root $ToolkitRoot
        $Items = @($Discovery.Items | Where-Object { $_.Category -eq $Category })
        if ($Items.Count -eq 0) { return }
        $HasRemovable = (@($Items | Where-Object { $_.Tag -and (Get-FGNRemoverFor -Discovery $Discovery -Tag $_.Tag) }).Count -gt 0)
        Show-FGNBanner -Win $Win -Fresh $Fresh
        Write-Host ("  {0}" -f $Category) -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $Item = $Items[$i]
            Write-Host ("  {0}. {1}" -f ($i + 1), $Item.Title) -ForegroundColor White
            if ($Item.Description) { Write-Host ("       " + $Item.Description) -ForegroundColor DarkGray }
            foreach ($Tag in @(Get-FGNItemTags -Item $Item -Win $Win -Fresh $Fresh -Discovery $Discovery)) {
                Write-Host ("       [" + $Tag + "]") -ForegroundColor Yellow
            }
        }
        Write-Host ''
        if ($HasRemovable) {
            Write-Host '  Type a number to run it. When a scan has a removal script, the list of what it found'
            Write-Host '  appears afterwards so you can pick items to remove.'
            Write-Host '  Type the number followed by R (for example 2R) to pick from that scan''s last report without scanning again.'
            Write-Host ''
        }
        if ($Items.Count -gt 1) { Write-Host '  A. Run all of the above, one after the other (no picking)' }
        Write-Host '  B. Back'
        Write-Host '  Q. Quit'
        Write-Host ''
        $Choice = Read-FGNChoice -Prompt 'Choose'
        if ($Choice -match '^[Bb]$') { return }
        if ($Choice -match '^[Qq]$') { exit 0 }
        if ($Choice -match '^[Aa]$') {
            if ($Items.Count -gt 1) {
                foreach ($RunItem in $Items) { Invoke-FGNMenuItem -Item $RunItem }
                [void](Read-Host 'Press Enter to return to the menu')
            }
            continue
        }
        if ($Choice -match '^(\d+)([Rr]?)$') {
            $Index = [int]$Matches[1]
            $PickOnly = ($Matches[2] -ne '')
            if ($Index -ge 1 -and $Index -le $Items.Count) {
                $Chosen = $Items[$Index - 1]
                if (-not $PickOnly) { Invoke-FGNMenuItem -Item $Chosen }
                if ($Chosen.Tag) {
                    if (-not $PickOnly) { [void](Read-Host 'Press Enter to see the list and pick items to remove') }
                    Start-FGNPickAndRemove -Item $Chosen -Discovery $Discovery
                    if ((-not (Get-FGNRemoverFor -Discovery $Discovery -Tag $Chosen.Tag)) -or $PickOnly) { [void](Read-Host 'Press Enter to return to the menu') }
                } elseif ($PickOnly) {
                    Write-Host 'That script has no report to pick from.' -ForegroundColor Yellow
                    [void](Read-Host 'Press Enter to return to the menu')
                } else {
                    [void](Read-Host 'Press Enter to return to the menu')
                }
            }
        }
    }
}

# ===========================================================================
$Win = Get-FGNWindowsInfo
$Fresh = ($null -ne $Win.InstallAgeDays) -and ($Win.InstallAgeDays -le 30)

if ($List) {
    $Discovery = Get-FGNMenuItems -Root $ToolkitRoot
    Write-Host "Toolkit folder: $ToolkitRoot"
    Write-Host ("Windows build {0}; installed {1} day(s) ago" -f $Win.Build, $Win.InstallAgeDays)
    if ($Discovery.Items.Count -eq 0) { Write-Host 'No menu items found.' -ForegroundColor Yellow }
    foreach ($Group in @($Discovery.Items | Group-Object Category | Sort-Object Name)) {
        Write-Host ''
        Write-Host $Group.Name -ForegroundColor Cyan
        foreach ($Item in @($Group.Group)) {
            Write-Host ("  {0}. {1}" -f $Item.Order, $Item.Title)
            foreach ($Tag in @(Get-FGNItemTags -Item $Item -Win $Win -Fresh $Fresh -Discovery $Discovery)) { Write-Host ("       [" + $Tag + "]") -ForegroundColor Yellow }
        }
    }
    foreach ($Item in @($Discovery.Hidden)) {
        Write-Host ''
        Write-Host ("Hidden: {0} (missing: {1})" -f $Item.Title, ($Item.Missing -join ', ')) -ForegroundColor DarkYellow
    }
    foreach ($Item in @($Discovery.Removers)) {
        Write-Host ''
        Write-Host ("Removal script ready: {0} -> for scan '{1}' (handles {2})" -f $Item.Title, $Item.Removes, ($Item.Handles -join ', ')) -ForegroundColor DarkGreen
    }
    foreach ($Item in @($Discovery.RemoversMissing)) {
        Write-Host ''
        Write-Host ("Removal script NOT usable: {0} (missing: {1})" -f $Item.Title, ($Item.Missing -join ', ')) -ForegroundColor DarkYellow
    }
    exit 0
}

while ($true) {
    $Discovery = Get-FGNMenuItems -Root $ToolkitRoot
    $Categories = @($Discovery.Items | Group-Object Category | Sort-Object Name)
    Show-FGNBanner -Win $Win -Fresh $Fresh
    if ($Categories.Count -eq 0) { Write-Host '  No tools were found in this toolkit folder.' -ForegroundColor Yellow }
    for ($i = 0; $i -lt $Categories.Count; $i++) {
        $Plural = 's'
        if ($Categories[$i].Count -eq 1) { $Plural = '' }
        Write-Host ("  {0}. {1}  ({2} tool{3})" -f ($i + 1), $Categories[$i].Name, $Categories[$i].Count, $Plural) -ForegroundColor White
    }
    foreach ($Item in @($Discovery.Hidden)) {
        Write-Host ("  (hidden: {0} - missing {1})" -f $Item.Title, ($Item.Missing -join ', ')) -ForegroundColor DarkYellow
    }
    Write-Host ''
    Write-Host '  R. Open the reports folder'
    Write-Host '  Q. Quit'
    Write-Host ''
    $Choice = Read-FGNChoice -Prompt 'Choose'
    if ($Choice -match '^[Qq]$') { exit 0 }
    if ($Choice -match '^[Rr]$') {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Get-FGNReportFolder) + '"')
        continue
    }
    if ($Choice -match '^\d+$') {
        $Index = [int]$Choice
        if ($Index -ge 1 -and $Index -le $Categories.Count) {
            Show-FGNCategory -Category $Categories[$Index - 1].Name -Win $Win -Fresh $Fresh
        }
    }
}
