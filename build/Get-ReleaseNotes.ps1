#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the text of a GitHub release: how to start, what is new in this
    version (its section of CHANGELOG.md) and how to verify the archive.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$repository = 'Traible/Migrator'

# The section "## <version> ..." up to the next "## ".
$section = [System.Collections.Generic.List[string]]::new()
$inside = $false
foreach ($line in Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Encoding utf8) {
    if ($line -match '^##\s+(\S+)') {
        if ($inside) { break }
        $inside = ($Matches[1] -eq $Version)
        continue
    }
    if ($inside) { $section.Add($line) }
}
if (-not $inside -and $section.Count -eq 0) { throw "CHANGELOG.md has no section for version $Version." }
$changes = ($section -join "`n").Trim()

$notes = @"
Back up a Windows user profile into one ``.7z`` archive and restore it on the same or another PC.

## Quick start

1. Download ``Migrator-$Version.zip`` below and unpack the whole archive, for example to an external drive.
2. Run ``Migrator.bat``. If PowerShell 7 or 7-Zip is missing, it explains what is needed and offers to get it; nothing is downloaded or installed until you type ``y``.
3. Choose *Back up a user profile*.
4. On the new PC run ``Migrator.bat`` and choose *Restore a user profile*.

The interface is available in English and Russian. See the [README](https://github.com/$repository/blob/main/README.md) ([на русском](https://github.com/$repository/blob/main/README.ru.md)) for details.

## New in $Version

$changes

Full history: [CHANGELOG.md](https://github.com/$repository/blob/main/CHANGELOG.md)

## Files

- ``Migrator-$Version.zip`` - scripts and documentation (PowerShell 7 and 7-Zip are obtained separately, with your confirmation)
- ``Migrator-$Version.zip.sha256`` - SHA256 checksum of the archive

The archive is built by GitHub Actions from the tagged commit, and GitHub keeps a signed record of that. With the [GitHub CLI](https://cli.github.com) you can check that the file you downloaded is that build:

``````
gh attestation verify Migrator-$Version.zip --repo $repository
``````
"@

Set-Content -LiteralPath $OutFile -Value $notes -Encoding utf8
Write-Host "Release notes: $OutFile"
