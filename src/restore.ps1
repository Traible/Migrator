#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Archive','WindowsOld')]
    [string]$Method,

    [string]$Archive,
    [string]$SourceUser,
    [string]$TargetUser,
    [string]$TargetPath,
    [switch]$CreateUser,
    [switch]$NonInteractive,
    [switch]$Verify,
    [switch]$NoVerify,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in 'Core', 'UI', 'Archive', 'Browsers', 'Kit') {
    Import-Module (Join-Path $toolRoot "src\lib\Migrator.$module.psm1") -Force
}

$config = Get-MigratorConfig
$isAdmin = Test-IsAdmin
$interactive = -not $NonInteractive

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$logRoot = Resolve-MigratorPath $config.LogRoot
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$script:RestoreLog = Join-Path $logRoot ('restore-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))

function Write-RestoreLog {
    param([AllowEmptyString()][string]$Message)
    try { Write-LogLine -Path $script:RestoreLog -Message $Message } catch { }
}

Write-RestoreLog "Restore session started. user=$env:USERNAME computer=$env:COMPUTERNAME admin=$isAdmin"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Get-UsersRoot { return (Join-Path $env:SystemDrive 'Users') }

function Assert-SafeTargetPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Equals($root.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw (T 'r.error.target_root' $full)
    }
    if (Test-PathWithin -Child $full -Parent ([IO.Path]::GetFullPath($env:WINDIR))) {
        throw (T 'r.error.target_windows' $full)
    }

    $usersRoot = (Get-UsersRoot).TrimEnd('\')
    if ($full.Equals($usersRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw (T 'r.error.target_users_root' $usersRoot)
    }
    if (-not (Test-PathWithin -Child $full -Parent $usersRoot) -and -not (Get-ProfileByPath $full)) {
        throw (T 'r.error.target_not_profile' $usersRoot $full)
    }

    $reserved = @('Public','Default','Default User','All Users','DefaultAppPool','WDAGUtilityAccount')
    $parent = Split-Path -Parent $full
    if ($parent -and $parent.TrimEnd('\').Equals($usersRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $full) -in $reserved) {
        throw (T 'r.error.target_reserved' $full)
    }
}

function Confirm-Continue {
    # Non-interactive runs take the default: routine questions default to
    # yes, risky ones to no.
    param([Parameter(Mandatory)][string]$Question, [bool]$Default = $false)
    if ($NonInteractive) { return $Default }
    return (Read-YesNo -Prompt $Question -Default $Default)
}

function Close-BrowsersForRestore {
    $running = @(Get-RunningBrowsers)
    if ($running.Count -eq 0) { return }

    Write-Host ''
    Write-Warn (T 'r.browsers.running' (($running.ProcessName | Sort-Object -Unique) -join ', '))
    Write-Hint (T 'r.browsers.hint')
    if ($NonInteractive) { return }
    if (-not (Read-YesNo (T 'r.browsers.ask_close') $true)) { return }

    [void](Stop-RunningBrowsers)
    if (@(Get-RunningBrowsers).Count -gt 0 -and (Read-YesNo (T 'r.browsers.ask_force') $false)) {
        [void](Stop-RunningBrowsers -Force)
    }
}

function Write-SkippedFiles {
    param([string[]]$Files, [string]$LogPath)
    if (-not $Files -or $Files.Count -eq 0) { return }
    Write-Host ''
    Write-Warn (T 'r.report.skipped_explain')
    foreach ($file in @($Files | Select-Object -First 10)) { Write-Hint "    $file" }
    if ($Files.Count -gt 10) { Write-Hint ('    ' + (T 'report.and_more' ($Files.Count - 10))) }
    if ($LogPath) { Write-Hint (T 'b.report.see_log' $LogPath) }
}

function Show-AfterRestoreNotes {
    param([Parameter(Mandatory)]$Target)
    Write-Host ''
    Write-Text (T 'r.next.title')
    Write-Hint (T 'r.next.1')
    Write-Hint (T 'r.next.2')
    Write-Hint (T 'r.next.3')
    Write-Hint (T 'r.next.4')
    if ($Target.IsNew) { Write-Hint (T 'r.next.new_user' $Target.Name) }
}

# ---------------------------------------------------------------------------
# Archive selection
# ---------------------------------------------------------------------------
function Select-ArchiveMetadata {
    param([string]$ArchivePath)

    if ($ArchivePath) {
        $resolved = $ArchivePath.Trim().Trim('"')
        if (-not [IO.Path]::IsPathRooted($resolved)) {
            $resolved = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $resolved))
        }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw (T 'r.error.archive_missing' $resolved) }
        if ($resolved -notmatch '\.(7z|rar)$') { throw (T 'r.error.archive_type' $resolved) }
        return Get-ArchiveMetadata -ArchivePath $resolved
    }

    $folder = Resolve-MigratorPath $config.BackupRoot

    while ($true) {
        $archives = @(Get-ArchiveList -BackupRoot $folder)

        if ($NonInteractive) {
            if ($archives.Count -eq 1) { return $archives[0] }
            if ($archives.Count -eq 0) { throw (T 'r.error.no_archives' $folder) }
            throw (T 'r.error.many_archives' $folder)
        }

        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $archives) {
            $user = if ($item.SourceUser) { $item.SourceUser } else { T 'unit.unknown' }
            $mode = if ($item.Mode) { $item.Mode } else { '?' }
            $items.Add((New-MenuItem -Value $item -Label $item.ArchiveName -Hint (T 'r.archive.hint' `
                $item.ArchiveTime.ToString('yyyy-MM-dd HH:mm') $user $mode (Format-Size $item.ArchiveBytes))))
        }
        $items.Add((New-MenuItem -Value 'other' -Label (T 'r.archive.other') -Key 'O'))

        Write-Host ''
        if ($archives.Count -eq 0) { Write-Warn (T 'r.archive.none_in' $folder) }
        $choice = Show-Menu -Title (T 'r.archive.select' $folder) -Items @($items) -AllowCancel
        if ($null -eq $choice) { return $null }
        if ($choice -isnot [string]) { return $choice }

        $entered = Read-Line (T 'r.archive.enter_path')
        if ([string]::IsNullOrWhiteSpace($entered)) { continue }
        $entered = [Environment]::ExpandEnvironmentVariables($entered.Trim().Trim('"'))
        if (Test-Path -LiteralPath $entered -PathType Container) {
            $folder = [IO.Path]::GetFullPath($entered)
        } elseif (Test-Path -LiteralPath $entered -PathType Leaf) {
            return Select-ArchiveMetadata -ArchivePath $entered
        } else {
            Write-Err (T 'r.error.no_such_path' $entered)
        }
    }
}

# ---------------------------------------------------------------------------
# Target selection
# ---------------------------------------------------------------------------
function New-TargetObject {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LocalPath,
        [string]$SID,
        [bool]$IsCurrent = $false,
        [bool]$IsNew = $false,
        [bool]$Loaded = $false,
        [string]$Note = ''
    )
    return [pscustomobject]@{
        Name      = $Name
        LocalPath = [IO.Path]::GetFullPath($LocalPath).TrimEnd('\')
        SID       = $SID
        IsCurrent = $IsCurrent
        IsNew     = $IsNew
        Loaded    = $Loaded
        Note      = $Note
    }
}

function Initialize-ProfileFolder {
    param([Parameter(Mandatory)][string]$Path, [string]$SID, [string]$UserName)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
    $account = if ($SID) { "*$SID" } else { $UserName }
    if (-not $account) { return }

    Write-Hint (T 'r.user.granting' $Path)
    & icacls.exe $Path '/grant' "$($account):(OI)(CI)F" '/T' '/C' '/Q' 2>&1 | Out-Null
    $code = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    if ($code -ne 0) {
        Write-RestoreLog "icacls failed ($code) for $Path account=$account"
        Write-Warn (T 'r.user.grant_failed' $code)
    } else {
        Write-RestoreLog "icacls granted full control on $Path to $account"
    }
}

function New-RestoreLocalUser {
    if (-not $isAdmin) { throw (T 'r.error.user_need_admin') }

    $usersRoot = Get-UsersRoot
    $defaultName = $null
    if ($SourceUser -and $SourceUser -notmatch '^(Public|Default|Default User|All Users)$') {
        $defaultName = New-SafeFileName $SourceUser
    }

    Write-Host ''
    $prompt = T 'r.user.name_prompt'
    if ($defaultName) { $prompt += " [$defaultName]" }
    $name = Read-Line $prompt
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $defaultName }
    if ([string]::IsNullOrWhiteSpace($name)) { throw (T 'r.error.user_name_required') }

    $name = $name.Trim()
    if ($name.Length -gt 20) { throw (T 'r.error.user_name_long') }
    if ($name -notmatch '^[\p{L}\p{N}._-]+$' -or $name.EndsWith('.')) { throw (T 'r.error.user_name_chars') }

    $account = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    $created = $false

    if (-not $account) {
        Write-Host ('  ' + (T 'r.user.password' $name) + ': ') -NoNewline
        $password = Read-Host -AsSecureString
        Write-Host ('  ' + (T 'r.user.password_confirm' $name) + ': ') -NoNewline
        $confirm = Read-Host -AsSecureString
        $plain = [Net.NetworkCredential]::new('', $password).Password
        if ($plain -ne [Net.NetworkCredential]::new('', $confirm).Password) { throw (T 'r.error.password_mismatch') }
        if ($plain.Length -lt 4) { throw (T 'r.error.password_short') }

        Write-Hint (T 'r.user.creating' $name)
        try {
            $account = New-LocalUser -Name $name -Password $password -FullName $name `
                -Description 'Profile restored by Migrator' -PasswordNeverExpires -ErrorAction Stop
            $created = $true
        } catch {
            throw (T 'r.error.user_create' $name $_.Exception.Message)
        }

        try {
            $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545' -ErrorAction Stop
            Add-LocalGroupMember -Group $usersGroup -Member $name -ErrorAction SilentlyContinue
        } catch {
            Write-RestoreLog "Could not add $name to Users group: $($_.Exception.Message)"
        }
        Write-RestoreLog "Created local user $name"
    } else {
        Write-Warn (T 'r.user.exists' $name)
    }

    $sid = $null
    try { $sid = [string](Get-LocalUser -Name $name -ErrorAction Stop).SID.Value } catch { }

    $profile = Get-ProfileByName $name -Refresh
    if ($profile) {
        return New-TargetObject -Name $profile.Name -LocalPath $profile.LocalPath -SID $profile.SID `
            -IsNew $created -Loaded ([bool]$profile.Loaded) -Note (T 'r.note.profile_exists')
    }

    $profilePath = Join-Path $usersRoot $name
    if (Test-Path -LiteralPath $profilePath -PathType Container) {
        Write-Host ''
        Write-Warn (T 'r.user.folder_exists' $profilePath)
        if (Read-YesNo (T 'r.user.ask_use_folder') $false) {
            Initialize-ProfileFolder -Path $profilePath -SID $sid -UserName $name
            return New-TargetObject -Name $name -LocalPath $profilePath -SID $sid -IsNew $created `
                -Note (T 'r.note.folder_existing')
        }
        throw (T 'r.error.choose_other_name')
    }

    Write-Host ''
    Write-Warn (T 'r.user.first_signin')
    Write-Hint (T 'r.user.step1' $name)
    Write-Hint (T 'r.user.step2')
    Write-Hint (T 'r.user.step3')

    while ($true) {
        $action = Show-Menu -Title (T 'r.user.wait_title') -AllowCancel -Items @(
            (New-MenuItem -Value 'check' -Label (T 'r.user.check'))
            (New-MenuItem -Value 'skip' -Label (T 'r.user.skip') -Hint (T 'r.user.skip.hint'))
            (New-MenuItem -Value 'cancel' -Label (T 'ui.cancel') -Key 'Q')
        )
        if (-not $action -or $action -eq 'cancel') {
            Write-RestoreLog "Restore cancelled while waiting for profile of $name"
            return $null
        }
        if ($action -eq 'skip') {
            Initialize-ProfileFolder -Path $profilePath -SID $sid -UserName $name
            Write-RestoreLog "Pre-created profile folder $profilePath without first sign-in"
            return New-TargetObject -Name $name -LocalPath $profilePath -SID $sid -IsNew $created `
                -Note (T 'r.note.precreated')
        }

        $profile = Get-ProfileByName $name -Refresh
        if ($profile) {
            Write-Ok (T 'r.user.detected' $profile.LocalPath)
            return New-TargetObject -Name $profile.Name -LocalPath $profile.LocalPath -SID $profile.SID `
                -IsNew $created -Loaded ([bool]$profile.Loaded) -Note (T 'r.note.initialized')
        }
        Write-Warn (T 'r.user.not_detected')
    }
}

function Select-RestoreTarget {
    param([string]$ArchiveSourceUser)

    if ($TargetPath) {
        $full = [IO.Path]::GetFullPath($TargetPath.Trim().Trim('"')).TrimEnd('\')
        Assert-SafeTargetPath -Path $full
        $existing = Get-ProfileByPath $full
        if ($existing) {
            return New-TargetObject -Name $existing.Name -LocalPath $full -SID $existing.SID `
                -IsCurrent ([bool]$existing.IsCurrent) -Loaded ([bool]$existing.Loaded) -Note (T 'r.note.explicit')
        }
        # A custom path inside the current user's profile is still the current
        # user; no Administrator rights are needed.
        $current = Get-CurrentUserProfile
        if ($current -and (Test-PathWithin -Child $full -Parent $current.LocalPath)) {
            return New-TargetObject -Name (Split-Path -Leaf $full) -LocalPath $full -SID $current.SID `
                -IsCurrent $true -Loaded $true -Note (T 'r.note.explicit')
        }
        return New-TargetObject -Name (Split-Path -Leaf $full) -LocalPath $full -Note (T 'r.note.explicit')
    }

    if ($TargetUser) {
        $profile = Get-ProfileByName $TargetUser
        if ($profile) {
            return New-TargetObject -Name $profile.Name -LocalPath $profile.LocalPath -SID $profile.SID `
                -IsCurrent ([bool]$profile.IsCurrent) -Loaded ([bool]$profile.Loaded -or [bool]$profile.IsCurrent)
        }
        if ($CreateUser) {
            if ($NonInteractive) { throw (T 'r.error.create_noninteractive') }
            return New-RestoreLocalUser
        }
        throw (T 'error.profile_not_found' $TargetUser ((Get-UserProfiles).Name -join ', '))
    }

    if ($NonInteractive) { throw (T 'r.error.need_target') }

    $currentProfile = Get-CurrentUserProfile
    $currentName = if ($currentProfile) { $currentProfile.Name } else { $env:USERNAME }

    if ($ArchiveSourceUser -and $ArchiveSourceUser -ne $currentName) {
        Write-Host ''
        Write-Hint (T 'r.target.name_differs' $ArchiveSourceUser)
    }

    $choice = Show-Menu -Title (T 'r.target.title') -AllowCancel -Items @(
        (New-MenuItem -Value 'current' -Label (T 'r.target.current' $currentName) -Hint (T 'r.target.current.hint'))
        (New-MenuItem -Value 'existing' -Label (T 'r.target.existing') -Hint (T 'r.target.existing.hint'))
        (New-MenuItem -Value 'new' -Label (T 'r.target.new') -Hint (T 'r.target.new.hint'))
    )

    switch ($choice) {
        'current' {
            if ($currentProfile) {
                return New-TargetObject -Name $currentProfile.Name -LocalPath $currentProfile.LocalPath `
                    -SID $currentProfile.SID -IsCurrent $true -Loaded $true
            }
            Assert-SafeTargetPath -Path $env:USERPROFILE
            return New-TargetObject -Name $env:USERNAME -LocalPath $env:USERPROFILE -IsCurrent $true -Loaded $true
        }
        'existing' {
            $profiles = @(Get-UserProfiles | Sort-Object Name)
            if ($profiles.Count -eq 0) { throw (T 'error.no_profiles') }
            $items = @(foreach ($item in $profiles) {
                $label = $item.Name
                if ($item.IsCurrent) { $label += '  ' + (T 'profile.current') }
                elseif ($item.Loaded) { $label += '  ' + (T 'profile.loaded') }
                New-MenuItem -Value $item -Label $label -Hint $item.LocalPath
            })
            $profile = Show-Menu -Title (T 'r.target.select_profile') -Items $items -AllowCancel
            if (-not $profile) { return $null }
            return New-TargetObject -Name $profile.Name -LocalPath $profile.LocalPath -SID $profile.SID `
                -IsCurrent ([bool]$profile.IsCurrent) -Loaded ([bool]$profile.Loaded -or [bool]$profile.IsCurrent)
        }
        'new' { return New-RestoreLocalUser }
        default { return $null }
    }
}

function Test-TargetReady {
    # Shared checks for both restore methods. Returns $false to cancel.
    param([Parameter(Mandatory)]$Target)

    Assert-SafeTargetPath -Path $Target.LocalPath

    if ($Target.IsCurrent) {
        Write-Host ''
        Write-Warn (T 'r.warn.current')
        Write-Hint (T 'r.hint.current')
    } elseif ($Target.Loaded) {
        Write-Host ''
        Write-Warn (T 'r.warn.loaded')
        Write-Hint (T 'r.hint.loaded')
        if (-not $Force -and -not (Confirm-Continue (T 'r.ask.loaded_continue') $false)) {
            Write-Warn (T 'r.cancelled_loaded')
            return $false
        }
    }

    Close-BrowsersForRestore

    if (-not $Target.IsCurrent -and -not $isAdmin) { throw (T 'r.error.need_admin') }
    return $true
}

# ---------------------------------------------------------------------------
# Restore from an archive
# ---------------------------------------------------------------------------
function Invoke-ArchiveRestoreFlow {
    $archiver = Get-ArchiverPath
    if (-not $archiver) { throw (T 'error.archiver_not_found') }

    Write-Section (T 'r.archive.section')
    $metadata = Select-ArchiveMetadata -ArchivePath $Archive
    if (-not $metadata) { return }

    if ($metadata.Format -eq 'rar' -and (Split-Path -Leaf $archiver) -ne '7z.exe') {
        throw (T 'r.error.rar_needs_full')
    }

    if (-not $metadata.HasManifest) {
        Write-Host ''
        Write-Warn (T 'r.warn.no_manifest')
        Write-Hint (T 'r.hint.no_manifest')
        if (-not (Confirm-Continue (T 'r.ask.continue_archive') $true)) { return }
    }

    $sourceUser = $metadata.SourceUser
    $target = Select-RestoreTarget -ArchiveSourceUser $sourceUser
    if (-not $target) { return }
    if (-not (Test-TargetReady -Target $target)) { return }

    # File list: content size, file count and the folders to skip.
    Write-Host ''
    Write-Hint (T 'r.reading_list')
    $content = Get-ArchiveContentInfo -ArchiverPath $archiver -ArchivePath $metadata.ArchivePath
    if ($content.ExitCode -ne 0) {
        Write-RestoreLog "Cannot read the archive file list: exit=$($content.ExitCode)"
        throw (T 'r.error.cannot_open' (Get-ArchiverExitMessage $content.ExitCode))
    }

    $excludeMasks = @(Get-RestoreExcludeMasks)
    $excludePaths = @(Select-ExcludedArchiveFolders -Directories $content.Directories -ExcludeMasks $excludeMasks)
    $nameMasks = @((Split-ExcludeMasks -Masks $excludeMasks).FileNameMasks)

    $freeBytes = Get-FreeSpaceBytes -Path $target.LocalPath
    $lowSpace = ($null -ne $freeBytes -and $content.Bytes -gt 0 -and $freeBytes -lt $content.Bytes)

    $expectedHash = if ($metadata.Manifest -and $metadata.Manifest['archiveSha256']) { [string]$metadata.Manifest['archiveSha256'] } else { $null }
    $verifyFirst = if ($NoVerify) { $false } elseif ($Verify) { $true } else { [bool]$config.VerifyBeforeRestore }

    $plan = [ordered]@{}
    $plan[(T 'f.archive')]     = $metadata.ArchiveName
    $plan[(T 'f.created')]     = $metadata.ArchiveTime.ToString('yyyy-MM-dd HH:mm')
    $plan[(T 'f.source_user')] = if ($sourceUser) { $sourceUser } else { T 'unit.unknown' }
    $plan[(T 'f.content')]     = T 'b.plan.size' (Format-Size $content.Bytes) $content.Files
    $plan[(T 'f.target_user')] = $target.Name
    $plan[(T 'f.target')]      = $target.LocalPath
    $plan[(T 'f.free_space')]  = if ($lowSpace) { @((Format-Size $freeBytes), 'Warn') } else { Format-Size $freeBytes }
    if ($target.Note) { $plan[(T 'f.note')] = $target.Note }
    Write-SummaryBox -Title (T 'r.plan.title') -Fields $plan

    Write-Hint (T 'r.plan.overwrite')
    if ($lowSpace) { Write-Warn (T 'r.warn.low_space') }

    if ($interactive) {
        $action = Show-Menu -Title (T 'r.confirm.title') -AllowCancel -Default $(if ($verifyFirst) { 1 } else { 0 }) -Items @(
            (New-MenuItem -Value 'start' -Label (T 'r.confirm.start') -Hint (T 'r.confirm.start.hint'))
            (New-MenuItem -Value 'verify' -Label (T 'r.confirm.verify') -Hint (T 'r.confirm.verify.hint'))
            (New-MenuItem -Value 'cancel' -Label (T 'ui.cancel') -Key 'Q')
        )
        if (-not $action -or $action -eq 'cancel') {
            Write-Warn (T 'r.cancelled')
            return
        }
        $verifyFirst = ($action -eq 'verify')
    } elseif ($lowSpace -and -not $Force) {
        throw (T 'r.error.low_space')
    }

    Write-Host ''
    if ($verifyFirst) {
        $check = Invoke-ArchiveCheck -ArchiverPath $archiver -ArchivePath $metadata.ArchivePath `
            -Test -Sha256:([bool]$expectedHash) -Activity (T 'b.activity_verify')
        $testExit = [int]$check.TestResult.ExitCode
        $hashOk = (-not $expectedHash) -or ([string]$check.Sha256).Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)
        Write-RestoreLog "Archive test exit=$testExit sha256=$(if ($expectedHash) { if ($hashOk) { 'match' } else { 'MISMATCH' } } else { 'n/a' })"

        if ($testExit -ne 0 -or -not $hashOk) {
            Write-Err $(if ($testExit -ne 0) { T 'r.error.verify_failed' (Get-ArchiverExitMessage $testExit) } else { T 'r.error.sha_mismatch' })
            if (-not (Confirm-Continue (T 'r.ask.restore_anyway') $false)) { return }
        } else {
            Write-Ok $(if ($expectedHash) { T 'r.verify.ok_sha' } else { T 'r.verify.ok' })
        }
    } else {
        Write-Hint (T 'r.verify.skipped')
        Write-RestoreLog 'Pre-restore verification skipped; relying on per-file checksums during extraction.'
    }

    New-Item -ItemType Directory -Force -Path $target.LocalPath | Out-Null

    Write-RestoreLog "Archive restore started: archive=$($metadata.ArchivePath) target=$($target.LocalPath) user=$($target.Name) excludedFolders=$($excludePaths.Count)"
    $result = Expand-ProfileArchive -ArchiverPath $archiver -ArchivePath $metadata.ArchivePath `
        -TargetPath $target.LocalPath -ExcludePaths $excludePaths -ExcludeNameMasks $nameMasks `
        -TotalBytes $content.Bytes -Activity (T 'r.activity' $target.Name)

    $success = ($result.Outcome -ne 'Failed')
    $skippedFiles = @($result.SkippedFiles)
    $hasWarnings = ($result.Outcome -eq 'Warnings') -or ($skippedFiles.Count -gt 0)
    $resultText = if (-not $success) { T 'result.failed' } elseif ($hasWarnings) { T 'result.warnings' } else { T 'result.success' }
    $resultColor = if (-not $success) { 'Error' } elseif ($hasWarnings) { 'Warn' } else { 'Ok' }
    $speed = if ($result.Duration.TotalSeconds -gt 0) { [int64]($content.Bytes / $result.Duration.TotalSeconds) } else { 0 }

    $errorLog = $null
    if ($result.StdErr.Trim()) {
        $errorLog = Join-Path $logRoot ('restore-errors-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        Write-TextFile -Path $errorLog -Lines @($result.StdErr)
    }

    $report = [ordered]@{}
    $report[(T 'f.result')]   = @($resultText, $resultColor)
    $report[(T 'f.target')]   = '{0}  ({1})' -f $target.LocalPath, $target.Name
    $report[(T 'f.duration')] = T 'b.report.duration' (Format-Duration $result.Duration) (Format-Size $speed) (T 'unit.sec')
    $report[(T 'f.skipped')]  = if ($skippedFiles.Count -gt 0) { @((T 'b.report.skipped' $skippedFiles.Count), 'Warn') } else { T 'b.report.none' }
    $report[(T 'f.log')]      = $script:RestoreLog

    Write-RestoreLog "Archive restore finished: outcome=$($result.Outcome) exit=$($result.ExitCode) duration=$([math]::Round($result.Duration.TotalSeconds,1))s skipped=$($skippedFiles.Count)"
    foreach ($section in @($plan, $report)) {
        foreach ($label in $section.Keys) {
            $value = $section[$label]
            if ($value -is [array]) { $value = $value[0] }
            Write-RestoreLog ('{0}: {1}' -f $label, $value)
        }
    }

    Write-SummaryBox -Title (T 'r.report.title') -Fields $report -Color $resultColor
    Write-SkippedFiles -Files $skippedFiles -LogPath $errorLog

    if (-not $success) {
        Write-Host ''
        $reason = if ($result.Issues.DataErrors.Count -gt 0) { T 'r.error.damaged' } else { Get-ArchiverExitMessage $result.ExitCode }
        Write-Err (T 'r.error.failed' $reason)
        foreach ($line in @(@($result.Issues.DataErrors) + @($result.Issues.Other) | Select-Object -First 5)) { Write-Hint "    $line" }
        if ($NonInteractive) { throw (T 'r.error.failed' $reason) }
        return
    }

    Show-AfterRestoreNotes -Target $target
}

# ---------------------------------------------------------------------------
# Restore from Windows.old
# ---------------------------------------------------------------------------
function Select-WindowsOldSource {
    $oldUsersRoot = Join-Path $env:SystemDrive 'Windows.old\Users'

    if ($SourceUser) {
        if ($SourceUser -match '[\\/]' -or $SourceUser -in @('.', '..')) { throw (T 'r.old.error.bad_name' $SourceUser) }
        $candidate = Join-Path $oldUsersRoot $SourceUser
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { throw (T 'r.old.error.not_found' $candidate) }
        return Get-Item -LiteralPath $candidate
    }
    if ($NonInteractive) { throw (T 'r.old.error.need_source') }
    if (-not (Test-Path -LiteralPath $oldUsersRoot -PathType Container)) { throw (T 'r.old.error.no_windows_old' $oldUsersRoot) }

    $excluded = @('All Users','Default','Default User','Public','DefaultAppPool','WDAGUtilityAccount')
    $users = @(Get-ChildItem -LiteralPath $oldUsersRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $excluded } | Sort-Object Name)
    if ($users.Count -eq 0) { throw (T 'r.old.error.no_users' $oldUsersRoot) }

    $items = @($users | ForEach-Object { New-MenuItem -Value $_ -Label $_.Name -Hint $_.FullName })
    return (Show-Menu -Title (T 'r.old.select' $oldUsersRoot) -Items $items -AllowCancel)
}

function Invoke-RobocopyRestore {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$LogPath,
        [string[]]$ExcludeDirectories = @(),
        [string[]]$ExcludeFiles = @(),
        [int64]$TotalBytes = 0,
        [string]$Activity = 'robocopy'
    )

    # Every copied file is written to the log as "<class> <TAB> <bytes> <TAB> <path>",
    # so progress is read from the log instead of rescanning the target folder.
    # /UNILOG keeps non-ASCII file names readable; /XX hides target-only files.
    $arguments = @(
        $Source, $Destination
        '/E', '/COPY:DAT', '/DCOPY:DAT', '/MT:16', '/R:1', '/W:1', '/XJ', '/XX'
        '/NDL', '/NJH', '/NJS', '/NP', '/FP', '/BYTES'
        "/UNILOG:$LogPath"
    )
    if ($ExcludeDirectories.Count -gt 0) { $arguments += '/XD'; $arguments += $ExcludeDirectories }
    if ($ExcludeFiles.Count -gt 0) { $arguments += '/XF'; $arguments += $ExcludeFiles }

    $commandLine = ConvertTo-NativeCommandLine -Arguments $arguments
    Write-RestoreLog "Robocopy command: robocopy.exe $commandLine"

    $sizeRegex = [regex]'\t\s*(\d+)\t'
    $progress = New-ProgressState -Activity $Activity -TotalBytes ([Math]::Max(1L, $TotalBytes))
    $started = Get-Date
    $process = Start-Process -FilePath 'robocopy.exe' -ArgumentList $commandLine -NoNewWindow -PassThru -ErrorAction Stop

    $copiedBytes = 0L
    $pending = ''
    $reader = $null
    $buffer = [char[]]::new(65536)

    try {
        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500

            if (-not $reader -and (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
                try {
                    $stream = [IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::Unicode, $true)
                } catch { $reader = $null }
            }

            if ($reader) {
                # Read only what robocopy appended since the last poll.
                $chunk = [Text.StringBuilder]::new($pending)
                while (($count = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    [void]$chunk.Append($buffer, 0, $count)
                }
                $text = $chunk.ToString()
                $lastNewLine = $text.LastIndexOf("`n")
                if ($lastNewLine -ge 0) {
                    foreach ($match in $sizeRegex.Matches($text.Substring(0, $lastNewLine))) {
                        $copiedBytes += [int64]$match.Groups[1].Value
                    }
                    $pending = $text.Substring($lastNewLine + 1)
                } else {
                    $pending = $text
                }
            }

            Update-ProgressState -State $progress -BytesDone $copiedBytes
        }
    } finally {
        if ($reader) { $reader.Dispose() }
    }

    $process.WaitForExit()
    Complete-ProgressState -State $progress

    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Duration = (Get-Date) - $started
    }
}

function Get-RobocopyExcludeDirectories {
    # Robocopy takes exact folders, so the same mask logic as the archive
    # backup is used: one scan resolves the masks into real paths.
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)]$Scan)
    return @($Scan.ExcludedDirectories | ForEach-Object { Join-Path $SourceRoot $_ })
}

function Invoke-WindowsOldRestoreFlow {
    Write-Section (T 'r.old.section')

    $source = Select-WindowsOldSource
    if (-not $source) { return }

    $target = Select-RestoreTarget -ArchiveSourceUser $source.Name
    if (-not $target) { return }
    if (-not (Test-TargetReady -Target $target)) { return }

    if (Test-PathWithin -Child $target.LocalPath -Parent $source.FullName) { throw (T 'r.old.error.target_inside') }

    Write-Host ''
    Write-Hint (T 'r.old.scanning')
    $masks = @(Get-ModeExcludeMasks -Mode Full)
    $scan = Measure-ProfileTree -Path $source.FullName -ExcludeMasks $masks
    $excludeDirectories = @(Get-RobocopyExcludeDirectories -SourceRoot $source.FullName -Scan $scan)
    $excludeFiles = @((Split-ExcludeMasks -Masks $masks).FileNameMasks)

    $freeBytes = Get-FreeSpaceBytes -Path $target.LocalPath
    $lowSpace = ($null -ne $freeBytes -and $scan.Bytes -gt 0 -and $freeBytes -lt $scan.Bytes)

    $plan = [ordered]@{}
    $plan[(T 'f.source')]      = $source.FullName
    $plan[(T 'f.content')]     = T 'b.plan.size' (Format-Size $scan.Bytes) $scan.Files
    $plan[(T 'f.excluded')]    = T 'b.plan.excluded' $excludeDirectories.Count $excludeFiles.Count
    $plan[(T 'f.target_user')] = $target.Name
    $plan[(T 'f.target')]      = $target.LocalPath
    $plan[(T 'f.free_space')]  = if ($lowSpace) { @((Format-Size $freeBytes), 'Warn') } else { Format-Size $freeBytes }
    if ($target.Note) { $plan[(T 'f.note')] = $target.Note }
    Write-SummaryBox -Title (T 'r.plan.title') -Fields $plan
    Write-Hint (T 'r.plan.overwrite')
    if ($lowSpace) { Write-Warn (T 'r.warn.low_space') }

    if (-not (Confirm-Continue (T 'r.ask.start') $true)) {
        Write-Warn (T 'r.cancelled')
        return
    }

    New-Item -ItemType Directory -Force -Path $target.LocalPath | Out-Null
    $robocopyLog = Join-Path $logRoot ('restore-robocopy-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    Write-RestoreLog "Windows.old restore started: source=$($source.FullName) target=$($target.LocalPath) user=$($target.Name) excludedDirs=$($excludeDirectories.Count)"

    Write-Host ''
    $result = Invoke-RobocopyRestore -Source $source.FullName -Destination $target.LocalPath `
        -LogPath $robocopyLog -ExcludeDirectories $excludeDirectories -ExcludeFiles $excludeFiles `
        -TotalBytes $scan.Bytes -Activity (T 'r.activity' $target.Name)

    # Robocopy: 0-7 = success with details, 8+ = at least one failure.
    $success = $result.ExitCode -lt 8
    $speed = if ($result.Duration.TotalSeconds -gt 0) { [int64]($scan.Bytes / $result.Duration.TotalSeconds) } else { 0 }
    Write-RestoreLog "Windows.old restore finished: robocopy exit=$($result.ExitCode) duration=$([math]::Round($result.Duration.TotalSeconds,1))s"

    $report = [ordered]@{}
    $report[(T 'f.result')]   = if ($success) { @((T 'result.success'), 'Ok') } else { @((T 'result.failed'), 'Error') }
    $report[(T 'f.target')]   = '{0}  ({1})' -f $target.LocalPath, $target.Name
    $report[(T 'f.duration')] = T 'b.report.duration' (Format-Duration $result.Duration) (Format-Size $speed) (T 'unit.sec')
    $report[(T 'f.log')]      = $robocopyLog
    Write-SummaryBox -Title (T 'r.report.title') -Fields $report -Color $(if ($success) { 'Ok' } else { 'Error' })

    if (-not $success) {
        Write-Host ''
        Write-Err (T 'r.old.error.failed' $result.ExitCode)
        if ($NonInteractive) { throw (T 'r.old.error.failed' $result.ExitCode) }
        return
    }

    Show-AfterRestoreNotes -Target $target
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    if ($interactive) {
        Clear-Screen
        Write-Banner (T 'r.subtitle')
    }

    if (-not $Method) {
        if ($NonInteractive) { throw (T 'r.error.need_method') }
        $Method = Show-Menu -Title (T 'r.method.title') -AllowCancel -Items @(
            (New-MenuItem -Value 'Archive' -Label (T 'r.method.archive') -Hint (T 'r.method.archive.hint'))
            (New-MenuItem -Value 'WindowsOld' -Label (T 'r.method.old') -Hint (T 'r.method.old.hint'))
        )
        if (-not $Method) { return }
    }

    if ($Method -eq 'Archive') { Invoke-ArchiveRestoreFlow } else { Invoke-WindowsOldRestoreFlow }
} catch {
    $message = $_.Exception.Message
    Write-RestoreLog "ERROR: $message"
    if ($_.ScriptStackTrace) { Write-RestoreLog $_.ScriptStackTrace }
    Write-Host ''
    Write-Err $message
    Write-Hint (T 'r.see_log' $script:RestoreLog)
    if ($interactive) { Wait-Enter; return }
    exit 1
}

Write-RestoreLog 'Restore session finished.'
if ($interactive) { Wait-Enter }
