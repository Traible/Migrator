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
    [string]$PowerShellVersion = '7.6.9'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$toolsRoot = Join-Path $root 'Tools'
$sevenZipDir = Join-Path $toolsRoot '7-Zip'
$pwshDir = Join-Path $toolsRoot 'pwsh'

function Write-Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Good([string]$Text) { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  $Text" -ForegroundColor DarkGray }
function Write-Bad([string]$Text)  { Write-Host "  [!]  $Text" -ForegroundColor Yellow }

function Confirm-Action([string]$Question) {
    if ($Yes) { return $true }
    $answer = Read-Host "  $Question [Y/n]"
    return ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[YyДд]')
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

function Install-WithWinget([string]$Id, [string]$Name) {
    if (-not (Test-Winget)) {
        Write-Bad "winget is not available on this PC."
        return $false
    }
    if (-not (Confirm-Action "Install $Name with winget?")) { return $false }
    & winget.exe install --id $Id --exact --source winget --accept-package-agreements --accept-source-agreements
    return ($LASTEXITCODE -eq 0)
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

function Install-PortablePwsh {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $zipName = "PowerShell-$PowerShellVersion-win-$arch.zip"
    $base = "https://github.com/PowerShell/PowerShell/releases/download/v$PowerShellVersion"
    $temp = Join-Path $env:TEMP ("migrator-pwsh-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        $zipPath = Join-Path $temp $zipName
        $hashPath = Join-Path $temp 'hashes.sha256'

        Write-Note "Downloading $zipName (about 110 MB)..."
        Invoke-WebRequest -Uri "$base/$zipName" -OutFile $zipPath -UseBasicParsing
        Invoke-WebRequest -Uri "$base/hashes.sha256" -OutFile $hashPath -UseBasicParsing

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

if (-not $sevenZip -and -not $CheckOnly) {
    if (Install-WithWinget -Id '7zip.7zip' -Name '7-Zip') { $sevenZip = Find-SevenZip }
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
    if (Confirm-Action "Download portable PowerShell $PowerShellVersion into Tools\pwsh?") {
        try {
            if (Install-PortablePwsh) { $pwsh = Find-Pwsh }
        } catch {
            Write-Bad "Portable PowerShell was not installed: $($_.Exception.Message)"
        }
    }
} elseif (-not $pwsh -and -not $CheckOnly) {
    if (Install-WithWinget -Id 'Microsoft.PowerShell' -Name 'PowerShell 7') { $pwsh = Find-Pwsh }
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
