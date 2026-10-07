# FGN Toolkit

Scan a Windows 11 PC for consumer, Microsoft and installed apps, then pick what to remove.

## Run it on a PC

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/somvisai88-rupp/fgn-toolkit/main/Start-FGN.ps1 | iex
```

The starter downloads the toolkit to `C:\ProgramData\FGN-Toolkit`, checks every script against
`manifest.json`, and opens the menu. Accept the Windows administrator prompt.

To use a fixed version instead of the latest, set a release tag first:

```powershell
$env:FGN_REF = 'v1.0.0'
irm https://raw.githubusercontent.com/somvisai88-rupp/fgn-toolkit/v1.0.0/Start-FGN.ps1 | iex
```

## Update the app list (no scripts to change)

1. Open `Data/consumer-app-list.json` on GitHub and choose the pencil (Edit).
2. Add or change an entry. Keep the commas and quotes exactly as in the other entries.
3. Choose **Commit changes**. PCs get the new list the next time they run the one-liner
   (GitHub can take a few minutes to show it).

If the list has a mistake, the scan and removal stop and name the line.

## Change a script

1. Edit the file and upload it.
2. Rebuild the manifest on a Windows PC: `powershell -ExecutionPolicy Bypass -File .\Build-Manifest.ps1 -Version 1.0.1`
3. Upload the new `manifest.json`. Until it matches, PCs refuse to run the changed script.
4. Optionally publish a release with the tag `v1.0.1`.

## Safety

* Scripts run as administrator and can uninstall software. Keep two-step sign-in on this GitHub account.
* A script whose SHA-256 does not match `manifest.json` is never run.
* Do not store client names or passwords in this repository.
