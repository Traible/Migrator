#Requires -Version 7.0
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Migrator.Self.psm1
# Migrator looking after its own copy:
#   * integrity - a release carries files.sha256, the SHA256 of every file in
#     it. At start the copy is compared with that list, which catches a
#     folder copied to a USB drive incompletely or a damaged file;
#   * new versions - once a day the latest release on GitHub is looked up;
#     after a typed "y" it is downloaded, checked and put over this copy.
#
# A copy without files.sha256 is a development checkout: it is neither
# checked nor ever updated over.
#
# This does not protect against someone who changes the scripts on purpose
# (they would change this check too). For that, a release archive can be
# verified from outside:  gh attestation verify Migrator-X.zip --repo Traible/Migrator
# ---------------------------------------------------------------------------

$script:Repository = 'Traible/Migrator'
$script:ManifestName = 'files.sha256'
# Not covered by the list: settings the user may edit and data Migrator creates.
$script:UncheckedPrefixes = @('src\config\', 'Tools\', 'Logs\', 'Backups\', 'dist\')

function Get-ReleasePageUrl { return "https://github.com/$script:Repository/releases/latest" }

function Test-SafeRelativePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) { return $false }
    foreach ($part in ($Path -split '[\\/]')) { if ($part -eq '..' -or $part -eq '') { return $false } }
    return $true
}

function New-CopyManifest {
    # Writes files.sha256 for the folder: "HASH *relative\path" per file.
    # Returns the number of files listed.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $lines = foreach ($file in @(Get-ChildItem -LiteralPath $base -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($base.Length)
        if ($relative -eq $script:ManifestName) { continue }
        if (@($script:UncheckedPrefixes | Where-Object { $relative.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        '{0} *{1}' -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash, $relative
    }
    [IO.File]::WriteAllLines((Join-Path $base $script:ManifestName), [string[]]@($lines), [Text.UTF8Encoding]::new($false))
    return @($lines).Count
}

function Read-CopyManifest {
    # relative path -> SHA256, or $null when the folder has no list.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $path = Join-Path $Root $script:ManifestName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $entries = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ($line -match '^([A-Fa-f0-9]{64})\s+\*?(.+)$' -and (Test-SafeRelativePath -Path $Matches[2].Trim())) {
            $entries[$Matches[2].Trim()] = $Matches[1].ToUpperInvariant()
        }
    }
    return $entries
}

function Test-MigratorCopy {
    # Compares the folder with its files.sha256.
    [CmdletBinding()]
    param([string]$Root = (Get-MigratorRoot))

    $entries = Read-CopyManifest -Root $Root
    $missing = [System.Collections.Generic.List[string]]::new()
    $changed = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $entries) {
        foreach ($relative in $entries.Keys) {
            $file = Join-Path $Root $relative
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $missing.Add($relative); continue }
            if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entries[$relative]) { $changed.Add($relative) }
        }
    }
    return [pscustomobject]@{
        HasManifest = ($null -ne $entries)
        Files       = if ($null -ne $entries) { $entries.Count } else { 0 }
        Missing     = @($missing)
        Changed     = @($changed)
        Ok          = ($null -ne $entries -and $entries.Count -gt 0 -and $missing.Count -eq 0 -and $changed.Count -eq 0)
    }
}

function Remove-EmptyFolder {
    # Removes the folder when nothing but empty folders is left in it.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue).Count -gt 0) { return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function ConvertFrom-ReleaseData {
    # Version and download addresses from the GitHub "latest release" answer.
    # Only files of this repository's own releases are accepted.
    [CmdletBinding()]
    param($Data)

    if (-not $Data -or -not $Data['tag_name']) { return $null }
    $version = ([string]$Data['tag_name']).TrimStart('v', 'V')
    $parsed = $null
    if (-not [version]::TryParse($version, [ref]$parsed)) { return $null }

    $prefix = "https://github.com/$script:Repository/releases/download/"
    $zipUrl = $null; $shaUrl = $null
    foreach ($asset in @($Data['assets'])) {
        if (-not $asset) { continue }
        $name = [string]$asset['name']; $url = [string]$asset['browser_download_url']
        if (-not $url.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($name -eq "Migrator-$version.zip") { $zipUrl = $url }
        if ($name -eq "Migrator-$version.zip.sha256") { $shaUrl = $url }
    }
    if (-not $zipUrl -or -not $shaUrl) { return $null }
    return [pscustomobject]@{ Version = $version; ZipUrl = $zipUrl; ShaUrl = $shaUrl; Fresh = $true }
}

function Get-LatestRelease {
    # The latest release, or $null (switched off, no internet, nothing usable).
    # GitHub is asked at most once a day (after a failure: once in two hours);
    # in between the saved answer is used. MIGRATOR_TEST_RELEASE_JSON replaces
    # the request with a file for the tests.
    [CmdletBinding()]
    param([switch]$CacheOnly)

    $config = Get-MigratorConfig
    if (-not [bool]$config['CheckForUpdates']) { return $null }

    if ($env:MIGRATOR_TEST_RELEASE_JSON) {
        if (-not (Test-Path -LiteralPath $env:MIGRATOR_TEST_RELEASE_JSON -PathType Leaf)) { return $null }
        return ConvertFrom-ReleaseData -Data (Get-Content -LiteralPath $env:MIGRATOR_TEST_RELEASE_JSON -Raw | ConvertFrom-Json -AsHashtable)
    }

    $cache = $config['UpdateCheck']
    if ($cache -is [System.Collections.IDictionary] -and $cache['checkedAtUtc']) {
        # ConvertFrom-Json may already have turned the text into a date.
        $checked = [datetime]::MinValue
        $parsedOk = $true
        if ($cache['checkedAtUtc'] -is [datetime]) {
            $checked = $cache['checkedAtUtc']
        } else {
            $parsedOk = [datetime]::TryParse([string]$cache['checkedAtUtc'], [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$checked)
        }
        $age = if ($parsedOk) { [datetime]::UtcNow - $checked.ToUniversalTime() } else { [TimeSpan]::MaxValue }
        $found = [bool]$cache['version']
        $recent = ($age -ge [TimeSpan]::Zero -and $age.TotalHours -lt $(if ($found) { 24 } else { 2 }))
        if ($recent -or $CacheOnly) {
            if (-not $found) { return $null }
            return [pscustomobject]@{ Version = [string]$cache['version']; ZipUrl = [string]$cache['zipUrl']; ShaUrl = [string]$cache['shaUrl']; Fresh = $false }
        }
    }
    if ($CacheOnly) { return $null }

    $release = $null
    try {
        $data = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:Repository/releases/latest" -TimeoutSec 4 `
            -Headers @{ 'User-Agent' = 'Migrator'; 'Accept' = 'application/vnd.github+json' } -ErrorAction Stop
        $release = ConvertFrom-ReleaseData -Data ($data | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable)
    } catch { }

    try {
        Set-MigratorUserSetting -Name 'UpdateCheck' -Value @{
            checkedAtUtc = [datetime]::UtcNow.ToString('o')
            version      = if ($release) { $release.Version } else { $null }
            zipUrl       = if ($release) { $release.ZipUrl } else { $null }
            shaUrl       = if ($release) { $release.ShaUrl } else { $null }
        }
    } catch { }      # a read-only folder: the check simply repeats next time
    return $release
}

function Test-NewerVersion {
    param([string]$Candidate, [string]$Current)
    $a = $null; $b = $null
    if (-not [version]::TryParse($Candidate, [ref]$a) -or -not [version]::TryParse($Current, [ref]$b)) { return $false }
    return ($a -gt $b)
}

function Get-UpdateNotice {
    # The newer version known from the last check, for the status line.
    $root = Get-MigratorRoot
    if (-not (Test-Path -LiteralPath (Join-Path $root $script:ManifestName) -PathType Leaf)) { return $null }
    $release = Get-LatestRelease -CacheOnly
    if ($release -and (Test-NewerVersion -Candidate $release.Version -Current ([string](Get-MigratorConfig).ToolVersion))) { return $release.Version }
    return $null
}

function Install-MigratorRelease {
    # Puts a release archive over the folder -Root.
    #   1. the archive must have the expected SHA256;
    #   2. it is unpacked aside and must be complete by its own files.sha256;
    #   3. its files replace the ones in -Root; files of the old release that
    #      the new one no longer has are removed.
    # Settings (src\config), Tools, Logs and Backups are never touched.
    # Nothing in -Root changes unless steps 1 and 2 pass.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Sha256
    )

    $actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
    if ($actual -ne $Sha256.Trim().ToUpperInvariant()) { throw (T 's.error.hash') }

    $stage = Join-Path ([IO.Path]::GetTempPath()) ('migrator-update-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $stage -Force
        $package = $stage
        $inner = @(Get-ChildItem -LiteralPath $stage)
        if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $package = $inner[0].FullName }

        $check = Test-MigratorCopy -Root $package
        $complete = $check.Ok -and (Test-Path -LiteralPath (Join-Path $package 'src\main.ps1') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $package 'Migrator.bat') -PathType Leaf)
        if (-not $complete) { throw (T 's.error.package') }

        $oldEntries = Read-CopyManifest -Root $Root
        $newEntries = Read-CopyManifest -Root $package
        $target = [IO.Path]::GetFullPath($Root).TrimEnd('\')

        foreach ($relative in @($newEntries.Keys) + @($script:ManifestName)) {
            $destination = Join-Path $target $relative
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            Copy-Item -LiteralPath (Join-Path $package $relative) -Destination $destination -Force
        }

        $removed = 0
        if ($null -ne $oldEntries) {
            foreach ($relative in $oldEntries.Keys) {
                if ($newEntries.Contains($relative)) { continue }
                $stale = Join-Path $target $relative
                if (Test-Path -LiteralPath $stale -PathType Leaf) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue; $removed++ }
            }
            # Folders the new version no longer has: only when they are empty now.
            foreach ($folder in @($oldEntries.Keys | ForEach-Object { $_.Split([char]92)[0] } | Sort-Object -Unique)) {
                if (@($newEntries.Keys | Where-Object { $_.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0 -and
                    @($script:UncheckedPrefixes | Where-Object { $_.TrimEnd('\') -eq $folder }).Count -eq 0) {
                    Remove-EmptyFolder -Path (Join-Path $target $folder)
                }
            }
        }
        return [pscustomobject]@{ Copied = $newEntries.Count; Removed = $removed }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Update-MigratorCopy {
    # Downloads the release and installs it over this copy.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Release, [string]$Root = (Get-MigratorRoot))

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('migrator-download-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    try {
        $zip = Join-Path $temp "Migrator-$($Release.Version).zip"
        $sha = "$zip.sha256"
        Invoke-WebRequest -Uri $Release.ZipUrl -OutFile $zip -TimeoutSec 120 -ErrorAction Stop
        Invoke-WebRequest -Uri $Release.ShaUrl -OutFile $sha -TimeoutSec 30 -ErrorAction Stop
        $expected = if ((Get-Content -LiteralPath $sha -Raw) -match '([A-Fa-f0-9]{64})') { $Matches[1] } else { '' }
        if (-not $expected) { throw (T 's.error.hash') }
        return (Install-MigratorRelease -Root $Root -ZipPath $zip -Sha256 $expected)
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-StartupCheck {
    # Called once when Migrator starts. Returns $true when a new Migrator has
    # been started and this one has to close.
    [CmdletBinding()]
    param()

    $root = Get-MigratorRoot
    $copy = Test-MigratorCopy -Root $root
    if (-not $copy.HasManifest) { return $false }        # development checkout

    # Since 2.5.1 a release has no tests\ and build\ folders. An update made
    # by 2.5.0 removes their files and leaves the empty folders behind.
    foreach ($folder in 'tests', 'build') { Remove-EmptyFolder -Path (Join-Path $root $folder) }

    $current = [string](Get-MigratorConfig).ToolVersion
    $damaged = -not $copy.Ok
    $release = Get-LatestRelease
    $newer = [bool]($release -and (Test-NewerVersion -Candidate $release.Version -Current $current))
    # A newer version is offered once per check (once a day); a damaged copy
    # is reported at every start.
    $offerNew = $newer -and $release.Fresh
    if (-not $damaged -and -not $offerNew) { return $false }

    Clear-Screen
    Write-Banner (T 'app.tagline')
    if ($damaged) {
        Write-Warn (T 's.damaged' $copy.Missing.Count $copy.Changed.Count)
        foreach ($name in @(@($copy.Missing) + @($copy.Changed) | Select-Object -First 6)) { Write-Detail $name }
    }
    if ($newer) {
        Write-Host ''
        Write-Ok (T 's.new_version' $release.Version $current)
        Write-Detail (T 's.whats_new' "https://github.com/$script:Repository/blob/main/CHANGELOG.md")
    }

    # A damaged copy is repaired with the same or a newer version, never an older one.
    $notOlder = $release -and -not (Test-NewerVersion -Candidate $current -Current $release.Version)
    $canAsk = $notOlder -and (Test-InteractiveConsole)
    if (-not $canAsk) {
        if ($damaged) {
            Write-Solution (T 's.damaged_solution' (Get-ReleasePageUrl))
            Wait-Enter
        }
        return $false
    }

    Write-Host ''
    $question = if ($newer) { T 's.ask_update' $release.Version } else { T 's.ask_repair' $release.Version }
    if (-not (Read-YesNo $question $false)) { return $false }

    try {
        Write-Hint (T 's.downloading' $release.Version)
        [void](Update-MigratorCopy -Release $release -Root $root)
    } catch {
        Write-Host ''
        Write-Err (T 's.failed' $_.Exception.Message)
        Write-Solution (T 's.damaged_solution' (Get-ReleasePageUrl))
        Wait-Enter
        return $false
    }

    Write-Ok (T 's.updated' $release.Version)
    $launchArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'src\main.ps1'))
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (ConvertTo-NativeCommandLine -Arguments $launchArgs)
    return $true
}

Export-ModuleMember -Function @(
    'New-CopyManifest'
    'Read-CopyManifest'
    'Test-MigratorCopy'
    'ConvertFrom-ReleaseData'
    'Get-LatestRelease'
    'Test-NewerVersion'
    'Get-UpdateNotice'
    'Install-MigratorRelease'
    'Update-MigratorCopy'
    'Invoke-StartupCheck'
)
