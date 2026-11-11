#Requires -Version 7.0
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Migrator.UI.psm1
# Everything the user sees: one color theme, message helpers, aligned
# fields, arrow-key menus, prompts and the progress line.
# ---------------------------------------------------------------------------

# One place for every color used by the tool.
$script:Theme = @{
    Title   = 'Cyan'
    Rule    = 'DarkCyan'
    Text    = 'Gray'
    Value   = 'White'
    Label   = 'DarkGray'
    Hint    = 'DarkGray'
    Ok      = 'Green'
    Warn    = 'Yellow'
    Error   = 'Red'
    Accent  = 'Cyan'
    Key     = 'Yellow'
}
$script:RuleWidth = 70

function Get-UiTheme { return $script:Theme }

function Test-InteractiveConsole {
    # Arrow-key menus and in-place progress need a real console.
    try {
        return (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
    } catch {
        return $false
    }
}

function Clear-Screen {
    if (Test-InteractiveConsole) { try { Clear-Host } catch { } }
}

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

function Write-Banner {
    [CmdletBinding()]
    param([string]$Subtitle = '')
    $config = Get-MigratorConfig
    Write-Host ''
    Write-Host ('  {0}  v{1}' -f (T 'app.title'), $config.ToolVersion) -ForegroundColor $script:Theme.Title
    Write-Host ('  ' + ('=' * ($script:RuleWidth - 2))) -ForegroundColor $script:Theme.Rule
    if ($Subtitle) {
        Write-Host ('  ' + $Subtitle) -ForegroundColor $script:Theme.Hint
    }
    Write-Host ''
}

function Write-Section {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor $script:Theme.Title
    Write-Host ('  ' + ('-' * [Math]::Min($script:RuleWidth - 2, [Math]::Max(8, $Text.Length)))) -ForegroundColor $script:Theme.Rule
}

function Write-Text {
    param([AllowEmptyString()][string]$Text = '')
    Write-Host ('  ' + $Text) -ForegroundColor $script:Theme.Text
}

function Write-Hint {
    param([AllowEmptyString()][string]$Text = '')
    Write-Host ('  ' + $Text) -ForegroundColor $script:Theme.Hint
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host '  [OK] ' -ForegroundColor $script:Theme.Ok -NoNewline
    Write-Host $Text -ForegroundColor $script:Theme.Ok
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host '  [!]  ' -ForegroundColor $script:Theme.Warn -NoNewline
    Write-Host $Text -ForegroundColor $script:Theme.Warn
}

function Write-Err {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host '  [X]  ' -ForegroundColor $script:Theme.Error -NoNewline
    Write-Host $Text -ForegroundColor $script:Theme.Error
}

function Write-Fields {
    # Aligned "label : value" rows. The label column is sized to the longest
    # label, so translated labels of any length line up.
    #   $Fields: ordered dictionary label -> value, or label -> @(value, color)
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields,
        [int]$Indent = 2
    )

    $width = 0
    foreach ($label in $Fields.Keys) { $width = [Math]::Max($width, ([string]$label).Length) }

    foreach ($label in $Fields.Keys) {
        $value = $Fields[$label]
        $color = $script:Theme.Value
        if ($value -is [array] -and $value.Count -eq 2 -and $script:Theme.ContainsKey([string]$value[1])) {
            $color = $script:Theme[[string]$value[1]]
            $value = $value[0]
        }
        Write-Host ((' ' * $Indent) + ([string]$label).PadRight($width) + ' : ') -ForegroundColor $script:Theme.Label -NoNewline
        Write-Host ([string]$value) -ForegroundColor $color
    }
}

function Write-SummaryBox {
    # A titled block with aligned fields: shown before an operation starts
    # and again with the result.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields,
        [string]$Color = 'Title'
    )

    $ruleColor = if ($script:Theme.ContainsKey($Color)) { $script:Theme[$Color] } else { $script:Theme.Title }
    $rule = '+' + ('-' * ($script:RuleWidth - 4)) + '+'
    Write-Host ''
    Write-Host ('  ' + $rule) -ForegroundColor $ruleColor
    Write-Host ('    ' + $Title) -ForegroundColor $ruleColor
    Write-Host ('  ' + $rule) -ForegroundColor $ruleColor
    Write-Fields -Fields $Fields -Indent 4
    Write-Host ('  ' + $rule) -ForegroundColor $ruleColor
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

function Read-Line {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt)
    Write-Host ('  ' + $Prompt + ': ') -ForegroundColor $script:Theme.Accent -NoNewline
    return (Read-Host)
}

function Wait-Enter {
    [CmdletBinding()]
    param([string]$Prompt)
    if (-not $Prompt) { $Prompt = T 'ui.press_enter' }
    Write-Host ''
    Write-Host ('  ' + $Prompt) -ForegroundColor $script:Theme.Hint -NoNewline
    [void](Read-Host)
}

function Read-YesNo {
    # Accepts y/n in English and the localized letters (д/н in Russian).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $false
    )

    $yes = (T 'ui.yes_letter'); $no = (T 'ui.no_letter')
    $suffix = if ($Default) { '[{0}/{1}]' -f $yes.ToUpper(), $no.ToLower() } else { '[{0}/{1}]' -f $yes.ToLower(), $no.ToUpper() }
    $yesAnswers = @('y', 'yes', $yes.ToLower(), (T 'ui.yes').ToLower())
    $noAnswers  = @('n', 'no', $no.ToLower(), (T 'ui.no').ToLower())

    while ($true) {
        Write-Host ('  ' + $Prompt + ' ' + $suffix + ' ') -ForegroundColor $script:Theme.Accent -NoNewline
        $raw = Read-Host
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $answer = $raw.Trim().ToLowerInvariant()
        if ($answer -in $yesAnswers) { return $true }
        if ($answer -in $noAnswers) { return $false }
        Write-Warn (T 'ui.answer_yes_no' $yes.ToUpper() $no.ToUpper())
    }
}

function New-MenuItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Label,
        [string]$Hint = '',
        [string]$Key = ''
    )
    return [pscustomobject]@{ Value = $Value; Label = $Label; Hint = $Hint; Key = $Key }
}

function Show-Menu {
    # Arrow-key menu. Up/Down move, Enter selects, a digit or a hot key
    # selects directly, Esc cancels (returns $null) when -AllowCancel is set.
    # Without a real console it falls back to typing the item number.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Title = '',
        [int]$Default = 0,
        [switch]$AllowCancel
    )

    if ($Items.Count -eq 0) { return $null }
    $Default = [Math]::Max(0, [Math]::Min($Items.Count - 1, $Default))

    # Hot keys: an explicit Key, otherwise 1..9 by position.
    $keys = @(for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i].Key) { ([string]$Items[$i].Key).ToUpperInvariant() }
        elseif ($i -lt 9) { [string]($i + 1) }
        else { '' }
    })

    if ($Title) {
        Write-Host ''
        Write-Host ('  ' + $Title) -ForegroundColor $script:Theme.Value
    }

    if (-not (Test-InteractiveConsole)) {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            Write-Host ('   [{0}] {1}' -f $keys[$i], $Items[$i].Label) -ForegroundColor $script:Theme.Text
            if ($Items[$i].Hint) { Write-Host ('       ' + $Items[$i].Hint) -ForegroundColor $script:Theme.Hint }
        }
        while ($true) {
            $raw = Read-Line (T 'ui.menu_number')
            if ([string]::IsNullOrWhiteSpace($raw)) { return $Items[$Default].Value }
            $answer = $raw.Trim().ToUpperInvariant()
            if ($AllowCancel -and $answer -in @('Q', 'ESC')) { return $null }
            $index = [array]::IndexOf($keys, $answer)
            if ($index -ge 0) { return $Items[$index].Value }
            Write-Warn (T 'ui.menu_invalid')
        }
    }

    $footer = if ($AllowCancel) { T 'ui.menu_help_cancel' } else { T 'ui.menu_help' }
    $selected = $Default
    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    $lineCount = 0
    foreach ($item in $Items) { $lineCount += $(if ($item.Hint) { 2 } else { 1 }) }
    $lineCount += 1   # footer

    $draw = {
        foreach ($i in 0..($Items.Count - 1)) {
            $item = $Items[$i]
            $isSelected = ($i -eq $selected)
            $marker = if ($isSelected) { ' > ' } else { '   ' }
            $keyText = if ($keys[$i]) { '[{0}] ' -f $keys[$i] } else { '    ' }
            $line = ($marker + $keyText + $item.Label)
            if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
            if ($isSelected) {
                Write-Host $line.PadRight($width) -ForegroundColor Black -BackgroundColor $script:Theme.Accent
            } else {
                Write-Host $marker -NoNewline
                Write-Host $keyText -ForegroundColor $script:Theme.Key -NoNewline
                $rest = $item.Label
                $room = $width - $marker.Length - $keyText.Length
                if ($rest.Length -gt $room) { $rest = $rest.Substring(0, [Math]::Max(0, $room)) }
                Write-Host $rest.PadRight([Math]::Max(0, $room)) -ForegroundColor $script:Theme.Text
            }
            if ($item.Hint) {
                $hint = '       ' + $item.Hint
                if ($hint.Length -gt $width) { $hint = $hint.Substring(0, $width) }
                Write-Host $hint.PadRight($width) -ForegroundColor $script:Theme.Hint
            }
        }
        $help = '   ' + $footer
        if ($help.Length -gt $width) { $help = $help.Substring(0, $width) }
        Write-Host $help.PadRight($width) -ForegroundColor $script:Theme.Hint
    }

    $cursorVisible = $true
    try { $cursorVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }
    try {
        & $draw
        while ($true) {
            $key = [Console]::ReadKey($true)
            $choice = $null

            switch ($key.Key) {
                'UpArrow'   { $selected = ($selected - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $selected = ($selected + 1) % $Items.Count }
                'Home'      { $selected = 0 }
                'End'       { $selected = $Items.Count - 1 }
                'Enter'     { $choice = $selected }
                'Escape'    { if ($AllowCancel) { return $null } }
                default {
                    $char = ([string]$key.KeyChar).ToUpperInvariant()
                    if ($char -and $char -ne "`0") {
                        $index = [array]::IndexOf($keys, $char)
                        if ($index -ge 0) { $selected = $index; $choice = $index }
                    }
                }
            }

            # Redraw in place: go back up over the lines just written.
            $top = [Math]::Max(0, [Console]::CursorTop - $lineCount)
            [Console]::SetCursorPosition(0, $top)
            & $draw

            if ($null -ne $choice) { return $Items[$choice].Value }
        }
    } finally {
        try { [Console]::CursorVisible = $cursorVisible } catch { }
    }
}

# ---------------------------------------------------------------------------
# Progress line: bar, percent, speed, remaining time
# ---------------------------------------------------------------------------

function New-ProgressState {
    [CmdletBinding()]
    param(
        [string]$Activity = '',
        [int64]$TotalBytes = 0
    )
    return [pscustomobject]@{
        Activity     = $Activity
        TotalBytes   = $TotalBytes
        Started      = Get-Date
        Interactive  = (Test-InteractiveConsole)
        LastPercent  = -1.0
        NextLogStep  = 10
        LastLength   = 0
        SpinIndex    = 0
        # Samples for a moving-average speed: (seconds, bytes)
        Samples      = [System.Collections.Generic.Queue[object]]::new()
    }
}

function Format-ProgressLine {
    # Pure formatting, kept separate so it can be tested.
    [CmdletBinding()]
    param(
        [string]$Activity = '',
        [double]$Percent = 0,
        [Nullable[double]]$BytesPerSecond,
        [Nullable[TimeSpan]]$Remaining,
        [TimeSpan]$Elapsed = [TimeSpan]::Zero,
        [int]$BarWidth = 28
    )

    $unicode = [bool](Get-MigratorConfig).Unicode
    $full = if ($unicode) { [string][char]0x2588 } else { '#' }
    $empty = if ($unicode) { [string][char]0x2591 } else { '-' }

    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $filled = [int][Math]::Floor($Percent / 100 * $BarWidth)
    $bar = ($full * $filled) + ($empty * ($BarWidth - $filled))

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add(('{0} {1} {2,3:N0}%' -f $Activity, $bar, $Percent).Trim())
    if ($null -ne $BytesPerSecond -and $BytesPerSecond -gt 0) {
        $parts.Add(('{0}/{1}' -f (Format-Size ([int64]$BytesPerSecond)), (T 'unit.sec')))
    }
    if ($null -ne $Remaining) {
        $parts.Add((T 'progress.remaining' (Format-Duration $Remaining)))
    } else {
        $parts.Add((T 'progress.elapsed' (Format-Duration $Elapsed)))
    }
    return ($parts -join '  ')
}

function Update-ProgressState {
    # -Percent comes from the archiver (whole percents); -BytesDone, when
    # known, gives a smoother percentage and a real speed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Nullable[int]]$Percent,
        [Nullable[int64]]$BytesDone
    )

    $elapsed = (Get-Date) - $State.Started
    $value = $null
    if ($null -ne $BytesDone -and $State.TotalBytes -gt 0) {
        $value = [Math]::Min(99.9, 100.0 * $BytesDone / $State.TotalBytes)
        if ($null -ne $Percent -and $Percent -ge 100) { $value = 100.0 }
    } elseif ($null -ne $Percent) {
        $value = [double]$Percent
    }

    if ($null -eq $value) {
        # Nothing to show yet: the archiver is still scanning.
        if ($State.Interactive) {
            $spin = @('|', '/', '-', '\')[$State.SpinIndex % 4]
            $State.SpinIndex++
            $line = '  {0} {1} {2}  {3}' -f $State.Activity, $spin, (T 'progress.preparing'), (Format-Duration $elapsed)
            Write-ProgressText -State $State -Line $line
        }
        return
    }

    $value = [Math]::Max($State.LastPercent, $value)   # never go backwards
    $State.LastPercent = $value

    # Speed over the last few seconds; remaining time from that speed.
    $speed = $null
    $remaining = $null
    $doneBytes = if ($null -ne $BytesDone) { [double]$BytesDone }
                 elseif ($State.TotalBytes -gt 0) { $State.TotalBytes * $value / 100.0 }
                 else { $null }

    if ($null -ne $doneBytes) {
        $State.Samples.Enqueue(@($elapsed.TotalSeconds, $doneBytes))
        while ($State.Samples.Count -gt 2 -and ($elapsed.TotalSeconds - $State.Samples.Peek()[0]) -gt 10) {
            [void]$State.Samples.Dequeue()
        }
        $first = $State.Samples.Peek()
        $span = $elapsed.TotalSeconds - $first[0]
        if ($span -ge 1.5 -and $doneBytes -gt $first[1]) {
            $speed = ($doneBytes - $first[1]) / $span
            if ($State.TotalBytes -gt $doneBytes) {
                $remaining = [TimeSpan]::FromSeconds([Math]::Min(359999, ($State.TotalBytes - $doneBytes) / $speed))
            }
        }
    } elseif ($value -ge 1 -and $elapsed.TotalSeconds -ge 3) {
        $remaining = [TimeSpan]::FromSeconds([Math]::Min(359999, $elapsed.TotalSeconds * (100 - $value) / $value))
    }

    if ($State.Interactive) {
        $line = '  ' + (Format-ProgressLine -Activity $State.Activity -Percent $value -BytesPerSecond $speed `
            -Remaining $remaining -Elapsed $elapsed)
        Write-ProgressText -State $State -Line $line
    } elseif ($value -ge $State.NextLogStep) {
        Write-Host ('  {0}: {1:N0}%  ({2})' -f $State.Activity, $value, (Format-Duration $elapsed))
        $State.NextLogStep = ([Math]::Floor($value / 10) + 1) * 10
    }
}

function Write-ProgressText {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Line)
    $width = 0
    try { $width = [Console]::WindowWidth - 1 } catch { }
    if ($width -gt 10 -and $Line.Length -gt $width) { $Line = $Line.Substring(0, $width) }
    $pad = [Math]::Max(0, $State.LastLength - $Line.Length)
    Write-Host ("`r" + $Line + (' ' * $pad)) -NoNewline -ForegroundColor $script:Theme.Accent
    $State.LastLength = $Line.Length
}

function Complete-ProgressState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    if ($State.Interactive -and $State.LastLength -gt 0) {
        Write-Host ("`r" + (' ' * $State.LastLength) + "`r") -NoNewline
        $State.LastLength = 0
    }
}

Export-ModuleMember -Function @(
    'Get-UiTheme'
    'Test-InteractiveConsole'
    'Clear-Screen'
    'Write-Banner'
    'Write-Section'
    'Write-Text'
    'Write-Hint'
    'Write-Ok'
    'Write-Warn'
    'Write-Err'
    'Write-Fields'
    'Write-SummaryBox'
    'Read-Line'
    'Wait-Enter'
    'Read-YesNo'
    'New-MenuItem'
    'Show-Menu'
    'New-ProgressState'
    'Format-ProgressLine'
    'Update-ProgressState'
    'Complete-ProgressState'
)
