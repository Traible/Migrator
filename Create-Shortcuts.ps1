#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$DesktopOnly,
    [switch]$StartMenuOnly,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$toolRoot = $PSScriptRoot

$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Migrator'
$iconBackup = Join-Path $toolRoot 'backup_restore.ico'
$backups = Join-Path $toolRoot 'Backups'

function New-MigratorShortcut {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [string]$Icon,
        [string]$Description = '',
        [string]$WorkingDirectory = $toolRoot
    )

    if ($Remove) {
        $path = Join-Path $Folder "$Name.lnk"
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            Write-Host "Removed: $path"
        }
        return
    }

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Folder | Out-Null
    }

    $path = Join-Path $Folder "$Name.lnk"
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = $Target
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = $Description
    if ($Icon -and (Test-Path -LiteralPath $Icon)) {
        $shortcut.IconLocation = "$Icon,0"
    }
    $shortcut.Save()
    Write-Host "Created: $path"
}

$folders = @()
if (-not $StartMenuOnly) { $folders += $desktop }
if (-not $DesktopOnly) { $folders += $startMenu }

if (-not (Test-Path -LiteralPath $backups)) {
    New-Item -ItemType Directory -Force -Path $backups | Out-Null
}

foreach ($folder in $folders) {
    New-MigratorShortcut -Folder $folder -Name 'Migrator' `
        -Target (Join-Path $toolRoot 'Migrator.bat') -Icon $iconBackup `
        -Description 'Backup and restore Windows user profiles'

    New-MigratorShortcut -Folder $folder -Name 'System Restore Tools' `
        -Target (Join-Path $toolRoot 'System Restore Tools.bat') -Icon $iconBackup `
        -Description 'System Restore, restore points and recovery settings'

    New-MigratorShortcut -Folder $folder -Name 'Migrator Backups' `
        -Target $backups -Icon $iconBackup `
        -Description 'Open the Migrator backups folder'
}

Write-Host ''
if ($Remove) {
    foreach ($folder in $folders) {
        $group = Join-Path $folder 'Migrator'
        if (Test-Path -LiteralPath $group -PathType Container) {
            $remaining = @(Get-ChildItem -LiteralPath $group -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $group -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Host 'Shortcuts removed.' -ForegroundColor Green
} else {
    Write-Host 'Shortcuts created. You can pin them to the taskbar or Start menu.' -ForegroundColor Green
}
