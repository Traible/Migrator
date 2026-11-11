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
  Migrator  v2.2.2
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
- **Honest results.** A file locked by a running program gives "completed with
  warnings" and a list of skipped files, not a red failure; a damaged archive
  is always a failure.
- **Restore anywhere.** Current user, another existing user or a new local
  account; from an archive or directly from `Windows.old`.
- **English and Russian interface**, arrow-key menus, progress with speed and
  remaining time.
- **Scriptable.** Every step has a command-line switch for unattended runs.
- **No bundled binaries.** MIT-licensed scripts; 7-Zip and PowerShell 7 are
  installed separately by `Get Tools.bat`.

## Quick start

1. Download the repository (or a release archive) and unpack it, for example
   to an external drive.
2. Run **`Get Tools.bat`** once. It finds PowerShell 7 and 7-Zip or installs
   them with `winget`. `"Get Tools.bat" -Portable` puts portable copies into
   `Tools\`, so the folder works on any PC from a USB drive.
3. Run **`Migrator.bat`** and choose *Back up a user profile*.
4. On the new PC run `Migrator.bat` and choose *Restore a user profile*.

To back up or restore **another** user's profile, start Migrator as
Administrator (menu item *Restart as Administrator*).

## What is transferred

| Transferred | Not transferred |
|---|---|
| Documents, Desktop, Pictures, Downloads, Music, Videos | Installed programs, drivers, printers |
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
| `backup.ps1` | `-User`, `-SourcePath`, `-Mode Full\|Standard`, `-Destination`, `-CloudFolders Auto\|Exclude\|Include`, `-RestoreKit None\|Copy\|Download`, `-NoVerify`, `-ComputeHash`, `-Force`, `-NonInteractive` |
| `restore.ps1` | `-Method Archive\|WindowsOld`, `-Archive`, `-SourceUser`, `-TargetUser`, `-TargetPath`, `-CreateUser`, `-Verify`, `-NoVerify`, `-Force`, `-NonInteractive` |
| `main.ps1` | `-Language en\|ru\|auto` |

Exit code is `0` on success (including "completed with warnings") and non-zero
on failure.

## Files created by a backup

| File | Content |
|---|---|
| `PC-user-date.7z` | the archive; paths inside are relative to the profile folder |
| `.manifest.json` | source user and SID, mode, sizes, result, skipped files, optional SHA256 |
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
| `ExcludeDevCaches` | `false` | also exclude developer caches in Full mode |
| `ExtraExcludes` | `[]` | your own masks, see below |
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
pwsh -NoProfile -File tests\Smoke.Tests.ps1     :: 115 checks, about a minute
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
