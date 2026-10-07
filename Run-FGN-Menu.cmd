@echo off
rem Starts the FGN Toolkit menu. It asks Windows for administrator rights itself.
rem First it removes the Windows 'downloaded from the internet' block from every toolkit file (needed after unzipping).
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File | Unblock-File"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FGN-Menu.ps1" %*
