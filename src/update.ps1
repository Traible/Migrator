#Requires -Version 7.0
[CmdletBinding()]
param(
    # Recommended - everyday programs from the UpdateRecommended list;
    # All         - everything winget offers.
    # Without it an interactive run shows a menu.
    [ValidateSet('Recommended','All')]
    [string]$Scope,
    # Only show what could be updated.
    [switch]$ListOnly,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in 'Core', 'UI', 'Archive', 'Browsers', 'Kit', 'Programs', 'Self') {
    Import-Module (Join-Path $toolRoot "src\lib\Migrator.$module.psm1") -Force
}

$interactive = -not $NonInteractive
if ($NonInteractive -and -not $Scope -and -not $ListOnly) { throw (T 'u.error.need_scope') }

if ($interactive) {
    Clear-Screen
    Write-Banner (T 'u.subtitle')
}

$ok = Invoke-ProgramUpdate -Scope ([string]$Scope) -ListOnly:$ListOnly -Interactive:$interactive

if ($interactive) { Wait-Enter }
if (-not $ok) { exit 1 }
