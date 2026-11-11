#Requires -Version 7.0
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Migrator.Core.psm1
# Configuration, localization, profiles, disks, exclusion planning, manifests.
# No console output and no archiver calls live here.
# ---------------------------------------------------------------------------

$script:MigratorRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ConfigPath     = Join-Path $script:MigratorRoot 'src\config\defaults.json'
$script:UserConfigPath = Join-Path $script:MigratorRoot 'src\config\user.json'
$script:LocaleRoot     = Join-Path $script:MigratorRoot 'src\locale'
$script:ConfigCache    = $null
$script:Strings        = $null
$script:FallbackStrings = $null
$script:Language       = $null
$script:ProfileCache   = $null

function Get-MigratorRoot {
    [CmdletBinding()]
    param()
    return $script:MigratorRoot
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Get-DefaultConfig {
    [ordered]@{
        ToolVersion         = '2.2.1'
        # auto | en | ru   (auto follows the Windows display language)
        Language            = 'auto'
        DefaultMode         = 'Full'
        # 7-Zip level: 0 = store (fastest) ... 9 = ultra
        Compression         = 0
        VerifyAfterBackup   = $true
        # Extraction already checks the CRC of every file.
        VerifyBeforeRestore = $false
        ComputeSha256       = $false
        # Cloud-synced folders in the profile root. Reading a cloud-only
        # placeholder makes the sync client download it.
        #   Auto    - interactive: ask; non-interactive: exclude when cloud-only files exist
        #   Exclude - always exclude    Include - always include
        CloudFolderPolicy   = 'Auto'
        CloudFolders        = @('OneDrive','OneDrive - *','iCloudDrive','Dropbox','Dropbox (*)')
        # Re-downloadable developer caches: always excluded in Standard mode,
        # in Full mode only when this is $true.
        ExcludeDevCaches    = $false
        BackupRoot          = 'Backups'
        LogRoot             = 'Logs'
        # Block characters in the progress bar; set to $false for plain ASCII.
        Unicode             = $true
        ArchiverPath        = 'Tools\7-Zip\7z.exe'
        ProgressPollMs      = 250
        BrowserProcessNames = @(
            'chrome','msedge','firefox','brave','vivaldi','opera','opera_gx','chromium','yandex','browser',
            'waterfox','librewolf','palemoon'
        )

        # Mask syntax (resolved by Migrator itself, not by the archiver):
        #   - a trailing '\' is a FOLDER mask: the whole folder is skipped;
        #   - a mask starting with '*' matches at any depth;
        #   - any other mask is relative to the profile root ('AppData\...');
        #   - '*' matches any characters including '\', '?' matches one.
        CommonExcludes = @(
            'AppData\*Cache*\'
            '.cache\'
            '*\Temp\'
            '*\tmp\'
            '*\TempState\'
            '*\WER\'
            '*\CrashDumps\'
            '*\Crashpad\'
            '*\Crash Reports\'
            '*\BrowserMetrics\'
            '*\User Data\Snapshots\'
            '*\User Data\Recovery\'
            '*\Service Worker\'
            'AppData\Local\Microsoft\OneDrive\'
            'AppData\Local\Microsoft\Windows\Explorer\'
            'AppData\Local\Microsoft\Windows\Temporary Internet Files\'
            'AppData\Local\History\'
            'AppData\Local\Microsoft\Windows\History\'
            '*\*.tmp'
            '*\~$*'
            '*\*dmp'
            '*\*.etl'
            '*\Thumbs.db'
            '*\*.crdownload'
            '*\*.partial'
            '*\NTUSER.DAT*'
            '*\UsrClass.dat*'
            '*\*.ost'
        )

        # Extra exclusions for the lighter "Standard" mode.
        StandardExcludes = @(
            'AppData\Local\Packages\'
            'AppData\Local\Programs\'
            'AppData\Local\Microsoft\Teams\'
            'AppData\Local\Slack\'
        )

        DevExcludes = @(
            '*\node_modules\'
            '.nuget\packages\'
            '.gradle\caches\'
            '.gradle\wrapper\dists\'
            '.m2\repository\'
            '.cargo\registry\'
            'go\pkg\mod\'
            'AppData\Local\Docker\'
        )

        # Never restored, whatever the archive contains (also applied to
        # archives made by older versions). Legacy junction copies appear in
        # old archives as real folders.
        RestoreExcludes = @(
            '*\NTUSER.DAT*'
            '*\UsrClass.dat*'
            '*\*.ost'
            '*\Application Data\'
            '*\My Documents\'
            '*\My Music\'
            '*\My Pictures\'
            '*\My Videos\'
        )

        ExtraExcludes = @()
    }
}

function Get-MigratorConfig {
    [CmdletBinding()]
    param()
    if ($null -ne $script:ConfigCache) { return $script:ConfigCache }

    $config = Get-DefaultConfig
    foreach ($path in @($script:ConfigPath, $script:UserConfigPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $overrides = Get-Content -LiteralPath $path -Raw -ErrorAction Stop |
                         ConvertFrom-Json -AsHashtable -ErrorAction Stop
            foreach ($key in $overrides.Keys) { $config[$key] = $overrides[$key] }
        } catch {
            Write-Warning "Could not read config '$path': $($_.Exception.Message). Using defaults."
        }
    }

    $script:ConfigCache = $config
    return $script:ConfigCache
}

function Set-MigratorUserSetting {
    # Persists one setting in src\config\user.json (not tracked by git).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Value
    )

    $data = @{}
    if (Test-Path -LiteralPath $script:UserConfigPath -PathType Leaf) {
        try {
            $data = Get-Content -LiteralPath $script:UserConfigPath -Raw | ConvertFrom-Json -AsHashtable
        } catch { $data = @{} }
    }
    $data[$Name] = $Value
    Set-Content -LiteralPath $script:UserConfigPath -Value ($data | ConvertTo-Json -Depth 5) -Encoding utf8

    $script:ConfigCache = $null
    $script:Strings = $null
    $script:Language = $null
}

function Resolve-MigratorPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $script:MigratorRoot $Path))
}

# ---------------------------------------------------------------------------
# Localization
# ---------------------------------------------------------------------------

function Get-AvailableLanguages {
    [CmdletBinding()]
    param()
    return @(Get-ChildItem -LiteralPath $script:LocaleRoot -Filter '*.psd1' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-MigratorLanguage {
    [CmdletBinding()]
    param()
    if ($script:Language) { return $script:Language }

    $available = @(Get-AvailableLanguages)
    $wanted = [string](Get-MigratorConfig).Language
    if ($env:MIGRATOR_LANG) { $wanted = $env:MIGRATOR_LANG }
    if ([string]::IsNullOrWhiteSpace($wanted) -or $wanted -eq 'auto') {
        $wanted = (Get-UICulture).TwoLetterISOLanguageName
    }
    $wanted = $wanted.ToLowerInvariant()
    if ($wanted -notin $available) { $wanted = 'en' }

    $script:Language = $wanted
    return $script:Language
}

function Import-MigratorStrings {
    $script:FallbackStrings = Import-PowerShellDataFile -LiteralPath (Join-Path $script:LocaleRoot 'en.psd1')
    $language = Get-MigratorLanguage
    if ($language -eq 'en') {
        $script:Strings = $script:FallbackStrings
    } else {
        $script:Strings = Import-PowerShellDataFile -LiteralPath (Join-Path $script:LocaleRoot "$language.psd1")
    }
}

function Get-Text {
    # Usage: T '<key>' [format arguments...]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(ValueFromRemainingArguments)][object[]]$FormatArgs
    )

    if ($null -eq $script:Strings) { Import-MigratorStrings }

    $text = $null
    if ($script:Strings.ContainsKey($Key)) {
        $text = [string]$script:Strings[$Key]
    } elseif ($script:FallbackStrings.ContainsKey($Key)) {
        $text = [string]$script:FallbackStrings[$Key]
    } else {
        return $Key
    }

    if ($FormatArgs -and $FormatArgs.Count -gt 0) {
        try { return ($text -f $FormatArgs) } catch { return $text }
    }
    return $text
}
Set-Alias -Name T -Value Get-Text

function Format-Size {
    [CmdletBinding()]
    param([Nullable[int64]]$Bytes)
    if ($null -eq $Bytes) { return (Get-Text 'unit.unknown') }
    $value = [double]$Bytes
    if ($value -ge 1TB) { return '{0:N2} {1}' -f ($value / 1TB), (Get-Text 'unit.tb') }
    if ($value -ge 1GB) { return '{0:N2} {1}' -f ($value / 1GB), (Get-Text 'unit.gb') }
    if ($value -ge 1MB) { return '{0:N1} {1}' -f ($value / 1MB), (Get-Text 'unit.mb') }
    if ($value -ge 1KB) { return '{0:N1} {1}' -f ($value / 1KB), (Get-Text 'unit.kb') }
    return '{0:N0} {1}' -f $value, (Get-Text 'unit.b')
}

function Format-Duration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][TimeSpan]$Duration)
    if ($Duration.TotalHours -ge 1) { return '{0}:{1:mm\:ss}' -f [int][Math]::Floor($Duration.TotalHours), $Duration }
    return '{0:mm\:ss}' -f $Duration
}

# ---------------------------------------------------------------------------
# Environment / profiles / disks
# ---------------------------------------------------------------------------

function Test-IsAdmin {
    [CmdletBinding()]
    param()
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UserProfiles {
    # The CIM query takes a noticeable fraction of a second, so the result is
    # cached; pass -Refresh after a profile may have been created.
    [CmdletBinding()]
    param([switch]$Refresh)

    if ($null -ne $script:ProfileCache -and -not $Refresh) { return $script:ProfileCache }

    $result = @(
        try {
            $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
                Where-Object { -not $_.Special -and $_.LocalPath }

            foreach ($profile in $profiles) {
                [pscustomobject]@{
                    Name      = Split-Path -Leaf $profile.LocalPath
                    LocalPath = $profile.LocalPath
                    SID       = [string]$profile.SID
                    Loaded    = [bool]$profile.Loaded
                    IsCurrent = ([string]$profile.SID -eq $currentSid)
                }
            }
        } catch {
            $usersRoot = Join-Path $env:SystemDrive 'Users'
            $excluded = @('All Users','Default','Default User','Public','DefaultAppPool','WDAGUtilityAccount')
            Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin $excluded } |
                ForEach-Object {
                    [pscustomobject]@{
                        Name      = $_.Name
                        LocalPath = $_.FullName
                        SID       = $null
                        Loaded    = $null
                        IsCurrent = ($_.Name -eq $env:USERNAME)
                    }
                }
        }
    )

    $script:ProfileCache = $result
    return $result
}

function Get-CurrentUserProfile {
    [CmdletBinding()]
    param()
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Get-UserProfiles | Where-Object { $_.SID -eq $sid } | Select-Object -First 1
}

function Get-ProfileByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [switch]$Refresh)
    Get-UserProfiles -Refresh:$Refresh | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Get-ProfileByPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    Get-UserProfiles | Where-Object { $_.LocalPath.TrimEnd('\') -eq $full } | Select-Object -First 1
}

function Get-TargetVolumes {
    # Fixed and removable drives other than the system drive.
    [CmdletBinding()]
    param()
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { $_.DriveType -in @(2, 3) -and $_.DeviceID -ne $env:SystemDrive } |
            ForEach-Object {
                [pscustomobject]@{
                    Drive      = $_.DeviceID
                    Label      = $_.VolumeName
                    FileSystem = $_.FileSystem
                    Size       = [int64]$_.Size
                    FreeSpace  = [int64]$_.FreeSpace
                }
            }
    } catch {
        @()
    }
}

function Get-FreeSpaceBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    if (-not $root) { return $null }
    try { return [IO.DriveInfo]::new($root).AvailableFreeSpace } catch { return $null }
}

function Test-PathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Child,
        [Parameter(Mandatory)][string]$Parent
    )
    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd('\')
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if ($childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $childFull.StartsWith($parentFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------------------
# Exclusion masks
# ---------------------------------------------------------------------------

function Get-ModeExcludeMasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Full','Standard')]
        [string]$Mode
    )

    $config = Get-MigratorConfig
    $masks = [System.Collections.Generic.List[string]]::new()
    foreach ($mask in @($config.CommonExcludes)) { $masks.Add([string]$mask) }
    if ($Mode -eq 'Standard') {
        foreach ($mask in @($config.StandardExcludes)) { $masks.Add([string]$mask) }
    }
    if ($Mode -eq 'Standard' -or $config.ExcludeDevCaches) {
        foreach ($mask in @($config.DevExcludes)) { $masks.Add([string]$mask) }
    }
    foreach ($mask in @($config.ExtraExcludes)) { $masks.Add([string]$mask) }
    return @($masks | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-RestoreExcludeMasks {
    [CmdletBinding()]
    param()
    $config = Get-MigratorConfig
    $masks = [System.Collections.Generic.List[string]]::new()
    foreach ($mask in @($config.CommonExcludes)) { $masks.Add([string]$mask) }
    foreach ($mask in @($config.RestoreExcludes)) { $masks.Add([string]$mask) }
    return @($masks | Where-Object { $_ } | Sort-Object -Unique)
}

function ConvertTo-MaskRegex {
    # One case-insensitive regex for a set of masks. Masks are matched against
    # profile-relative paths written with a leading '\' ('\AppData\Local\Temp\'
    # for a folder, '\Documents\a.tmp' for a file), so '*\Temp\' also matches a
    # top-level Temp folder and 'AppData\...' can only match from the root.
    [CmdletBinding()]
    param([string[]]$Masks)

    $parts = @(foreach ($mask in @($Masks)) {
        if ([string]::IsNullOrWhiteSpace($mask)) { continue }
        $normalized = if ($mask.StartsWith('*')) { $mask } else { '\' + $mask.TrimStart('\') }
        '^' + ([regex]::Escape($normalized) -replace '\\\*', '.*' -replace '\\\?', '.') + '$'
    })
    if ($parts.Count -eq 0) { return $null }
    return [regex]::new(($parts -join '|'),
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
        [Text.RegularExpressions.RegexOptions]::Compiled)
}

function Split-ExcludeMasks {
    # Folder masks, file-name masks ('*\name' - any folder, name only) and the
    # rare file masks that contain a path.
    [CmdletBinding()]
    param([string[]]$Masks)

    $folders = [System.Collections.Generic.List[string]]::new()
    $names = [System.Collections.Generic.List[string]]::new()
    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($mask in @($Masks)) {
        if ([string]::IsNullOrWhiteSpace($mask)) { continue }
        if ($mask.EndsWith('\')) { $folders.Add($mask); continue }
        if ($mask -match '^\*\\([^\\]+)$') { $names.Add($Matches[1]); continue }
        if ($mask -notmatch '\\') { $names.Add($mask); continue }
        $paths.Add($mask)
    }

    return [pscustomobject]@{
        FolderMasks   = @($folders)
        FileNameMasks = @($names | Sort-Object -Unique)
        FilePathMasks = @($paths)
    }
}

function Measure-ProfileTree {
    # One fast pass over the profile that does everything the backup needs:
    #   - size and file count AFTER exclusions (enumeration already returns
    #     file sizes, so there is no extra metadata call per file);
    #   - the exact list of excluded folders, handed to the archiver as plain
    #     paths, so the result does not depend on any archiver's mask dialect;
    #   - junctions/symlinks, which are never followed;
    #   - cloud-only placeholders (OneDrive Files On-Demand etc.).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExcludeMasks = @()
    )

    $excludedDirectories = [System.Collections.Generic.List[string]]::new()
    $excludedFiles = [System.Collections.Generic.List[string]]::new()
    $result = [pscustomobject]@{
        Bytes               = 0L
        Files               = 0L
        CloudOnlyFiles      = 0L
        CloudOnlyBytes      = 0L
        Links               = 0
        ExcludedDirectories = $excludedDirectories
        ExcludedFiles       = $excludedFiles
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $result }

    $split = Split-ExcludeMasks -Masks $ExcludeMasks
    $dirRegex  = ConvertTo-MaskRegex $split.FolderMasks
    $pathRegex = ConvertTo-MaskRegex $split.FilePathMasks
    # File-name masks are matched against the bare name: much shorter input.
    $nameRegex = $null
    if ($split.FileNameMasks.Count -gt 0) {
        $nameParts = @($split.FileNameMasks | ForEach-Object {
            '^' + ([regex]::Escape($_) -replace '\\\*', '.*' -replace '\\\?', '.') + '$'
        })
        $nameRegex = [regex]::new(($nameParts -join '|'),
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
            [Text.RegularExpressions.RegexOptions]::Compiled)
    }

    $options = [IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $false
    $options.IgnoreInaccessible = $true
    $options.AttributesToSkip = [IO.FileAttributes]::None
    $options.ReturnSpecialDirectories = $false

    $reparse = [int][IO.FileAttributes]::ReparsePoint
    $directory = [int][IO.FileAttributes]::Directory
    # FILE_ATTRIBUTE_OFFLINE | RECALL_ON_OPEN | RECALL_ON_DATA_ACCESS
    $cloudMask = 0x1000 -bor 0x40000 -bor 0x400000

    $bytes = 0L; $files = 0L; $cloudFiles = 0L; $cloudBytes = 0L; $links = 0
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@([IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path)), ''))

    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $relative = $item[1]
        try {
            foreach ($entry in $item[0].EnumerateFileSystemInfos('*', $options)) {
                $attributes = [int]$entry.Attributes
                $isCloud = ($attributes -band $cloudMask) -ne 0
                $entryRelative = $relative + '\' + $entry.Name

                if (($attributes -band $directory) -ne 0) {
                    # Cloud folders are reparse points too, but they are not links.
                    if (($attributes -band $reparse) -ne 0 -and -not $isCloud -and $null -ne $entry.LinkTarget) {
                        $links++
                        $excludedDirectories.Add($entryRelative.Substring(1))
                        continue
                    }
                    if ($dirRegex -and $dirRegex.IsMatch($entryRelative + '\')) {
                        $excludedDirectories.Add($entryRelative.Substring(1))
                        continue
                    }
                    $stack.Push(@($entry, $entryRelative))
                    continue
                }

                if ($nameRegex -and $nameRegex.IsMatch($entry.Name)) { continue }
                if ($pathRegex -and $pathRegex.IsMatch($entryRelative)) {
                    $excludedFiles.Add($entryRelative.Substring(1))
                    continue
                }

                $length = ([IO.FileInfo]$entry).Length
                $bytes += $length
                $files++
                if ($isCloud) {
                    $cloudFiles++
                    $cloudBytes += $length
                }
            }
        } catch { }
    }

    $result.Bytes = $bytes
    $result.Files = $files
    $result.CloudOnlyFiles = $cloudFiles
    $result.CloudOnlyBytes = $cloudBytes
    $result.Links = $links
    return $result
}

function Get-DirectorySizeFast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExcludeMasks = @()
    )
    return (Measure-ProfileTree -Path $Path -ExcludeMasks $ExcludeMasks).Bytes
}

function Get-CloudFolders {
    # Cloud-synced folders in the profile root, with their size and the
    # number of cloud-only (not downloaded) files.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilePath)

    $patterns = @((Get-MigratorConfig).CloudFolders | Where-Object { $_ })
    if ($patterns.Count -eq 0) { return @() }
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) { return @() }

    $found = @(Get-ChildItem -LiteralPath $ProfilePath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.Name
            @($patterns | Where-Object { $name -like $_ }).Count -gt 0
        })

    foreach ($folder in $found) {
        $stats = Measure-ProfileTree -Path $folder.FullName
        [pscustomobject]@{
            Name           = $folder.Name
            Path           = $folder.FullName
            Bytes          = $stats.Bytes
            Files          = $stats.Files
            CloudOnlyFiles = $stats.CloudOnlyFiles
            CloudOnlyBytes = $stats.CloudOnlyBytes
        }
    }
}

function Select-ExcludedArchiveFolders {
    # Restore side of the same mask logic: given the folder paths stored in an
    # archive, returns the top-most folders that match the folder masks.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Directories,
        [string[]]$ExcludeMasks = @()
    )

    $dirRegex = ConvertTo-MaskRegex (Split-ExcludeMasks -Masks $ExcludeMasks).FolderMasks
    if (-not $dirRegex) { return @() }

    $matched = @($Directories | Where-Object { $_ -and $dirRegex.IsMatch('\' + $_.Trim('\') + '\') } |
        ForEach-Object { $_.Trim('\') } | Sort-Object -Unique)

    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $matched) {
        $covered = $false
        foreach ($parent in $kept) {
            if ($path.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break }
        }
        if (-not $covered) { $kept.Add($path) }
    }
    return @($kept)
}

# ---------------------------------------------------------------------------
# Naming / manifests / logs
# ---------------------------------------------------------------------------

function New-SafeFileName {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'unknown' }
    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'unknown' }
    return $safe
}

function New-BackupArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$UserName
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $baseName = '{0}-{1}-{2}' -f (New-SafeFileName $ComputerName), (New-SafeFileName $UserName), $stamp

    return [pscustomobject]@{
        BaseName = $baseName
        Archive  = Join-Path $BackupRoot "$baseName.7z"
        Manifest = Join-Path $BackupRoot "$baseName.manifest.json"
        Summary  = Join-Path $BackupRoot "$baseName.summary.txt"
        ErrorLog = Join-Path $BackupRoot "$baseName.errors.log"
        Log      = Join-Path $BackupRoot "$baseName.log"
    }
}

function Get-ManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchivePath)
    return ($ArchivePath -replace '\.(7z|rar)$', '.manifest.json')
}

function Write-ManifestFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Data
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Set-Content -LiteralPath $Path -Value ($Data | ConvertTo-Json -Depth 8) -Encoding utf8
}

function Read-ManifestFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop |
               ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        return $null
    }
}

function Write-LogLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Message
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Add-Content -LiteralPath $Path -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message) -Encoding utf8
}

function Write-TextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Set-Content -LiteralPath $Path -Value ($Lines -join [Environment]::NewLine) -Encoding utf8
}

function Get-ArchiveMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchivePath)

    $item = Get-Item -LiteralPath $ArchivePath
    $manifestPath = Get-ManifestPath -ArchivePath $ArchivePath
    $manifest = Read-ManifestFile -Path $manifestPath

    $sourceUser = $null; $sourceSid = $null; $computer = $null; $created = $null
    $mode = $null; $sourceBytes = $null; $sourceFiles = $null; $sourceProfile = $null

    if ($manifest) {
        $sourceUser = [string]$manifest['sourceUser']
        $sourceSid = [string]$manifest['sourceSid']
        $computer = [string]$manifest['computer']
        $created = [string]$manifest['createdAtUtc']
        $mode = [string]$manifest['mode']
        $sourceBytes = $manifest['sourceBytes']
        $sourceFiles = $manifest['sourceFiles']
        $sourceProfile = [string]$manifest['sourceProfile']
    }

    if ([string]::IsNullOrWhiteSpace($sourceUser)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($item.Name)
        if ($name -match '^(?<computer>.+?)-(?<user>.+?)-(?<date>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})$') {
            $computer = $Matches['computer']
            $sourceUser = $Matches['user']
        } elseif ($name -match '^(?<user>.+)-profile$') {
            $sourceUser = $Matches['user']
        } else {
            $sourceUser = $name
        }
    }

    $archiveTime = $item.LastWriteTime
    if ($created) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($created, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            $archiveTime = $parsed.ToLocalTime()
        }
    }

    return [pscustomobject]@{
        ArchivePath   = $item.FullName
        ArchiveName   = $item.Name
        ArchiveBytes  = [int64]$item.Length
        ArchiveTime   = $archiveTime
        Format        = $item.Extension.TrimStart('.').ToLowerInvariant()
        SourceUser    = $sourceUser
        SourceSid     = $sourceSid
        SourceProfile = $sourceProfile
        Computer      = $computer
        Mode          = $mode
        SourceBytes   = $sourceBytes
        SourceFiles   = $sourceFiles
        HasManifest   = [bool]$manifest
        Manifest      = $manifest
        ManifestPath  = $manifestPath
    }
}

function Get-ArchiveList {
    # .7z archives made by this version and .rar archives made by 2.0.x.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupRoot)

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { return @() }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($archive in @(Get-ChildItem -LiteralPath $BackupRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.7z', '.rar') })) {
        if ($archive.Name -match '\.part(\d+)\.rar$' -and [int]$Matches[1] -ne 1) { continue }
        $result.Add((Get-ArchiveMetadata -ArchivePath $archive.FullName))
    }
    return @($result | Sort-Object { $_.ArchiveTime } -Descending)
}

# ---------------------------------------------------------------------------
# Native command line quoting
# ---------------------------------------------------------------------------

function ConvertTo-NativeArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Argument)

    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq '\') { $backslashes++; continue }
        if ($char -eq '"') {
            [void]$builder.Append('\' * ($backslashes * 2 + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($char)
    }

    if ($backslashes -gt 0) { [void]$builder.Append('\' * ($backslashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-NativeCommandLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    return (($Arguments | ForEach-Object { ConvertTo-NativeArgument -Argument $_ }) -join ' ')
}

Export-ModuleMember -Alias 'T' -Function @(
    'Get-MigratorRoot'
    'Get-DefaultConfig'
    'Get-MigratorConfig'
    'Set-MigratorUserSetting'
    'Resolve-MigratorPath'
    'Get-AvailableLanguages'
    'Get-MigratorLanguage'
    'Get-Text'
    'Format-Size'
    'Format-Duration'
    'Test-IsAdmin'
    'Get-UserProfiles'
    'Get-CurrentUserProfile'
    'Get-ProfileByName'
    'Get-ProfileByPath'
    'Get-TargetVolumes'
    'Get-FreeSpaceBytes'
    'Test-PathWithin'
    'Get-ModeExcludeMasks'
    'Get-RestoreExcludeMasks'
    'ConvertTo-MaskRegex'
    'Split-ExcludeMasks'
    'Measure-ProfileTree'
    'Get-DirectorySizeFast'
    'Get-CloudFolders'
    'Select-ExcludedArchiveFolders'
    'New-SafeFileName'
    'New-BackupArtifacts'
    'Get-ManifestPath'
    'Write-ManifestFile'
    'Read-ManifestFile'
    'Write-LogLine'
    'Write-TextFile'
    'Get-ArchiveMetadata'
    'Get-ArchiveList'
    'ConvertTo-NativeArgument'
    'ConvertTo-NativeCommandLine'
)
