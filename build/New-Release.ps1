#Requires -Version 7.0
<#
.SYNOPSIS
    Builds release archives into dist\.

.DESCRIPTION
    Migrator-<version>.zip           scripts only (needs PowerShell 7 and 7-Zip on the PC)
    Migrator-<version>-portable.zip  scripts + Tools\ (run "Get Tools.bat -Portable" first)

    The portable archive may contain only software that can be redistributed:
    7-Zip (GNU LGPL, with its License.txt) and PowerShell (MIT). The script
    refuses to pack anything else found in Tools\.
#>
[CmdletBinding()]
param(
    [switch]$Portable,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\lib\Migrator.Core.psm1') -Force
$version = [string](Get-DefaultConfig).ToolVersion

if (-not $SkipTests) {
    & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File (Join-Path $root 'tests\Smoke.Tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Smoke tests failed; no release was built.' }
}

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist "Migrator-$version"
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$include = @(
    'src', 'tests', 'build'
    'Migrator.bat', 'Get Tools.bat', 'Get-Tools.ps1'
    'System Restore Tools.bat'
    'README.md', 'README.ru.md', 'CHANGELOG.md', 'LICENSE', 'THIRD-PARTY.md'
)
foreach ($name in $include) {
    $source = Join-Path $root $name
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $stage -Recurse -Force }
}
Remove-Item -LiteralPath (Join-Path $stage 'src\config\user.json') -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'Backups'), (Join-Path $stage 'Logs') | Out-Null

function New-Zip([string]$Name) {
    $zip = Join-Path $dist $Name
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Set-Content -LiteralPath "$zip.sha256" -Value "$hash *$Name" -Encoding ascii
    Write-Host ("{0}  {1:N1} MB  SHA256 {2}" -f $Name, ((Get-Item $zip).Length / 1MB), $hash) -ForegroundColor Green
}

New-Zip "Migrator-$version.zip"

if ($Portable) {
    $tools = Join-Path $root 'Tools'
    $allowed = @('7-Zip', 'pwsh')
    $found = @(Get-ChildItem -LiteralPath $tools -Directory -ErrorAction SilentlyContinue)
    $foreign = @($found | Where-Object { $_.Name -notin $allowed })
    if ($foreign.Count -gt 0) {
        throw "Tools\ contains folders that must not be redistributed: $($foreign.Name -join ', '). Remove them first."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tools '7-Zip\7z.exe')) -or
        -not (Test-Path -LiteralPath (Join-Path $tools '7-Zip\License.txt'))) {
        throw 'Tools\7-Zip is incomplete (7z.exe and License.txt are required). Run "Get Tools.bat" -Portable.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tools 'pwsh\pwsh.exe'))) {
        throw 'Tools\pwsh is missing. Run "Get Tools.bat" -Portable.'
    }
    if (Get-ChildItem -LiteralPath $tools -Recurse -File -Include '*.key' -ErrorAction SilentlyContinue) {
        throw 'A license key file was found in Tools\. It must never be published.'
    }

    Copy-Item -LiteralPath $tools -Destination $stage -Recurse -Force
    New-Zip "Migrator-$version-portable.zip"
}

Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host "Release files are in: $dist"
