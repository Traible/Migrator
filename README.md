# Migrator

**Back up a Windows user profile into one archive and restore it on the same or another PC.**

[Русская версия](README.ru.md)

[![tests](https://github.com/Traible/Migrator/actions/workflows/tests.yml/badge.svg)](https://github.com/Traible/Migrator/actions/workflows/tests.yml)

Migrator is a small PowerShell tool for moving a person to a new computer or
a fresh Windows installation. It packs documents, desktop, browser profiles
and application settings into a single `.7z` file - much faster than copying
hundreds of thousands of small files in Explorer - and restores them into the
same, another or a brand-new account.

```text
  Migrator  v2.5.1
  ====================================================================
  Back up and restore a Windows user profile

  User           : alex
  Administrator  : yes
  Browsers       : Google Chrome, Microsoft Edge
  Backups folder : E:\Migrator\Backups

  What would you like to do?
 > [1] Back up a user profile
       Pack documents, desktop, browser profiles and app settings into one archive
   [2] Restore a user profile
       From a Migrator archive or from Windows.old after reinstalling Windows
   [3] Open the backups folder
   ...
   Up/Down - move, Enter - select, Esc - back

  Backing up alex ██████████████░░░░░░░░░░  52%  310.4 MB/s  12,400 / 40,000 files  about 4 min left  DocumentsProjects
```

## Features

- **Fast.** No compression by default, one sequential archive, 7-Zip engine.
  2 GB / 40,000 files on an NVMe drive: backup with verification in 8 s,
  restore in 30 s.
- **Knows what not to copy.** Caches, temp files, crash dumps, registry hives
  and junctions are skipped; the size shown before the start is the size
  *after* exclusions.
- **Cloud-aware.** OneDrive / iCloud Drive / Dropbox folders with cloud-only
  files are detected, so the backup does not silently download tens of GB.
- **Honest results.** Service files of running programs (cookies, databases
  in `AppData`) are skipped quietly: the result stays a success. A skipped
  file from your own folders gives "completed with warnings" and is named; a
  damaged archive is always a failure.
- **Restore anywhere.** Current user, another existing user or a new local
  account; from an archive or directly from `Windows.old`.
- **Brings the programs back.** The list of installed programs is saved with
  the backup; after the restore you tick what to install again with `winget`.
- **Updates the installed programs.** New versions through `winget`: the
  recommended everyday programs, the ones you tick, or everything.
- **English and Russian interface**, arrow-key menus, progress with speed and
  remaining time.
- **Scriptable.** Every step has a command-line switch for unattended runs.
- **No bundled binaries.** MIT-licensed scripts; 7-Zip and PowerShell 7 are
  installed separately by `Get Tools.bat`.

## Quick start

1. Download the repository (or a release archive) and unpack it, for example
   to an external drive.
2. Run **`Get Tools.bat`** once. It finds PowerShell 7 and 7-Zip or offers to
   install them with `winget` or, without winget, to download portable copies
   into the Migrator folder; nothing happens until you type `y` for each program. `"Get Tools.bat" -Portable` puts portable copies into
   `Tools\`, so the folder works on any PC from a USB drive.
3. Run **`Migrator.bat`** and choose *Back up a user profile*.
4. On the new PC run `Migrator.bat` and choose *Restore a user profile*.

To back up or restore **another** user's profile, start Migrator as
Administrator (menu item *Restart as Administrator*).

## What is transferred

| Transferred | Not transferred |
|---|---|
| Documents, Desktop, Pictures, Downloads, Music, Videos | Installed programs (their **list** is saved, see below), drivers, printers |
| Browser profiles: bookmarks, history, extensions, settings | Saved browser passwords and cookies (Windows ties them to the account; use browser sync) |
| Application settings in `AppData\Roaming` and `AppData\Local` | Registry hives (`NTUSER.DAT`) - copying them breaks the target profile |
| Everything else in the profile folder | VPN and Wi-Fi profiles, Windows Hello/PIN, EFS certificates |

### Backup modes

- **Full** (default) - the whole profile except caches, temp files, crash
  dumps and registry hives.
- **Standard** - lighter: additionally skips Store app data
  (`AppData\Local\Packages`), per-user programs (`AppData\Local\Programs`),
  Teams/Slack data and re-downloadable developer caches (`node_modules`,
  `.nuget\packages`, `.gradle\caches`, `.m2\repository`, ...).

### Cloud folders

Reading a cloud-only (Files On-Demand) file forces the sync client to download
it. Before archiving, Migrator lists `OneDrive`, `OneDrive - *`, `iCloudDrive`
and `Dropbox` folders with their size and the number of cloud-only files and
asks whether to exclude each one. Unattended runs exclude folders that contain
cloud-only files; `-CloudFolders Exclude|Include|Auto` overrides this.

## Restore kit: for a new PC without internet

A freshly installed PC often has no PowerShell 7, no 7-Zip and no network
driver yet. When you make a backup, Migrator offers to put a **restore kit**
next to the archive: a copy of Migrator with both programs inside.

```text
E:\MigratorBackups\PC-alex-2026-11-11_10-00-00.7z
E:\MigratorBackups\Migrator\Migrator.bat        <- run this on the new PC
E:\MigratorBackups\Migrator\Tools\pwsh, Tools\7-Zip
```

- **Copy the installed programs** (default) - about 250 MB, no internet
  needed, the same versions the backup has just worked with.
- **Download PowerShell** from the official release instead - hash and
  Microsoft signature are checked.
- The question is asked once per backup folder: an existing kit is reused,
  and its scripts are refreshed when Migrator has been updated.
- Unattended runs: `-RestoreKit Copy|Download|None` (default `None`).

If the archives are saved inside the Migrator folder itself, that folder
becomes the kit: only its `Tools\` folder is filled. The same can be done
from the menu: *Check required tools*.

If you start `Migrator.bat` on a PC that has no PowerShell 7 and no kit, it
offers to install PowerShell 7 and 7-Zip (this needs internet).

## Restore

- **From an archive** - `.7z` made by Migrator, or `.rar` made by version 2.0.
  Files are extracted over the target profile: files with the same names are
  replaced, everything else in the target stays. Every file is checked against
  its checksum while it is extracted; a full test of the archive beforehand is
  optional.
- **From `Windows.old`** - after Windows was reinstalled over itself, the old
  profile is copied directly with `robocopy` using the same exclusions.
- **Target** - the current user, another existing user (sign that user out
  first) or a new local account, which Migrator can create.

## Programs

A profile archive does not contain the programs. When a backup is made,
Migrator saves their **list** in the manifest: the packages `winget` can
install again and the names of everything installed.

After a restore the list is written to `Logs\programs-<archive>.txt`. On a PC
with `winget` Migrator offers to choose what to install:

- programs already installed on the new PC and runtimes (Visual C++, .NET,
  WebView2 and the like, which come with the programs that need them) are
  not shown;
- utilities tied to the hardware of the old PC, trial antiviruses and
  "optimizers" are shown **without a tick**;
- everything else is ticked. Space changes a tick, `A` ticks all, `N` clears
  all, Enter confirms.

Nothing is installed without two typed `y`: one to open the list and one to
start. Paid programs are installed too, but ask for their license again.
Both lists are settings (`ProgramsHidden`, `ProgramsUnchecked`); a backup made
with `-NoProgramList` saves no list.

## Updating programs

Menu item *Update installed programs* asks `winget` which installed programs
have a newer version and shows them in two groups:

- **Recommended** - everyday programs that update without surprises:
  browsers, messengers, players, archivers, utilities, runtimes;
- **Other** - development tools and engines (Unity, Visual Studio, SDKs,
  Node.js, Python) and everything Migrator does not know, where a new
  version can change how things work.

Then you choose: *Recommended only*, *Choose from the list* (check marks,
recommended ones ticked) or *Everything*. Nothing is updated without a typed
`y`. Programs are updated one by one; the ones that failed are named at the
end. The recommended set is a setting, `UpdateRecommended`.

Only programs `winget` knows are updated, and `winget` must be present
(it is not in Windows Sandbox or LTSC). Drivers are not touched.

## Self-check and new versions

A release archive carries `files.sha256`, the SHA256 of every file in it.
Every time Migrator starts it compares its own folder with that list and
says so when a file is missing or changed - the usual result of a folder
copied to a USB drive incompletely.

Once a day Migrator also asks GitHub for the latest release (one request to
`api.github.com`, nothing about your PC is sent). When a newer version
exists it asks whether to update: after `y` the archive is downloaded,
checked against its checksum and its own file list, put over the folder, and
Migrator restarts. Settings, `Tools`, `Logs` and `Backups` are kept. Without
`y` nothing is downloaded. `"CheckForUpdates": false` in the settings turns
the request off. A copy without `files.sha256` (a `git clone`) is neither
checked nor updated.

This check cannot protect against someone who changes the scripts on
purpose. For that, release archives are built by GitHub Actions and GitHub
keeps a signed record of the build, which can be verified from outside:

```bat
gh attestation verify Migrator-2.5.0.zip --repo Traible/Migrator
```

## Command line

```bat
:: Backup
pwsh -NoProfile -File src\backup.ps1 -User alex -Mode Full -Destination E:\Backups -NonInteractive

:: Restore into an existing profile
pwsh -NoProfile -File src\restore.ps1 -Method Archive -Archive E:\Backups\PC-alex-2026-11-11_10-00-00.7z ^
     -TargetUser alex -NonInteractive

:: Restore from Windows.old
pwsh -NoProfile -File src\restore.ps1 -Method WindowsOld -SourceUser alex -TargetUser alex -NonInteractive
```

| Script | Switches |
|---|---|
| `backup.ps1` | `-User`, `-SourcePath`, `-Mode Full\|Standard`, `-Destination`, `-CloudFolders Auto\|Exclude\|Include`, `-RestoreKit None\|Copy\|Download`, `-NoProgramList`, `-NoVerify`, `-ComputeHash`, `-Force`, `-NonInteractive` |
| `restore.ps1` | `-Method Archive\|WindowsOld`, `-Archive`, `-SourceUser`, `-TargetUser`, `-TargetPath`, `-CreateUser`, `-Verify`, `-NoVerify`, `-Force`, `-NonInteractive` |
| `update.ps1` | `-Scope Recommended\|All`, `-ListOnly`, `-NonInteractive` |
| `main.ps1` | `-Language en\|ru\|auto` |

Exit code is `0` on success (including "completed with warnings") and non-zero
on failure.

## Files created by a backup

| File | Content |
|---|---|
| `PC-user-date.7z` | the archive; paths inside are relative to the profile folder |
| `.manifest.json` | source user and SID, mode, sizes, result, skipped files, the list of installed programs, optional SHA256 |
| `.summary.txt` | the same report as on screen, in the interface language |
| `.errors.log` | skipped files and archiver messages (only when there were any) |
| `.log` | start/finish records |

Keep the `.manifest.json` next to the archive: the restore uses it.

## Configuration

`src\config\defaults.json` (the language chosen in the menu is saved to
`src\config\user.json`):

| Setting | Default | Meaning |
|---|---|---|
| `Language` | `auto` | `auto` follows Windows; `en`, `ru` |
| `DefaultMode` | `Full` | `Full` or `Standard` |
| `Compression` | `0` | 7-Zip level 0-9. `0` stores without compression: fastest, right for SSDs and USB 3 drives. Try `1` for a slow USB 2.0 drive or a network share |
| `VerifyAfterBackup` | `true` | default choice for the test after backup |
| `VerifyBeforeRestore` | `false` | default choice for the full test before restore |
| `ComputeSha256` | `false` | store the archive's SHA256 in the manifest (computed together with the test) |
| `CloudFolderPolicy` | `Auto` | `Auto`, `Exclude`, `Include` |
| `CheckForUpdates` | `true` | look up the latest release at start, at most once a day |
| `ExcludeDevCaches` | `false` | also exclude developer caches in Full mode |
| `ExtraExcludes` | `[]` | your own masks, see below |
| `UpdateRecommended` | everyday programs | winget package ids (wildcards) updated by *Recommended only* |
| `ProgramsHidden` | runtimes | winget package ids (wildcards) never offered after a restore |
| `ProgramsUnchecked` | hardware utilities, trial antiviruses | package ids offered without a tick |
| `ArchiverPath` | `Tools\7-Zip\7z.exe` | checked first; an installed 7-Zip is found automatically |

### Exclusion masks

Masks are resolved by Migrator itself in one fast pass over the profile; the
archiver receives a ready list of folders.

- a trailing `\` is a **folder** mask - the whole folder is skipped: `*\Temp\`
- a mask starting with `*` matches at any depth: `*\node_modules\`, `*\*.bak`
- any other mask is relative to the profile root: `AppData\Local\Vendor\`

That is why `AppData\*Cache*\` removes every cache folder under `AppData` but
keeps a `Documents\CachedProjects` folder.

## Good to know

- **A `.7z` archive that was not written completely cannot be opened.** Use
  *Safely remove hardware* for external drives, keep verification after backup
  switched on, and do not delete the source profile until a restore worked.
- A profile that is signed in cannot be copied completely: files held open by
  programs are skipped and listed. For a complete copy run the backup from
  another administrator account.
- Restoring over the profile you are signed in to works for ordinary files;
  sign out and in again afterwards.
- Antivirus real-time scanning can slow down restoring hundreds of thousands
  of small files.

## Development

```bat
pwsh -NoProfile -File tests\Smoke.Tests.ps1     :: 179 checks, about a minute
pwsh -NoProfile -File build\New-Release.ps1     :: dist\Migrator-<version>.zip
```

```text
src\main.ps1, backup.ps1, restore.ps1    entry points
src\lib\Migrator.Core.psm1               config, localization, profile scan, exclusion masks
src\lib\Migrator.Archive.psm1            the only module that talks to 7-Zip
src\lib\Migrator.UI.psm1                 colors, menus, prompts, progress line
src\lib\Migrator.Browsers.psm1           browser detection
src\locale\en.psd1, ru.psd1              interface strings
```

To add a language, copy `src\locale\en.psd1` to `<code>.psd1` and translate
the values; the tests check that every key is present.

## License

MIT, © 2025-2026 Artem Osadchyi - see [LICENSE](LICENSE). Third-party programs and their licenses are
listed in [THIRD-PARTY.md](THIRD-PARTY.md). Version history:
[CHANGELOG.md](CHANGELOG.md).
