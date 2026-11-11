# Changelog

## 2.2.2 — 2026-11-11

### Fixed

- **Resizing the window during a backup or restore no longer leaves copies of the progress line on screen.** When the window gets narrower, the terminal re-wraps the line already drawn over several rows; Migrator used to return only to the start of the last one. It now works out how many rows the previous line takes at the current width, goes back to the first and erases from there. Terminals without escape sequences keep the old overwrite with spaces.

## 2.2.1 — 2026-11-11

### Changed

- **Remaining time is estimated from bytes and files together.** The old forecast divided the remaining bytes by the current speed, so it was far too optimistic while large files were copied and jumped to many hours on small ones. The new model fits two costs to the work already done - seconds per megabyte and seconds per file - and applies them to the remaining bytes and the remaining files. On a simulated profile (300,000 small files first, 50 GB of large files after) the forecast is 736 s against a true 580 s; the old method says 10,480 s.
- The progress line now shows the current speed, files done out of the total, a rounded and smoothed remaining time ("about 4 min left") and the folder being processed. "Estimating time..." is shown until there is enough data.
- The current speed stays in the line on purpose: a drive plugged into a slow USB port is visible at once.

## 2.2.0 — 2026-11-11

### Added

- **Restore kit.** A backup can put a copy of Migrator with portable PowerShell 7 and 7-Zip next to the archive (`<backup folder>\Migrator`), so a new PC with no tools and no internet can restore straight from the external drive. The programs are copied from the ones installed on the PC (default, offline) or PowerShell is downloaded from the official release. The kit looks for archives in its parent folder, keeps the interface language, is reused by later backups and gets its scripts refreshed after an update. New switch `-RestoreKit Copy|Download|None`.
- When the archives are saved inside the Migrator folder, that folder itself is made self-contained; the same is offered in *Check required tools*.
- `Migrator.bat` offers to install PowerShell 7 and 7-Zip when PowerShell 7 is missing, instead of only printing a hint.

### Tests

- 104 smoke tests; the new ones build a kit and restore with the kit's own PowerShell.

## 2.1.0 — 2026-11-11

### Changed: archiver

- **RAR/WinRAR replaced by 7-Zip** (free software, GNU LGPL). New archives are `.7z`. Measured on 2 GB / 40,000 files (NVMe, no compression): create 4.8 s vs 9.4 s, test 0.7 s vs 30 s, extract 26 s vs 50–65 s.
- `.rar` archives made by 2.0.x can still be restored (7-Zip extracts them).
- All archiver calls live in one module, `Migrator.Archive.psm1`.
- Exclusions no longer depend on the archiver's mask dialect: one fast pass over the profile resolves the masks into an exact list of folders, measures the size after exclusions and finds junctions and cloud-only files. Masks are matched against profile-relative paths, so the location of the profile on disk cannot affect them.
- 7-Zip reports a locked target file during extraction with the same exit code as a damaged archive; Migrator tells them apart by the error text ("completed with warnings" vs "failed").

### Changed: interface

- **English and Russian interface.** Strings live in `src\locale\*.psd1`; the language follows Windows and can be switched in the menu (`-Language`, `Language` setting).
- **Arrow-key menus** with a hint under each item (number/hot keys still work; plain numbered input without a real console).
- **One color theme** and aligned fields in `Migrator.UI.psm1` instead of colors set by hand in every script.
- **Plan before the start**: what, where, size after exclusions, free space; then one choice to start.
- **Progress with speed and remaining time.**
- Result screen: what was done, what was skipped and why, what to do next.

### Changed: packaging

- **No third-party binaries in the repository.** `Get Tools.bat` finds PowerShell 7 and 7-Zip or installs them with winget; `-Portable` makes the folder self-contained. The bundled WinRAR (with its license key) and Dism++ are gone.
- MIT license, `THIRD-PARTY.md`, GitHub Actions workflow (PSScriptAnalyzer + smoke tests), `build\New-Release.ps1`.

### Removed

- Dism++ launcher, desktop/Start-menu shortcut scripts and their icons.
- `UseEmoji`, `RarPath`, `HashType`, `EstimateSourceSize` settings. `Compression` is now a 7-Zip level `0`–`9`.
- The hard "less than 2 GB free" stop; the free-space check compares with the real estimate.

### Performance (interface)

- The profile list (CIM query) and the installed-browser list are cached; running browsers are found with one process snapshot instead of ~15 queries.

### Tests

- 93 smoke tests: both locales (same keys, same placeholders, every key used in code is defined), masks, junctions, a locked source file, a locked target file, damaged and truncated archives, cloud-folder policy, Russian output, robocopy log parsing.

## 2.0.3 — 2026-11-10

### Performance

- **Size estimate is ~30–50× faster and follows the exclusions.** It no longer opens every file a second time to read its size, and it skips excluded folders the same way RAR does, so it does not count caches and the free-space warning is no longer triggered by data that will never be archived. On a 50,000-file test tree: 3.45 s → 0.07 s; on a 60,000-file tree with exclusions the estimate matched the RAR archive to the byte.
- **Windows.old restore no longer rescans the target every 2 seconds.** Progress is read from the robocopy log (`/BYTES`), and the source is scanned once (with exclusions) instead of three times. The log is now `/UNILOG`, so non-ASCII file names stay readable.
- **Fewer full reads of the archive.**
  - Restore no longer runs a separate `RAR t` by default: extraction already checks every file and reports a damaged archive as FAILED (exit code 3). The tool asks interactively; `-Verify` forces the test, `VerifyBeforeRestore` sets the default.
  - When a test and SHA256 are both needed (backup with `-ComputeHash`, restore with `-Verify` and a hashed manifest), they run at the same time, so the archive is read about once instead of twice.
  - New archives store BLAKE2 per-file checksums (`-htb`, `HashType`) instead of CRC32. Cost: about 0.15 s per GB.
- **Cloud folders.** `OneDrive`, `OneDrive - *`, `iCloudDrive` and `Dropbox` folders are detected with their cloud-only file count. They are excluded when they contain cloud-only files (interactive: asked per folder), because archiving such files forces a download. New switch `-CloudFolders Auto|Exclude|Include` and setting `CloudFolderPolicy`.
- **Exclusions as folder masks in one list file.** Masks now end with `\`, so RAR skips excluded folders entirely (no empty cache folders in the archive), and are passed via `-scfl -x@<list>` (UTF-8, safe for non-ASCII paths).
- Developer package caches (`node_modules`, `.nuget\packages`, `.gradle\caches`, `.m2\repository`, `.cargo\registry`, `go\pkg\mod`, Docker Desktop) are excluded in Standard mode, and in Full mode with `ExcludeDevCaches`.

### Fixed

- Cache exclusion is limited to `AppData` (plus `%USERPROFILE%\.cache`): user folders such as `Documents\CachedProjects` are archived again.
- Masks that refer to profile folders (`AppData\...`) are anchored to the source profile. RAR matches masks against the full disk path, so a profile stored under another `AppData` or `Temp` folder could be excluded completely.
- `VerifyBeforeRestore` from the config was ignored; it is now used.

### Tests

- 87 smoke tests: mask anchoring and matching, list-file encoding, BLAKE2, size estimate vs. exclusions, cloud-folder exclusion, restore with and without `-Verify`, a damaged archive failing during extraction, robocopy log parsing.
## 2.0.2 — 2026-11-09

### Bundled tools

- PowerShell **7.5.1 → 7.6.9 (LTS)**. PowerShell 7.5 reaches end of support on 2026-11-10, so this moves the bundled runtime to the supported LTS branch (.NET 10).
- WinRAR / RAR **7.11 → 7.23** stable (not the 7.30 beta).
- Dism++ already matches the latest published 10.1.1002.2 package: the executables and cleaning-rule data are byte-identical, so it was left unchanged.
- PowerShell ZIP was verified against the official `hashes.sha256`; `pwsh.exe` and `Rar.exe` have valid Authenticode signatures from Microsoft and win.rar GmbH. The existing WinRAR license key was preserved.

### Tests

- Full smoke suite re-run on the new runtime: parser, modules, RAR partial results, backup and restore integration.

## 2.0.1 — 2026-11-09

### Fixed

- RAR error logging now uses `-ilog<path>` (no colon). The previous `-ilog:<path>` made RAR fail to write the error log and add a spurious file-open error, which is also why the first run reported `Warnings: 0`.
- Exit codes `1`, `6` and `12` are reported as **COMPLETED WITH WARNINGS** when the archive exists and verification passes. Skipped files are counted, listed in the summary and written to `.errors.log` instead of showing a false red **FAILED**.
- Restore extraction exit codes `6` and `12` are treated as **COMPLETED WITH WARNINGS** when extraction produced a usable result; locked files are listed for the user.
- Error-log parsing understands both `Cannot open` (backup) and `Cannot create` (restore) lines.
- Summary writing accepts empty lines, so a summary with a skipped-files section no longer fails to save.

### Performance

- The exclusion list was consolidated from 147 narrow masks to 32 broad masks (`*Cache*`, `*Temp*`, WER, Crashpad, etc.). RAR checks every `-x` mask against every file, so the old list made backup roughly 2–4× slower. New benchmark on 1.22 GB: v1-style RAR 2.1 s, v2 with the consolidated list 1.4 s and a 0.98 GB archive.
- Interactive backup now asks whether to verify the archive, so large profiles can skip the extra full read when speed matters. Non-interactive: `-NoVerify` or `"VerifyAfterBackup": false`.

### Tests

- Regression coverage for a locked file (RAR exit 6), archive validity after exit 6, `-ilog<path>` behavior, error-log parsing of `Cannot open`/`Cannot create`, and the compact exclusion list (59 tests total).

## 2.0.0 — 2026-11-08

### Backup

- New modular code base (`src\lib\Migrator.Core.psm1`, `Migrator.Browsers.psm1`).
- Two modes: **Full** (default) and **Standard** (optional).
- Explicit RAR exclusion lists for temp, caches, dumps, registry hives and legacy junctions.
- `-ol-` prevents RAR from following junctions/reparse points.
- `-idn` progress output parsed from RAR stdout; no expensive rescan of the destination.
- Timestamped archives: `COMPUTER-USER-YYYY-MM-DD_HH-mm-ss.rar`.
- Sidecar manifest (JSON), human-readable summary, error log and operation log.
- Optional SHA256 (off by default for speed).
- Archive verification after backup.
- Source size estimation, destination free-space checks and browser-running warning.
- Native quoting helper (`ConvertTo-NativeCommandLine`) fixes arguments with spaces.
- All Chromium/Gecko browser families detected; browser caches/locks excluded for every profile.

### Restore

- Restore from a Migrator RAR archive or from `Windows.old`.
- Target selection: current user, an existing local profile, or a newly created local user.
- Archive name mismatch is handled: profile-relative archive layout restores into any account.
- New-user flow creates a local account, then waits for the Windows profile to initialise after the first sign-in.
- Verify archive (`RAR t`) and manifest SHA256 before extraction.
- Restore excludes registry hives, `.ost` caches and legacy junction copies.
- Optional browser shutdown before restore.
- Windows.old restore uses `robocopy` with junction skipping and explicit junk exclusions.
- Restore logs and summaries in `Logs`.
- Safety checks: refuses drive roots, Windows folder, users root, reserved profiles and paths outside user profiles.

### UI and launchers

- New main menu with English prompts and ASCII/emoji markers.
- "Restart as Administrator" option.
- Fixed architecture-aware `Dism++.bat` (the `:NOTFOUND` path is now reachable).
- `System Restore Tools.bat` menu: Dism++, System Restore, restore point, recovery settings.
- `Create-Shortcuts.ps1` / `Create Shortcuts.bat` for desktop and Start-menu shortcuts.
- Bundled PowerShell 7.5.1, RAR 7.11 and Dism++ retained.

### Documentation and tests

- `README.md` (English) and `README.ru.md` (Russian).
- `tests\Smoke.Tests.ps1`: parser, modules, exclusions, quoting, RAR partial-result regression (locked file, exit 6, `-ilog<path>`, error-log parsing), backup and restore integration.
- `.gitignore` for archives, logs and test data.

### Known limitations

- Windows registry hives are not migrated by design.
- Browser passwords/cookies and other DPAPI-protected secrets do not transfer across accounts or PCs.
- Installed applications, drivers, printers, VPN, Wi-Fi, Windows Hello/PIN and EFS keys are not migrated.
