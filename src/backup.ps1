#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$User,
    [ValidateSet('Full','Standard')]
    [string]$Mode,
    [string]$Destination,
    [string]$SourcePath,
    [switch]$NonInteractive,
    [switch]$NoVerify,
    [switch]$ComputeHash,
    [ValidateSet('Auto','Exclude','Include')]
    [string]$CloudFolders,
    # Put Migrator with portable PowerShell and 7-Zip next to the archive.
    [ValidateSet('None','Copy','Download')]
    [string]$RestoreKit,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in 'Core', 'UI', 'Archive', 'Browsers', 'Kit') {
    Import-Module (Join-Path $toolRoot "src\lib\Migrator.$module.psm1") -Force
}

$config = Get-MigratorConfig
$archiver = Get-ArchiverPath
if (-not $archiver) { throw (T 'error.archiver_not_found') }

$isAdmin = Test-IsAdmin
$interactive = -not $NonInteractive

if ($interactive) {
    Clear-Screen
    Write-Banner (T 'b.subtitle')
}

# ---------------------------------------------------------------------------
# 1. Source profile
# ---------------------------------------------------------------------------
$profile = $null

if ($SourcePath) {
    $sourcePath = [IO.Path]::GetFullPath($SourcePath).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw (T 'b.error.source_missing' $sourcePath)
    }
    $userName = Split-Path -Leaf $sourcePath
} else {
    $profiles = @(Get-UserProfiles | Sort-Object Name)
    if ($profiles.Count -eq 0) { throw (T 'error.no_profiles') }

    if ($User) {
        $profile = $profiles | Where-Object { $_.Name -eq $User } | Select-Object -First 1
        if (-not $profile) { throw (T 'error.profile_not_found' $User (($profiles.Name) -join ', ')) }
    } else {
        if ($NonInteractive) { throw (T 'b.error.need_user') }

        $default = 0
        $items = @(for ($i = 0; $i -lt $profiles.Count; $i++) {
            $label = $profiles[$i].Name
            if ($profiles[$i].IsCurrent) { $label += '  ' + (T 'profile.current'); $default = $i }
            elseif ($profiles[$i].Loaded) { $label += '  ' + (T 'profile.loaded') }
            New-MenuItem -Value $profiles[$i] -Label $label -Hint $profiles[$i].LocalPath
        })
        $profile = Show-Menu -Title (T 'b.select_profile') -Items $items -Default $default -AllowCancel
        if (-not $profile) { return }
    }

    $sourcePath = $profile.LocalPath.TrimEnd('\')
    $userName = $profile.Name

    if (-not $isAdmin -and -not $profile.IsCurrent) {
        Write-Warn (T 'b.warn.need_admin')
        if ($NonInteractive) { throw (T 'b.error.need_admin') }
        if (-not (Read-YesNo (T 'b.ask.continue_incomplete') $false)) { return }
    }

    if ($profile.Loaded) {
        Write-Host ''
        Write-Warn (T 'b.warn.loaded')
        Write-Hint (T 'b.hint.loaded')
    }
}

# ---------------------------------------------------------------------------
# 2. Mode
# ---------------------------------------------------------------------------
if (-not $Mode) {
    $Mode = [string]$config.DefaultMode
    if ($Mode -notin @('Full','Standard')) { $Mode = 'Full' }

    if ($interactive) {
        $Mode = Show-Menu -Title (T 'b.select_mode') -Default $(if ($Mode -eq 'Standard') { 1 } else { 0 }) -Items @(
            (New-MenuItem -Value 'Full' -Label (T 'mode.full') -Hint (T 'mode.full.hint'))
            (New-MenuItem -Value 'Standard' -Label (T 'mode.standard') -Hint (T 'mode.standard.hint'))
        )
    }
}

# ---------------------------------------------------------------------------
# 3. Destination
# ---------------------------------------------------------------------------
$defaultDestination = Resolve-MigratorPath $config.BackupRoot

if (-not $Destination -and $interactive) {
    $items = [System.Collections.Generic.List[object]]::new()
    $items.Add((New-MenuItem -Value $defaultDestination -Label $defaultDestination `
        -Hint (T 'b.dest.default_hint' (Format-Size (Get-FreeSpaceBytes -Path $defaultDestination)))))
    foreach ($volume in @(Get-TargetVolumes)) {
        $label = if ($volume.Label) { $volume.Label } else { T 'b.dest.no_label' }
        $items.Add((New-MenuItem -Value "$($volume.Drive)\MigratorBackups" -Label "$($volume.Drive)\MigratorBackups" `
            -Hint (T 'b.dest.volume_hint' $label (Format-Size $volume.FreeSpace) (Format-Size $volume.Size) $volume.FileSystem)))
    }
    $items.Add((New-MenuItem -Value '' -Label (T 'b.dest.other') -Key 'O'))

    $Destination = Show-Menu -Title (T 'b.select_destination') -Items @($items)
    if ($Destination -eq '') {
        $entered = Read-Line (T 'b.dest.enter_path')
        if ([string]::IsNullOrWhiteSpace($entered)) { return }
        $Destination = [Environment]::ExpandEnvironmentVariables($entered.Trim().Trim('"'))
    }
}

if (-not $Destination) { $Destination = $defaultDestination }
if ($Destination -match '^[A-Za-z]:$') { $Destination = "$Destination\MigratorBackups" }
if (-not [IO.Path]::IsPathRooted($Destination)) { $Destination = Resolve-MigratorPath $Destination }
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')

if (Test-PathWithin -Child $Destination -Parent $sourcePath) { throw (T 'b.error.dest_inside_source' $Destination) }
if (Test-PathWithin -Child $sourcePath -Parent $Destination) { throw (T 'b.error.source_inside_dest' $sourcePath) }

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# ---------------------------------------------------------------------------
# 4. Exclusions, cloud folders, one scan of the profile
# ---------------------------------------------------------------------------
$excludeMasks = @(Get-ModeExcludeMasks -Mode $Mode)

$cloudPolicy = if ($CloudFolders) { $CloudFolders } else { [string]$config.CloudFolderPolicy }
if ($cloudPolicy -notin @('Auto','Exclude','Include')) { $cloudPolicy = 'Auto' }
$excludedCloudFolders = [System.Collections.Generic.List[string]]::new()

$cloudFound = @(Get-CloudFolders -ProfilePath $sourcePath)
if ($cloudFound.Count -gt 0) {
    Write-Host ''
    Write-Warn (T 'b.cloud.found')
    foreach ($cloud in $cloudFound) {
        $state = if ($cloud.CloudOnlyFiles -gt 0) {
            T 'b.cloud.state_online' $cloud.CloudOnlyFiles (Format-Size $cloud.CloudOnlyBytes)
        } else {
            T 'b.cloud.state_local'
        }
        Write-Text ('  {0}  -  {1}  ({2})' -f $cloud.Name, (Format-Size $cloud.Bytes), $state)
    }
    Write-Hint (T 'b.cloud.explain1')
    Write-Hint (T 'b.cloud.explain2')

    foreach ($cloud in $cloudFound) {
        $hasOnline = $cloud.CloudOnlyFiles -gt 0
        $exclude = switch ($cloudPolicy) {
            'Exclude' { $true }
            'Include' { $false }
            default {
                if ($NonInteractive) { $hasOnline }
                else { Read-YesNo (T 'b.cloud.ask_exclude' $cloud.Name) $hasOnline }
            }
        }

        if ($exclude) {
            $excludedCloudFolders.Add($cloud.Name)
            $excludeMasks += ($cloud.Name + '\')
        } elseif ($hasOnline) {
            Write-Warn (T 'b.cloud.will_download' $cloud.Name (Format-Size $cloud.CloudOnlyBytes))
        }
    }
}

Write-Host ''
Write-Hint (T 'b.scanning')
$scanStarted = Get-Date
$scan = Measure-ProfileTree -Path $sourcePath -ExcludeMasks $excludeMasks
$nameMasks = @((Split-ExcludeMasks -Masks $excludeMasks).FileNameMasks)
$excludePaths = @($scan.ExcludedDirectories) + @($scan.ExcludedFiles)
$sourceBytes = [int64]$scan.Bytes

# ---------------------------------------------------------------------------
# 5. Checks: free space, running browsers
# ---------------------------------------------------------------------------
$freeBytes = Get-FreeSpaceBytes -Path $Destination
$lowSpace = ($null -ne $freeBytes -and $sourceBytes -gt 0 -and $freeBytes -lt $sourceBytes)
$runningBrowsers = @(Get-RunningBrowsers)

# ---------------------------------------------------------------------------
# 6. Summary and confirmation
# ---------------------------------------------------------------------------
$artifacts = New-BackupArtifacts -BackupRoot $Destination -ComputerName $env:COMPUTERNAME -UserName $userName
while (Test-Path -LiteralPath $artifacts.Archive) {
    Start-Sleep -Seconds 1
    $artifacts = New-BackupArtifacts -BackupRoot $Destination -ComputerName $env:COMPUTERNAME -UserName $userName
}

$compression = 0
if ([string]$config.Compression -match '(\d)') { $compression = [int]$Matches[1] }
$verifyAfterBackup = [bool]$config.VerifyAfterBackup -and -not $NoVerify
$wantHash = [bool]($config.ComputeSha256 -or $ComputeHash)

$plan = [ordered]@{}
$plan[(T 'f.user')]        = $userName
$plan[(T 'f.source')]      = $sourcePath
$plan[(T 'f.mode')]        = T "mode.$($Mode.ToLower())"
$plan[(T 'f.size')]        = T 'b.plan.size' (Format-Size $sourceBytes) $scan.Files
$plan[(T 'f.excluded')]    = T 'b.plan.excluded' $scan.ExcludedDirectories.Count $nameMasks.Count
if ($excludedCloudFolders.Count -gt 0) { $plan[(T 'f.cloud_excluded')] = ($excludedCloudFolders -join ', ') }
$plan[(T 'f.archive')]     = $artifacts.Archive
$plan[(T 'f.free_space')]  = if ($lowSpace) { @((Format-Size $freeBytes), 'Warn') } else { Format-Size $freeBytes }
$plan[(T 'f.compression')] = if ($compression -eq 0) { T 'b.plan.store' } else { T 'b.plan.level' $compression }

# Restore kit: Migrator + portable tools next to the archive, for a new PC
# that has neither PowerShell 7, nor 7-Zip, nor internet yet.
$kit = Test-RestoreKit -Path (Get-RestoreKitPath -Destination $Destination)
$kitAction = if ($RestoreKit) { $RestoreKit } else { 'None' }
if ($kit.State -eq 'Ready') {
    $kitAction = 'None'
    $plan[(T 'f.kit')] = T 'b.kit.ready' $kit.Path
} elseif ($kit.State -eq 'Outdated' -and $kitAction -eq 'None') {
    $kitAction = 'Copy'      # tools are there; only the scripts are refreshed
    $plan[(T 'f.kit')] = T 'b.kit.will_update' $kit.Path
} elseif ($kitAction -ne 'None') {
    $plan[(T 'f.kit')] = T 'b.kit.will_create' $kit.Path
}
$askKit = $interactive -and -not $RestoreKit -and $kit.State -in @('Missing', 'NoTools')

Write-SummaryBox -Title (T 'b.plan.title') -Fields $plan

if ($lowSpace) { Write-Warn (T 'b.warn.low_space') }
if ($runningBrowsers.Count -gt 0) {
    Write-Warn (T 'b.warn.browsers' (($runningBrowsers.ProcessName | Sort-Object -Unique) -join ', '))
    Write-Hint (T 'b.hint.browsers')
}

if ($interactive) {
    $action = Show-Menu -Title (T 'b.confirm.title') -AllowCancel -Default $(if ($verifyAfterBackup) { 0 } else { 1 }) -Items @(
        (New-MenuItem -Value 'verify' -Label (T 'b.confirm.start_verify') -Hint (T 'b.confirm.start_verify.hint'))
        (New-MenuItem -Value 'fast' -Label (T 'b.confirm.start_fast') -Hint (T 'b.confirm.start_fast.hint'))
        (New-MenuItem -Value 'cancel' -Label (T 'ui.cancel') -Key 'Q')
    )
    if (-not $action -or $action -eq 'cancel') {
        Write-Warn (T 'b.cancelled')
        return
    }
    $verifyAfterBackup = ($action -eq 'verify')

    if ($askKit) {
        Write-Host ''
        Write-Hint (T 'b.kit.explain1')
        Write-Hint (T 'b.kit.explain2' $kit.Path)
        $kitAction = Show-Menu -Title (T 'b.kit.title') -Items @(
            (New-MenuItem -Value 'Copy' -Label (T 'b.kit.copy') -Hint (T 'b.kit.copy.hint'))
            (New-MenuItem -Value 'Download' -Label (T 'b.kit.download') -Hint (T 'b.kit.download.hint'))
            (New-MenuItem -Value 'None' -Label (T 'b.kit.skip') -Hint (T 'b.kit.skip.hint'))
        )
    }
} elseif ($lowSpace -and -not $Force) {
    throw (T 'b.error.low_space')
}

# ---------------------------------------------------------------------------
# 7. Archive
# ---------------------------------------------------------------------------
Write-Host ''
Write-LogLine -Path $artifacts.Log -Message "Backup started: user=$userName mode=$Mode source=$sourcePath archive=$($artifacts.Archive) files=$($scan.Files) bytes=$sourceBytes excludedFolders=$($scan.ExcludedDirectories.Count)"

$result = New-ProfileArchive -ArchiverPath $archiver -SourcePath $sourcePath -ArchivePath $artifacts.Archive `
    -ExcludePaths $excludePaths -ExcludeNameMasks $nameMasks -Compression $compression `
    -TotalBytes $sourceBytes -TotalFiles $scan.Files -Activity (T 'b.activity' $userName)

if (-not (Test-Path -LiteralPath $artifacts.Archive -PathType Leaf)) {
    $message = Get-ArchiverExitMessage $result.ExitCode
    Write-LogLine -Path $artifacts.Log -Message "Archiver exit code $($result.ExitCode): $message; archive was not created. $($result.StdErr)"
    throw (T 'b.error.no_archive' $result.ExitCode $message)
}

$fatal = ($result.Outcome -eq 'Failed')
$skippedFiles = @($result.SkippedFiles)

# ---------------------------------------------------------------------------
# 8. Verification (and SHA256 at the same time)
# ---------------------------------------------------------------------------
$verifyState = 'not_requested'
$verifyExit = $null
$runTest = $verifyAfterBackup -and -not $fatal
if ($verifyAfterBackup -and $fatal) { $verifyState = 'skipped' }

$check = Invoke-ArchiveCheck -ArchiverPath $archiver -ArchivePath $artifacts.Archive `
    -Test:$runTest -Sha256:($wantHash -and -not $fatal) -Activity (T 'b.activity_verify')
if ($runTest) {
    $verifyExit = [int]$check.TestResult.ExitCode
    $verifyState = if ($verifyExit -eq 0) { 'passed' } else { 'failed' }
}
$archiveHash = $check.Sha256

$finalOk = (-not $fatal) -and ($verifyState -ne 'failed')
$hasWarnings = ($result.Outcome -eq 'Warnings') -or ($skippedFiles.Count -gt 0)
$resultCode = if (-not $finalOk) { 'FAILED' } elseif ($hasWarnings) { 'COMPLETED WITH WARNINGS' } else { 'SUCCESS' }
$resultText = if (-not $finalOk) { T 'result.failed' } elseif ($hasWarnings) { T 'result.warnings' } else { T 'result.success' }
$resultColor = if (-not $finalOk) { 'Error' } elseif ($hasWarnings) { 'Warn' } else { 'Ok' }

# The kit is an extra: a problem with it never turns a good backup into a failure.
$kitResult = $null
if ($finalOk -and $kitAction -ne 'None') {
    Write-Hint (T 'b.kit.building' $kit.Path)
    try {
        $kitResult = New-RestoreKit -Path $kit.Path -ToolSource $kitAction
    } catch {
        $kitResult = [pscustomobject]@{ Path = $kit.Path; Ok = $false; Problems = @($_.Exception.Message); State = 'NoTools' }
    }
    Write-LogLine -Path $artifacts.Log -Message "Restore kit: path=$($kit.Path) source=$kitAction ok=$($kitResult.Ok) problems=$($kitResult.Problems -join '; ')"
}

$archiveBytes = (Get-Item -LiteralPath $artifacts.Archive).Length
$speed =if ($result.Duration.TotalSeconds -gt 0) { [int64]($archiveBytes / $result.Duration.TotalSeconds) } else { 0 }

# ---------------------------------------------------------------------------
# 9. Manifest, logs, summary
# ---------------------------------------------------------------------------
if ($skippedFiles.Count -gt 0 -or $result.StdErr.Trim()) {
    Write-TextFile -Path $artifacts.ErrorLog -Lines @(
        "Skipped files: $($skippedFiles.Count)"
        $skippedFiles
        ''
        '--- archiver messages ---'
        $result.StdErr
    )
}

$browserNames = @(Get-InstalledBrowsers | Select-Object -ExpandProperty Name -Unique)
Write-ManifestFile -Path $artifacts.Manifest -Data @{
    toolVersion          = [string]$config.ToolVersion
    createdAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
    computer             = $env:COMPUTERNAME
    sourceUser           = $userName
    sourceSid            = if ($profile) { [string]$profile.SID } else { $null }
    sourceProfile        = $sourcePath
    archiveName          = Split-Path -Leaf $artifacts.Archive
    archiveFormat        = '7z'
    archiveBytes         = [int64]$archiveBytes
    sourceBytes          = $sourceBytes
    sourceFiles          = [int64]$scan.Files
    mode                 = $Mode
    compression          = $compression
    archiver             = Get-ArchiverVersion -ArchiverPath $archiver
    archiverExitCode     = [int]$result.ExitCode
    result               = $resultCode
    skippedFileCount     = $skippedFiles.Count
    skippedFiles         = @($skippedFiles | Select-Object -First 200)
    excludedFolderCount  = $scan.ExcludedDirectories.Count
    excludedCloudFolders = @($excludedCloudFolders)
    verify               = $verifyState
    verifyExitCode       = $verifyExit
    archiveSha256        = $archiveHash
    durationSeconds      = [math]::Round($result.Duration.TotalSeconds, 1)
    browsers             = $browserNames
}

$verifyText = T "verify.$verifyState"
$report = [ordered]@{}
$report[(T 'f.result')]   = @($resultText, $resultColor)
$report[(T 'f.archive')]  = $artifacts.Archive
$report[(T 'f.size')]     = T 'b.report.size' (Format-Size $archiveBytes) $scan.Files
$report[(T 'f.duration')] = T 'b.report.duration' (Format-Duration $result.Duration) (Format-Size $speed) (T 'unit.sec')
$report[(T 'f.verify')]   = if ($verifyState -eq 'failed') { @($verifyText, 'Error') } else { $verifyText }
$report[(T 'f.skipped')]  = if ($skippedFiles.Count -gt 0) { @((T 'b.report.skipped' $skippedFiles.Count), 'Warn') } else { T 'b.report.none' }
if ($archiveHash) { $report['SHA256'] = $archiveHash }
if ($kitResult) {
    $report[(T 'f.kit')] = if ($kitResult.Ok) { $kitResult.Path } else { @((T 'b.kit.failed' ($kitResult.Problems -join '; ')), 'Warn') }
} elseif ($kit.State -eq 'Ready') {
    $report[(T 'f.kit')] = $kit.Path
}
$report[(T 'f.manifest')] = $artifacts.Manifest

$summaryLines = [System.Collections.Generic.List[string]]::new()
$summaryLines.Add(('{0} v{1} - {2}' -f (T 'app.title'), $config.ToolVersion, (T 'b.report.title')))
$summaryLines.Add((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$summaryLines.Add('')
foreach ($section in @($plan, $report)) {
    foreach ($label in $section.Keys) {
        $value = $section[$label]
        if ($value -is [array]) { $value = $value[0] }
        $summaryLines.Add(('{0}: {1}' -f $label, $value))
    }
}
if ($skippedFiles.Count -gt 0) {
    $summaryLines.Add('')
    $summaryLines.Add((T 'b.report.skipped_list'))
    foreach ($file in @($skippedFiles | Select-Object -First 50)) { $summaryLines.Add("  $file") }
    if ($skippedFiles.Count -gt 50) { $summaryLines.Add('  ' + (T 'report.and_more' ($skippedFiles.Count - 50))) }
}
Write-TextFile -Path $artifacts.Summary -Lines @($summaryLines)
Write-LogLine -Path $artifacts.Log -Message "Backup finished: result=$resultCode exit=$($result.ExitCode) size=$archiveBytes verify=$verifyState skipped=$($skippedFiles.Count) scan=$([math]::Round(((Get-Date) - $scanStarted).TotalSeconds, 1))s"

# ---------------------------------------------------------------------------
# 10. Result on screen
# ---------------------------------------------------------------------------
Write-SummaryBox -Title (T 'b.report.title') -Fields $report -Color $resultColor

if ($skippedFiles.Count -gt 0) {
    Write-Host ''
    Write-Warn (T 'b.report.skipped_explain')
    foreach ($file in @($skippedFiles | Select-Object -First 10)) { Write-Hint "    $file" }
    if ($skippedFiles.Count -gt 10) { Write-Hint ('    ' + (T 'report.and_more' ($skippedFiles.Count - 10))) }
    Write-Hint (T 'b.report.see_log' $artifacts.ErrorLog)
}

if (-not $finalOk) {
    $reason = if ($verifyState -eq 'failed') { T 'b.error.verify_failed' } else { Get-ArchiverExitMessage $result.ExitCode }
    Write-Host ''
    Write-Err (T 'b.error.failed' $reason)
    foreach ($line in @($result.Issues.Other | Select-Object -First 5)) { Write-Hint "    $line" }
} else {
    Write-Host ''
    Write-Text (T 'b.next.title')
    $kitReady = ($kitResult -and $kitResult.Ok) -or ($kit.State -eq 'Ready')
    Write-Hint (T 'b.next.1')
    Write-Hint $(if ($kitReady) { T 'b.next.2_kit' (Join-Path $kit.Path 'Migrator.bat') } else { T 'b.next.2' })
    Write-Hint (T 'b.next.3')
}

if ($interactive) {
    # The failure is already on screen; do not make the menu print it twice.
    Wait-Enter
    return
}

if (-not $finalOk) {
    throw (T 'b.error.failed' $(if ($verifyState -eq 'failed') { T 'b.error.verify_failed' } else { Get-ArchiverExitMessage $result.ExitCode }))
}
