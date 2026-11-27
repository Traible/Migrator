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

function Get-WingetFailureHint {
    # What to do about a winget exit code that has a known cause; '' for the
    # rest (the code is shown anyway).
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Code, [Parameter(Mandatory)][string]$Id)

    switch ($Code) {
        # 0x8A15008E: the new version uses another installer type (MSI vs EXE,
        # per-user vs machine) than the installed one; winget will not upgrade
        # across that.
        -1978335090 { return (T 'w.hint.technology' $Id) }
        # 0x8A150006: winget started the program's own installer, and that
        # installer reported a failure.
        -1978335226 { return (T 'w.hint.installer') }
    }
    return ''
}

function Install-WingetPrograms {
    # Installs the packages one by one, so one failure does not stop the rest
    # and every program gets its own line in the result.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Ids,
        [ValidateSet('install', 'upgrade')][string]$Verb = 'install',
        [scriptblock]$Log
    )

    $winget = Get-WingetPath
    $failed = [System.Collections.Generic.List[string]]::new()
    $hinted = [System.Collections.Generic.List[string]]::new()
    $number = 0
    foreach ($id in $Ids) {
        $number++
        Write-Host ''
        Write-Text (T 'p.installing' $number $Ids.Count $id)
        # A separate process attached to this console: winget draws its own progress.
        $process = Start-Process -FilePath $winget -NoNewWindow -PassThru -ArgumentList @(
            $Verb, '--id', $id, '--exact', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )
        $process.WaitForExit()
        $code = $process.ExitCode
        # 0x8A15002B: already installed and nothing newer to install.
        $ok = ($code -eq 0 -or $code -eq -1978335189)
        if (-not $ok) {
            Write-Warn $(if ($Verb -eq 'upgrade') { T 'u.failed_one' $id $code } else { T 'p.failed_one' $id $code })
            $hint = Get-WingetFailureHint -Code $code -Id $id
            if ($hint) { Write-Solution $hint; $hinted.Add($id) }
            $failed.Add($id)
        }
        if ($Log) { & $Log "Program $id`: winget exit $code" }
        [void](Reset-SleepTimer)
    }
    return [pscustomobject]@{ Installed = $Ids.Count - $failed.Count; Failed = @($failed); Hinted = @($hinted) }
}

# After this many failed updates a program is no longer recommended.
$script:SkipAfterFailures = 2

function Get-UpdateFailures {
    # Failed updates remembered by this copy (UpdateFailures in user.json):
    # program id -> @{ version = the last version that failed; count = how many times }.
    [CmdletBinding()]
    param()
    $result = @{}
    $saved = (Get-MigratorConfig)['UpdateFailures']
    if ($saved -is [System.Collections.IDictionary]) {
        foreach ($id in $saved.Keys) {
            $entry = $saved[$id]
            if ($entry -is [System.Collections.IDictionary] -and $entry['version']) {
                $result[[string]$id] = @{ version = [string]$entry['version']; count = [int]$entry['count'] }
            }
        }
    }
    return $result
}

function Update-UpdateFailures {
    # The failure record after an update run: every failure counts up,
    # whatever the version; only a successful update (a program ticked by
    # hand) forgets the program.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Failures,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Attempted,
        [AllowEmptyCollection()][string[]]$Failed = @()
    )
    $next = @{}
    foreach ($id in $Failures.Keys) { $next[$id] = $Failures[$id] }
    foreach ($item in $Attempted) {
        if ($Failed -contains $item.Id) {
            $old = $next[$item.Id]
            $count = if ($old) { $old.count + 1 } else { 1 }
            $next[$item.Id] = @{ version = [string]$item.Available; count = $count }
        } else {
            $next.Remove($item.Id)
        }
    }
    return $next
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

# ---------------------------------------------------------------------------
# Updates of the installed programs
# ---------------------------------------------------------------------------

function ConvertFrom-WingetUpgradeText {
    # Rows of the table "winget upgrade --source winget" prints:
    #   Name ... Id  Version  Available
    #   -----------------------------------
    #   Git      Git.Git  2.54.0  2.56.0.4
    #   23 upgrades available.
    # winget has no machine-readable output for this list. Every row is read
    # from the right (available, version, id; the rest is the name), which
    # does not depend on the column positions, the language of the headers or
    # the width of the letters in a name.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')

    $lines = @($Text -split "`r?`n")
    $start = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^-{20,}\s*$') { $start = $i + 1; break }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($start -lt 0) { return @() }

    for ($i = $start; $i -lt $lines.Count; $i++) {
        $tokens = @($lines[$i].Trim() -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -lt 4) { break }
        $available = $tokens[-1]
        $version = $tokens[-2]
        $idIndex = $tokens.Count - 3
        # "< 2.0": the installed version is only known to be older than this.
        if ($tokens[$idIndex] -in @('<', '>') -and $idIndex -ge 2) { $version = $tokens[$idIndex] + ' ' + $version; $idIndex-- }
        $id = $tokens[$idIndex]
        # A package id is "Publisher.Package"; the footer lines are not.
        if ($idIndex -lt 1 -or $id -notmatch '^[^\s.]+\.\S+$') { break }
        $rows.Add([pscustomobject]@{
            Name      = ($tokens[0..($idIndex - 1)] -join ' ')
            Id        = $id
            Version   = $version
            Available = $available
        })
    }
    return @($rows)
}

function Get-WingetUpgrades {
    # Programs with a newer version in winget, or $null when winget cannot be
    # asked. Each one carries Recommended: its id is in the UpdateRecommended
    # list of everyday programs that update without surprises. Skipped: this
    # copy failed to update it twice, so it is never Recommended here any more
    # (it can still be ticked by hand or updated with "Everything").
    # The array comes back as one object: assign the result, do not wrap the
    # call in @(). MIGRATOR_TEST_WINGET_UPGRADE replaces the call with a saved
    # output for the tests; -Failures replaces the saved failure record.
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 180, [hashtable]$Failures)

    if (-not $PSBoundParameters.ContainsKey('Failures')) { $Failures = Get-UpdateFailures }

    $text = $null
    if ($env:MIGRATOR_TEST_WINGET_UPGRADE) {
        if (-not (Test-Path -LiteralPath $env:MIGRATOR_TEST_WINGET_UPGRADE -PathType Leaf)) { return $null }
        $text = [IO.File]::ReadAllText($env:MIGRATOR_TEST_WINGET_UPGRADE, [Text.Encoding]::UTF8)
    } else {
        $winget = Get-WingetPath
        if (-not $winget) { return $null }
        $base = Join-Path ([IO.Path]::GetTempPath()) ('migrator-programs-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N'))
        try {
            $process = Start-Process -FilePath $winget -NoNewWindow -PassThru `
                -RedirectStandardOutput "$base.out" -RedirectStandardError "$base.err" -ArgumentList @(
                    'upgrade', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity'
                )
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try { $process.Kill($true) } catch { }
                return $null
            }
            if (-not (Test-Path -LiteralPath "$base.out" -PathType Leaf)) { return $null }
            $text = [IO.File]::ReadAllText("$base.out", [Text.Encoding]::UTF8)
        } catch {
            return $null
        } finally {
            foreach ($extension in 'out', 'err') { Remove-Item -LiteralPath "$base.$extension" -Force -ErrorAction SilentlyContinue }
        }
    }

    $masks = (Get-MigratorConfig).UpdateRecommended
    $found = @(ConvertFrom-WingetUpgradeText -Text $text | ForEach-Object {
        $failure = $Failures[$_.Id]
        $skipped = [bool]($failure -and $failure.count -ge $script:SkipAfterFailures)
        $recommended = (-not $skipped) -and (Test-ProgramMask -Id $_.Id -Masks $masks)
        $_ | Add-Member -NotePropertyName Recommended -NotePropertyValue $recommended -PassThru |
             Add-Member -NotePropertyName Skipped -NotePropertyValue $skipped -PassThru
    } | Sort-Object Id)
    return , $found
}

function Invoke-ProgramUpdate {
    # Shows which installed programs have a newer version and updates:
    #   Recommended - only the ones from the UpdateRecommended list;
    #   All         - everything winget offers;
    #   interactive without -Scope: a menu with both and "choose from the list".
    # Interactive runs ask for a typed "y" before anything is updated; in a
    # non-interactive run the -Scope switch is the consent.
    # Returns $false when winget could not be asked or a program failed, and
    # 'Restarted' when Migrator was started again as administrator.
    [CmdletBinding()]
    param(
        [ValidateSet('', 'Recommended', 'All')][string]$Scope = '',
        [switch]$ListOnly,
        [switch]$Interactive
    )

    Write-Hint (T 'u.checking')
    $upgrades = Get-WingetUpgrades
    if ($null -eq $upgrades) {
        Write-Host ''
        Write-Warn (T 'u.no_winget')
        Write-Solution (T 'u.no_winget_solution')
        return $false
    }
    $upgrades = @($upgrades)
    if ($upgrades.Count -eq 0) { Write-Ok (T 'u.none'); return $true }

    $recommended = @($upgrades | Where-Object { $_.Recommended })
    $other = @($upgrades | Where-Object { -not $_.Recommended -and -not $_.Skipped })
    $skippedItems = @($upgrades | Where-Object { $_.Skipped })
    $everything = @($recommended + $other + $skippedItems)
    $idWidth = ($upgrades | ForEach-Object { $_.Id.Length } | Measure-Object -Maximum).Maximum
    $versionWidth = ($upgrades | ForEach-Object { $_.Version.Length } | Measure-Object -Maximum).Maximum
    $describe = { param($item) '{0}  {1} -> {2}' -f $item.Id.PadRight($idWidth), $item.Version.PadRight($versionWidth), $item.Available }

    if ($recommended.Count -gt 0) {
        Write-Host ''
        Write-Ok (T 'u.recommended_title' $recommended.Count)
        foreach ($item in $recommended) { Write-Text ('     ' + (& $describe $item)) }
    }
    if ($other.Count -gt 0) {
        Write-Host ''
        Write-Warn (T 'u.other_title' $other.Count)
        foreach ($item in $other) { Write-Hint ('     ' + (& $describe $item)) }
    }
    if ($skippedItems.Count -gt 0) {
        Write-Host ''
        Write-Warn (T 'u.skipped_title' $skippedItems.Count)
        foreach ($item in $skippedItems) { Write-Hint ('     ' + (& $describe $item)) }
        Write-Solution (T 'u.skipped_solution')
    }
    Write-Host ''
    Write-Hint (T 'u.source_note')
    if ($ListOnly) { return $true }

    $picked = @()
    if ($Interactive) {
        $choice = $Scope
        $isAdmin = Test-IsAdmin
        if (-not $choice) {
            if (-not $isAdmin) {
                # Without administrator rights Windows asks for permission
                # again for every program installed for all users.
                Write-Host ''
                Write-Warn (T 'u.admin_hint')
                Write-Solution (T 'u.admin_solution')
            }
            $items = [System.Collections.Generic.List[object]]::new()
            if ($recommended.Count -gt 0) {
                $items.Add((New-MenuItem -Value 'Recommended' -Label (T 'u.menu.recommended' $recommended.Count) -Hint (T 'u.menu.recommended.hint')))
            }
            $items.Add((New-MenuItem -Value 'Choose' -Label (T 'u.menu.choose') -Hint (T 'u.menu.choose.hint')))
            if ($everything.Count -gt 0) {
                $items.Add((New-MenuItem -Value 'All' -Label (T 'u.menu.all' $everything.Count) -Hint (T 'u.menu.all.hint')))
            }
            if (-not $isAdmin) { $items.Add((New-MenuItem -Value 'Admin' -Label (T 'm.menu.admin') -Key 'A')) }
            $items.Add((New-MenuItem -Value 'Cancel' -Label (T 'ui.cancel') -Key 'Q'))
            $choice = Show-Menu -Title (T 'u.menu.title') -Items @($items) -AllowCancel
        }
        switch ($choice) {
            'Admin' {
                # Migrator again, in a new window with administrator rights,
                # opened on this screen. 'Restarted' tells the caller to close
                # this window; when Windows was not given the permission,
                # nothing was started and this window stays.
                $script = Join-Path (Get-MigratorRoot) 'src\main.ps1'
                $launchArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Start', 'Update')
                try {
                    Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList (ConvertTo-NativeCommandLine -Arguments $launchArgs)
                } catch {
                    Write-Warn (T 'u.admin_declined')
                    return $true
                }
                Write-Hint (T 'm.admin.restarting')
                return 'Restarted'
            }
            'Recommended' { $picked = @($recommended.Id) }
            'All'         { $picked = @($everything.Id) }
            'Choose' {
                $checkItems = @(foreach ($item in @($recommended + $other + $skippedItems)) {
                    New-CheckItem -Value $item.Id -Label (& $describe $item) -Checked ([bool]$item.Recommended)
                })
                $ticked = Show-CheckList -Title (T 'u.menu.choose') -Items $checkItems
                if ($null -ne $ticked) { $picked = @($ticked | ForEach-Object { [string]$_ }) }
            }
        }
        if ($picked.Count -eq 0) { Write-Hint (T 'u.nothing'); return $true }
        Write-Host ''
        if (-not (Read-YesNo (T 'u.confirm' $picked.Count) $false)) { Write-Hint (T 'u.nothing'); return $true }
    } else {
        $picked = if ($Scope -eq 'All') { @($everything.Id) } elseif ($Scope -eq 'Recommended') { @($recommended.Id) } else { @() }
        if ($picked.Count -eq 0) { Write-Hint (T 'u.nothing'); return $true }
    }

    $result = Install-WingetPrograms -Ids $picked -Verb upgrade

    # Remember what failed, so that a program failing again and again is
    # skipped instead of costing time on every run. A read-only folder only
    # means the record is not kept.
    $attempted = @($upgrades | Where-Object { $picked -contains $_.Id })
    $record = Update-UpdateFailures -Failures (Get-UpdateFailures) -Attempted $attempted -Failed @($result.Failed)
    try { Set-MigratorUserSetting -Name 'UpdateFailures' -Value $record } catch { }

    Write-Host ''
    if ($result.Failed.Count -eq 0) {
        Write-Ok (T 'u.summary' $result.Installed $picked.Count)
        return $true
    }
    Write-Warn (T 'u.summary' $result.Installed $picked.Count)
    $failedText = $result.Failed -join ', '
    $allHinted = @($result.Failed | Where-Object { $result.Hinted -notcontains $_ }).Count -eq 0
    Write-Solution $(if ($allHinted) { T 'u.failed_list_hinted' $failedText } else { T 'u.failed_list' $failedText })
    $nowSkipped = @($result.Failed | Where-Object { $record[$_].count -eq $script:SkipAfterFailures })
    if ($nowSkipped.Count -gt 0) { Write-Hint (T 'u.skipped_next' ($nowSkipped -join ', ')) }
    return $false
}

Export-ModuleMember -Function @(
    'ConvertFrom-WingetUpgradeText'
    'Get-WingetUpgrades'
    'Invoke-ProgramUpdate'
    'Get-WingetPath'
    'Read-WingetExport'
    'Get-WingetPackageIds'
    'Get-InstalledProgramNames'
    'Get-InstalledProgramList'
    'Get-ProgramChoices'
    'Install-WingetPrograms'
    'Get-WingetFailureHint'
    'Get-UpdateFailures'
    'Update-UpdateFailures'
    'Invoke-ProgramRestore'
)
