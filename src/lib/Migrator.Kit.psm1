#Requires -Version 7.0
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Migrator.Kit.psm1
# The "restore kit": a copy of Migrator with portable PowerShell 7 and 7-Zip
# placed next to the archives, so a new PC without internet or any tools can
# restore straight from the external drive.
#
#   E:\MigratorBackups\PC-user-date.7z
#   E:\MigratorBackups\Migrator\Migrator.bat      <- run this on the new PC
#   E:\MigratorBackups\Migrator\Tools\pwsh, Tools\7-Zip
# ---------------------------------------------------------------------------

$script:KitFolderName = 'Migrator'
$script:KitFiles = @(
    'src'
    'Migrator.bat', 'Get Tools.bat', 'Get-Tools.ps1', 'System Restore Tools.bat'
    'README.md', 'README.ru.md', 'CHANGELOG.md', 'LICENSE', 'THIRD-PARTY.md'
)

function Get-RestoreKitPath {
    # When the archives are saved inside the Migrator folder itself, that
    # folder is the kit (only Tools\ has to be filled). Otherwise the kit is
    # a "Migrator" folder next to the archives.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Destination)

    $root = (Get-MigratorRoot).TrimEnd('\')
    if (Test-PathWithin -Child $Destination -Parent $root) { return $root }
    return (Join-Path ([IO.Path]::GetFullPath($Destination).TrimEnd('\')) $script:KitFolderName)
}

function Test-RestoreKit {
    # Ready    - scripts of this version and both tools are in place
    # Outdated - tools are in place, scripts are from another version
    # NoTools  - PowerShell or 7-Zip is missing
    # Missing  - there is no kit
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $hasScripts = Test-Path -LiteralPath (Join-Path $Path 'src\main.ps1') -PathType Leaf
    $hasPwsh = Test-Path -LiteralPath (Join-Path $Path 'Tools\pwsh\pwsh.exe') -PathType Leaf
    $hasArchiver = Test-Path -LiteralPath (Join-Path $Path 'Tools\7-Zip\7z.exe') -PathType Leaf

    $state = 'Missing'
    if ($hasScripts -or $hasPwsh -or $hasArchiver) { $state = 'NoTools' }
    if ($hasPwsh -and $hasArchiver) {
        $state = 'Outdated'
        if ($hasScripts) {
            $inPlace = [IO.Path]::GetFullPath($Path).TrimEnd('\').Equals((Get-MigratorRoot).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
            $info = $null
            try { $info = Get-Content -LiteralPath (Join-Path $Path 'kit.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { }
            if ($inPlace -or ($info -and [string]$info['toolVersion'] -eq [string](Get-MigratorConfig).ToolVersion)) {
                $state = 'Ready'
            }
        }
    }

    return [pscustomobject]@{
        Path        = $Path
        State       = $state
        HasScripts  = $hasScripts
        HasPwsh     = $hasPwsh
        HasArchiver = $hasArchiver
    }
}

function Copy-KitFolder {
    # robocopy is much faster than Copy-Item for the ~1500 files of PowerShell.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target, [string[]]$ExcludeFiles = @())
    $arguments = @($Source, $Target, '/E', '/MT:8', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($ExcludeFiles.Count -gt 0) { $arguments += '/XF'; $arguments += $ExcludeFiles }
    & robocopy.exe @arguments | Out-Null
    return ($LASTEXITCODE -lt 8)
}

function New-RestoreKit {
    # -ToolSource Copy      copies the PowerShell that is running right now and
    #                       the 7-Zip in use: no internet needed, and these are
    #                       the versions the backup has just worked with.
    # -ToolSource Download  copies 7-Zip and downloads the PowerShell release
    #                       pinned in Get-Tools.ps1 (hash and signature checked).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Copy', 'Download')][string]$ToolSource = 'Copy'
    )

    $root = (Get-MigratorRoot).TrimEnd('\')
    $kit = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $inPlace = $kit.Equals($root, [StringComparison]::OrdinalIgnoreCase)
    $problems = [System.Collections.Generic.List[string]]::new()

    New-Item -ItemType Directory -Force -Path $kit | Out-Null

    # --- scripts ------------------------------------------------------------
    if (-not $inPlace) {
        foreach ($name in $script:KitFiles) {
            $source = Join-Path $root $name
            if (-not (Test-Path -LiteralPath $source)) { continue }
            if (Test-Path -LiteralPath $source -PathType Container) {
                if (-not (Copy-KitFolder -Source $source -Target (Join-Path $kit $name) -ExcludeFiles @('user.json'))) {
                    $problems.Add("copy $name")
                }
            } else {
                Copy-Item -LiteralPath $source -Destination $kit -Force
            }
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $kit 'Logs') | Out-Null

        # The kit looks for archives in its parent folder and keeps the
        # interface language chosen here.
        $settings = @{ BackupRoot = '..' }
        $language = [string](Get-MigratorConfig).Language
        if ($language -and $language -ne 'auto') { $settings['Language'] = $language }
        Set-Content -LiteralPath (Join-Path $kit 'src\config\user.json') -Value ($settings | ConvertTo-Json) -Encoding utf8
    }

    # --- 7-Zip --------------------------------------------------------------
    $archiver = Get-ArchiverPath
    $archiverTarget = Join-Path $kit 'Tools\7-Zip'
    if (-not $archiver) {
        $problems.Add('7-Zip not found')
    } elseif (-not (Split-Path -Parent $archiver).TrimEnd('\').Equals($archiverTarget, [StringComparison]::OrdinalIgnoreCase)) {
        New-Item -ItemType Directory -Force -Path $archiverTarget | Out-Null
        $sourceDir = Split-Path -Parent $archiver
        foreach ($name in @('7z.exe', '7z.dll', 'License.txt')) {
            $file = Join-Path $sourceDir $name
            if (Test-Path -LiteralPath $file -PathType Leaf) { Copy-Item -LiteralPath $file -Destination $archiverTarget -Force }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $archiverTarget '7z.exe'))) { $problems.Add('copy 7-Zip') }
    }

    # --- PowerShell 7 -------------------------------------------------------
    $pwshTarget = Join-Path $kit 'Tools\pwsh'
    if (-not (Test-Path -LiteralPath (Join-Path $pwshTarget 'pwsh.exe') -PathType Leaf)) {
        if ($ToolSource -eq 'Download') {
            $getTools = Join-Path $kit 'Get-Tools.ps1'
            & (Get-Process -Id $PID).Path -NoLogo -NoProfile -ExecutionPolicy Bypass -File $getTools -Portable -Yes | Out-Host
        } elseif (-not $PSHOME.TrimEnd('\').Equals($pwshTarget, [StringComparison]::OrdinalIgnoreCase)) {
            [void](Copy-KitFolder -Source $PSHOME -Target $pwshTarget)
        }
        if (-not (Test-Path -LiteralPath (Join-Path $pwshTarget 'pwsh.exe') -PathType Leaf)) { $problems.Add('PowerShell 7') }
    }

    if (-not $inPlace -and $problems.Count -eq 0) {
        $info = @{
            toolVersion = [string](Get-MigratorConfig).ToolVersion
            createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            powerShell  = [string]$PSVersionTable.PSVersion
            archiver    = if ($archiver) { Get-ArchiverVersion -ArchiverPath $archiver } else { $null }
            toolSource  = $ToolSource
        }
        Set-Content -LiteralPath (Join-Path $kit 'kit.json') -Value ($info | ConvertTo-Json) -Encoding utf8
    }

    return [pscustomobject]@{
        Path     = $kit
        Ok       = ($problems.Count -eq 0)
        Problems = @($problems)
        State    = (Test-RestoreKit -Path $kit).State
    }
}

function Request-Archiver {
    # Returns the path of 7-Zip, or $null. When 7-Zip is missing and the run
    # is interactive, explains what would be installed and offers to install
    # it with winget right here, so the user does not have to leave Migrator
    # and start "Get Tools.bat". Nothing is installed without a typed "y".
    [CmdletBinding()]
    param([switch]$Interactive)

    $archiver = Get-ArchiverPath
    if ($archiver -or -not $Interactive -or -not (Test-InteractiveConsole)) { return $archiver }

    Write-Host ''
    Write-Warn (T 'tools.7zip.missing')
    Write-Hint (T 'tools.7zip.about')

    # 1. Install in Windows with winget, when this PC has it.
    if (Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue) {
        Write-Hint (T 'tools.install.how')
        if (Read-YesNo (T 'tools.7zip.ask') $false) {
            Write-Hint (T 'tools.install.progress' '7-Zip')
            # A separate process attached to this console: winget draws its own
            # progress bar, and its output does not become this function's result.
            $process = Start-Process -FilePath 'winget.exe' -NoNewWindow -PassThru -ArgumentList @(
                'install', '--id', '7zip.7zip', '--exact', '--source', 'winget',
                '--accept-package-agreements', '--accept-source-agreements'
            )
            $process.WaitForExit()
            Write-Host ''
            $archiver = Get-ArchiverPath
            if ($archiver) {
                Write-Ok (T 'tools.7zip.installed' $archiver)
                return $archiver
            }
            Write-Err (T 'tools.install.failed' $process.ExitCode)
        }
    } else {
        Write-Hint (T 'tools.no_winget')
    }

    # 2. A portable copy in the Migrator folder: no winget and no
    #    administrator rights needed, nothing is installed in Windows.
    #    Get-Tools.ps1 downloads the official package and checks its SHA256.
    $getTools = Join-Path (Get-MigratorRoot) 'Get-Tools.ps1'
    if (Test-Path -LiteralPath $getTools -PathType Leaf) {
        Write-Hint (T 'tools.7zip.portable_about')
        if (Read-YesNo (T 'tools.7zip.ask_portable') $false) {
            & (Get-Process -Id $PID).Path -NoLogo -NoProfile -ExecutionPolicy Bypass -File $getTools -SevenZipOnly -Yes | Out-Host
            $archiver = Get-ArchiverPath
            if ($archiver) {
                Write-Ok (T 'tools.7zip.installed' $archiver)
                return $archiver
            }
        }
    }

    Write-Hint (T 'm.tools.get_tools')
    return $null
}

Export-ModuleMember -Function @(
    'Request-Archiver'
    'Get-RestoreKitPath'
    'Test-RestoreKit'
    'New-RestoreKit'
)
