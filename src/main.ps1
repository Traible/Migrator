#Requires -Version 7.0
[CmdletBinding()]
param(
    # en | ru | auto - overrides the saved language for this run
    [string]$Language
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
try { [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { }
if ($Language) { $env:MIGRATOR_LANG = $Language }

$toolRoot = Split-Path -Parent $PSScriptRoot

function Import-MigratorModules {
    foreach ($module in 'Core', 'UI', 'Archive', 'Browsers') {
        Import-Module (Join-Path $toolRoot "src\lib\Migrator.$module.psm1") -Force -Global
    }
}
Import-MigratorModules

$isAdmin = Test-IsAdmin

function Show-About {
    Clear-Screen
    Write-Banner (T 'm.about.subtitle')
    foreach ($index in 1..12) { Write-Text (T "m.about.$index") }
    Wait-Enter
}

function Show-ToolStatus {
    Clear-Screen
    Write-Banner (T 'm.tools.subtitle')
    $archiver = Get-ArchiverPath
    $fields = [ordered]@{}
    $fields['PowerShell'] = '{0}  ({1})' -f $PSVersionTable.PSVersion, (Get-Process -Id $PID).Path
    $fields['7-Zip'] = if ($archiver) { '{0}  ({1})' -f (Get-ArchiverVersion -ArchiverPath $archiver), $archiver } else { @((T 'm.tools.missing'), 'Error') }
    Write-Fields -Fields $fields
    Write-Host ''
    if (-not $archiver) {
        Write-Warn (T 'm.tools.how_to_get')
        Write-Hint (T 'm.tools.get_tools')
    } else {
        Write-Ok (T 'm.tools.ready')
    }
    Wait-Enter
}

function Select-Language {
    $names = @{ en = 'English'; ru = 'Русский' }
    $items = @(foreach ($code in Get-AvailableLanguages) {
        $label = if ($names.ContainsKey($code)) { $names[$code] } else { $code }
        New-MenuItem -Value $code -Label $label
    })
    $items += New-MenuItem -Value 'auto' -Label (T 'm.lang.auto') -Key 'A'

    $choice = Show-Menu -Title (T 'm.lang.title') -Items $items -AllowCancel
    if (-not $choice) { return }
    $env:MIGRATOR_LANG = $null
    Set-MigratorUserSetting -Name 'Language' -Value $choice
}

while ($true) {
    $config = Get-MigratorConfig
    $backupRoot = Resolve-MigratorPath $config.BackupRoot
    try { $Host.UI.RawUI.WindowTitle = '{0} v{1}' -f (T 'app.title'), $config.ToolVersion } catch { }

    Clear-Screen
    Write-Banner (T 'app.tagline')

    $archiver = Get-ArchiverPath
    $browsers = @(Get-InstalledBrowsers | Select-Object -ExpandProperty Name -Unique)
    $status = [ordered]@{}
    $status[(T 'f.user')]     = $env:USERNAME
    $status[(T 'f.admin')]    = if ($isAdmin) { @((T 'ui.yes'), 'Ok') } else { @((T 'm.admin.no'), 'Warn') }
    $status[(T 'f.browsers')] = if ($browsers.Count -gt 0) { $browsers -join ', ' } else { T 'm.browsers.none' }
    $status[(T 'f.backups')]  = $backupRoot
    if (-not $archiver) { $status['7-Zip'] = @((T 'm.tools.missing'), 'Error') }
    Write-Fields -Fields $status

    $items = [System.Collections.Generic.List[object]]::new()
    $items.Add((New-MenuItem -Value 'backup' -Label (T 'm.menu.backup') -Hint (T 'm.menu.backup.hint')))
    $items.Add((New-MenuItem -Value 'restore' -Label (T 'm.menu.restore') -Hint (T 'm.menu.restore.hint')))
    $items.Add((New-MenuItem -Value 'folder' -Label (T 'm.menu.folder')))
    $items.Add((New-MenuItem -Value 'system' -Label (T 'm.menu.system')))
    $items.Add((New-MenuItem -Value 'shortcuts' -Label (T 'm.menu.shortcuts')))
    $items.Add((New-MenuItem -Value 'tools' -Label (T 'm.menu.tools')))
    $items.Add((New-MenuItem -Value 'language' -Label 'Language / Язык' -Key 'L'))
    $items.Add((New-MenuItem -Value 'about' -Label (T 'm.menu.about') -Key 'H'))
    if (-not $isAdmin) { $items.Add((New-MenuItem -Value 'admin' -Label (T 'm.menu.admin') -Key 'A')) }
    $items.Add((New-MenuItem -Value 'quit' -Label (T 'm.menu.quit') -Key 'Q'))

    $choice = Show-Menu -Title (T 'm.menu.title') -Items @($items) -AllowCancel
    if (-not $choice) { $choice = 'quit' }

    try {
        switch ($choice) {
            'backup'  { & (Join-Path $PSScriptRoot 'backup.ps1'); Import-MigratorModules }
            'restore' { & (Join-Path $PSScriptRoot 'restore.ps1'); Import-MigratorModules }
            'folder' {
                if (-not (Test-Path -LiteralPath $backupRoot)) { New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null }
                Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$backupRoot`""
            }
            'system' {
                $launcher = Join-Path $toolRoot 'System Restore Tools.bat'
                if (Test-Path -LiteralPath $launcher) {
                    Start-Process -FilePath $launcher -WorkingDirectory $toolRoot
                } else {
                    Write-Err (T 'm.error.not_found' 'System Restore Tools.bat')
                    Wait-Enter
                }
            }
            'shortcuts' {
                $shortcuts = Join-Path $toolRoot 'Create-Shortcuts.ps1'
                if (Test-Path -LiteralPath $shortcuts) { & $shortcuts } else { Write-Err (T 'm.error.not_found' 'Create-Shortcuts.ps1') }
                Wait-Enter
            }
            'tools'    { Show-ToolStatus }
            'language' { Select-Language }
            'about'    { Show-About }
            'admin' {
                Write-Hint (T 'm.admin.restarting')
                $self = (Get-Process -Id $PID).Path
                $launchArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'main.ps1'))
                Start-Process -FilePath $self -ArgumentList (ConvertTo-NativeCommandLine -Arguments $launchArgs) -Verb RunAs
                return
            }
            'quit' {
                Write-Host ''
                Write-Ok (T 'm.goodbye')
                return
            }
        }
    } catch {
        Write-Host ''
        Write-Err $_.Exception.Message
        Wait-Enter
    }
}
