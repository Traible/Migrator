#Requires -Version 7.0
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Browser detection / process helpers.
# Cache exclusions live in Migrator.Core.psm1 (BrowserExcludes) so they work
# for every Chromium/Gecko browser, not only the ones detected here.
# ---------------------------------------------------------------------------

function Get-BrowserDefinitions {
    [CmdletBinding()]
    param()

    $programFilesX86 = ${env:ProgramFiles(x86)}
    $localAppData = $env:LOCALAPPDATA
    $appData = $env:APPDATA

    return @(
        [pscustomobject]@{
            Name         = 'Google Chrome'
            Family       = 'Chromium'
            ProcessNames = @('chrome')
            ExeCandidates = @(
                (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
                (Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe')
                (Join-Path $localAppData 'Google\Chrome\Application\chrome.exe')
            )
            ProfileRoots = @(
                (Join-Path $localAppData 'Google\Chrome\User Data')
            )
        }
        [pscustomobject]@{
            Name         = 'Microsoft Edge'
            Family       = 'Chromium'
            ProcessNames = @('msedge')
            ExeCandidates = @(
                (Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe')
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
            )
            ProfileRoots = @(
                (Join-Path $localAppData 'Microsoft\Edge\User Data')
            )
        }
        [pscustomobject]@{
            Name         = 'Mozilla Firefox'
            Family       = 'Gecko'
            ProcessNames = @('firefox')
            ExeCandidates = @(
                (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe')
                (Join-Path $programFilesX86 'Mozilla Firefox\firefox.exe')
            )
            ProfileRoots = @(
                (Join-Path $appData 'Mozilla\Firefox')
                (Join-Path $localAppData 'Mozilla\Firefox')
            )
        }
        [pscustomobject]@{
            Name         = 'Brave'
            Family       = 'Chromium'
            ProcessNames = @('brave')
            ExeCandidates = @(
                (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe')
                (Join-Path $programFilesX86 'BraveSoftware\Brave-Browser\Application\brave.exe')
                (Join-Path $localAppData 'BraveSoftware\Brave-Browser\Application\brave.exe')
            )
            ProfileRoots = @(
                (Join-Path $localAppData 'BraveSoftware\Brave-Browser\User Data')
            )
        }
        [pscustomobject]@{
            Name         = 'Vivaldi'
            Family       = 'Chromium'
            ProcessNames = @('vivaldi')
            ExeCandidates = @(
                (Join-Path $localAppData 'Vivaldi\Application\vivaldi.exe')
                (Join-Path $env:ProgramFiles 'Vivaldi\Application\vivaldi.exe')
            )
            ProfileRoots = @(
                (Join-Path $localAppData 'Vivaldi\User Data')
            )
        }
        [pscustomobject]@{
            Name         = 'Opera'
            Family       = 'Chromium'
            ProcessNames = @('opera')
            ExeCandidates = @(
                (Join-Path $localAppData 'Programs\Opera\opera.exe')
                (Join-Path $env:ProgramFiles 'Opera\opera.exe')
                (Join-Path $programFilesX86 'Opera\opera.exe')
            )
            ProfileRoots = @(
                (Join-Path $appData 'Opera Software\Opera Stable')
                (Join-Path $localAppData 'Opera Software\Opera Stable')
            )
        }
        [pscustomobject]@{
            Name         = 'Opera GX'
            Family       = 'Chromium'
            ProcessNames = @('opera')
            ExeCandidates = @(
                (Join-Path $localAppData 'Programs\Opera GX\opera.exe')
                (Join-Path $env:ProgramFiles 'Opera GX\opera.exe')
            )
            ProfileRoots = @(
                (Join-Path $appData 'Opera Software\Opera GX Stable')
                (Join-Path $localAppData 'Opera Software\Opera GX Stable')
            )
        }
        [pscustomobject]@{
            Name         = 'Chromium'
            Family       = 'Chromium'
            ProcessNames = @('chrome')
            ExeCandidates = @(
                (Join-Path $localAppData 'Chromium\Application\chrome.exe')
            )
            ProfileRoots = @(
                (Join-Path $localAppData 'Chromium\User Data')
            )
        }
        [pscustomobject]@{
            Name         = 'Yandex Browser'
            Family       = 'Chromium'
            ProcessNames = @('browser','yandex')
            ExeCandidates = @(
                (Join-Path $localAppData 'Yandex\YandexBrowser\Application\browser.exe')
                (Join-Path $env:ProgramFiles 'Yandex\YandexBrowser\Application\browser.exe')
            )
            ProfileRoots = @(
                (Join-Path $localAppData 'Yandex\YandexBrowser\User Data')
            )
        }
        [pscustomobject]@{
            Name         = 'Waterfox'
            Family       = 'Gecko'
            ProcessNames = @('waterfox')
            ExeCandidates = @(
                (Join-Path $env:ProgramFiles 'Waterfox\Waterfox.exe')
                (Join-Path $programFilesX86 'Waterfox\Waterfox.exe')
            )
            ProfileRoots = @(
                (Join-Path $appData 'Waterfox')
                (Join-Path $localAppData 'Waterfox')
            )
        }
        [pscustomobject]@{
            Name         = 'LibreWolf'
            Family       = 'Gecko'
            ProcessNames = @('librewolf')
            ExeCandidates = @(
                (Join-Path $env:ProgramFiles 'LibreWolf\LibreWolf.exe')
                (Join-Path $programFilesX86 'LibreWolf\LibreWolf.exe')
            )
            ProfileRoots = @(
                (Join-Path $appData 'librewolf')
                (Join-Path $localAppData 'librewolf')
            )
        }
        [pscustomobject]@{
            Name         = 'Pale Moon'
            Family       = 'Gecko'
            ProcessNames = @('palemoon')
            ExeCandidates = @(
                (Join-Path $env:ProgramFiles 'Pale Moon\palemoon.exe')
                (Join-Path $programFilesX86 'Pale Moon\palemoon.exe')
            )
            ProfileRoots = @(
                (Join-Path $appData 'Moonchild Productions\Pale Moon')
                (Join-Path $localAppData 'Moonchild Productions\Pale Moon')
            )
        }
    )
}

$script:InstalledBrowsersCache = $null

function Get-InstalledBrowsers {
    # Checks ~60 paths on disk, so the result is cached for the session
    # (the main menu shows it on every redraw).
    [CmdletBinding()]
    param([switch]$Refresh)

    if ($null -ne $script:InstalledBrowsersCache -and -not $Refresh) {
        return $script:InstalledBrowsersCache
    }

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($definition in Get-BrowserDefinitions) {
        $exe = $null
        foreach ($candidate in $definition.ExeCandidates) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $exe = $candidate
                break
            }
        }

        $profiles = @($definition.ProfileRoots | Where-Object {
            $_ -and (Test-Path -LiteralPath $_ -PathType Container)
        })

        if (-not $exe -and $profiles.Count -eq 0) { continue }

        $version = $null
        if ($exe) {
            try { $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { }
        }

        $result.Add([pscustomobject]@{
            Name          = $definition.Name
            Family        = $definition.Family
            ProcessNames  = $definition.ProcessNames
            Executable    = $exe
            Version       = $version
            ProfileRoots  = $profiles
        })
    }

    $script:InstalledBrowsersCache = @($result)
    return $script:InstalledBrowsersCache
}

function Get-RunningBrowsers {
    [CmdletBinding()]
    param()

    $config = Get-MigratorConfig
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($name in @($config.BrowserProcessNames)) {
        if ($name) { [void]$names.Add([string]$name) }
    }
    foreach ($browser in Get-InstalledBrowsers) {
        foreach ($name in @($browser.ProcessNames)) {
            if ($name) { [void]$names.Add([string]$name) }
        }
    }

    # One process snapshot filtered by name, instead of one query per name.
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($process in [Diagnostics.Process]::GetProcesses()) {
        try {
            if ($names.Contains($process.ProcessName)) {
                $result.Add([pscustomobject]@{
                    Id          = $process.Id
                    ProcessName = $process.ProcessName
                })
            }
        } catch { } finally { $process.Dispose() }
    }

    return @($result | Sort-Object ProcessName, Id)
}

function Stop-RunningBrowsers {
    [CmdletBinding()]
    param([switch]$Force)

    $running = @(Get-RunningBrowsers)
    if ($running.Count -eq 0) { return 0 }

    foreach ($process in $running) {
        try {
            $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
            if (-not $live) { continue }
            [void]$live.CloseMainWindow()
        } catch { }
    }

    Start-Sleep -Seconds 3

    $remaining = @(Get-RunningBrowsers)
    if ($remaining.Count -gt 0 -and $Force) {
        foreach ($process in $remaining) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Seconds 1
    }

    return @(Get-RunningBrowsers).Count
}

function Get-BrowserSummary {
    [CmdletBinding()]
    param()

    $browsers = @(Get-InstalledBrowsers)
    if ($browsers.Count -eq 0) { return 'none detected' }
    return (($browsers | Select-Object -ExpandProperty Name -Unique) -join ', ')
}

Export-ModuleMember -Function @(
    'Get-BrowserDefinitions'
    'Get-InstalledBrowsers'
    'Get-RunningBrowsers'
    'Stop-RunningBrowsers'
    'Get-BrowserSummary'
)
