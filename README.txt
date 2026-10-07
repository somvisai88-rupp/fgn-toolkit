FGN TOOLKIT
===========

START
  Double-click  Run-FGN-Menu.cmd   (or run FGN-Menu.ps1 in PowerShell).
  Accept the Windows administrator prompt. Choose a category, then a tool.
  Copy the whole FGN-Toolkit folder to the PC or a USB stick; the folders must stay together.

IF WINDOWS SAYS "FGN-Menu.ps1 is not digitally signed"
  The zip was downloaded, so Windows blocks the files. Use Run-FGN-Menu.cmd (it unblocks them), or run once:
    Get-ChildItem -Recurse "<toolkit folder>" | Unblock-File
  Right-click the zip > Properties > Unblock BEFORE extracting also works. Do not start the .ps1 by typing its path.

FOLDERS
  FGN-Menu.ps1        the menu
  Run-FGN-Menu.cmd    double-click launcher
  Lib\                shared code. Not a menu item.
  Data\               the lists the scans use. Edit these, not the scripts.
  Reports\            scan reports (.txt + .csv), removal logs and your picks are saved here
  Tools\              scripts the toolkit calls (the unattended debloat script lives here). Not a menu item.
  Scan\               one script per scan. Each one is a menu item.
  Remove\             one removal script per scan. Not in the menu list; used after you pick items.

SCAN, PICK, REMOVE
  1. Menu > Scan > choose a scan. It reads the PC and changes nothing.
  2. When it finishes, press Enter. The menu lists what it found, numbered, colour-coded by verdict.
  3. Type the numbers you want removed:  1,3,5-8    (R = everything rated REMOVE,  M = also show the
     KEEP / UPDATE / CHECK / NOT RATED items,  B = back).
  4. Check the list you picked, then Y = remove now, D = dry run (shows what would happen, changes
     nothing), N = go back.
  5. Run the scan again to confirm.
  Type 2R instead of 2 to pick from scan 2's last report without scanning again.
  A scan only offers removal when its removal script exists in Remove\ (the menu tells you when it does
  not). Remove the script and that scan goes back to read-only.

  What each removal script can remove:
    Consumer   Store apps (for every user and from the Windows image), Copilot installed as a program
    Microsoft  Store apps, programs, and the components Edge, OneDrive, Microsoft Store, WSL and Remote
               Desktop Connection (done by Tools\FGN-Win11-Debloat-Auto.ps1, so its safety checks apply:
               for example Edge is skipped while no other browser is installed, and a OneDrive profile
               whose files would be stranded is skipped)
    Installed  programs (with their own uninstaller, silent when it supports that; otherwise its own
               window opens) and Store apps
  User files are never deleted. Every run writes a log to Reports\FGN-Remove-*.txt.

THE CONSUMER APP LIST (Data\consumer-app-list.json)
  Known apps are listed here. Removal of a consumer app is only allowed for an app on this list with
  action "remove" or "ask-client". An app that is NOT on the list is shown as NEW (highlighted label, grey
  text), cannot be picked, and is skipped even if someone forces it.
  When a scan finds NEW apps it also saves Reports\FGN-NewApps-<computer>-<date>.json with an entry ready
  to fill in for each one:
    1. Find out what the app is.
    2. In that file change "action" from review to remove, keep or ask-client, and write a short "reason".
    3. Copy the entry into the "apps" list of Data\consumer-app-list.json (keep the comma between entries).
    4. Scan again. The app is now known.
  Every entry also says HOW the app is removed ("method"), because apps differ:
    appx       a Store app. Uses "package" (the Store package name shown by the scan). Removed for every user
               and from the Windows image.
    uninstall  an installed program. Uses "program" (the name shown in Installed apps). Runs the program's own
               uninstaller, silent when it has a quiet mode. Add "silentArgs" (for example /S) only when the
               uninstaller has no quiet mode of its own.
    command    your own command, for apps that need something special. Uses "program" (to recognise the app)
               and "command" (run as written; for example a winget uninstall line). The app counts as removed
               when it is no longer in the installed programs list.
  "exclude" (optional) lists names to leave out, for example "GitHub*". "keep" entries need only a package or a
  program. Data\consumer-app-list.json has an "_examples" section showing each method; it is not used.
  * works as a wildcard, and the first matching entry wins. If the file has a mistake (a missing comma, for example) the scan and the removal stop and say which line.
  The Microsoft apps and installed apps lists still use their own CSV files.

THE SCANS (all read-only: they change nothing)
  1. Scan-ConsumerApps.ps1    newly installed Windows 11 24H2: Xbox, Spotify, news, Teams chat, Copilot ...
  2. Scan-MicrosoftApps.ps1   newly installed Windows 11 24H2: Edge, OneDrive, Store, WSL, Remote Desktop
                              Connection, and every other Microsoft app rated keep or remove
  3. Scan-InstalledApps.ps1   older Windows 11: everything installed over time, with old versions,
                              remote tools and trial software flagged

  Every scan gives each item a verdict:
    REMOVE      recommended under FGN policy
    OPTIONAL    safe to remove if the PC does not need it
    UPDATE      keep it, but the installed version is old
    REVIEW      look at it and decide
    ASK CLIENT  depends on the client's policy
    CHECK       needs a quick test
    NEW         consumer apps scan only: not in the FGN list yet. Blocked from removal until it is added.
    KEEP        leave it
    NOT RATED   no rule for it yet

HOW THE MENU DECIDES WHAT TO SHOW
  It reads the folders every time it draws a screen.
  - A script appears only if it exists AND carries the "# FGN.Title:" header block.
  - It is hidden (with a note on the menu) if a file listed in "# FGN.Needs:" is missing.
  - Delete Scan\Scan-InstalledApps.ps1 and the Scan menu shows two tools. Put it back and it shows three.
  - A new folder with such scripts (for example Remove\) becomes a new category by itself.
  Check what it sees without opening the menu:  FGN-Menu.ps1 -List

ADD A NEW SCAN
  1. Copy one of the scripts in Scan\ and give it a new name.
  2. Change the "# FGN." lines at the very top (Title, Description, Order, Audience, MinBuild, ReportTag, Needs).
  3. Change the body. Use the helpers in Lib\FGN-Common.ps1 (Add-FGNScanRow, Complete-FGNScanReport ...).
     Give each row a -Kind and -Target (Store, Program, Copilot or Component) if it can be removed.
  4. It shows up in the menu next time. Nothing else to register.

ADD A REMOVAL SCRIPT FOR A SCAN
  Copy one of the scripts in Remove\. Set "# FGN.Removes:" to the scan's "# FGN.ReportTag:" and list the
  kinds it can remove in "# FGN.Handles:". The scan then offers the pick-and-remove screen.

THE DATA FILES (Data\)
  consumer-app-list.json  every consumer app FGN has decided about: name, package, action (remove, keep or
                          ask-client), reason, risk, added. See "THE CONSUMER APP LIST" below.
  MicrosoftApps.csv       rates Microsoft apps and programs (Kind, Pattern, Verdict, Why)
  InstalledAppRules.csv   rates installed programs (Pattern = regular expression, Verdict, MinVersion, Why).
                          The first matching row wins.
  PromoKeywords.txt       words that mark trial or consumer software for REVIEW. One per line.

REPORTS
  Reports\FGN-Scan-<scan>-<computer>-<date>.txt   the report
  Reports\FGN-Scan-<scan>-<computer>-<date>.csv   one row per item; same columns for every scan and PC,
                                                  so CSVs from many PCs can be combined in Excel.
  If the Reports folder cannot be written (a locked USB stick) the files go to the Desktop.

THE UNATTENDED SCRIPT
  Tools\FGN-Win11-Debloat-Auto.ps1 still works on its own for a full unattended debloat of a new PC.
  It is not in the menu list; the Microsoft removal script calls its sections for the components.
