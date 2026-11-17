#Requires -Version 7.0
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Migrator.Programs.psm1
# The list of installed programs: saved in the manifest when a backup is
# made, offered for installation with winget after a restore.
#
#   manifest.programs.winget     package ids winget can install again
#   manifest.programs.installed  names of everything installed (for reference)
#
# A profile archive does not contain the programs themselves. The list lets
# the user tick what to put back instead of remembering what was there.
# ---------------------------------------------------------------------------

function Get-WingetPath {
    $command = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Read-WingetExport {
    # Package ids from a "winget export" file. Only the "winget" source:
    # Store ids are unreadable codes, and Store apps come back by themselves
    # when the user signs in.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $ids = [System.Collections.Generic.List[string]]::new()
    if ($data -and $data.ContainsKey('Sources')) {
        foreach ($source in @($data['Sources'])) {
            if (-not $source -or -not $source.ContainsKey('SourceDetails')) { continue }
            if ([string]$source['SourceDetails']['Name'] -ne 'winget') { continue }
            foreach ($package in @($source['Packages'])) {
                if ($package -and $package['PackageIdentifier']) { $ids.Add([string]$package['PackageIdentifier']) }
            }
        }
    }
    return @($ids | Sort-Object -Unique)
}

function Get-WingetPackageIds {
    # Ids of the installed programs winget knows, or $null when that cannot
    # be found out (no winget, it failed, or it did not answer in time).
    # MIGRATOR_TEST_WINGET_EXPORT replaces the call with a ready export file
    # for the tests (a missing file = no winget).
    # The array comes back as one object, so $null and "nothing installed"
    # stay different: assign the result, do not wrap the call in @().
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 90)

    if ($env:MIGRATOR_TEST_WINGET_EXPORT) {
        if (-not (Test-Path -LiteralPath $env:MIGRATOR_TEST_WINGET_EXPORT -PathType Leaf)) { return $null }
        $found = @(Read-WingetExport -Path $env:MIGRATOR_TEST_WINGET_EXPORT)
        return , $found
    }

    $winget = Get-WingetPath
    if (-not $winget) { return $null }

    $base = Join-Path ([IO.Path]::GetTempPath()) ('migrator-programs-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N'))
    try {
        # The output (one line for every program winget does not know) goes
        # to files, not to the screen.
        $process = Start-Process -FilePath $winget -NoNewWindow -PassThru `
            -RedirectStandardOutput "$base.out" -RedirectStandardError "$base.err" -ArgumentList @(
                'export', '--output', "`"$base.json`"", '--source', 'winget',
                '--accept-source-agreements', '--disable-interactivity'
            )
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            return $null
        }
        if (-not (Test-Path -LiteralPath "$base.json" -PathType Leaf)) { return $null }
        $found = @(Read-WingetExport -Path "$base.json")
        return , $found
    } catch {
        return $null
    } finally {
        foreach ($extension in 'json', 'out', 'err') {
            Remove-Item -LiteralPath "$base.$extension" -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-InstalledProgramNames {
    # "Installed apps" as Windows shows them: names and versions from the
    # uninstall keys of the machine and of one user.
    [CmdletBinding()]
    param([string]$Sid)

    $tail = 'Microsoft\Windows\CurrentVersion\Uninstall'
    $roots = @(
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\$tail"
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\$tail"
        $(if ($Sid) { "Registry::HKEY_USERS\$Sid\Software\$tail" } else { "Registry::HKEY_CURRENT_USER\Software\$tail" })
    )

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $roots) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $name = [string]$key.GetValue('DisplayName')
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                if ($key.GetValue('SystemComponent') -eq 1) { continue }        # hidden from "Installed apps"
                if ($key.GetValue('ParentKeyName')) { continue }                # an update of another program
                if ([string]$key.GetValue('ReleaseType') -match 'Update|Hotfix') { continue }
                $version = [string]$key.GetValue('DisplayVersion')
                $names.Add($(if ($version) { '{0}  {1}' -f $name.Trim(), $version.Trim() } else { $name.Trim() }))
            } catch { }
        }
    }
    return @($names | Sort-Object -Unique)
}

function Get-InstalledProgramList {
    # What goes into the manifest. Winget is $null when winget could not be asked.
    [CmdletBinding()]
    param([string]$Sid)

    $ids = Get-WingetPackageIds
    return [pscustomobject]@{
        Winget    = $ids
        Installed = @(Get-InstalledProgramNames -Sid $Sid)
    }
}

function Test-ProgramMask {
    param([string]$Id, [object[]]$Masks)
    foreach ($mask in @($Masks)) { if ($mask -and $Id -like [string]$mask) { return $true } }
    return $false
}

function Get-ProgramChoices {
    # Sorts the saved package ids into:
    #   Present   - already installed on this PC
    #   Hidden    - runtimes and components that come with the programs needing them
    #   Unchecked - shown without a tick: tied to the old hardware, trial
    #               antiviruses, "optimizers" (config: ProgramsUnchecked)
    #   Install   - shown with a tick
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Ids = @(),
        [AllowEmptyCollection()][string[]]$InstalledIds = @()
    )

    $config = Get-MigratorConfig
    $result = foreach ($id in @($Ids | Where-Object { $_ } | Sort-Object -Unique)) {
        $state = 'Install'
        if ($InstalledIds -contains $id) { $state = 'Present' }
        elseif (Test-ProgramMask -Id $id -Masks $config.ProgramsHidden) { $state = 'Hidden' }
        elseif (Test-ProgramMask -Id $id -Masks $config.ProgramsUnchecked) { $state = 'Unchecked' }
        [pscustomobject]@{ Id = $id; State = $state }
    }
    return @($result)
}

function Install-WingetPrograms {
    # Installs the packages one by one, so one failure does not stop the rest
    # and every program gets its own line in the result.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Ids, [scriptblock]$Log)

    $winget = Get-WingetPath
    $failed = [System.Collections.Generic.List[string]]::new()
    $number = 0
    foreach ($id in $Ids) {
        $number++
        Write-Host ''
        Write-Text (T 'p.installing' $number $Ids.Count $id)
        # A separate process attached to this console: winget draws its own progress.
        $process = Start-Process -FilePath $winget -NoNewWindow -PassThru -ArgumentList @(
            'install', '--id', $id, '--exact', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )
        $process.WaitForExit()
        $code = $process.ExitCode
        # 0x8A15002B: already installed and nothing newer to install.
        $ok = ($code -eq 0 -or $code -eq -1978335189)
        if (-not $ok) {
            Write-Warn (T 'p.failed_one' $id $code)
            $failed.Add($id)
        }
        if ($Log) { & $Log "Program $id`: winget exit $code" }
        [void](Reset-SleepTimer)
    }
    return [pscustomobject]@{ Installed = $Ids.Count - $failed.Count; Failed = @($failed) }
}

function Invoke-ProgramRestore {
    # After a restore: writes the saved program list to a file and, in an
    # interactive run on a PC with winget, lets the user tick what to install.
    # Nothing is installed without two typed "y": one to open the list, one
    # to start the installation.
    [CmdletBinding()]
    param(
        $Manifest,
        [string]$SourceUser = '',
        [Parameter(Mandatory)][string]$ListPath,
        [switch]$Interactive,
        [scriptblock]$Log
    )

    if (-not $Manifest -or -not $Manifest['programs']) { return }
    $programs = $Manifest['programs']
    $ids = @(@($programs['winget']) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $names = @(@($programs['installed']) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ($ids.Count -eq 0 -and $names.Count -eq 0) { return }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($ids.Count -gt 0) {
        $lines.Add((T 'p.file.winget'))
        foreach ($id in $ids) { $lines.Add("  $id") }
        $lines.Add('')
    }
    $lines.Add((T 'p.file.all'))
    foreach ($name in $names) { $lines.Add("  $name") }
    Write-TextFile -Path $ListPath -Lines @($lines)
    if ($Log) { & $Log "Program list from the backup: winget=$($ids.Count) installed=$($names.Count) file=$ListPath" }

    Write-Section (T 'p.section')
    Write-Text (T 'p.found' $SourceUser $names.Count $ids.Count)
    Write-Hint (T 'p.file' $ListPath)
    if (-not $Interactive -or $ids.Count -eq 0) { return }

    if (-not (Get-WingetPath)) {
        Write-Host ''
        Write-Warn (T 'p.no_winget')
        Write-Solution (T 'p.by_hand' $ListPath)
        return
    }

    if (-not (Read-YesNo (T 'p.ask_choose') $false)) { Write-Hint (T 'p.nothing'); return }

    Write-Hint (T 'p.checking')
    $here = Get-WingetPackageIds
    $choices = @(Get-ProgramChoices -Ids $ids -InstalledIds $(if ($null -eq $here) { @() } else { @($here) }))
    $shown = @(@($choices | Where-Object { $_.State -eq 'Install' }) + @($choices | Where-Object { $_.State -eq 'Unchecked' }))
    if ($shown.Count -eq 0) { Write-Ok (T 'p.all_installed'); return }

    $items = @(foreach ($choice in $shown) {
        $unchecked = ($choice.State -eq 'Unchecked')
        New-CheckItem -Value $choice.Id -Label $choice.Id -Checked (-not $unchecked) -Hint $(if ($unchecked) { T 'p.unchecked_hint' } else { '' })
    })
    $picked = Show-CheckList -Title (T 'p.list_title' ($choices.Count - $shown.Count)) -Items $items
    if ($null -eq $picked -or @($picked).Count -eq 0) { Write-Hint (T 'p.nothing'); return }
    $picked = @($picked | ForEach-Object { [string]$_ })

    Write-Host ''
    Write-Hint (T 'p.paid_hint')
    if (-not (Read-YesNo (T 'p.confirm' $picked.Count) $false)) { Write-Hint (T 'p.nothing'); return }

    $result = Install-WingetPrograms -Ids $picked -Log $Log
    Write-Host ''
    if ($result.Failed.Count -eq 0) {
        Write-Ok (T 'p.summary' $result.Installed $picked.Count)
    } else {
        Write-Warn (T 'p.summary' $result.Installed $picked.Count)
        Write-Solution (T 'p.failed_list' ($result.Failed -join ', '))
    }
    if ($Log) { & $Log "Programs installed: $($result.Installed) of $($picked.Count); failed: $($result.Failed -join ', ')" }
}

Export-ModuleMember -Function @(
    'Get-WingetPath'
    'Read-WingetExport'
    'Get-WingetPackageIds'
    'Get-InstalledProgramNames'
    'Get-InstalledProgramList'
    'Get-ProgramChoices'
    'Install-WingetPrograms'
    'Invoke-ProgramRestore'
)
