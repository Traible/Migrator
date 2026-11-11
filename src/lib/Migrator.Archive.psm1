#Requires -Version 7.0
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Migrator.Archive.psm1
# The only module that knows about the archiver (7-Zip).
# 7-Zip is free software (GNU LGPL) and creates .7z; it also extracts the
# .rar archives made by Migrator 2.0.x.
# ---------------------------------------------------------------------------

function Get-ArchiverPath {
    [CmdletBinding()]
    param()

    $config = Get-MigratorConfig
    $candidates = @(
        (Resolve-MigratorPath ([string]$config.ArchiverPath))
        (Resolve-MigratorPath 'Tools\7-Zip\7z.exe')
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
    )
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe') }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }

    foreach ($name in @('7z.exe', '7za.exe', '7zr.exe')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    return $null
}

function Get-ArchiverVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiverPath)
    try {
        $version = (Get-Item -LiteralPath $ArchiverPath).VersionInfo.ProductVersion
        if ($version) { return "7-Zip $version" }
    } catch { }
    return '7-Zip'
}

function Get-ArchiverExitMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ExitCode)
    switch ($ExitCode) {
        0   { T 'exit.0' }
        1   { T 'exit.1' }
        2   { T 'exit.2' }
        7   { T 'exit.7' }
        8   { T 'exit.8' }
        255 { T 'exit.255' }
        default { T 'exit.other' $ExitCode }
    }
}

function ConvertFrom-ArchiverProgress {
    # Parses the last progress mark of 7-Zip's stdout:
    #     "\r 45% 1234 + Documents\report.docx"
    # -> percent, number of files processed so far, current file.
    # Marks start a line, so a '%' inside a file name is never mistaken for one.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $found = [regex]::Matches(($Text ?? ''), '(?:^|[\r\n\x08])[ \t]*(\d{1,3})%(?:[ \t]+(\d+))?(?:[ \t]+[-+TUR=.][ \t]+([^\r\n\x08]*))?')
    if ($found.Count -eq 0) { return $null }
    $last = $found[$found.Count - 1]

    # The newest mark may still be half-written; take the file count and name
    # from the previous one when it has none yet.
    $files = $null
    $current = ''
    for ($i = $found.Count - 1; $i -ge 0 -and $i -ge $found.Count - 3; $i--) {
        if ($null -eq $files -and $found[$i].Groups[2].Success) { $files = [int64]$found[$i].Groups[2].Value }
        if (-not $current -and $found[$i].Groups[3].Success) { $current = $found[$i].Groups[3].Value.Trim() }
    }

    return [pscustomobject]@{
        Percent = [int]$last.Groups[1].Value
        Files   = $files
        Current = $current
    }
}

function Get-ArchiverProgress {
    # Reads the tail of 7-Zip's stdout file while the archiver is running.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $length = $stream.Length
            if ($length -le 0) { return $null }
            $take = [int][Math]::Min(4096, $length)
            [void]$stream.Seek(-$take, 'End')
            $buffer = [byte[]]::new($take)
            [void]$stream.Read($buffer, 0, $take)
        } finally {
            $stream.Dispose()
        }
        return ConvertFrom-ArchiverProgress -Text ([Text.Encoding]::UTF8.GetString($buffer))
    } catch {
        return $null
    }
}

function Get-ArchiverIssues {
    # Sorts 7-Zip's stderr into files that were skipped (locked / in use) and
    # real data errors (damaged archive).
    [CmdletBinding()]
    param([AllowEmptyString()][string]$StdErr)

    $skipped = [System.Collections.Generic.List[string]]::new()
    $dataErrors = [System.Collections.Generic.List[string]]::new()
    $other = [System.Collections.Generic.List[string]]::new()
    $openError = $false

    $inFileWarnings = $false
    foreach ($raw in @(($StdErr ?? '') -split "`r?`n")) {
        $line = $raw.TrimEnd()
        if (-not $line) { continue }

        if ($line -match '^WARNINGS for files:') { $inFileWarnings = $true; continue }
        if ($line -match '^-{4,}') { $inFileWarnings = $false; continue }

        if ($inFileWarnings) {
            # ".\Documents\locked.bin : The process cannot access the file ..."
            if ($line -match '^(?<path>.+?) : (?<reason>.+)$') {
                $skipped.Add(($Matches['path'] -replace '^\.\\', ''))
            }
            continue
        }

        if ($line -match '^ERROR: Cannot (?:open|delete|create) (?:output )?(?:file|folder|directory) : .* : (?<path>.+)$') {
            $skipped.Add($Matches['path'])
            continue
        }
        if ($line -match '^ERROR: (?<kind>CRC Failed|Data Error|Headers Error|Unexpected end of (?:data|archive)|Unsupported Method|Unavailable data|Is not archive)[^:]*: (?<path>.+)$') {
            $dataErrors.Add(('{0}: {1}' -f $Matches['kind'], $Matches['path']))
            continue
        }
        if ($line -match 'Open ERROR|Cannot open the file as|Unexpected end of archive|Headers Error|Is not archive') {
            $openError = $true
            $other.Add($line)
            continue
        }
        if ($line -match '^(ERROR|WARNING)\b' -and $line -notmatch '^WARNING: Cannot open \d+ file') {
            # The plain "WARNING: <system message>" line is followed by the path
            # and repeated in the "WARNINGS for files" block, so it is not counted.
            if ($line -notmatch '^WARNING: ') { $other.Add($line) }
        }
    }

    return [pscustomobject]@{
        SkippedFiles = @($skipped | Sort-Object -Unique)
        DataErrors   = @($dataErrors)
        Other        = @($other)
        OpenError    = $openError
    }
}

function Get-ArchiveOutcome {
    # Success | Warnings | Failed
    #   add:     exit 1 = some files were locked, the archive is usable.
    #   extract: 7-Zip returns 2 for a locked target file as well as for a
    #            damaged archive, so the error text decides.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)]$Issues
    )

    if ($ExitCode -eq 0) { return 'Success' }
    if ($ExitCode -eq 1) { return 'Warnings' }
    if ($ExitCode -eq 2 -and -not $Issues.OpenError -and $Issues.DataErrors.Count -eq 0 -and
        $Issues.Other.Count -eq 0 -and $Issues.SkippedFiles.Count -gt 0) {
        return 'Warnings'
    }
    return 'Failed'
}

$script:StaleFilesChecked = $false

function Remove-StaleArchiverFile {
    # Deletes temporary files left by a Migrator run that was closed half-way
    # (the window was closed during a backup, so nothing could clean up).
    # A file is stale when the process whose id is in its name no longer
    # exists, or when that id now belongs to a process started after the file
    # was created. Returns the number of files removed.
    [CmdletBinding()]
    param([string]$Path = $env:TEMP)

    $removed = 0
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $removed }
    $files = @(Get-ChildItem -LiteralPath $Path -Filter 'migrator-*' -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        if ($file.Name -notmatch '^migrator-(?:7z|list|ls)-(\d+)-[0-9a-f]{32}\.') { continue }
        $ownerId = [int]$Matches[1]
        if ($ownerId -eq $PID) { continue }
        $alive = $false
        try {
            $owner = Get-Process -Id $ownerId -ErrorAction Stop
            $alive = $true
            try {
                if ($owner.StartTime -gt $file.CreationTime.AddSeconds(5)) { $alive = $false }
            } catch { }   # start time not readable: keep the file
        } catch { }
        if ($alive) { continue }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $removed++
        } catch { }
    }
    return $removed
}
function Invoke-Archiver {
    # Runs 7-Zip, shows progress with speed and remaining time, returns the
    # exit code and the parsed issues.
    #   -TotalBytes  expected amount of data (for speed / remaining time)
    #   -GrowthFile  a file whose size follows the progress (the archive being
    #                written without compression): smoother than 7-Zip's 1% steps
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchiverPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$Activity = '7-Zip',
        [int64]$TotalBytes = 0,
        [int64]$TotalFiles = 0,
        [string]$GrowthFile,
        [switch]$NoProgress
    )

    if (-not (Test-Path -LiteralPath $ArchiverPath -PathType Leaf)) {
        throw (T 'error.archiver_missing' $ArchiverPath)
    }

    if (-not $script:StaleFilesChecked) {
        $script:StaleFilesChecked = $true
        [void](Remove-StaleArchiverFile)
    }

    $pollMs = [int](Get-MigratorConfig).ProgressPollMs
    if ($pollMs -lt 100) { $pollMs = 250 }

    $id = [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $env:TEMP "migrator-7z-$PID-$id.out"
    $stderrPath = Join-Path $env:TEMP "migrator-7z-$PID-$id.err"
    $commandLine = ConvertTo-NativeCommandLine -Arguments $Arguments
    $started = Get-Date
    $progress = New-ProgressState -Activity $Activity -TotalBytes $TotalBytes -TotalFiles $TotalFiles

    try {
        $process = Start-Process -FilePath $ArchiverPath -ArgumentList $commandLine `
            -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath -ErrorAction Stop

        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds $pollMs
            if ($NoProgress) { continue }

            $mark = Get-ArchiverProgress -Path $stdoutPath
            $percent = if ($mark) { $mark.Percent } else { $null }
            $bytesDone = $null
            if ($GrowthFile -and $TotalBytes -gt 0) {
                try {
                    $growth = [IO.FileInfo]::new($GrowthFile)
                    if ($growth.Exists) { $bytesDone = $growth.Length }
                } catch { }
            }
            Update-ProgressState -State $progress -Percent $percent -BytesDone $bytesDone `
                -FilesDone $(if ($mark) { $mark.Files } else { $null }) `
                -Current $(if ($mark) { $mark.Current } else { '' })
        }

        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
        $duration = (Get-Date) - $started
        if (-not $NoProgress) { Complete-ProgressState -State $progress }

        $stderr = ''
        try { $stderr = [IO.File]::ReadAllText($stderrPath, [Text.Encoding]::UTF8) } catch { }
        $issues = Get-ArchiverIssues -StdErr $stderr

        return [pscustomobject]@{
            ExitCode     = $exitCode
            Duration     = $duration
            StdErr       = [string]$stderr
            Issues       = $issues
            SkippedFiles = @($issues.SkippedFiles)
            Outcome      = Get-ArchiveOutcome -ExitCode $exitCode -Issues $issues
            CommandLine  = $commandLine
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function New-ListFile {
    # UTF-8 list file for 7-Zip's -x@ / -xr@ (used with -scsUTF-8).
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)
    $path = Join-Path $env:TEMP ('migrator-list-{0}-{1}.lst' -f $PID, [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllLines($path, [string[]]@($Lines | Where-Object { $_ }), [Text.UTF8Encoding]::new($false))
    return $path
}

function Get-ExcludeArguments {
    # Exact paths go to -x@ (anchored at the archive root); name masks go to
    # -xr@ (any folder). Returns the arguments and the temp files to delete.
    param(
        [string[]]$ExactPaths = @(),
        [string[]]$NameMasks = @()
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $files = [System.Collections.Generic.List[string]]::new()
    $exact = @($ExactPaths | Where-Object { $_ })
    $names = @($NameMasks | Where-Object { $_ })

    if ($exact.Count -gt 0) {
        $list = New-ListFile -Lines $exact
        $files.Add($list)
        $arguments.Add("-x@$list")
    }
    if ($names.Count -gt 0) {
        $list = New-ListFile -Lines $names
        $files.Add($list)
        $arguments.Add("-xr@$list")
    }
    return [pscustomobject]@{ Arguments = @($arguments); Files = @($files) }
}

function New-ProfileArchive {
    # Archives the content of -SourcePath (paths in the archive are relative
    # to it). Exclusions are exact relative paths computed by
    # Measure-ProfileTree plus file-name masks.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchiverPath,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$ArchivePath,
        [string[]]$ExcludePaths = @(),
        [string[]]$ExcludeNameMasks = @(),
        [ValidateRange(0, 9)][int]$Compression = 0,
        [int64]$TotalBytes = 0,
        [int64]$TotalFiles = 0,
        [string]$Activity = '7-Zip',
        [switch]$NoProgress
    )

    $exclude = Get-ExcludeArguments -ExactPaths $ExcludePaths -NameMasks $ExcludeNameMasks
    try {
        $arguments = @(
            'a'
            '-t7z'
            "-mx$Compression"
            '-ssw'          # read files that other programs have open for writing
            '-mtc=on'       # keep creation time
            '-scsUTF-8'     # list files are UTF-8
            '-sccUTF-8'     # console output is UTF-8
            '-bso0'         # no per-file listing
            '-bsp1'         # progress to stdout
            '-y'
        ) + $exclude.Arguments + @(
            $ArchivePath
            ($SourcePath.TrimEnd('\') + '\*')
        )

        $splat = @{
            ArchiverPath = $ArchiverPath
            Arguments    = $arguments
            Activity     = $Activity
            TotalBytes   = $TotalBytes
            TotalFiles   = $TotalFiles
            NoProgress   = $NoProgress
        }
        # Without compression the archive grows byte for byte with the data.
        if ($Compression -eq 0) { $splat.GrowthFile = $ArchivePath }
        return Invoke-Archiver @splat
    } finally {
        foreach ($file in $exclude.Files) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}

function Test-ProfileArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchiverPath,
        [Parameter(Mandatory)][string]$ArchivePath,
        [string]$Activity = '7-Zip',
        [switch]$NoProgress
    )
    $size = 0L
    try { $size = (Get-Item -LiteralPath $ArchivePath).Length } catch { }
    return Invoke-Archiver -ArchiverPath $ArchiverPath -Activity $Activity -TotalBytes $size -NoProgress:$NoProgress `
        -Arguments @('t', '-sccUTF-8', '-bso0', '-bsp1', '-y', $ArchivePath)
}

function Expand-ProfileArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchiverPath,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$TargetPath,
        [string[]]$ExcludePaths = @(),
        [string[]]$ExcludeNameMasks = @(),
        [int64]$TotalBytes = 0,
        [int64]$TotalFiles = 0,
        [string]$Activity = '7-Zip',
        [switch]$NoProgress
    )

    $exclude = Get-ExcludeArguments -ExactPaths $ExcludePaths -NameMasks $ExcludeNameMasks
    try {
        $arguments = @(
            'x'
            '-aoa'          # overwrite existing files
            '-scsUTF-8'
            '-sccUTF-8'
            '-bso0'
            '-bsp1'
            '-y'
            ('-o' + $TargetPath.TrimEnd('\'))
        ) + $exclude.Arguments + @($ArchivePath)

        return Invoke-Archiver -ArchiverPath $ArchiverPath -Arguments $arguments -Activity $Activity `
            -TotalBytes $TotalBytes -TotalFiles $TotalFiles -NoProgress:$NoProgress
    } finally {
        foreach ($file in $exclude.Files) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ArchiveContentInfo {
    # Reads the archive's file list (headers only, fast): folder paths for
    # the restore exclusions plus file count and unpacked size.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchiverPath,
        [Parameter(Mandatory)][string]$ArchivePath
    )

    $listPath = Join-Path $env:TEMP ('migrator-ls-{0}-{1}.txt' -f $PID, [guid]::NewGuid().ToString('N'))
    $errPath = "$listPath.err"
    try {
        $commandLine = ConvertTo-NativeCommandLine -Arguments @('l', '-ba', '-sccUTF-8', $ArchivePath)
        $process = Start-Process -FilePath $ArchiverPath -ArgumentList $commandLine -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput $listPath -RedirectStandardError $errPath -ErrorAction Stop

        $directories = [System.Collections.Generic.List[string]]::new()
        $files = 0L
        $bytes = 0L
        if ($process.ExitCode -eq 0) {
            # "2026-11-11 05:04:43 D....            0            0  AppData\Local"
            foreach ($line in [IO.File]::ReadLines($listPath, [Text.Encoding]::UTF8)) {
                if ($line.Length -lt 54) { continue }
                $name = $line.Substring(53)
                if ($line[20] -eq 'D') {
                    $directories.Add($name)
                } else {
                    $files++
                    $size = 0L
                    if ([int64]::TryParse($line.Substring(26, 12).Trim(), [ref]$size)) { $bytes += $size }
                }
            }
        }

        return [pscustomobject]@{
            ExitCode    = [int]$process.ExitCode
            Directories = @($directories)
            Files       = $files
            Bytes       = $bytes
        }
    } finally {
        Remove-Item -LiteralPath $listPath, $errPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ArchiveCheck {
    # Tests the archive and/or computes its SHA256. When both are requested
    # they run at the same time and share the OS file cache, so on a slow
    # disk the archive is read about once instead of twice.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchiverPath,
        [Parameter(Mandatory)][string]$ArchivePath,
        [switch]$Test,
        [switch]$Sha256,
        [string]$Activity = '7-Zip',
        [switch]$NoProgress
    )

    $result = [pscustomobject]@{
        TestResult = $null
        Sha256     = $null
    }
    if (-not $Test -and -not $Sha256) { return $result }

    $job = $null
    if ($Sha256 -and $Test -and (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        $job = Start-ThreadJob -ScriptBlock {
            param($path)
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        } -ArgumentList $ArchivePath
    }

    try {
        if ($Test) {
            $result.TestResult = Test-ProfileArchive -ArchiverPath $ArchiverPath -ArchivePath $ArchivePath `
                -Activity $Activity -NoProgress:$NoProgress
        }
        if ($Sha256) {
            if ($job) {
                $result.Sha256 = [string](Receive-Job -Job $job -Wait -ErrorAction Stop)
            } else {
                $result.Sha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
            }
        }
    } finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
    return $result
}

Export-ModuleMember -Function @(
    'Get-ArchiverPath'
    'Get-ArchiverVersion'
    'Get-ArchiverExitMessage'
    'ConvertFrom-ArchiverProgress'
    'Get-ArchiverProgress'
    'Get-ArchiverIssues'
    'Get-ArchiveOutcome'
    'Remove-StaleArchiverFile'
    'Invoke-Archiver'
    'New-ProfileArchive'
    'Test-ProfileArchive'
    'Expand-ProfileArchive'
    'Get-ArchiveContentInfo'
    'Invoke-ArchiveCheck'
)
