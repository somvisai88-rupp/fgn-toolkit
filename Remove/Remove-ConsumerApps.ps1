# FGN.Title: Remove - consumer apps
# FGN.Menu: hidden
# FGN.Removes: Consumer
# FGN.Handles: Store, Program
# FGN.Needs: Lib\FGN-Common.ps1, Data\consumer-app-list.json

<#
.SYNOPSIS
    FGN Toolkit - Remove the items picked from the consumer apps scan
.DESCRIPTION
    Removes the consumer apps you picked after the consumer apps scan.

    Normally started by FGN-Menu.ps1: after a scan, the menu shows the list, you pick the items,
    and the menu passes your picks to this script in a small CSV file.

    Only apps on Data\consumer-app-list.json with action remove or ask-client are removed. An app that
    is not on the list, or is marked keep, is skipped. The entry's "method" decides how it is removed:
      appx       a Store app: removed for every user and from the Windows image
      uninstall  an installed program: its own uninstaller, silent when it has a quiet mode
      command    your own command, written in the list
    Anything else in the file is skipped and listed.

    The log is saved in the toolkit's Reports folder.
.PARAMETER ItemsFile
    CSV of the picked rows (made by the menu from the scan report).
.PARAMETER DryRun
    Show what would be removed without changing anything.
.PARAMETER WaitAtEnd
    Wait for Enter before the window closes (added automatically when the script restarts itself elevated).
#>

param(
    [Parameter(Mandatory = $true)][string]$ItemsFile,
    [switch]$DryRun,
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

if (-not (Test-Path -LiteralPath $ItemsFile)) {
    Write-Host "Cannot find the list of picked items: $ItemsFile" -ForegroundColor Red
    exit 1
}
$Rows = @(Import-Csv -LiteralPath $ItemsFile -Encoding UTF8)

Start-FGNRemoveLog -Name 'consumer apps' -FileTag 'Consumer' -DryRun:$DryRun
Write-FGNLog "$($Rows.Count) item(s) picked." 'White'
Write-FGNLog ''

# Only apps that are on Data\consumer-app-list.json with action remove or ask-client may be removed.
# This is checked again here, whatever the pick list said.
$List = Import-FGNConsumerList
if (-not $List.Ok) {
    Write-FGNLog 'The consumer app list has a problem, so nothing was removed:' 'Red'
    foreach ($ListError in $List.Errors) { Write-FGNLog "  $ListError" 'Red' }
    Write-FGNLog 'Fix Data\consumer-app-list.json and try again.' 'Red'
    if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
    exit 1
}
$Provisioned = $null
$Seen = @{}
foreach ($Row in $Rows) {
    $Key = "$($Row.Kind)|$($Row.Target)"
    if ($Seen.ContainsKey($Key)) { continue }
    $Seen[$Key] = $true
    $Entry = $null
    if ($Row.Kind -eq 'Store') {
        $Entry = Find-FGNConsumerEntry -List $List -Name $Row.Target
    } elseif ($Row.Kind -eq 'Program') {
        $Part = Split-FGNTarget -Target $Row.Target
        $Entry = Find-FGNConsumerProgramEntry -List $List -Name $Part.Name
    } else {
        Add-FGNRemoveResult -Item $Row.Item -Result 'SKIPPED' -Detail "this removal script does not handle '$($Row.Kind)' items"
        continue
    }
    if (-not $Entry) {
        Add-FGNRemoveResult -Item $Row.Item -Result 'SKIPPED' -Detail 'not on Data\consumer-app-list.json yet - add it to the list first'
        continue
    }
    if ($Entry.Action -eq 'keep') {
        Add-FGNRemoveResult -Item $Row.Item -Result 'SKIPPED' -Detail 'the list says keep'
        continue
    }
    # The method written in the list decides how the app is removed
    if ($Entry.Method -eq 'appx') {
        if ($null -eq $Provisioned) { $Provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) }
        Remove-FGNStoreApp -Name $Row.Target -ProvisionedList $Provisioned -DryRun:$DryRun
    } elseif ($Entry.Method -eq 'uninstall') {
        Remove-FGNProgram -Target $Row.Target -SilentArgs $Entry.SilentArgs -DryRun:$DryRun
    } elseif ($Entry.Method -eq 'command') {
        Remove-FGNProgram -Target $Row.Target -Command $Entry.Command -DryRun:$DryRun
    } else {
        Add-FGNRemoveResult -Item $Row.Item -Result 'SKIPPED' -Detail 'the list gives no removal method for it'
    }
}
Complete-FGNRemoveLog
if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
