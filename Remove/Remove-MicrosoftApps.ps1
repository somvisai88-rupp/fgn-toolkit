# FGN.Title: Remove - Microsoft apps
# FGN.Menu: hidden
# FGN.Removes: Microsoft
# FGN.Handles: Store, Program, Component
# FGN.Needs: Lib\FGN-Common.ps1, Tools\FGN-Win11-Debloat-Auto.ps1

<#
.SYNOPSIS
    FGN Toolkit - Remove the items picked from the Microsoft apps scan
.DESCRIPTION
    Removes the Microsoft apps and Windows components you picked after the Microsoft apps scan.

    Normally started by FGN-Menu.ps1: after a scan, the menu shows the list, you pick the items,
    and the menu passes your picks to this script in a small CSV file.
    This script removes only what is in that file. It handles: Store apps, programs, and the components Edge, OneDrive, Microsoft Store, WSL and Remote Desktop Connection.
    Anything else in the file is skipped and listed.
    Components are removed by the unattended script in Tools\ (same safety checks as the scan showed).
    OneDrive is removed for every profile that is safe to remove, not only the one you picked.

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

Start-FGNRemoveLog -Name 'Microsoft apps' -FileTag 'Microsoft' -DryRun:$DryRun
Write-FGNLog "$($Rows.Count) item(s) picked." 'White'
Write-FGNLog ''
Invoke-FGNRemoveRows -Rows $Rows -Handles @('Store', 'Program', 'Component') -DryRun:$DryRun
Complete-FGNRemoveLog
if ($WaitAtEnd) { [void](Read-Host "`nPress Enter to close this window") }
