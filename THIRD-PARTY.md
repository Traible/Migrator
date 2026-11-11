# Third-party software

Migrator itself is licensed under the MIT License (see `LICENSE`).
The repository contains **no third-party binaries**. The programs below are
used at run time and are installed separately (`Get Tools.bat`).

| Program | Used for | License | Source |
|---|---|---|---|
| 7-Zip (`7z.exe`, `7z.dll`) | creating, testing and extracting archives | GNU LGPL 2.1+ (parts under BSD 3-clause; the RAR *extraction* code has the unRAR restriction) | https://www.7-zip.org |
| PowerShell 7 | running the scripts | MIT | https://github.com/PowerShell/PowerShell |
| robocopy | Windows.old restore | part of Windows | built in |

The portable release archive (`build\New-Release.ps1 -Portable`) redistributes
unmodified 7-Zip and PowerShell binaries together with their license files
(`Tools\7-Zip\License.txt`, `Tools\pwsh\LICENSE.txt`).

Migrator 2.0.x used RAR/WinRAR, which is proprietary shareware and cannot be
redistributed; it was replaced by 7-Zip in 2.1.0. Archives made by 2.0.x
(`.rar`) can still be restored: 7-Zip extracts them.
