#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$SkipIntegration
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolRoot = Split-Path -Parent $PSScriptRoot
$backupScript = Join-Path $toolRoot 'src\backup.ps1'
$restoreScript = Join-Path $toolRoot 'src\restore.ps1'
$pwsh = Join-Path $toolRoot 'Tools\pwsh\pwsh.exe'
if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = (Get-Process -Id $PID).Path }

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Condition) {
        $script:Passed++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

function Invoke-Script {
    # Runs a script in a child PowerShell with English messages.
    param([Parameter(Mandatory)][string]$Path, [string[]]$Arguments = @())
    $env:MIGRATOR_LANG = 'en'
    $output = & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
}

Write-Host ''
Write-Host 'Migrator smoke tests' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor DarkCyan

# ---------------------------------------------------------------------------
# 1. Parser
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '1. PowerShell parser' -ForegroundColor Yellow

$projectFiles = @(Get-ChildItem -LiteralPath $toolRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File |
    Where-Object { $_.FullName -notlike '*\Tools\*' -and $_.FullName -notlike '*\dist\*' })
Assert-True ($projectFiles.Count -ge 9) "Project scripts found: $($projectFiles.Count)"

foreach ($file in $projectFiles) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True (-not $errors -or $errors.Count -eq 0) "Parses: $($file.Name)"
}

# ---------------------------------------------------------------------------
# 2. Modules, configuration, localization
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '2. Modules, configuration, localization' -ForegroundColor Yellow

$env:MIGRATOR_LANG = 'en'
foreach ($module in 'Core', 'UI', 'Archive', 'Browsers', 'Kit') {
    Import-Module (Join-Path $toolRoot "src\lib\Migrator.$module.psm1") -Force
}

$config = Get-MigratorConfig
Assert-True ([string]$config.ToolVersion -eq '2.2.4') 'Tool version is 2.2.4'
Assert-True (-not [bool]$config.VerifyBeforeRestore) 'Separate pre-restore verification is off by default'

$localeRoot = Join-Path $toolRoot 'src\locale'
$en = Import-PowerShellDataFile -LiteralPath (Join-Path $localeRoot 'en.psd1')
$ru = Import-PowerShellDataFile -LiteralPath (Join-Path $localeRoot 'ru.psd1')
$missingInRu = @($en.Keys | Where-Object { -not $ru.ContainsKey($_) })
$extraInRu = @($ru.Keys | Where-Object { -not $en.ContainsKey($_) })
Assert-True ($missingInRu.Count -eq 0) "Russian has every English string (missing: $($missingInRu -join ', '))"
Assert-True ($extraInRu.Count -eq 0) "Russian has no unknown strings (extra: $($extraInRu -join ', '))"

# Placeholders ({0}, {1}...) must match between languages.
$badPlaceholders = @(foreach ($key in $en.Keys) {
    if (-not $ru.ContainsKey($key)) { continue }
    $a = @([regex]::Matches([string]$en[$key], '\{(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
    $b = @([regex]::Matches([string]$ru[$key], '\{(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
    if ($a -ne $b) { $key }
})
Assert-True ($badPlaceholders.Count -eq 0) "Placeholders match in both languages (differ: $($badPlaceholders -join ', '))"

# Every key used in the code exists.
$sourceText = (Get-ChildItem -LiteralPath (Join-Path $toolRoot 'src') -Recurse -Include '*.ps1', '*.psm1' -File |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$usedKeys = @([regex]::Matches($sourceText, "\b(?:T|Get-Text) '([a-z0-9_.]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$unknownKeys = @($usedKeys | Where-Object { -not $en.ContainsKey($_) })
Assert-True ($usedKeys.Count -gt 150) "Localization keys used in code: $($usedKeys.Count)"
Assert-True ($unknownKeys.Count -eq 0) "Every key used in code is defined (unknown: $($unknownKeys -join ', '))"

Assert-True ((T 'ui.cancel') -eq 'Cancel') 'English text is returned'
Assert-True ((T 'b.cloud.ask_exclude' 'OneDrive') -eq 'Exclude "OneDrive" from the backup?') 'Format arguments are applied'
Assert-True ((T 'no.such.key') -eq 'no.such.key') 'Unknown key falls back to the key itself'
Assert-True ((Format-Size 1048576) -eq ('{0:N1} MB' -f 1)) 'Format-Size works'

# ---------------------------------------------------------------------------
# 3. Exclusion masks
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '3. Exclusion masks' -ForegroundColor Yellow

$fullMasks = @(Get-ModeExcludeMasks -Mode Full)
$standardMasks = @(Get-ModeExcludeMasks -Mode Standard)
Assert-True ($fullMasks.Count -ge 20 -and $fullMasks.Count -le 40) "Full exclusion list is compact: $($fullMasks.Count)"
Assert-True ($standardMasks.Count -gt $fullMasks.Count) 'Standard mode adds exclusions'
Assert-True ($fullMasks -contains 'AppData\*Cache*\') 'AppData cache folders are excluded with one folder mask'
Assert-True ($fullMasks -notcontains '*\node_modules\') 'Developer caches are kept in Full mode by default'
Assert-True ($standardMasks -contains '*\node_modules\') 'Standard mode excludes developer caches'
Assert-True ((Get-RestoreExcludeMasks) -contains '*\NTUSER.DAT*') 'Registry hive is excluded on restore'

$split = Split-ExcludeMasks -Masks @('AppData\*Cache*\', '*\Temp\', '*\*.tmp', '*\NTUSER.DAT*', 'Documents\secret.db')
Assert-True ($split.FolderMasks.Count -eq 2) 'Folder masks are recognized by the trailing backslash'
Assert-True (($split.FileNameMasks -join '|') -eq '*.tmp|NTUSER.DAT*') 'File-name masks are reduced to the bare name'
Assert-True ($split.FilePathMasks -contains 'Documents\secret.db') 'File masks with a path are kept separately'

$folderRegex = ConvertTo-MaskRegex @('AppData\*Cache*\', '*\Temp\')
Assert-True ($folderRegex.IsMatch('\AppData\Local\Google\Chrome\User Data\Default\Cache\')) 'Mask: AppData cache folder matches'
Assert-True (-not $folderRegex.IsMatch('\Documents\CachedProjects\')) 'Mask: Cache-like folder outside AppData is kept'
Assert-True ($folderRegex.IsMatch('\Temp\') -and $folderRegex.IsMatch('\AppData\Local\Temp\')) 'Mask: global folder mask matches at any depth, including the root'
Assert-True (-not $folderRegex.IsMatch('\Documents\Templates\')) 'Mask: similar folder name does not match'

$archiveFolders = @('AppData', 'AppData\Local', 'AppData\Local\Temp', 'AppData\Local\Temp\sub', 'Documents', 'My Documents')
$selected = @(Select-ExcludedArchiveFolders -Directories $archiveFolders -ExcludeMasks (Get-RestoreExcludeMasks))
Assert-True (($selected -join '|') -eq 'AppData\Local\Temp|My Documents') "Restore: excluded archive folders are top-most only ($($selected -join '|'))"

# ---------------------------------------------------------------------------
# 4. Quoting, paths, UI helpers
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '4. Quoting, paths, UI helpers' -ForegroundColor Yellow

Assert-True ((ConvertTo-NativeArgument 'plain') -eq 'plain') 'Plain argument is not quoted'
Assert-True ((ConvertTo-NativeArgument 'a b') -eq '"a b"') 'Argument with a space is quoted'
Assert-True ((ConvertTo-NativeArgument 'c"d') -eq '"c\"d"') 'Embedded quote is escaped'
Assert-True ((ConvertTo-NativeArgument 'a b\') -eq '"a b\\"') 'Trailing backslash is escaped before the closing quote'
Assert-True (Test-PathWithin -Child 'C:\Users\A\Desktop' -Parent 'C:\Users\A') 'Child path is detected'
Assert-True (-not (Test-PathWithin -Child 'C:\Users\AB' -Parent 'C:\Users\A')) 'Prefix-only sibling is not a child'

$line = Format-ProgressLine -Activity 'Backup' -Percent 50 -BytesPerSecond (100MB) -RemainingSeconds 200 `
    -FilesDone 12400 -TotalFiles 40000 -Current 'AppData\Roaming\App' -BarWidth 10
Assert-True ($line -match ' 50%' -and $line -match '/s' -and $line -match 'about 4 min left' -and $line -match 'files' -and $line -match 'Roaming') "Progress line has percent, current speed, files, remaining time and folder: $line"
Assert-True ((Format-ProgressLine -Activity 'x' -Percent 1 -Estimating) -match 'estimating') 'Progress line says "estimating" instead of a made-up time'
$staleDir = Join-Path $env:LOCALAPPDATA ('MigratorSmokeTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staleDir | Out-Null
try {
    $deadId = 4000000
    while (Get-Process -Id $deadId -ErrorAction SilentlyContinue) { $deadId++ }
    $guid = [guid]::NewGuid().ToString('N')
    $staleNames = @("migrator-7z-$deadId-$guid.out", "migrator-7z-$deadId-$guid.err", "migrator-list-$deadId-$guid.lst", "migrator-ls-$deadId-$guid.txt.err")
    $keptNames = @("migrator-list-$PID-$guid.lst", "migrator-notes.txt", "migrator-pwsh-$guid.zip")
    foreach ($name in ($staleNames + $keptNames)) { Set-Content -LiteralPath (Join-Path $staleDir $name) -Value 'x' }
    $removedCount = Remove-StaleArchiverFile -Path $staleDir
    $remaining = @(Get-ChildItem -LiteralPath $staleDir -File | ForEach-Object Name | Sort-Object)
    Assert-True ($removedCount -eq 4) "Files of a run that no longer exists are removed ($removedCount of 4)"
    Assert-True (($remaining -join '|') -eq (($keptNames | Sort-Object) -join '|')) 'Files of a running Migrator and unrelated files are kept'
} finally {
    Remove-Item -LiteralPath $staleDir -Recurse -Force -ErrorAction SilentlyContinue
}
# Batch files: cmd.exe misreads labels and UTF-8 lines in a file with LF-only
# line endings, so every .bat must use CRLF.
$badEol = @(Get-ChildItem -LiteralPath $toolRoot -Filter '*.bat' -File | Where-Object {
    $text = [IO.File]::ReadAllText($_.FullName)
    ($text -replace "`r`n", '') -match "[`r`n]"
} | ForEach-Object Name)
Assert-True ($badEol.Count -eq 0) "Batch files use CRLF line endings$(if ($badEol) { ': ' + ($badEol -join ', ') })"

# The launcher without PowerShell 7: nothing is installed unless "y" is typed.
$env:MIGRATOR_TEST_NO_PWSH = '1'
try {
    $launcher = Join-Path $toolRoot 'Migrator.bat'
    foreach ($case in @(@('', 'an empty answer'), @('n', '"n"'), @('ye"s & echo INJECTED', 'an unexpected answer'))) {
        $out = @($case[0] | cmd.exe /c "`"$launcher`"" 2>&1 | ForEach-Object { [string]$_ })
        $declined = [bool]($out -match 'Nothing was installed')
        $started = [bool]($out -match 'required tools|INJECTED|is not recognized')
        Assert-True ($LASTEXITCODE -eq 1 -and $declined -and -not $started) "Launcher installs nothing on $($case[1])"
    }
} finally {
    Remove-Item Env:MIGRATOR_TEST_NO_PWSH -ErrorAction SilentlyContinue
}
$ruLocale = Import-PowerShellDataFile -LiteralPath (Join-Path $toolRoot 'src\locale\ru.psd1')
Assert-True ($ruLocale['ui.yes_letter'] -eq 'y' -and $ruLocale['ui.no_letter'] -eq 'n') 'Russian interface asks y/n like the English one'
Assert-True ((Format-RemainingTime -Seconds 20) -match 'less than a minute') 'Remaining time: under a minute'
Assert-True ((Format-RemainingTime -Seconds 7300) -eq 'about 2 h 0 min left') 'Remaining time: hours are rounded to 5 minutes'

$mark = ConvertFrom-ArchiverProgress -Text "  0M Scan `r          `r  0%`r    `r 45% 1234 + Documents\report 100%.docx`r"
Assert-True ($mark.Percent -eq 45 -and $mark.Files -eq 1234 -and $mark.Current -eq 'Documents\report 100%.docx') 'Archiver progress mark: percent, file count and current file are parsed'
Assert-True ($null -eq (ConvertFrom-ArchiverProgress -Text '  0M Scan ')) 'Archiver progress mark: nothing to parse while scanning'

# Remaining-time model: time = bytes x cost + files x cost.
function Invoke-EtaSimulation {
    # Phases: @{ Mb; Files; Seconds } processed one after another at a steady
    # pace. Returns the forecast and the true remaining time at -AskAt seconds.
    param([object[]]$Phases, [double]$AskAt)
    $totalMb = ($Phases | ForEach-Object { $_.Mb } | Measure-Object -Sum).Sum
    $totalFiles = ($Phases | ForEach-Object { $_.Files } | Measure-Object -Sum).Sum
    $totalSeconds = ($Phases | ForEach-Object { $_.Seconds } | Measure-Object -Sum).Sum
    $estimator = New-EtaEstimator -TotalBytes ([int64]($totalMb * 1MB)) -TotalFiles ([int64]$totalFiles)
    $forecast = $null
    for ($t = 1; $t -le $AskAt; $t++) {
        $mb = 0.0; $files = 0.0; $start = 0.0
        foreach ($phase in $Phases) {
            $part = [Math]::Max(0.0, [Math]::Min(1.0, ($t - $start) / $phase.Seconds))
            $mb += $phase.Mb * $part; $files += $phase.Files * $part; $start += $phase.Seconds
        }
        $forecast = Update-EtaEstimator -Estimator $estimator -Seconds $t -Bytes ($mb * 1MB) -Files $files
    }
    return [pscustomobject]@{ Forecast = $forecast; Truth = $totalSeconds - $AskAt }
}

# 50 GB of large files at 500 MB/s, then 300,000 small files (3 GB) at ~2 ms each.
$largeThenSmall = @(@{ Mb = 50000; Files = 100; Seconds = 100 }, @{ Mb = 3000; Files = 300000; Seconds = 600 })
$sim = Invoke-EtaSimulation -Phases $largeThenSmall -AskAt 160
$naive = 2000 * 1.0 / (3000 / 600)      # remaining bytes / current byte speed, for comparison
Assert-True ($sim.Forecast -gt $sim.Truth / 2 -and $sim.Forecast -lt $sim.Truth * 2) ("Forecast in the small-file phase is within 2x of the truth ({0:N0} s vs {1:N0} s)" -f $sim.Forecast, $sim.Truth)

# The same data in the opposite order: small files first, 50 GB of large files still ahead.
$smallThenLarge = @(@{ Mb = 3000; Files = 300000; Seconds = 600 }, @{ Mb = 50000; Files = 100; Seconds = 100 })
$sim = Invoke-EtaSimulation -Phases $smallThenLarge -AskAt 120
$naive = (53000 - 600) / (3000 / 600)   # what "remaining bytes / current speed" would say: ~3 hours
Assert-True ($sim.Forecast -lt $sim.Truth * 2.5 -and $sim.Forecast -gt $sim.Truth / 2.5) ("Small files first: forecast {0:N0} s, truth {1:N0} s, bytes-only forecast {2:N0} s" -f $sim.Forecast, $sim.Truth, $naive)
Assert-True ($naive -gt $sim.Truth * 10) 'The bytes-only forecast is off by more than 10x in that case'

# A slow drive (30 MB/s, large files): the forecast must follow the real speed.
$sim = Invoke-EtaSimulation -Phases @(@{ Mb = 30000; Files = 60; Seconds = 1000 }) -AskAt 120
Assert-True ($sim.Forecast -gt $sim.Truth * 0.7 -and $sim.Forecast -lt $sim.Truth * 1.3) ("Slow drive: forecast {0:N0} s, truth {1:N0} s" -f $sim.Forecast, $sim.Truth)

$state = New-ProgressState -Activity 'x' -TotalBytes 1000
$state.Interactive = $false
Update-ProgressState -State $state -Percent 40 -BytesDone 400 6>$null
Update-ProgressState -State $state -Percent 30 -BytesDone 300 6>$null
Assert-True ($state.LastPercent -eq 40) 'Progress never moves backwards'

$issues = Get-ArchiverIssues -StdErr @'

WARNING: The process cannot access the file because it is being used by another process.
C:\Users\A\Documents\locked.bin

WARNINGS for files:

C:\Users\A\Documents\locked.bin : The process cannot access the file because it is being used by another process.
----------------
WARNING: Cannot open 1 file
'@
Assert-True (($issues.SkippedFiles -join '|') -eq 'C:\Users\A\Documents\locked.bin') 'Locked file is parsed from the archiver warnings'
Assert-True ((Get-ArchiveOutcome -ExitCode 1 -Issues $issues) -eq 'Warnings') 'Exit 1 with locked files is a usable result'

$extractLocked = Get-ArchiverIssues -StdErr 'ERROR: Cannot delete output file : The process cannot access the file. : C:\Users\B\Documents\a.txt'
Assert-True ((Get-ArchiveOutcome -ExitCode 2 -Issues $extractLocked) -eq 'Warnings') 'Extraction: a locked target file is a warning, not a failure'
$extractDamaged = Get-ArchiverIssues -StdErr 'ERROR: CRC Failed : Documents\report.txt'
Assert-True ((Get-ArchiveOutcome -ExitCode 2 -Issues $extractDamaged) -eq 'Failed') 'Extraction: a checksum error is a failure'
$notArchive = Get-ArchiverIssues -StdErr "ERROR: D:\x.7z`nD:\x.7z`nOpen ERROR: Cannot open the file as [7z] archive"
Assert-True ((Get-ArchiveOutcome -ExitCode 2 -Issues $notArchive) -eq 'Failed') 'A file that is not an archive is a failure'

$archiver = Get-ArchiverPath
Assert-True (-not [string]::IsNullOrWhiteSpace($archiver)) "7-Zip is available: $archiver"

# ---------------------------------------------------------------------------
# 5. Backup + restore integration
# ---------------------------------------------------------------------------
if ($SkipIntegration -or -not $archiver) {
    Write-Host ''
    Write-Host '5. Integration tests skipped' -ForegroundColor DarkYellow
} else {
    Write-Host ''
    Write-Host '5. Backup and restore integration' -ForegroundColor Yellow

    # Under %LOCALAPPDATA% on purpose: the path above the profile contains
    # "AppData", which must not influence the exclusions.
    # A new folder with a unique name every run: the tests never delete a
    # folder they did not create.
    $base = Join-Path $env:LOCALAPPDATA ('MigratorSmokeTest-' + [guid]::NewGuid().ToString('N'))
    $source = Join-Path $base 'Source Юзер'
    $backups = Join-Path $base 'Backups'
    $target = Join-Path $base 'Target User'
    $junctions = [System.Collections.Generic.List[string]]::new()

    try {
        $files = [ordered]@{
            'Desktop\hello world.txt' = 'hello desktop'
            'Desktop\æøå.txt' = 'unicode name'
            'Documents\report.txt' = 'quarterly report'
            'Documents\CachedProjects\keep.txt' = 'user data, not a cache'
            'Documents\draft.tmp' = 'temporary'
            'AppData\Roaming\Example App\settings.json' = '{"theme":"dark"}'
            'AppData\Local\Google\Chrome\User Data\Default\Bookmarks' = '{"bookmarks":[]}'
            'AppData\Local\Google\Chrome\User Data\Default\Cache\cache.bin' = 'cache'
            'AppData\Local\Packages\App\LocalCache\c.bin' = 'uwp cache'
            'AppData\Local\Temp\junk.txt' = 'junk'
            'OneDrive\local.txt' = 'local OneDrive file'
            'NTUSER.DAT' = 'registry hive'
            'Documents\locked.bin' = ('x' * 5000)
        }
        foreach ($relative in $files.Keys) {
            $path = Join-Path $source $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            Set-Content -LiteralPath $path -Value $files[$relative] -NoNewline
        }
        # A junction, like the legacy "Application Data" link: must not be followed.
        cmd.exe /c mklink /J (Join-Path $source 'Application Data') (Join-Path $source 'AppData\Roaming') | Out-Null

        $scan = Measure-ProfileTree -Path $source -ExcludeMasks (Get-ModeExcludeMasks -Mode Full)
        Assert-True ($scan.Links -eq 1 -and $scan.ExcludedDirectories -contains 'Application Data') 'Scan: junction is detected and excluded'
        Assert-True ($scan.ExcludedDirectories -contains 'AppData\Local\Google\Chrome\User Data\Default\Cache') 'Scan: cache folder is in the exclusion list'
        Assert-True ($scan.ExcludedDirectories -notcontains 'Documents\CachedProjects') 'Scan: user folder is not excluded'
        Assert-True ($scan.Files -eq 8) "Scan: counts only files that will be archived ($($scan.Files))"

        # --- backup with a locked file -----------------------------------
        $tempBefore = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'migrator-*' -File -ErrorAction SilentlyContinue | ForEach-Object Name)
        $lockedStream = [IO.File]::Open((Join-Path $source 'Documents\locked.bin'), 'Open', 'ReadWrite', 'None')
        try {
            $backup = Invoke-Script $backupScript @('-SourcePath', $source, '-Destination', $backups, '-Mode', 'Full', '-NonInteractive', '-ComputeHash')
        } finally {
            $lockedStream.Dispose()
        }
        if ($backup.ExitCode -ne 0) { $backup.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        Assert-True ($backup.ExitCode -eq 0) 'backup.ps1 completes when one file is locked'
        Assert-True ([bool]($backup.Output -match 'COMPLETED WITH WARNINGS')) 'Locked file gives "completed with warnings", not a failure'

        $archive = Get-ChildItem -LiteralPath $backups -Filter '*.7z' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $manifestFile = Get-ChildItem -LiteralPath $backups -Filter '*.manifest.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert-True ($null -ne $archive) 'Archive (.7z) was created'
        Assert-True ($null -ne $manifestFile) 'Manifest was created'
        Assert-True ($null -ne (Get-ChildItem -LiteralPath $backups -Filter '*.summary.txt' -File | Select-Object -First 1)) 'Summary was created'
        # Only files that appeared during this backup count: another Migrator
        # running on the same PC keeps its own files in the same folder.
        $leftover = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'migrator-*' -File -ErrorAction SilentlyContinue |
            Where-Object { $tempBefore -notcontains $_.Name -and $_.Name -match '^migrator-(7z|list|ls)-(\d+)-' -and -not (Get-Process -Id ([int]$Matches[2]) -ErrorAction SilentlyContinue) })
        Assert-True ($leftover.Count -eq 0) 'Temporary files are removed after a backup'

        if ($manifestFile) {
            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json -AsHashtable
            Assert-True ([string]$manifest['archiveSha256'] -match '^[A-Fa-f0-9]{64}$') 'Manifest contains SHA256'
            Assert-True ([string]$manifest['verify'] -eq 'passed') 'Manifest records the passed verification'
            Assert-True ([int]$manifest['skippedFileCount'] -eq 1 -and ($manifest['skippedFiles'] -join '') -match 'locked\.bin') 'Manifest lists the skipped file'
            Assert-True ([int64]$manifest['sourceBytes'] -gt 0 -and [int64]$manifest['sourceBytes'] -lt (Get-DirectorySizeFast -Path $source)) 'Size estimate follows the exclusions'
        }

        if ($archive) {
            $content = Get-ArchiveContentInfo -ArchiverPath $archiver -ArchivePath $archive.FullName
            $entries = @(& $archiver l -ba -sccUTF-8 $archive.FullName | ForEach-Object { if ($_.Length -gt 53) { $_.Substring(53) } })
            Assert-True ($entries -contains 'Desktop\hello world.txt') 'Archive keeps the profile-relative layout'
            Assert-True ($entries -contains 'Desktop\æøå.txt') 'Non-ASCII file name is archived'
            Assert-True ($entries -contains 'Documents\CachedProjects\keep.txt') 'Cache-like user folder is archived'
            Assert-True ($entries -contains 'OneDrive\local.txt') 'Fully local OneDrive folder is kept in non-interactive Auto mode'
            Assert-True ($entries -contains 'AppData\Local\Google\Chrome\User Data\Default\Bookmarks') 'Browser bookmarks are archived'
            Assert-True ($entries -notcontains 'NTUSER.DAT') 'NTUSER.DAT is not archived'
            Assert-True ($entries -notcontains 'Documents\draft.tmp') '*.tmp is not archived'
            $junk = @($entries | Where-Object { $_ -like 'AppData\*\Cache*' -or $_ -like 'AppData\*\LocalCache*' -or $_ -like 'AppData\Local\Temp*' })
            Assert-True ($junk.Count -eq 0) "Cache and Temp folders are not archived, not even as empty folders ($($junk -join '|'))"
            Assert-True (@($entries | Where-Object { $_ -like 'Application Data*' }).Count -eq 0) 'Junction is not followed'
            Assert-True ($content.Files -eq 7) "Archive file list is parsed ($($content.Files) files)"
        }

        # --- cloud folder policy -------------------------------------------
        $cloud = Invoke-Script $backupScript @('-SourcePath', $source, '-Destination', (Join-Path $base 'BackupsCloud'), '-NonInteractive', '-NoVerify', '-CloudFolders', 'Exclude')
        $cloudArchive = Get-ChildItem -LiteralPath (Join-Path $base 'BackupsCloud') -Filter '*.7z' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert-True ($cloud.ExitCode -eq 0 -and $null -ne $cloudArchive) 'backup.ps1 -CloudFolders Exclude completes'
        if ($cloudArchive) {
            $cloudEntries = @(& $archiver l -ba -sccUTF-8 $cloudArchive.FullName | ForEach-Object { if ($_.Length -gt 53) { $_.Substring(53) } })
            Assert-True ($cloudEntries -notcontains 'OneDrive\local.txt' -and $cloudEntries -contains 'Documents\report.txt') 'OneDrive folder is excluded, other files are kept'
        }

        # --- restore kit ---------------------------------------------------------
        # Migrator + portable PowerShell and 7-Zip next to the archive; the kit
        # must restore on its own, using only its own tools and finding the
        # archive in its parent folder.
        $kitBackups = Join-Path $base 'BackupsKit'
        $kitRun = Invoke-Script $backupScript @('-SourcePath', $source, '-Destination', $kitBackups, '-NonInteractive', '-NoVerify', '-RestoreKit', 'Copy')
        $kitPath = Join-Path $kitBackups 'Migrator'
        if ($kitRun.ExitCode -ne 0) { $kitRun.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        Assert-True ($kitRun.ExitCode -eq 0) 'backup.ps1 -RestoreKit Copy completes'
        Assert-True ((Get-RestoreKitPath -Destination $kitBackups) -eq $kitPath) 'Kit path is a Migrator folder next to the archives'
        Assert-True ((Get-RestoreKitPath -Destination (Join-Path $toolRoot 'Backups')) -eq $toolRoot) 'Backups inside the Migrator folder: the folder itself is the kit'
        Assert-True ((Test-RestoreKit -Path $kitPath).State -eq 'Ready') 'Kit is complete: scripts, PowerShell and 7-Zip'
        Assert-True ((Test-RestoreKit -Path (Join-Path $base 'no-kit')).State -eq 'Missing') 'A missing kit is reported as missing'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $kitPath 'Tools\WinRAR'))) 'Kit contains only redistributable tools'

        $kitPwsh = Join-Path $kitPath 'Tools\pwsh\pwsh.exe'
        if (Test-Path -LiteralPath $kitPwsh) {
            $env:MIGRATOR_LANG = 'en'
            $kitOutput = & $kitPwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kitPath 'src\restore.ps1') `
                -Method Archive -TargetPath (Join-Path $base 'Kit Target') -NonInteractive 2>&1
            $kitExit = $LASTEXITCODE
            if ($kitExit -ne 0) { $kitOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
            Assert-True ($kitExit -eq 0) 'Kit restores with its own PowerShell and finds the archive in the parent folder'
            Assert-True (Test-Path -LiteralPath (Join-Path $base 'Kit Target\Documents\report.txt')) 'Kit restore extracted the files'
            Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $kitPath 'Logs') -Filter 'restore-*.log' -ErrorAction SilentlyContinue).Count -gt 0) 'Kit writes its log inside the kit, not into the source Migrator folder'
        }

        $second = Invoke-Script $backupScript @('-SourcePath', $source, '-Destination', $kitBackups, '-NonInteractive', '-NoVerify')
        Assert-True ($second.ExitCode -eq 0 -and [bool]($second.Output -match 'already at')) 'A second backup finds the existing kit and does not rebuild it'

        # --- restore -----------------------------------------------------------
        if ($archive) {
            $restore = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $archive.FullName, '-TargetPath', $target, '-NonInteractive')
            if ($restore.ExitCode -ne 0) { $restore.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
            Assert-True ($restore.ExitCode -eq 0) 'restore.ps1 completes without errors'
            Assert-True (Test-Path -LiteralPath (Join-Path $target 'Desktop\hello world.txt')) 'Desktop file was restored'
            Assert-True (Test-Path -LiteralPath (Join-Path $target 'Desktop\æøå.txt')) 'Non-ASCII file was restored'
            Assert-True ((Get-Content -LiteralPath (Join-Path $target 'Documents\report.txt') -Raw) -eq 'quarterly report') 'File content survives the round trip'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'NTUSER.DAT'))) 'NTUSER.DAT was not restored'
            Assert-True ([bool]($restore.Output -match 'No separate verification')) 'Restore skips the separate test by default'

            $verified = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $archive.FullName, '-TargetPath', (Join-Path $base 'Verified Target'), '-NonInteractive', '-Verify')
            Assert-True ($verified.ExitCode -eq 0 -and [bool]($verified.Output -match 'SHA256 matches')) 'restore.ps1 -Verify tests the archive and checks SHA256'

            # A locked file in the target is a warning; everything else is restored.
            $lockedTarget = Join-Path $base 'Locked Target'
            New-Item -ItemType Directory -Force -Path (Join-Path $lockedTarget 'Documents') | Out-Null
            Set-Content -LiteralPath (Join-Path $lockedTarget 'Documents\report.txt') -Value 'old' -NoNewline
            $targetLock = [IO.File]::Open((Join-Path $lockedTarget 'Documents\report.txt'), 'Open', 'ReadWrite', 'None')
            try {
                $lockedRestore = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $archive.FullName, '-TargetPath', $lockedTarget, '-NonInteractive')
            } finally {
                $targetLock.Dispose()
            }
            Assert-True ($lockedRestore.ExitCode -eq 0 -and [bool]($lockedRestore.Output -match 'COMPLETED WITH WARNINGS')) 'Restore over a locked file completes with warnings'
            Assert-True (Test-Path -LiteralPath (Join-Path $lockedTarget 'Desktop\hello world.txt')) 'Other files are restored when one target file is locked'

            # A folder in the target that is a junction leading outside it is
            # skipped: nothing may be written through it.
            $linkTarget = Join-Path $base 'Link Target'
            $outside = Join-Path $base 'Outside'
            New-Item -ItemType Directory -Force -Path $linkTarget, $outside, (Join-Path $linkTarget 'AppData\Roaming') | Out-Null
            cmd.exe /c mklink /J (Join-Path $linkTarget 'Documents') $outside | Out-Null
            cmd.exe /c mklink /J (Join-Path $linkTarget 'Application Data') (Join-Path $linkTarget 'AppData\Roaming') | Out-Null
            $junctions.Add((Join-Path $linkTarget 'Documents')); $junctions.Add((Join-Path $linkTarget 'Application Data'))
            Assert-True (((Get-OutsideLinks -Root $linkTarget) -join '|') -eq 'Documents') 'Only a link that leaves the target is reported, not one that stays inside'
            $linkRestore = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $archive.FullName, '-TargetPath', $linkTarget, '-NonInteractive')
            Assert-True ($linkRestore.ExitCode -eq 0 -and [bool]($linkRestore.Output -match 'links leading outside')) 'Restore over a junction completes and names the skipped folder'
            Assert-True (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'Nothing is written through a junction that leads outside the target'
            Assert-True (Test-Path -LiteralPath (Join-Path $linkTarget 'Desktop\hello world.txt')) 'The rest of the profile is restored next to the junction'

            # The target folder itself is a junction: refused without -Force.
            $realTarget = Join-Path $base 'Real Target'
            $linkedRoot = Join-Path $base 'Linked Root'
            New-Item -ItemType Directory -Force -Path $realTarget | Out-Null
            cmd.exe /c mklink /J $linkedRoot $realTarget | Out-Null
            $junctions.Add($linkedRoot)
            Assert-True ((Resolve-RealPath -Path (Join-Path $linkedRoot 'a\b')) -eq (Join-Path $realTarget 'a\b')) 'A path through a junction resolves to the real location'
            $rootLink = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $archive.FullName, '-TargetPath', $linkedRoot, '-NonInteractive')
            Assert-True ($rootLink.ExitCode -ne 0 -and [bool]($rootLink.Output -match 'is a link to') -and @(Get-ChildItem -LiteralPath $realTarget -Force).Count -eq 0) 'A target that is a junction is refused without -Force'
            $rootForced = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $archive.FullName, '-TargetPath', $linkedRoot, '-NonInteractive', '-Force')
            Assert-True ($rootForced.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $realTarget 'Documents\report.txt'))) 'With -Force the restore goes to the real location'

            # A backup that ended with an error is not restored by default.
            $failedDir = Join-Path $base 'Failed Backup'
            New-Item -ItemType Directory -Force -Path $failedDir | Out-Null
            $failedArchive = Join-Path $failedDir $archive.Name
            Copy-Item -LiteralPath $archive.FullName -Destination $failedArchive
            $failedManifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json -AsHashtable
            $failedManifest['result'] = 'FAILED'
            $failedManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-ManifestPath -ArchivePath $failedArchive) -Encoding utf8
            Assert-True ((Get-ArchiveMetadata -ArchivePath $failedArchive).Failed -and -not (Get-ArchiveMetadata -ArchivePath $archive.FullName).Failed) 'A failed backup is recognised by its manifest'
            $failedTarget = Join-Path $base 'Failed Target'
            $failedRestore = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $failedArchive, '-TargetPath', $failedTarget, '-NonInteractive')
            Assert-True ($failedRestore.ExitCode -ne 0 -and [bool]($failedRestore.Output -match 'ended with an error') -and -not (Test-Path -LiteralPath $failedTarget)) 'A failed backup is not restored without -Force'

            # A damaged archive must fail during extraction even without -Verify.
            $damaged = Join-Path $base 'damaged.7z'
            $bytes = [IO.File]::ReadAllBytes($archive.FullName)
            $marker = [Text.Encoding]::ASCII.GetBytes('quarterly report')
            $offset = -1
            for ($i = 0; $i -le $bytes.Length - $marker.Length; $i++) {
                $hit = $true
                for ($j = 0; $j -lt $marker.Length; $j++) { if ($bytes[$i + $j] -ne $marker[$j]) { $hit = $false; break } }
                if ($hit) { $offset = $i; break }
            }
            Assert-True ($offset -ge 0) 'Stored (uncompressed) file content is found in the archive'
            if ($offset -ge 0) {
                $bytes[$offset] = [byte][char]'Q'
                [IO.File]::WriteAllBytes($damaged, $bytes)
                $bad = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $damaged, '-TargetPath', (Join-Path $base 'Damaged Target'), '-NonInteractive')
                Assert-True ($bad.ExitCode -ne 0 -and [bool]($bad.Output -match 'damaged')) 'Damaged archive is reported as failed during extraction'
            }

            # A truncated archive cannot be opened at all.
            $truncated = Join-Path $base 'truncated.7z'
            [IO.File]::WriteAllBytes($truncated, [byte[]]($bytes[0..($bytes.Length - 60)]))
            $cut = Invoke-Script $restoreScript @('-Method', 'Archive', '-Archive', $truncated, '-TargetPath', (Join-Path $base 'Cut Target'), '-NonInteractive')
            Assert-True ($cut.ExitCode -ne 0) 'Truncated archive is rejected'

            # Russian interface produces Russian text.
            $env:MIGRATOR_LANG = 'ru'
            $ruOutput = & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $restoreScript -Method Archive -Archive $archive.FullName -TargetPath (Join-Path $base 'Ru Target') -NonInteractive 2>&1
            $env:MIGRATOR_LANG = 'en'
            Assert-True ([bool](@($ruOutput | ForEach-Object { [string]$_ }) -match 'План восстановления')) 'Russian interface is used when requested'
        }

        # --- robocopy progress parser ------------------------------------------
        $rcSource = Join-Path $base 'rc-src'
        $rcLog = Join-Path $base 'rc.log'
        New-Item -ItemType Directory -Force -Path (Join-Path $rcSource 'Документы') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $rcSource 'Документы\a.bin'), [byte[]]::new(1234))
        [IO.File]::WriteAllBytes((Join-Path $rcSource 'b.bin'), [byte[]]::new(766))
        & robocopy.exe $rcSource (Join-Path $base 'rc-dst') /E /MT:4 /XX /NDL /NJH /NJS /NP /FP /BYTES "/UNILOG:$rcLog" | Out-Null
        $rcText = [IO.File]::ReadAllText($rcLog, [Text.Encoding]::Unicode)
        $rcBytes = 0L
        foreach ($m in ([regex]'\t\s*(\d+)\t').Matches($rcText)) { $rcBytes += [int64]$m.Groups[1].Value }
        Assert-True ($rcBytes -eq 2000) "Robocopy log parser counts copied bytes ($rcBytes of 2000)"
        Assert-True ($rcText -match 'Документы') 'Robocopy /UNILOG keeps non-ASCII paths'
    } catch {
        $script:Failed++
        Write-Host "  FAIL  Integration test threw: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    } finally {
        # Junctions first, as links: their targets must not be emptied.
        foreach ($junction in $junctions) {
            if (Test-Path -LiteralPath $junction) { cmd.exe /c rmdir $junction | Out-Null }
        }
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkCyan
Write-Host ("Passed: {0}   Failed: {1}" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })

if ($script:Failed -gt 0) { exit 1 }
exit 0
