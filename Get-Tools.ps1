<#
.SYNOPSIS
    Checks and installs the two programs Migrator needs: PowerShell 7 and 7-Zip.

.DESCRIPTION
    The repository contains only scripts. This script runs under the built-in
    Windows PowerShell 5.1 (so it works before PowerShell 7 is there) and:

      * 7-Zip        - uses an installed copy, or installs it with winget
                       (winget checks the installer hash from its manifest);
      * PowerShell 7 - uses an installed copy, or installs it with winget.

    -Portable makes the Migrator folder self-contained (for a USB drive):
      * copies 7z.exe, 7z.dll and License.txt of the installed 7-Zip to Tools\7-Zip;
      * downloads the PowerShell 7 ZIP from the official GitHub release to
        Tools\pwsh, checks it against the release's hashes.sha256 and then
        checks that pwsh.exe carries a valid Microsoft signature.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Get-Tools.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Get-Tools.ps1 -Portable
#>
[CmdletBinding()]
param(
    [switch]$Portable,
    [switch]$CheckOnly,
    [switch]$Yes,
    # Only put a portable 7-Zip into Tools\7-Zip (used by Migrator itself).
    [switch]$SevenZipOnly,
    [string]$PowerShellVersion = '7.6.10'
)

$ErrorActionPreference = 'Stop'

# 7-Zip for the download without winget. The SHA256 values are the ones
# published for this release (winget manifest and the GitHub release of the
# author); update the version and both hashes together.
$SevenZipVersion = '26.06'
$SevenZipPackages = @{
    x64 = @{ File = '7z2606-x64.msi'; Sha256 = '6DC822569E777D9A3ECD5FFCBC22B55600AF87E6C5D9810A64E8566CF5A4AF9F' }
    x86 = @{ File = '7z2606.msi';     Sha256 = '1B3694F6F1449FB5EE98CBDAE5B3DCCE4A86E7F4929E8543DC28B89B55B89187' }
}
$root = $PSScriptRoot
$toolsRoot = Join-Path $root 'Tools'
$sevenZipDir = Join-Path $toolsRoot '7-Zip'
$pwshDir = Join-Path $toolsRoot 'pwsh'

function Write-Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Good([string]$Text) { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  $Text" -ForegroundColor DarkGray }
function Write-Bad([string]$Text)  { Write-Host "  [!]  $Text" -ForegroundColor Yellow }

function Confirm-Action([string]$Question) {
    # Nothing is downloaded or installed on an empty answer: the user has to
    # type "y". -Yes is for callers that have already asked (the restore kit).
    if ($Yes) { return $true }
    $answer = Read-Host "  $Question [y/N]"
    # Also accepted: н, the letter the Y key gives in the Russian keyboard
    # layout, and да ("da"). Written as escapes because Windows
    # PowerShell 5.1 reads a script without a BOM in the ANSI code page.
    return ([string]$answer).Trim() -match '^(y|yes|н|да)$'
}

function Find-SevenZip {
    $candidates = @(
        (Join-Path $sevenZipDir '7z.exe')
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
    )
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command '7z.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Find-Pwsh {
    $candidates = @(
        (Join-Path $pwshDir 'pwsh.exe')
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Test-Winget { return [bool](Get-Command 'winget.exe' -ErrorAction SilentlyContinue) }

function Install-WithWinget([string]$Id, [string]$Name, [string]$About) {
    if (-not (Test-Winget)) {
        Write-Bad "winget is not available on this PC."
        return $false
    }
    Write-Bad "$Name is not installed."
    Write-Note $About
    Write-Note "winget (the Windows package manager) would download it and install it on this PC"
    Write-Note "for all users; Windows asks for administrator rights. Installing it means"
    Write-Note "accepting its license. It stays installed until you remove it in Windows Settings."
    if (-not (Confirm-Action "Install $Name now?")) {
        Write-Note "$Name was not installed."
        return $false
    }
    Write-Note "Downloading and installing $Name. This can take a few minutes; winget shows its progress below."
    # winget is started as a separate process attached to this console, so its
    # own progress bar is visible. Called with "&" inside this function, its
    # output would be collected as the function's return value and never shown.
    $process = Start-Process -FilePath 'winget.exe' -NoNewWindow -PassThru -ArgumentList @(
        'install', '--id', $Id, '--exact', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    $null = $process.Handle   # keeps the exit code readable in Windows PowerShell 5.1
    $process.WaitForExit()
    Write-Host ''
    if ($process.ExitCode -ne 0) {
        Write-Bad "winget finished with code $($process.ExitCode); $Name may not be installed."
        return $false
    }
    return $true
}

function Copy-PortableSevenZip([string]$InstalledExe) {
    $sourceDir = Split-Path -Parent $InstalledExe
    New-Item -ItemType Directory -Force -Path $sevenZipDir | Out-Null
    foreach ($name in @('7z.exe', '7z.dll', 'License.txt')) {
        $source = Join-Path $sourceDir $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $sevenZipDir -Force }
    }
    return (Test-Path -LiteralPath (Join-Path $sevenZipDir '7z.exe'))
}

function Get-MachineArchitecture {
    # The architecture of Windows itself: a 32-bit process on 64-bit Windows
    # reports x86 in PROCESSOR_ARCHITECTURE and the real one in ...W6432.
    $machine = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($machine) {
        'ARM64' { return 'arm64' }
        'x86'   { return 'x86' }
        default { return 'x64' }
    }
}

function Get-WebFile([string]$Url, [string]$OutFile) {
    # Downloads with curl.exe (part of Windows 10 1803 and later): it is fast
    # and draws a progress bar. Invoke-WebRequest is the fallback; its own
    # progress display makes Windows PowerShell 5.1 many times slower, so it
    # is switched off there.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (Get-Command 'curl.exe' -ErrorAction SilentlyContinue) {
        $process = Start-Process -FilePath 'curl.exe' -NoNewWindow -PassThru -ArgumentList @(
            '--location', '--fail', '--progress-bar', '--output', "`"$OutFile`"", $Url
        )
        $null = $process.Handle
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Download failed (curl code $($process.ExitCode)): $Url" }
    } else {
        $previous = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing } finally { $ProgressPreference = $previous }
    }
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) { throw "Download failed: $Url" }
}

function Invoke-ComMember($Object, [string]$Name, [string]$Kind, [object[]]$Arguments) {
    # The Windows Installer automation objects expose no type information to
    # PowerShell, so their members are called by name.
    return $Object.GetType().InvokeMember($Name, [Reflection.BindingFlags]$Kind, $null, $Object, $Arguments)
}

function Expand-MsiFile([string]$MsiPath, [string]$Destination, [string[]]$Names) {
    # Takes the named files out of an MSI package without installing it and
    # without msiexec: the package database is read through the built-in
    # "WindowsInstaller.Installer" object, the cabinet stored inside it is
    # saved and unpacked with expand.exe (part of Windows).
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = Invoke-ComMember $installer 'OpenDatabase' 'InvokeMethod' @($MsiPath, 0)
    $query = {
        param($sql)
        $opened = Invoke-ComMember $database 'OpenView' 'InvokeMethod' @($sql)
        [void](Invoke-ComMember $opened 'Execute' 'InvokeMethod' $null)
        return $opened
    }

    # File table: key inside the cabinet -> real file name ("short|long").
    $keys = @{}
    $view = & $query 'SELECT `File`, `FileName` FROM `File`'
    while ($record = Invoke-ComMember $view 'Fetch' 'InvokeMethod' $null) {
        $key = [string](Invoke-ComMember $record 'StringData' 'GetProperty' @(1))
        $name = ([string](Invoke-ComMember $record 'StringData' 'GetProperty' @(2)) -split '\|')[-1]
        if ($Names -contains $name) { $keys[$key] = $name }
    }

    # The cabinet stored inside the package ("#name" in the Media table).
    $cabinet = $null
    $view = & $query 'SELECT `Cabinet` FROM `Media`'
    while ($record = Invoke-ComMember $view 'Fetch' 'InvokeMethod' $null) {
        $value = [string](Invoke-ComMember $record 'StringData' 'GetProperty' @(1))
        if ($value.StartsWith('#')) { $cabinet = $value.Substring(1) }
    }
    if (-not $cabinet) { throw 'the package has no embedded cabinet' }

    $view = & $query ("SELECT ``Data`` FROM ``_Streams`` WHERE ``Name`` = '$cabinet'")
    $record = Invoke-ComMember $view 'Fetch' 'InvokeMethod' $null
    if (-not $record) { throw "cabinet stream '$cabinet' was not found" }
    $size = [int](Invoke-ComMember $record 'DataSize' 'GetProperty' @(1))
    # Format 1: every byte comes back as one character (0..255).
    $text = [string](Invoke-ComMember $record 'ReadStream' 'InvokeMethod' @(1, $size, 1))
    $bytes = [Text.Encoding]::GetEncoding(28591).GetBytes($text)

    # Let go of the package: while these objects are alive the .msi stays
    # open and the temporary folder cannot be deleted afterwards.
    foreach ($object in @($record, $view, $database, $installer)) {
        if ($object) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($object) } catch { } }
    }
    $record = $null; $view = $null; $database = $null; $installer = $null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()

    if ($bytes.Length -ne $size) { throw "the cabinet was read incompletely ($($bytes.Length) of $size bytes)" }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $cabPath = Join-Path $Destination 'package.cab'
    [IO.File]::WriteAllBytes($cabPath, $bytes)
    $raw = Join-Path $Destination 'raw'
    New-Item -ItemType Directory -Force -Path $raw | Out-Null
    $null = & expand.exe $cabPath '-F:*' $raw
    if ($LASTEXITCODE -ne 0) { throw "expand.exe could not unpack the cabinet (code $LASTEXITCODE)" }

    foreach ($key in $keys.Keys) {
        $source = Join-Path $raw $key
        if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination (Join-Path $Destination $keys[$key]) -Force }
    }
    Remove-Item -LiteralPath $raw -Recurse -Force
    Remove-Item -LiteralPath $cabPath -Force
    return @($Names | Where-Object { Test-Path -LiteralPath (Join-Path $Destination $_) })
}

function Install-PortableSevenZip {
    # Puts 7z.exe, 7z.dll and License.txt into Tools\7-Zip without installing
    # anything in Windows: the official MSI package is downloaded from the
    # author's GitHub release, checked against the SHA256 pinned above, and
    # the three files are taken out of it (no registry entries, no shortcuts,
    # no entry in "Installed apps").
    $arch = Get-MachineArchitecture
    if ($arch -eq 'arm64') { $arch = 'x64' }   # no MSI for ARM64; Windows 11 on ARM runs the x64 build
    $package = $SevenZipPackages[$arch]
    $msiName = $package.File
    $url = "https://github.com/ip7z/7zip/releases/download/$SevenZipVersion/$msiName"
    $temp = Join-Path $env:TEMP ("migrator-7zip-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null

    try {
        $msiPath = Join-Path $temp $msiName
        Write-Note "Downloading $msiName (about 2 MB) from $url"
        Get-WebFile -Url $url -OutFile $msiPath

        $actual = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
        if ($actual -ne $package.Sha256) { throw "SHA256 mismatch for $msiName (got $actual)" }
        Write-Good "SHA256 matches the value published for 7-Zip $SevenZipVersion."

        $wanted = @('7z.exe', '7z.dll', 'License.txt')
        $unpacked = Join-Path $temp 'files'
        try {
            # The files are read straight out of the package. msiexec is not
            # used: in Windows Sandbox it takes many minutes even for 2 MB.
            [void](Expand-MsiFile -MsiPath $msiPath -Destination $unpacked -Names $wanted)
        } catch {
            Write-Note "Reading the package directly failed ($($_.Exception.Message))."
            Write-Note 'Unpacking it with Windows Installer instead; this can take several minutes.'
            $image = Join-Path $temp 'image'
            $process = Start-Process -FilePath 'msiexec.exe' -PassThru -ArgumentList @('/a', "`"$msiPath`"", '/qn', "TARGETDIR=`"$image`"")
            $null = $process.Handle
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) { throw "msiexec could not unpack the package (code $($process.ExitCode))." }
            $exe = Get-ChildItem -LiteralPath $image -Recurse -Filter '7z.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $exe) { throw '7z.exe was not found in the unpacked package.' }
            $unpacked = $exe.DirectoryName
        }

        if (-not (Test-Path -LiteralPath (Join-Path $unpacked '7z.exe'))) { throw '7z.exe was not found in the package.' }
        New-Item -ItemType Directory -Force -Path $sevenZipDir | Out-Null
        foreach ($name in $wanted) {
            $source = Join-Path $unpacked $name
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $sevenZipDir -Force }
        }
        Write-Good "Portable 7-Zip is in $sevenZipDir"
        return (Test-Path -LiteralPath (Join-Path $sevenZipDir '7z.exe'))
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-PortablePwsh {
    $arch = Get-MachineArchitecture
    $zipName = "PowerShell-$PowerShellVersion-win-$arch.zip"
    $base = "https://github.com/PowerShell/PowerShell/releases/download/v$PowerShellVersion"
    $temp = Join-Path $env:TEMP ("migrator-pwsh-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null

    try {
        $zipPath = Join-Path $temp $zipName
        $hashPath = Join-Path $temp 'hashes.sha256'

        Write-Note "Downloading $zipName (about 110 MB) from $base"
        Get-WebFile -Url "$base/$zipName" -OutFile $zipPath
        Get-WebFile -Url "$base/hashes.sha256" -OutFile $hashPath

        $expected = $null
        foreach ($line in Get-Content -LiteralPath $hashPath) {
            if ($line -match '^([A-Fa-f0-9]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $zipName) { $expected = $Matches[1] }
        }
        if (-not $expected) { throw "hashes.sha256 has no entry for $zipName" }
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "SHA256 mismatch for $zipName" }
        Write-Good 'SHA256 matches the release hash list.'

        $staging = Join-Path $temp 'pwsh'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $staging -Force

        # Authenticity: the executable must be signed by Microsoft.
        $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $staging 'pwsh.exe')
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw "pwsh.exe does not have a valid Microsoft signature (status: $($signature.Status))."
        }
        Write-Good 'pwsh.exe has a valid Microsoft signature.'

        if (Test-Path -LiteralPath $pwshDir) { Remove-Item -LiteralPath $pwshDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
        Move-Item -LiteralPath $staging -Destination $pwshDir
        return $true
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'Migrator - required tools' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor DarkCyan

# ---------------------------------------------------------------------------
# 7-Zip
# ---------------------------------------------------------------------------
Write-Step '7-Zip (creates and restores the archives)'
$sevenZip = Find-SevenZip

function Request-PortableSevenZip {
    # Without winget, or when the user did not want a system-wide install.
    Write-Note "A portable 7-Zip $SevenZipVersion (about 2 MB) can be downloaded from the author's GitHub release"
    Write-Note 'into the Tools folder of Migrator. Nothing is installed in Windows.'
    if (-not (Confirm-Action "Download portable 7-Zip into Tools\7-Zip?")) { return $false }
    try {
        return [bool](Install-PortableSevenZip)
    } catch {
        Write-Bad "Portable 7-Zip was not installed: $($_.Exception.Message)"
        return $false
    }
}

if ($SevenZipOnly) {
    if (Find-SevenZip) { exit 0 }
    if (Request-PortableSevenZip) { Write-Good "Found: $(Find-SevenZip)"; exit 0 }
    exit 1
}

if (-not $sevenZip -and -not $CheckOnly) {
    if (Test-Winget) {
        if (Install-WithWinget -Id '7zip.7zip' -Name '7-Zip' -About 'Free archiver by Igor Pavlov, GNU LGPL license, https://www.7-zip.org') { $sevenZip = Find-SevenZip }
    } else {
        Write-Bad '7-Zip is not installed, and winget (the Windows package manager) is not available on this PC.'
    }
    if (-not $sevenZip -and (Request-PortableSevenZip)) { $sevenZip = Find-SevenZip }
}

if ($sevenZip) {
    Write-Good "Found: $sevenZip"
    if ($Portable -and -not $CheckOnly -and -not $sevenZip.StartsWith($sevenZipDir, [StringComparison]::OrdinalIgnoreCase)) {
        if (Copy-PortableSevenZip -InstalledExe $sevenZip) {
            Write-Good "Portable copy: $sevenZipDir (7-Zip is free software under GNU LGPL; License.txt is copied with it)"
        } else {
            Write-Bad 'Could not copy 7-Zip into the Tools folder.'
        }
    }
} else {
    Write-Bad '7-Zip was not found.'
    Write-Note 'Install it from https://www.7-zip.org (or: winget install 7zip.7zip) and run this script again.'
}

# ---------------------------------------------------------------------------
# PowerShell 7
# ---------------------------------------------------------------------------
Write-Step 'PowerShell 7 (runs Migrator)'
$pwsh = Find-Pwsh

if ($Portable -and -not $CheckOnly -and -not (Test-Path -LiteralPath (Join-Path $pwshDir 'pwsh.exe'))) {
    Write-Note "A portable PowerShell $PowerShellVersion (about 110 MB) can be downloaded from Microsoft's official"
    Write-Note 'GitHub release into the Tools folder of Migrator. Nothing is installed in Windows.'
    if (Confirm-Action "Download portable PowerShell $PowerShellVersion into Tools\pwsh?") {
        try {
            if (Install-PortablePwsh) { $pwsh = Find-Pwsh }
        } catch {
            Write-Bad "Portable PowerShell was not installed: $($_.Exception.Message)"
        }
    }
} elseif (-not $pwsh -and -not $CheckOnly) {
    if (Test-Winget) {
        if (Install-WithWinget -Id 'Microsoft.PowerShell' -Name 'PowerShell 7' -About 'Free shell by Microsoft, MIT license, https://aka.ms/powershell') { $pwsh = Find-Pwsh }
    } else {
        Write-Bad 'PowerShell 7 is not installed, and winget (the Windows package manager) is not available on this PC.'
    }
    if (-not $pwsh) {
        Write-Note "A portable PowerShell $PowerShellVersion (about 110 MB) can be downloaded from Microsoft's official"
        Write-Note 'GitHub release into the Tools folder of Migrator. Nothing is installed in Windows.'
        if (Confirm-Action "Download portable PowerShell $PowerShellVersion into Tools\pwsh?") {
            try {
                if (Install-PortablePwsh) { $pwsh = Find-Pwsh }
            } catch {
                Write-Bad "Portable PowerShell was not installed: $($_.Exception.Message)"
            }
        }
    }
}

if ($pwsh) {
    Write-Good "Found: $pwsh"
} else {
    Write-Bad 'PowerShell 7 was not found.'
    Write-Note 'Install it from https://aka.ms/powershell (or: winget install Microsoft.PowerShell) and run this script again.'
}

Write-Host ''
if ($sevenZip -and $pwsh) {
    Write-Host 'Everything is ready. Start Migrator.bat.' -ForegroundColor Green
    exit 0
}
Write-Host 'Some tools are still missing; see the notes above.' -ForegroundColor Yellow
exit 1
