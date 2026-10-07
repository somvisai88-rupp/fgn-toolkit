<#
.SYNOPSIS
    Rebuilds manifest.json (the list of toolkit files and their SHA-256 hashes).
.DESCRIPTION
    Run this after you change any script or file in the repository, then upload manifest.json together
    with the changed files. Files under Data\ are listed as "data": they are not hash-checked by
    Start-FGN.ps1, so you can edit a list on GitHub without rebuilding the manifest.
.PARAMETER Version
    The version number shown when the toolkit starts, for example 1.0.1.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Build-Manifest.ps1 -Version 1.0.1
#>
param(
    [string]$Version = '1.0.0'
)

$Root = $PSScriptRoot
$Skip = @('manifest.json', 'Start-FGN.ps1', 'Build-Manifest.ps1', 'README.md', '.gitattributes', '.gitignore')
$Entries = @()
foreach ($File in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)) {
    $Relative = $File.FullName.Substring($Root.Length).TrimStart('\') -replace '\\', '/'
    if ($Relative.StartsWith('.git/') -or $Relative.StartsWith('Reports/')) { continue }
    if ($Skip -contains $Relative) { continue }
    $Mode = 'pinned'
    if ($Relative.StartsWith('Data/')) { $Mode = 'data' }
    $Entries += [ordered]@{
        path   = $Relative
        sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
        mode   = $Mode
    }
}
$Manifest = [ordered]@{ version = $Version; files = @($Entries) }
$Json = ConvertTo-Json -InputObject $Manifest -Depth 4
[IO.File]::WriteAllText((Join-Path $Root 'manifest.json'), $Json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("manifest.json written: {0} files, version {1}" -f $Entries.Count, $Version)
