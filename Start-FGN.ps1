# FGN Toolkit starter
#
# Run this on any Windows PC (PowerShell):
#   irm https://raw.githubusercontent.com/somvisai88-rupp/fgn-toolkit/main/Start-FGN.ps1 | iex
#
# What it does:
#   1. Downloads manifest.json (the list of toolkit files and their SHA-256 hashes).
#   2. Downloads every file into a staging folder and checks it. A script whose hash does not match the
#      manifest is never used: nothing is installed and nothing is run.
#   3. Copies the verified files into C:\ProgramData\FGN-Toolkit, removes files that are no longer part of the
#      toolkit, and starts FGN-Menu.ps1 (which asks for administrator rights itself).
#   Files under Data\ (the app lists) are not hash-checked, so a list edited on GitHub applies at once;
#   the toolkit checks the lists itself before using them.
#   If GitHub cannot be reached, the last downloaded copy is used.
#
# Options (set before the command, in the same window):
#   $env:FGN_REF = 'v1.0.0'     use a release tag or branch instead of main (pins the version)
#   $env:FGN_BASE_URL = '...'   use another web address that serves the same files

$FGNOwner = 'somvisai88-rupp'
$FGNRepo = 'fgn-toolkit'
$FGNRef = 'main'

& {
    $ErrorActionPreference = 'Stop'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $Ref = $FGNRef
    if ($env:FGN_REF) { $Ref = $env:FGN_REF }
    $Base = "https://raw.githubusercontent.com/$FGNOwner/$FGNRepo/$Ref"
    if ($env:FGN_BASE_URL) { $Base = $env:FGN_BASE_URL.TrimEnd('/') }
    $Work = Join-Path $env:ProgramData 'FGN-Toolkit'
    $Stage = Join-Path $Work '.staging'
    $Stamp = [DateTime]::UtcNow.Ticks

    function Get-FGNRemoteFile {
        param([string]$RelativePath, [string]$Destination)
        $Dir = Split-Path -Parent $Destination
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        Invoke-WebRequest -Uri ("$Base/$RelativePath" + '?t=' + $Stamp) -OutFile $Destination -UseBasicParsing
    }

    function Start-FGNCached {
        param([string]$Reason)
        $Menu = Join-Path $Work 'FGN-Menu.ps1'
        if (-not (Test-Path -LiteralPath $Menu)) {
            Write-Host "FGN Toolkit could not be downloaded and there is no earlier copy on this PC." -ForegroundColor Red
            Write-Host $Reason -ForegroundColor Red
            return
        }
        Write-Host "Could not reach the download address. Using the copy already on this PC." -ForegroundColor Yellow
        Write-Host $Reason -ForegroundColor DarkGray
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Menu
    }

    Write-Host "FGN Toolkit - checking $Base" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }

    # 1. manifest
    try {
        $Response = Invoke-WebRequest -Uri ("$Base/manifest.json?t=$Stamp") -UseBasicParsing
        $ManifestText = "$($Response.Content)".TrimStart([char]0xFEFF)
        $Manifest = $ManifestText | ConvertFrom-Json
    } catch {
        Start-FGNCached -Reason $_.Exception.Message
        return
    }
    $Files = @($Manifest.files)
    if ($Files.Count -eq 0) {
        Write-Host 'The manifest lists no files. Nothing was installed.' -ForegroundColor Red
        return
    }
    foreach ($File in $Files) {
        $P = "$($File.path)"
        if (-not $P -or $P.StartsWith('/') -or $P.StartsWith('\') -or $P -match '^[A-Za-z]:' -or $P -match '(^|[\\/])\.\.([\\/]|$)') {
            Write-Host "The manifest has an unsafe path ($P). Nothing was installed." -ForegroundColor Red
            return
        }
    }

    # 2. download everything to staging and verify before anything is replaced
    if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
    New-Item -ItemType Directory -Path $Stage -Force | Out-Null
    try {
        foreach ($File in $Files) {
            $Rel = "$($File.path)" -replace '\\', '/'
            $Dest = Join-Path $Stage ($Rel -replace '/', '\')
            Get-FGNRemoteFile -RelativePath $Rel -Destination $Dest
            if ("$($File.mode)" -ne 'data') {
                $Actual = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash
                if ($Actual -ne "$($File.sha256)".ToUpper()) {
                    Remove-Item -LiteralPath $Stage -Recurse -Force
                    Write-Host "SECURITY CHECK FAILED: $Rel does not match the manifest. Nothing was installed and nothing was run." -ForegroundColor Red
                    Write-Host 'Tell the person who looks after the toolkit. Do not run it until this is explained.' -ForegroundColor Red
                    return
                }
            }
        }
    } catch {
        if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
        Start-FGNCached -Reason $_.Exception.Message
        return
    }

    # 3. install the verified files, remove files that are no longer part of the toolkit
    foreach ($File in $Files) {
        $Rel = ("$($File.path)" -replace '/', '\')
        $From = Join-Path $Stage $Rel
        $To = Join-Path $Work $Rel
        $ToDir = Split-Path -Parent $To
        if (-not (Test-Path -LiteralPath $ToDir)) { New-Item -ItemType Directory -Path $ToDir -Force | Out-Null }
        Copy-Item -LiteralPath $From -Destination $To -Force
    }
    Remove-Item -LiteralPath $Stage -Recurse -Force
    $Keep = @($Files | ForEach-Object { (Join-Path $Work ("$($_.path)" -replace '/', '\')).ToLower() })
    foreach ($Existing in @(Get-ChildItem -LiteralPath $Work -Recurse -File -ErrorAction SilentlyContinue)) {
        $Relative = $Existing.FullName.Substring($Work.Length).TrimStart('\')
        if ($Relative -like 'Reports\*') { continue }
        if ($Keep -notcontains $Existing.FullName.ToLower()) { Remove-Item -LiteralPath $Existing.FullName -Force -ErrorAction SilentlyContinue }
    }
    Set-Content -LiteralPath (Join-Path $Work 'manifest.json') -Value $ManifestText -Encoding UTF8

    Write-Host ("FGN Toolkit {0} ready in {1}" -f $Manifest.version, $Work) -ForegroundColor Green
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Work 'FGN-Menu.ps1')
}
