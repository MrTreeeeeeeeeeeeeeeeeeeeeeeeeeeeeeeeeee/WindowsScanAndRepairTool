@echo off
setlocal DisableDelayedExpansion
title Windows Scan and Fix

set "SYSDIR=%SystemRoot%\System32"
if exist "%SystemRoot%\Sysnative\cmd.exe" set "SYSDIR=%SystemRoot%\Sysnative"

set "_PS_EXE=powershell.exe"
if exist "%SYSDIR%\WindowsPowerShell\v1.0\powershell.exe" set "_PS_EXE=%SYSDIR%\WindowsPowerShell\v1.0\powershell.exe"

"%SYSDIR%\fltmc.exe" >nul 2>&1
if not "%errorlevel%"=="0" goto :elevate
goto :run_engine

:elevate
if /i "%~1"=="--elevated" (
    echo [ERROR] Administrator privileges are required to run Windows Scan and Fix.
    echo Please right-click this file and choose "Run as administrator".
    echo.
    pause
    exit /b 1
)
echo Requesting Administrator privileges...
set "_SELF=%~f0"
"%_PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:_SELF -ArgumentList '--elevated' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (
    echo.
    echo [CANCELLED] Administrator access was declined or could not be started.
    echo.
    pause
    exit /b 1
)
exit /b 0

:run_engine
set "_SELF=%~f0"
set "_SCRIPT_DIR=%~dp0"
set "_PS_TMP=%TEMP%\Windows_Scan_and_Fix_%RANDOM%_%RANDOM%.ps1"

"%_PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$raw = [System.IO.File]::ReadAllText($env:_SELF, [System.Text.Encoding]::UTF8); $m = '#__' + 'PS_ENGINE_START__'; $i = $raw.LastIndexOf($m); if ($i -lt 0) { throw 'Embedded PowerShell engine not found.' }; $ps = $raw.Substring($i + $m.Length); [System.IO.File]::WriteAllText($env:_PS_TMP, $ps, (New-Object System.Text.UTF8Encoding($false)))"
if errorlevel 1 (
    echo.
    echo [ERROR] Failed to initialize the diagnostic engine.
    echo.
    pause
    exit /b 1
)

"%_PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%_PS_TMP%"
set "_EXIT=%errorlevel%"
if exist "%_PS_TMP%" del /f /q "%_PS_TMP%" >nul 2>&1

if not "%_EXIT%"=="0" (
    echo.
    echo [ERROR] Script exited with code %_EXIT%.
    echo.
    pause
)
exit /b %_EXIT%
#__PS_ENGINE_START__
param(
    [switch]$SkipRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Get-SafeProp {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
}

function Write-RawLog {
    param(
        [string]$Message,
        [string]$LogPath
    )
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    try {
        [System.IO.File]::AppendAllText($LogPath, $Message + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # Keep scan running even if log append fails
    }
}

function Format-DurationSpan {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) {
        return ('{0}h {1}m {2}s' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
    }
    if ($Span.TotalMinutes -ge 1) {
        return ('{0}m {1}s' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds)
    }
    return ('{0}s' -f [int][math]::Round($Span.TotalSeconds))
}

function Format-ClockSpan {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
    }
    return ('{0:00}:{1:00}' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Get-ConsoleSafeWidth {
    $w = 78
    try {
        $cw = [Console]::WindowWidth
        if ($cw -ge 50) { $w = [math]::Min(110, $cw - 1) }
    } catch {
        $w = 78
    }
    return $w
}

function Truncate-Text {
    param(
        [string]$Text,
        [int]$MaxLen
    )
    if ([string]::IsNullOrEmpty($Text) -or $MaxLen -le 0) { return '' }
    $clean = ($Text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
    if ($clean.Length -le $MaxLen) { return $clean }
    if ($MaxLen -le 3) { return $clean.Substring(0, $MaxLen) }
    return $clean.Substring(0, $MaxLen - 3) + '...'
}

function Invoke-ConsoleTool {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [ValidateSet('Default', 'Unicode')][string]$Encoding = 'Default',
        [scriptblock]$OnTick = $null,
        [switch]$EchoToConsole
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    if ($Encoding -eq 'Unicode') {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode
        $psi.StandardErrorEncoding = [System.Text.Encoding]::Unicode
    } else {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::Default
        $psi.StandardErrorEncoding = [System.Text.Encoding]::Default
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    $errTask = $proc.StandardError.ReadToEndAsync()
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object char[] 512
    $readTask = $proc.StandardOutput.ReadAsync($buf, 0, $buf.Length)

    $stageLabel = ''
    $liveHint = ''
    $lastTick = [datetime]::MinValue

    while ($true) {
        if ($readTask.Wait(180)) {
            $n = $readTask.Result
            if ($n -le 0) { break }
            $chunk = (New-Object string ($buf, 0, $n)).Replace("`0", '')
            [void]$sb.Append($chunk)
            if ($EchoToConsole) { [Console]::Write($chunk) }

            if ($chunk -match '(Stage\s+\d+)') {
                $stageLabel = $matches[1]
            }
            $pctMatches = [regex]::Matches($chunk, '(\d+(?:\.\d+)?)\s*%')
            if ($pctMatches.Count -gt 0) {
                $pct = $pctMatches[$pctMatches.Count - 1].Groups[1].Value + '%'
                $liveHint = if (-not [string]::IsNullOrWhiteSpace($stageLabel)) { "$stageLabel - $pct" } else { $pct }
            } elseif ($chunk -match '(Observing system behavior|Analyzing trace data|Beginning verification phase|Beginning system scan|Enabling tracing)') {
                $liveHint = $matches[1] + '...'
            }

            $readTask = $proc.StandardOutput.ReadAsync($buf, 0, $buf.Length)
        }

        if ($null -ne $OnTick) {
            $now = Get-Date
            if (($now - $lastTick).TotalMilliseconds -ge 180) {
                $lastTick = $now
                try { & $OnTick $liveHint } catch {}
            }
        }
    }

    $proc.WaitForExit()
    $errText = $errTask.GetAwaiter().GetResult()
    $outText = $sb.ToString().Replace("`0", '')
    if ($null -eq $errText) {
        $errText = ''
    } else {
        $errText = $errText.Replace("`0", '')
    }

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Output   = $outText
        Error    = $errText
    }
}

function New-DefaultScanConfig {
    $stepDefs = @(
        [PSCustomObject]@{ Order=1;  Id='disk_health';      ShortName='Physical Disks & Free Space';    Tag='Get-PhysicalDisk + SMART' }
        [PSCustomObject]@{ Order=2;  Id='power_energy';     ShortName='Power, Energy & Battery';        Tag='powercfg /energy (60s)' }
        [PSCustomObject]@{ Order=3;  Id='reliability';      ShortName='Reliability & Crash Logs';       Tag='perfmon /rel + WHEA/BSOD' }
        [PSCustomObject]@{ Order=4;  Id='drivers';          ShortName='Device Manager Drivers';         Tag='Broken/missing drivers' }
        [PSCustomObject]@{ Order=5;  Id='security_posture'; ShortName='Security & Memory Integrity';    Tag='HVCI + Firewall + Defender' }
        [PSCustomObject]@{ Order=6;  Id='wmi_repo';         ShortName='WMI Repository Repair';          Tag='winmgmt /verify & /salvage' }
        [PSCustomObject]@{ Order=7;  Id='dism_scan';        ShortName='DISM Component Store Scan';      Tag='DISM /ScanHealth' }
        [PSCustomObject]@{ Order=8;  Id='dism_restore';     ShortName='DISM Repair & Cleanup';          Tag='DISM /RestoreHealth + Clean' }
        [PSCustomObject]@{ Order=9;  Id='sfc';              ShortName='System File Integrity';          Tag='sfc /scannow' }
        [PSCustomObject]@{ Order=10; Id='chkdsk';           ShortName='All Connected Drives Scan';      Tag='chkdsk /scan (all drives)' }
        [PSCustomObject]@{ Order=11; Id='opt_cleanup';      ShortName='SSD TRIM & Safe Temp Cleanup';   Tag='ReTrim + Temp > 24h' }
        [PSCustomObject]@{ Order=12; Id='network_time';     ShortName='Network, DNS & Clock Sync';      Tag='flushdns + winsock + w32tm' }
        [PSCustomObject]@{ Order=13; Id='core_services';    ShortName='Core Windows Services';          Tag='Recover stopped services' }
        [PSCustomObject]@{ Order=14; Id='defender';         ShortName='Microsoft Defender Scan';        Tag='Start-MpScan' }
        [PSCustomObject]@{ Order=15; Id='memdiag';          ShortName='Windows Memory Diagnostic';      Tag='RAM test on restart' }
    )

    $enabled = @{}
    foreach ($s in $stepDefs) { $enabled[$s.Order] = $true }

    return [PSCustomObject]@{
        Preset          = 'Full'
        Enabled         = $enabled
        DefenderMode    = 'FullScan'
        AutoRestart     = $true
        OpenReport      = $true
        RestartDelaySec = 30
        StepDefs        = $stepDefs
    }
}

function Apply-ScanConfigInput {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$InputLine
    )

    $trimmed = if ($null -eq $InputLine) { '' } else { $InputLine.Trim() }
    if ($trimmed -eq '' -or $trimmed -match '^(?i)(s|start|run)$') {
        $enabledCount = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
        if ($enabledCount -eq 0) {
            return [PSCustomObject]@{ Action='Message'; Text='Enable at least one check before starting.' }
        }
        return [PSCustomObject]@{ Action='Start'; Text='' }
    }

    if ($trimmed -match '^(?i)(x|exit|quit)$') {
        return [PSCustomObject]@{ Action='Exit'; Text='' }
    }

    $tokens = @($trimmed -split '[\s,]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $notes = New-Object 'System.Collections.Generic.List[string]'

    foreach ($tok in $tokens) {
        $up = $tok.ToUpperInvariant()
        if ($up -match '^\d+$') {
            $num = [int]$up
            if ($num -ge 1 -and $num -le 15) {
                $newVal = -not [bool]$Config.Enabled[$num]
                $Config.Enabled[$num] = $newVal
                $Config.Preset = 'Custom'
                if ($num -eq 14) {
                    if ($newVal -and $Config.DefenderMode -eq 'Off') { $Config.DefenderMode = 'FullScan' }
                    if (-not $newVal) { $Config.DefenderMode = 'Off' }
                }
            } else {
                $notes.Add("Unknown step: $tok (use 1-15)")
            }
        } elseif ($up -eq 'F' -or $up -eq 'FULL') {
            foreach ($k in 1..15) { $Config.Enabled[$k] = $true }
            $Config.DefenderMode = 'FullScan'
            $Config.AutoRestart = $true
            $Config.OpenReport = $true
            $Config.Preset = 'Full'
            $notes.Add('Applied Full Scan preset (all 15 checks + Full Defender + Restart).')
        } elseif ($up -eq 'Q' -or $up -eq 'QUICK') {
            foreach ($k in 1..15) { $Config.Enabled[$k] = $true }
            $Config.Enabled[2] = $false
            $Config.Enabled[15] = $false
            $Config.DefenderMode = 'QuickScan'
            $Config.AutoRestart = $false
            $Config.OpenReport = $true
            $Config.Preset = 'Quick'
            $notes.Add('Applied Quick Tune-Up preset (Quick Defender, no 60s energy trace, no reboot).')
        } elseif ($up -eq 'A' -or $up -eq 'ALL') {
            foreach ($k in 1..15) { $Config.Enabled[$k] = $true }
            if ($Config.DefenderMode -eq 'Off') { $Config.DefenderMode = 'FullScan' }
            $Config.Preset = 'Custom'
            $notes.Add('Selected all 15 checks.')
        } elseif ($up -eq 'N' -or $up -eq 'NONE') {
            foreach ($k in 1..15) { $Config.Enabled[$k] = $false }
            $Config.DefenderMode = 'Off'
            $Config.Preset = 'Custom'
            $notes.Add('Deselected all checks.')
        } elseif ($up -eq 'D') {
            switch ($Config.DefenderMode) {
                'FullScan'  { $Config.DefenderMode = 'QuickScan'; $Config.Enabled[14] = $true }
                'QuickScan' { $Config.DefenderMode = 'Off';       $Config.Enabled[14] = $false }
                default     { $Config.DefenderMode = 'FullScan';  $Config.Enabled[14] = $true }
            }
            $Config.Preset = 'Custom'
        } elseif ($up -eq 'R') {
            $Config.AutoRestart = -not $Config.AutoRestart
            $Config.Preset = 'Custom'
        } elseif ($up -eq 'M') {
            $Config.Enabled[15] = -not [bool]$Config.Enabled[15]
            $Config.Preset = 'Custom'
        } elseif ($up -eq 'O') {
            $Config.OpenReport = -not $Config.OpenReport
        } else {
            $notes.Add("Unrecognized option: $tok")
        }
    }

    return [PSCustomObject]@{ Action='Continue'; Text=($notes -join ' ') }
}

function Get-MenuEntries {
    param([Parameter(Mandatory = $true)]$Config)

    $items = New-Object 'System.Collections.Generic.List[object]'
    $items.Add([PSCustomObject]@{
        Kind='Start'; Order=0; Checked=$null
        Label='[ START SCAN ]'; Detail='Run selected checks now (or press S)'
    })

    foreach ($s in $Config.StepDefs) {
        $isOn = [bool]$Config.Enabled[$s.Order]
        $detail = $s.Tag
        if ($s.Order -eq 14) { $detail = "Mode: $($Config.DefenderMode) (Space/Left/Right)" }
        if ($s.Order -eq 15) { $detail = if ($Config.AutoRestart) { 'Runs during auto-restart' } else { 'Runs on next manual restart' } }
        $numStr = ('{0,2}' -f $s.Order)
        $items.Add([PSCustomObject]@{
            Kind='Step'; Order=$s.Order; Checked=$isOn
            Label="$numStr. $($s.ShortName)"; Detail=$detail
        })
    }

    $rstDetail = if ($Config.AutoRestart) { "Yes ($($Config.RestartDelaySec)s countdown)" } else { 'No (stay in Windows)' }
    $items.Add([PSCustomObject]@{
        Kind='Restart'; Order=0; Checked=[bool]$Config.AutoRestart
        Label='Restart PC When Done'; Detail=$rstDetail
    })

    $openDetail = if ($Config.OpenReport) {
        if ($Config.AutoRestart) { 'Yes (auto after reboot)' } else { 'Yes (immediately when done)' }
    } else { 'No (save to Desktop only)' }
    $items.Add([PSCustomObject]@{
        Kind='OpenReport'; Order=0; Checked=[bool]$Config.OpenReport
        Label='Open HTML Report Automatically'; Detail=$openDetail
    })

    $items.Add([PSCustomObject]@{
        Kind='Exit'; Order=0; Checked=$null
        Label='[ Exit ]'; Detail='Cancel without making any changes'
    })

    return @($items.ToArray())
}

function Invoke-MenuKeyAction {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [int]$CursorIndex,
        [string]$KeyName,
        [string]$KeyChar = ''
    )

    $entries = Get-MenuEntries -Config $Config
    $maxIdx = $entries.Count - 1
    if ($CursorIndex -lt 0) { $CursorIndex = 0 }
    if ($CursorIndex -gt $maxIdx) { $CursorIndex = $maxIdx }

    $current = $entries[$CursorIndex]
    $upperChar = if ([string]::IsNullOrEmpty($KeyChar)) { '' } else { $KeyChar.ToUpperInvariant() }

    if ($KeyName -eq 'UpArrow') {
        $next = if ($CursorIndex -le 0) { $maxIdx } else { $CursorIndex - 1 }
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$next; Feedback='' }
    }
    if ($KeyName -eq 'DownArrow') {
        $next = if ($CursorIndex -ge $maxIdx) { 0 } else { $CursorIndex + 1 }
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$next; Feedback='' }
    }
    if ($KeyName -eq 'Home') {
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=0; Feedback='' }
    }
    if ($KeyName -eq 'End') {
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$maxIdx; Feedback='' }
    }
    if ($KeyName -eq 'PageUp') {
        $next = [math]::Max(0, $CursorIndex - 5)
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$next; Feedback='' }
    }
    if ($KeyName -eq 'PageDown') {
        $next = [math]::Min($maxIdx, $CursorIndex + 5)
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$next; Feedback='' }
    }
    if ($KeyName -eq 'Escape' -or $upperChar -eq 'X') {
        return [PSCustomObject]@{ Action='Exit'; CursorIndex=$CursorIndex; Feedback='' }
    }

    if ($upperChar -eq 'S') {
        $enabledCount = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
        if ($enabledCount -eq 0) {
            return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='Select at least one check before starting.' }
        }
        return [PSCustomObject]@{ Action='Start'; CursorIndex=$CursorIndex; Feedback='' }
    }
    if ($upperChar -eq 'F') {
        [void](Apply-ScanConfigInput -Config $Config -InputLine 'F')
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='Preset: Full Scan (all 15 checks + Full Defender + Restart).' }
    }
    if ($upperChar -eq 'Q') {
        [void](Apply-ScanConfigInput -Config $Config -InputLine 'Q')
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='Preset: Quick Tune-Up (Quick Defender, no 60s energy trace, no reboot).' }
    }
    if ($upperChar -eq 'A') {
        [void](Apply-ScanConfigInput -Config $Config -InputLine 'A')
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='Selected all 15 checks.' }
    }
    if ($upperChar -eq 'N') {
        [void](Apply-ScanConfigInput -Config $Config -InputLine 'N')
        return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='Deselected all checks.' }
    }

    if ($KeyName -in @('Spacebar', 'Enter', 'RightArrow', 'LeftArrow')) {
        if ($current.Kind -eq 'Start') {
            if ($KeyName -in @('Enter', 'Spacebar')) {
                $enabledCount = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
                if ($enabledCount -eq 0) {
                    return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='Select at least one check before starting.' }
                }
                return [PSCustomObject]@{ Action='Start'; CursorIndex=$CursorIndex; Feedback='' }
            }
            return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='' }
        }
        if ($current.Kind -eq 'Exit') {
            if ($KeyName -in @('Enter', 'Spacebar')) {
                return [PSCustomObject]@{ Action='Exit'; CursorIndex=$CursorIndex; Feedback='' }
            }
            return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='' }
        }
        if ($current.Kind -eq 'Step') {
            if ($current.Order -eq 14) {
                if ($KeyName -eq 'LeftArrow') {
                    switch ($Config.DefenderMode) {
                        'FullScan'  { $Config.DefenderMode = 'Off';       $Config.Enabled[14] = $false }
                        'Off'       { $Config.DefenderMode = 'QuickScan'; $Config.Enabled[14] = $true }
                        default     { $Config.DefenderMode = 'FullScan';  $Config.Enabled[14] = $true }
                    }
                } else {
                    switch ($Config.DefenderMode) {
                        'FullScan'  { $Config.DefenderMode = 'QuickScan'; $Config.Enabled[14] = $true }
                        'QuickScan' { $Config.DefenderMode = 'Off';       $Config.Enabled[14] = $false }
                        default     { $Config.DefenderMode = 'FullScan';  $Config.Enabled[14] = $true }
                    }
                }
                $Config.Preset = 'Custom'
                return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback="Defender mode set to: $($Config.DefenderMode)" }
            }
            $Config.Enabled[$current.Order] = -not [bool]$Config.Enabled[$current.Order]
            $Config.Preset = 'Custom'
            return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='' }
        }
        if ($current.Kind -eq 'Restart') {
            $Config.AutoRestart = -not [bool]$Config.AutoRestart
            $Config.Preset = 'Custom'
            return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='' }
        }
        if ($current.Kind -eq 'OpenReport') {
            $Config.OpenReport = -not [bool]$Config.OpenReport
            return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='' }
        }
    }

    return [PSCustomObject]@{ Action='Continue'; CursorIndex=$CursorIndex; Feedback='' }
}

function Show-OptionsMenu {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$OSCaption = 'Windows'
    )

    $interactive = $true
    try {
        if ([Console]::IsInputRedirected) { $interactive = $false }
    } catch {
        $interactive = $false
    }

    if (-not $interactive) {
        $feedback = ''
        while ($true) {
            Write-Host "Preset: $($Config.Preset) | Press Enter to start, or type option (1-15, F, Q, D, R, M, O, A, N, X)"
            if (-not [string]::IsNullOrWhiteSpace($feedback)) { Write-Host "  > $feedback" }
            $ans = Read-Host 'Choice'
            $res = Apply-ScanConfigInput -Config $Config -InputLine $ans
            if ($res.Action -eq 'Start') { return $Config }
            if ($res.Action -eq 'Exit')  { return $null }
            $feedback = $res.Text
        }
    }

    $cursorIdx = 0
    $scrollTop = 0
    $feedback = 'Use Up/Down arrows to navigate, Space/Enter to toggle, or press Enter on [ START SCAN ].'
    $lastW = -1
    $lastH = -1

    try {
        try { [Console]::CursorVisible = $false } catch {}
        try { Clear-Host } catch {}

        while ($true) {
            $w = Get-ConsoleSafeWidth
            $h = 30
            try {
                $ch = [Console]::WindowHeight
                if ($ch -ge 14) { $h = $ch }
            } catch {}

            if ($w -ne $lastW -or $h -ne $lastH) {
                try { Clear-Host } catch {}
                $lastW = $w
                $lastH = $h
            }

            try { [Console]::SetCursorPosition(0, 0) } catch {}

            $entries = Get-MenuEntries -Config $Config
            $selectedCount = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
            $bar = '=' * $w
            $sep = '-' * $w

            # Header (4 lines) + Footer (4 lines) + Scroll hints (2 lines) = 10 reserved lines
            $maxVisible = [math]::Max(5, $h - 10)
            if ($cursorIdx -lt $scrollTop) { $scrollTop = $cursorIdx }
            if ($cursorIdx -ge ($scrollTop + $maxVisible)) { $scrollTop = $cursorIdx - $maxVisible + 1 }
            $maxScroll = [math]::Max(0, $entries.Count - $maxVisible)
            if ($scrollTop -gt $maxScroll) { $scrollTop = $maxScroll }
            $endIdx = [math]::Min($entries.Count - 1, $scrollTop + $maxVisible - 1)

            Write-Host $bar -ForegroundColor DarkCyan
            Write-Host (('  ' + (Truncate-Text "WINDOWS SCAN & FIX  |  Settings  [Preset: $($Config.Preset) | $selectedCount/15 Checks]" ($w - 2))).PadRight($w)) -ForegroundColor Cyan
            Write-Host (('  ' + (Truncate-Text "PC: $env:COMPUTERNAME  |  $OSCaption" ($w - 2))).PadRight($w)) -ForegroundColor Gray
            Write-Host $bar -ForegroundColor DarkCyan

            $aboveHint = if ($scrollTop -gt 0) { '    ^ More items above (Up Arrow)' } else { '' }
            Write-Host ($aboveHint.PadRight($w)) -ForegroundColor DarkGray

            for ($i = $scrollTop; $i -le $endIdx; $i++) {
                $item = $entries[$i]
                $isSel = ($i -eq $cursorIdx)
                $ptr = if ($isSel) { '>' } else { ' ' }

                if ($null -eq $item.Checked) {
                    $box = '   '
                } elseif ([bool]$item.Checked) {
                    $box = '[x]'
                } else {
                    $box = '[ ]'
                }

                $lblCol = $item.Label.PadRight(33)
                $detMax = [math]::Max(8, $w - 44)
                $detTxt = Truncate-Text $item.Detail $detMax
                $rowStr = ("  $ptr $box $lblCol $detTxt").PadRight($w)
                if ($rowStr.Length -gt $w) { $rowStr = $rowStr.Substring(0, $w) }

                if ($isSel) {
                    $bg = if ($item.Kind -eq 'Start') { 'DarkGreen' } elseif ($item.Kind -eq 'Exit') { 'DarkRed' } else { 'DarkCyan' }
                    Write-Host $rowStr -ForegroundColor White -BackgroundColor $bg
                } elseif ($item.Kind -eq 'Start') {
                    Write-Host $rowStr -ForegroundColor Green
                } elseif ($item.Kind -eq 'Exit') {
                    Write-Host $rowStr -ForegroundColor DarkGray
                } elseif ($null -ne $item.Checked -and -not [bool]$item.Checked) {
                    Write-Host $rowStr -ForegroundColor DarkGray
                } else {
                    Write-Host $rowStr -ForegroundColor White
                }
            }

            $belowHint = if ($endIdx -lt ($entries.Count - 1)) { '    v More items below (Down Arrow)' } else { '' }
            Write-Host ($belowHint.PadRight($w)) -ForegroundColor DarkGray

            Write-Host $sep -ForegroundColor DarkGray
            $fbLine = if ([string]::IsNullOrWhiteSpace($feedback)) { '' } else { '  ' + (Truncate-Text $feedback ($w - 2)) }
            Write-Host ($fbLine.PadRight($w)) -ForegroundColor Yellow
            $helpLine = '  ' + (Truncate-Text 'Up/Down: Move | Space/Enter: Toggle | S: Start | F: Full | Q: Quick | A/N: All/None | Esc: Exit' ($w - 2))
            Write-Host ($helpLine.PadRight($w)) -ForegroundColor Cyan -NoNewline

            $keyInfo = [Console]::ReadKey($true)
            $keyName = $keyInfo.Key.ToString()
            $keyChar = if ($keyInfo.KeyChar -eq [char]0) { '' } else { [string]$keyInfo.KeyChar }

            $act = Invoke-MenuKeyAction -Config $Config -CursorIndex $cursorIdx -KeyName $keyName -KeyChar $keyChar
            $cursorIdx = $act.CursorIndex
            if (-not [string]::IsNullOrWhiteSpace($act.Feedback)) {
                $feedback = $act.Feedback
            } else {
                $feedback = ''
            }
            if ($act.Action -eq 'Start') { return $Config }
            if ($act.Action -eq 'Exit')  { return $null }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function New-ScanUiState {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [datetime]$ScanStart,
        [string]$RawLogPath
    )

    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $Config.StepDefs) {
        $isOn = [bool]$Config.Enabled[$s.Order]
        $rows.Add([PSCustomObject]@{
            Order        = $s.Order
            ShortName    = $s.ShortName
            State        = if ($isOn) { 'QUEUED' } else { 'SKIPPED' }
            DurationText = ''
            SummaryLine  = if ($isOn) { 'Queued' } else { 'Skipped by user' }
        })
    }

    return [PSCustomObject]@{
        Steps          = $rows
        ScanStart      = $ScanStart
        ActiveOrder    = 0
        ActiveCommand  = ''
        FixedCount     = 0
        AttentionCount = 0
        RawLogPath     = $RawLogPath
        SpinIdx        = 0
        TotalEnabled   = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
        HeaderRow      = -1
        HeaderPrefix   = ''
        StatusRow      = -1
        LastHeaderSec  = ''
    }
}

function Render-ScanDashboard {
    param(
        [Parameter(Mandatory = $true)]$UiState,
        [switch]$Final,
        [switch]$NoClear
    )

    $w = Get-ConsoleSafeWidth
    $bar = '=' * $w
    $sep = '-' * $w

    $doneCount = @($UiState.Steps | Where-Object { $_.State -in @('OK', 'FIXED', 'ATTENTION', 'PENDING', 'ERROR') }).Count
    $totalEn = [math]::Max(1, [int]$UiState.TotalEnabled)
    $pct = [math]::Min(100, [int][math]::Floor(($doneCount * 100.0) / $totalEn))
    if ($Final) { $pct = 100 }

    $barLen = 20
    $filled = [int][math]::Round(($pct / 100.0) * $barLen)
    $progBar = ('#' * $filled) + ('-' * ($barLen - $filled))
    $elapsedStr = Format-ClockSpan ((Get-Date) - $UiState.ScanStart)
    $headerPrefix = ("  WINDOWS SCAN & FIX   [$progBar] {0,3}%  ($doneCount/$totalEn)   Elapsed: " -f $pct)

    if (-not $NoClear) {
        try { [Console]::CursorVisible = (-not (-not $Final)) } catch {}
        try { Clear-Host } catch {}
    }

    Write-Host $bar -ForegroundColor DarkCyan
    try { $UiState.HeaderRow = [Console]::CursorTop } catch { $UiState.HeaderRow = -1 }
    $UiState.HeaderPrefix = $headerPrefix
    $UiState.LastHeaderSec = $elapsedStr
    Write-Host (($headerPrefix + $elapsedStr).PadRight($w)) -ForegroundColor Cyan
    Write-Host ("  PC: $env:COMPUTERNAME  |  Fixed: $($UiState.FixedCount)  |  Alerts: $($UiState.AttentionCount)  |  Raw Log Saved Silently") -ForegroundColor Gray
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ''

    foreach ($row in $UiState.Steps) {
        $badge = '[     ]'
        $badgeColor = 'DarkGray'
        $textColor = 'Gray'
        switch ($row.State) {
            'OK'        { $badge = '[ OK  ]'; $badgeColor = 'Green';    $textColor = 'White' }
            'FIXED'     { $badge = '[FIX  ]'; $badgeColor = 'Cyan';     $textColor = 'White' }
            'ATTENTION' { $badge = '[WARN ]'; $badgeColor = 'Yellow';   $textColor = 'Yellow' }
            'PENDING'   { $badge = '[PEND ]'; $badgeColor = 'Magenta';  $textColor = 'White' }
            'ERROR'     { $badge = '[ERR  ]'; $badgeColor = 'Red';      $textColor = 'Red' }
            'SKIPPED'   { $badge = '[SKIP ]'; $badgeColor = 'DarkGray'; $textColor = 'DarkGray' }
            'RUNNING'   { $badge = '[ >>> ]'; $badgeColor = 'White';    $textColor = 'Cyan' }
            default     { $badge = '[     ]'; $badgeColor = 'DarkGray'; $textColor = 'DarkGray' }
        }

        $numStr = ('{0,2}' -f $row.Order)
        $nameCol = $row.ShortName.PadRight(29)
        $durCol = if ([string]::IsNullOrWhiteSpace($row.DurationText)) { '       ' } else { ('{0,6} ' -f $row.DurationText) }
        $prefixLen = 2 + 7 + 2 + 4 + 29 + 1 + 7
        $sumMax = [math]::Max(10, $w - $prefixLen)
        $sumTxt = Truncate-Text $row.SummaryLine $sumMax

        Write-Host '  ' -NoNewline
        Write-Host $badge -ForegroundColor $badgeColor -NoNewline
        Write-Host ("  $numStr. $nameCol ") -ForegroundColor $textColor -NoNewline
        Write-Host $durCol -ForegroundColor DarkGray -NoNewline
        Write-Host $sumTxt -ForegroundColor $(if ($row.State -eq 'RUNNING') { 'Cyan' } elseif ($row.State -eq 'ATTENTION') { 'Yellow' } elseif ($row.State -eq 'ERROR') { 'Red' } else { 'Gray' })
    }

    Write-Host ''
    Write-Host $sep -ForegroundColor DarkGray
    if (-not $Final) {
        $actTxt = '  ' + (Truncate-Text ("ACTIVE: [$($UiState.ActiveOrder)/15] $($UiState.ActiveCommand)") ($w - 2))
        Write-Host $actTxt -ForegroundColor Cyan
        try { $UiState.StatusRow = [Console]::CursorTop } catch { $UiState.StatusRow = -1 }
        Write-Host '  STATUS: [|] Starting...' -ForegroundColor Gray -NoNewline
    } else {
        $UiState.StatusRow = -1
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Update-ActiveStatusLine {
    param(
        [Parameter(Mandatory = $true)]$UiState,
        [datetime]$StepStart,
        [string]$Hint = ''
    )

    $frames = @('|', '/', '-', '\')
    $UiState.SpinIdx = ($UiState.SpinIdx + 1) % $frames.Count
    $spin = $frames[$UiState.SpinIdx]
    $stepClock = Format-ClockSpan ((Get-Date) - $StepStart)
    $totalClock = Format-ClockSpan ((Get-Date) - $UiState.ScanStart)
    $w = Get-ConsoleSafeWidth

    # Keep top header Elapsed timer ticking live every second
    if ($totalClock -ne $UiState.LastHeaderSec -and $UiState.HeaderRow -ge 0 -and -not [string]::IsNullOrEmpty($UiState.HeaderPrefix)) {
        $UiState.LastHeaderSec = $totalClock
        try {
            $oldFg = [Console]::ForegroundColor
            [Console]::SetCursorPosition(0, $UiState.HeaderRow)
            [Console]::ForegroundColor = [ConsoleColor]::Cyan
            $hdrFull = $UiState.HeaderPrefix + $totalClock
            if ($hdrFull.Length -gt $w) { $hdrFull = $hdrFull.Substring(0, $w) }
            [Console]::Write($hdrFull.PadRight($w))
            [Console]::ForegroundColor = $oldFg
        } catch {
            # Ignore non-interactive cursor errors
        }
    }

    $detail = if ([string]::IsNullOrWhiteSpace($Hint)) { 'Working... (raw output captured to log)' } else { $Hint }
    $line = '  ' + (Truncate-Text "STATUS: [$spin] Step $stepClock | Total $totalClock | $detail" ($w - 2))
    $padded = $line.PadRight($w)
    try {
        if ($UiState.StatusRow -ge 0) {
            [Console]::SetCursorPosition(0, $UiState.StatusRow)
            [Console]::Write($padded)
        } else {
            [Console]::Write("`r" + $padded)
        }
    } catch {
        # Ignore non-interactive console write errors
    }
}

function New-ScanHtmlReport {
    param(
        [Parameter(Mandatory = $true)]$State
    )

    function Escape-Html {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        return [System.Net.WebUtility]::HtmlEncode($Text)
    }

    function Get-BadgeClass {
        param([string]$Status)
        switch ($Status) {
            'OK'        { return 'badge-ok' }
            'FIXED'     { return 'badge-fixed' }
            'ATTENTION' { return 'badge-warn' }
            'PENDING'   { return 'badge-pending' }
            'ERROR'     { return 'badge-err' }
            'SKIPPED'   { return 'badge-skip' }
            default     { return 'badge-info' }
        }
    }

    function Get-SeverityClass {
        param([string]$Severity)
        switch ($Severity) {
            'High'   { return 'sev-high' }
            'Medium' { return 'sev-med' }
            default  { return 'sev-info' }
        }
    }

    $fixedItems = @(Get-SafeProp $State 'FixedItems' @() | Where-Object { $null -ne $_ })
    $attentionItems = @(Get-SafeProp $State 'AttentionItems' @() | Where-Object { $null -ne $_ })
    $results = @(Get-SafeProp $State 'Results' @() | Where-Object { $null -ne $_ } | Sort-Object { [int](Get-SafeProp $_ 'Order' 99) })

    $okCount = @($results | Where-Object { (Get-SafeProp $_ 'Status' '') -eq 'OK' }).Count
    $runCount = @($results | Where-Object { (Get-SafeProp $_ 'Status' '') -ne 'SKIPPED' }).Count
    $fixedCount = $fixedItems.Count
    $attentionCount = $attentionItems.Count
    $totalCount = $results.Count

    $highCount = @($attentionItems | Where-Object { (Get-SafeProp $_ 'Severity' '') -eq 'High' }).Count
    $pendingCount = @($results | Where-Object { (Get-SafeProp $_ 'Status' '') -eq 'PENDING' }).Count

    if ($highCount -gt 0 -or $attentionCount -gt 0) {
        $overallLabel = 'ACTION RECOMMENDED'
        $overallClass = 'overall-warn'
        $overallDesc = "$attentionCount item(s) need your review below."
    } elseif ($pendingCount -gt 0) {
        $overallLabel = 'RESTART PENDING'
        $overallClass = 'overall-pending'
        $overallDesc = 'Pre-restart checks finished; Memory Diagnostic will finish during restart.'
    } elseif ($fixedCount -gt 0) {
        $overallLabel = 'ISSUES FIXED'
        $overallClass = 'overall-fixed'
        $overallDesc = "Automatically repaired $fixedCount issue(s) with no remaining alerts."
    } else {
        $overallLabel = 'ALL GOOD'
        $overallClass = 'overall-ok'
        $overallDesc = 'All checks completed cleanly with no issues found.'
    }

    $postReboot = [bool](Get-SafeProp $State 'PostRebootFinalized' $false)
    $finalizedTime = [string](Get-SafeProp $State 'FinalizedTimeDisplay' '')
    $computerName = Escape-Html ([string](Get-SafeProp $State 'ComputerName' ''))
    $userName = Escape-Html ([string](Get-SafeProp $State 'UserName' ''))
    $osCaption = Escape-Html ([string](Get-SafeProp $State 'OSCaption' 'Windows'))
    $timestampDisplay = Escape-Html ([string](Get-SafeProp $State 'TimestampDisplay' ''))
    $durationDisplay = Escape-Html ([string](Get-SafeProp $State 'DurationDisplay' ''))
    $rawLogPath = Escape-Html ([string](Get-SafeProp $State 'RawLogPath' ''))
    $energyHtmlPath = Escape-Html ([string](Get-SafeProp $State 'EnergyHtmlPath' ''))
    $archiveReportPath = Escape-Html ([string](Get-SafeProp $State 'ArchiveReportPath' ''))
    $desktopReportPath = Escape-Html ([string](Get-SafeProp $State 'DesktopReportPath' ''))

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en">')
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine("<title>Windows Scan &amp; Fix Report - $computerName</title>")
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('  :root { --bg:#f4f6f9; --card:#ffffff; --text:#1e293b; --muted:#64748b; --border:#e2e8f0; --ok:#15803d; --ok-bg:#dcfce7; --fixed:#0369a1; --fixed-bg:#e0f2fe; --warn:#b45309; --warn-bg:#fef3c7; --err:#b91c1c; --err-bg:#fee2e2; --pend:#6d28d9; --pend-bg:#ede9fe; }')
    [void]$sb.AppendLine('  * { box-sizing:border-box; }')
    [void]$sb.AppendLine('  body { margin:0; padding:24px; font-family:"Segoe UI",system-ui,-apple-system,sans-serif; background:var(--bg); color:var(--text); line-height:1.5; }')
    [void]$sb.AppendLine('  .wrap { max-width:980px; margin:0 auto; }')
    [void]$sb.AppendLine('  .hero { background:#0f172a; color:#f8fafc; border-radius:12px; padding:24px 28px; margin-bottom:20px; box-shadow:0 4px 14px rgba(15,23,42,0.12); }')
    [void]$sb.AppendLine('  .hero-top { display:flex; flex-wrap:wrap; justify-content:space-between; align-items:flex-start; gap:16px; }')
    [void]$sb.AppendLine('  .hero h1 { margin:0 0 6px 0; font-size:24px; font-weight:700; }')
    [void]$sb.AppendLine('  .hero-meta { color:#cbd5e1; font-size:13px; }')
    [void]$sb.AppendLine('  .overall-pill { padding:8px 14px; border-radius:999px; font-size:13px; font-weight:700; letter-spacing:0.04em; white-space:nowrap; }')
    [void]$sb.AppendLine('  .overall-ok { background:#16a34a; color:#ffffff; }')
    [void]$sb.AppendLine('  .overall-fixed { background:#0284c7; color:#ffffff; }')
    [void]$sb.AppendLine('  .overall-warn { background:#d97706; color:#ffffff; }')
    [void]$sb.AppendLine('  .overall-pending { background:#7c3aed; color:#ffffff; }')
    [void]$sb.AppendLine('  .hero-sub { margin-top:12px; font-size:14px; color:#e2e8f0; }')
    [void]$sb.AppendLine('  .kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:12px; margin-bottom:20px; }')
    [void]$sb.AppendLine('  .kpi { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:14px 16px; }')
    [void]$sb.AppendLine('  .kpi-num { font-size:26px; font-weight:700; line-height:1.1; }')
    [void]$sb.AppendLine('  .kpi-lbl { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:0.05em; margin-top:4px; }')
    [void]$sb.AppendLine('  .section { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:20px 22px; margin-bottom:18px; }')
    [void]$sb.AppendLine('  .section h2 { margin:0 0 12px 0; font-size:18px; border-bottom:1px solid var(--border); padding-bottom:8px; }')
    [void]$sb.AppendLine('  .empty-note { color:var(--muted); font-size:14px; margin:4px 0; }')
    [void]$sb.AppendLine('  .bullet-list { list-style:none; padding:0; margin:0; display:flex; flex-direction:column; gap:10px; }')
    [void]$sb.AppendLine('  .bullet-item { padding:12px 14px; border-radius:8px; border:1px solid var(--border); background:#f8fafc; }')
    [void]$sb.AppendLine('  .item-head { display:flex; align-items:center; gap:8px; flex-wrap:wrap; margin-bottom:4px; }')
    [void]$sb.AppendLine('  .sev { font-size:11px; font-weight:700; padding:2px 8px; border-radius:999px; text-transform:uppercase; }')
    [void]$sb.AppendLine('  .sev-high { background:var(--err-bg); color:var(--err); }')
    [void]$sb.AppendLine('  .sev-med { background:var(--warn-bg); color:var(--warn); }')
    [void]$sb.AppendLine('  .sev-info { background:var(--fixed-bg); color:var(--fixed); }')
    [void]$sb.AppendLine('  .src-tag { font-size:12px; font-weight:600; color:var(--muted); }')
    [void]$sb.AppendLine('  .action-text { font-size:13px; color:#334155; margin-top:4px; }')
    [void]$sb.AppendLine('  .check-card { border:1px solid var(--border); border-radius:10px; padding:14px 16px; margin-bottom:12px; background:#ffffff; }')
    [void]$sb.AppendLine('  .check-card:last-child { margin-bottom:0; }')
    [void]$sb.AppendLine('  .check-head { display:flex; justify-content:space-between; align-items:center; gap:10px; flex-wrap:wrap; }')
    [void]$sb.AppendLine('  .check-title { font-size:15px; font-weight:700; }')
    [void]$sb.AppendLine('  .badge { font-size:11px; font-weight:700; padding:3px 10px; border-radius:999px; text-transform:uppercase; letter-spacing:0.04em; }')
    [void]$sb.AppendLine('  .badge-ok { background:var(--ok-bg); color:var(--ok); }')
    [void]$sb.AppendLine('  .badge-fixed { background:var(--fixed-bg); color:var(--fixed); }')
    [void]$sb.AppendLine('  .badge-warn { background:var(--warn-bg); color:var(--warn); }')
    [void]$sb.AppendLine('  .badge-err { background:var(--err-bg); color:var(--err); }')
    [void]$sb.AppendLine('  .badge-pending { background:var(--pend-bg); color:var(--pend); }')
    [void]$sb.AppendLine('  .badge-skip { background:#f1f5f9; color:#64748b; }')
    [void]$sb.AppendLine('  .badge-info { background:#e2e8f0; color:#334155; }')
    [void]$sb.AppendLine('  .check-meta { font-size:12px; color:var(--muted); margin:4px 0 6px 0; font-family:Consolas,monospace; }')
    [void]$sb.AppendLine('  .check-sum { font-size:14px; margin:4px 0 8px 0; }')
    [void]$sb.AppendLine('  details { margin-top:6px; }')
    [void]$sb.AppendLine('  summary { cursor:pointer; font-size:13px; font-weight:600; color:#0369a1; user-select:none; }')
    [void]$sb.AppendLine('  pre { background:#0f172a; color:#e2e8f0; padding:12px; border-radius:8px; overflow-x:auto; font-size:12px; line-height:1.45; margin:8px 0 0 0; white-space:pre-wrap; word-break:break-word; }')
    [void]$sb.AppendLine('  .ext-link { display:inline-block; margin-top:6px; font-size:13px; color:#0284c7; text-decoration:none; font-weight:600; }')
    [void]$sb.AppendLine('  .ext-link:hover { text-decoration:underline; }')
    [void]$sb.AppendLine('  .footer { font-size:12px; color:var(--muted); padding:8px 4px; }')
    [void]$sb.AppendLine('  code { background:#e2e8f0; padding:1px 5px; border-radius:4px; font-family:Consolas,monospace; font-size:12px; color:#0f172a; }')
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine('<div class="wrap">')

    # Hero
    [void]$sb.AppendLine('  <div class="hero">')
    [void]$sb.AppendLine('    <div class="hero-top">')
    [void]$sb.AppendLine('      <div>')
    [void]$sb.AppendLine('        <h1>Windows Scan &amp; Fix Report</h1>')
    [void]$sb.AppendLine("        <div class=""hero-meta"">PC: <strong>$computerName</strong> | User: <strong>$userName</strong> | OS: $osCaption</div>")
    if ($postReboot -and -not [string]::IsNullOrWhiteSpace($finalizedTime)) {
        $finEsc = Escape-Html $finalizedTime
        [void]$sb.AppendLine("        <div class=""hero-meta"">Started: $timestampDisplay | Scan Duration: $durationDisplay | Finalized after reboot: $finEsc</div>")
    } else {
        [void]$sb.AppendLine("        <div class=""hero-meta"">Started: $timestampDisplay | Scan Duration: $durationDisplay</div>")
    }
    [void]$sb.AppendLine('      </div>')
    [void]$sb.AppendLine("      <div class=""overall-pill $overallClass"">$overallLabel</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine("    <div class=""hero-sub"">$(Escape-Html $overallDesc)</div>")
    [void]$sb.AppendLine('  </div>')

    # KPIs
    [void]$sb.AppendLine('  <div class="kpis">')
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"">$runCount</div><div class=""kpi-lbl"">Checks Run</div></div>")
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"" style=""color:var(--fixed)"">$fixedCount</div><div class=""kpi-lbl"">Issues Fixed</div></div>")
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"" style=""color:var(--warn)"">$attentionCount</div><div class=""kpi-lbl"">Need Attention</div></div>")
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"" style=""color:var(--ok)"">$okCount</div><div class=""kpi-lbl"">Passed Clean</div></div>")
    [void]$sb.AppendLine('  </div>')

    # Section 1: What Was Fixed
    [void]$sb.AppendLine('  <div class="section">')
    [void]$sb.AppendLine('    <h2>1. What Was Fixed</h2>')
    if ($fixedCount -eq 0) {
        [void]$sb.AppendLine('    <p class="empty-note">No automatic repairs were needed &ndash; Windows system files, component store, drives, and security scans required no fixes.</p>')
    } else {
        [void]$sb.AppendLine('    <ul class="bullet-list">')
        foreach ($item in $fixedItems) {
            $src = Escape-Html ([string](Get-SafeProp $item 'Source' 'Repair'))
            $desc = Escape-Html ([string](Get-SafeProp $item 'Description' ''))
            [void]$sb.AppendLine("      <li class=""bullet-item""><div class=""item-head""><span class=""badge badge-fixed"">FIXED</span><span class=""src-tag"">$src</span></div><div>$desc</div></li>")
        }
        [void]$sb.AppendLine('    </ul>')
    }
    [void]$sb.AppendLine('  </div>')

    # Section 2: Things You May Need to Look At
    [void]$sb.AppendLine('  <div class="section">')
    [void]$sb.AppendLine('    <h2>2. Things You May Need to Look At</h2>')
    if ($attentionCount -eq 0) {
        [void]$sb.AppendLine('    <p class="empty-note">Nothing requires your attention right now.</p>')
    } else {
        [void]$sb.AppendLine('    <ul class="bullet-list">')
        foreach ($item in $attentionItems) {
            $sev = [string](Get-SafeProp $item 'Severity' 'Info')
            $sevClass = Get-SeverityClass $sev
            $src = Escape-Html ([string](Get-SafeProp $item 'Source' 'Check'))
            $title = Escape-Html ([string](Get-SafeProp $item 'Title' ''))
            $action = Escape-Html ([string](Get-SafeProp $item 'Action' ''))
            [void]$sb.AppendLine("      <li class=""bullet-item""><div class=""item-head""><span class=""sev $sevClass"">$(Escape-Html $sev)</span><span class=""src-tag"">$src</span></div><div><strong>$title</strong></div><div class=""action-text"">$action</div></li>")
        }
        [void]$sb.AppendLine('    </ul>')
    }
    [void]$sb.AppendLine('  </div>')

    # Section 3: Detailed Results
    [void]$sb.AppendLine('  <div class="section">')
    [void]$sb.AppendLine("    <h2>3. Detailed Results (All $totalCount Checks)</h2>")
    foreach ($r in $results) {
        $name = Escape-Html ([string](Get-SafeProp $r 'Name' ''))
        $cmd = Escape-Html ([string](Get-SafeProp $r 'Command' ''))
        $status = [string](Get-SafeProp $r 'Status' 'INFO')
        $badgeClass = Get-BadgeClass $status
        $dur = Escape-Html ([string](Get-SafeProp $r 'Duration' ''))
        $summary = Escape-Html ([string](Get-SafeProp $r 'Summary' ''))
        $details = [string](Get-SafeProp $r 'Details' '')
        $extraPath = [string](Get-SafeProp $r 'ExtraLinkPath' '')
        $extraLabel = Escape-Html ([string](Get-SafeProp $r 'ExtraLinkLabel' 'Open report'))

        [void]$sb.AppendLine('    <div class="check-card">')
        [void]$sb.AppendLine('      <div class="check-head">')
        [void]$sb.AppendLine("        <div class=""check-title"">$name</div>")
        [void]$sb.AppendLine("        <span class=""badge $badgeClass"">$(Escape-Html $status)</span>")
        [void]$sb.AppendLine('      </div>')
        [void]$sb.AppendLine("      <div class=""check-meta"">$cmd | Duration: $dur</div>")
        [void]$sb.AppendLine("      <div class=""check-sum"">$summary</div>")
        if (-not [string]::IsNullOrWhiteSpace($extraPath)) {
            $fileUri = 'file:///' + ($extraPath.Replace('\', '/').TrimStart('/'))
            [void]$sb.AppendLine("      <div><a class=""ext-link"" href=""$(Escape-Html $fileUri)"" target=""_blank"">$extraLabel</a> (<code>$(Escape-Html $extraPath)</code>)</div>")
        }
        if (-not [string]::IsNullOrWhiteSpace($details)) {
            [void]$sb.AppendLine('      <details>')
            [void]$sb.AppendLine('        <summary>View detailed output</summary>')
            [void]$sb.AppendLine("        <pre>$(Escape-Html $details.Trim())</pre>")
            [void]$sb.AppendLine('      </details>')
        }
        [void]$sb.AppendLine('    </div>')
    }
    [void]$sb.AppendLine('  </div>')

    # Footer
    [void]$sb.AppendLine('  <div class="footer">')
    [void]$sb.AppendLine("    <div><strong>Saved Reports:</strong> Desktop copy: <code>$desktopReportPath</code> | Archive copy: <code>$archiveReportPath</code></div>")
    [void]$sb.AppendLine("    <div><strong>Raw Logs:</strong> Script log: <code>$rawLogPath</code> | PowerCfg Energy: <code>$energyHtmlPath</code> | SFC: <code>C:\Windows\Logs\CBS\CBS.log</code> | DISM: <code>C:\Windows\Logs\DISM\dism.log</code></div>")
    [void]$sb.AppendLine('    <div>Tip: Press <code>Win + R</code> and run <code>perfmon /rel</code> anytime to view the interactive Windows Reliability Monitor timeline.</div>')
    [void]$sb.AppendLine('  </div>')

    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')
    return $sb.ToString()
}

function Get-FinalizeScriptText {
    $safePropCode = "function Get-SafeProp {`r`n" + (Get-Command Get-SafeProp).ScriptBlock.ToString() + "`r`n}"
    $reportFuncCode = "function New-ScanHtmlReport {`r`n" + (Get-Command New-ScanHtmlReport).ScriptBlock.ToString() + "`r`n}"

    $body = @'
param(
    [Parameter(Mandatory = $true)][string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

__SAFE_PROP__

__REPORT_FUNC__

if (-not (Test-Path -LiteralPath $StatePath)) { exit 0 }

try {
    $rawJson = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8)
    $state = $rawJson | ConvertFrom-Json
} catch {
    exit 1
}

$fixedList = New-Object 'System.Collections.Generic.List[object]'
foreach ($item in @(Get-SafeProp $state 'FixedItems' @())) {
    if ($null -ne $item) { $fixedList.Add($item) }
}

$attentionList = New-Object 'System.Collections.Generic.List[object]'
foreach ($item in @(Get-SafeProp $state 'AttentionItems' @())) {
    if ($null -ne $item) { $attentionList.Add($item) }
}

$resultsList = New-Object 'System.Collections.Generic.List[object]'
foreach ($item in @(Get-SafeProp $state 'Results' @())) {
    if ($null -ne $item) { $resultsList.Add($item) }
}

$scanStartIso = [string](Get-SafeProp $state 'ScanStartIso' '')
try {
    $scanStart = [datetime]::Parse($scanStartIso)
} catch {
    $scanStart = (Get-Date).AddHours(-6)
}

if ([bool](Get-SafeProp $state 'MemDiagScheduled' $false)) {
    $memEvent = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $memEvent = Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'
                StartTime    = $scanStart
            } -MaxEvents 1 -ErrorAction SilentlyContinue
        } catch {
            $memEvent = $null
        }
        if ($null -ne $memEvent) { break }
        Start-Sleep -Seconds 3
    }

    $memCard = $resultsList | Where-Object { (Get-SafeProp $_ 'Id' '') -eq 'memdiag' } | Select-Object -First 1
    if ($null -ne $memEvent) {
        $evId = $memEvent.Id
        $evMsg = ([string]$memEvent.Message).Trim()
        $evTime = $memEvent.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
        if ($evId -in @(1101, 1201)) {
            if ($null -ne $memCard) {
                $memCard.Status = 'OK'
                $memCard.Summary = 'Windows Memory Diagnostic tested your RAM during restart and detected no errors.'
                $memCard.Details = "Event ID: $evId ($evTime)`r`n$evMsg"
            }
        } elseif ($evId -in @(1102, 1202)) {
            if ($null -ne $memCard) {
                $memCard.Status = 'ATTENTION'
                $memCard.Summary = 'HARDWARE MEMORY (RAM) ERRORS DETECTED by Windows Memory Diagnostic!'
                $memCard.Details = "Event ID: $evId ($evTime)`r`n$evMsg"
            }
            $attentionList.Insert(0, [PSCustomObject]@{
                Severity = 'High'
                Source   = 'Memory Diagnostic (mdsched)'
                Title    = 'Windows Memory Diagnostic detected RAM hardware errors!'
                Action   = 'Back up important files right away. Reseat or test individual RAM sticks, or contact your PC/RAM manufacturer.'
            })
        } elseif ($evId -eq 1103) {
            if ($null -ne $memCard) {
                $memCard.Status = 'ATTENTION'
                $memCard.Summary = 'Windows Memory Diagnostic was cancelled before completing.'
                $memCard.Details = "Event ID: $evId ($evTime)`r`n$evMsg"
            }
            $attentionList.Add([PSCustomObject]@{
                Severity = 'Medium'
                Source   = 'Memory Diagnostic (mdsched)'
                Title    = 'Memory Diagnostic test was cancelled before finishing.'
                Action   = 'Run mdsched.exe and choose "Restart now" when you want a full RAM check.'
            })
        } else {
            if ($null -ne $memCard) {
                $memCard.Status = 'ATTENTION'
                $memCard.Summary = "Windows Memory Diagnostic could not complete (Event ID $evId)."
                $memCard.Details = "Event ID: $evId ($evTime)`r`n$evMsg"
            }
            $attentionList.Add([PSCustomObject]@{
                Severity = 'Medium'
                Source   = 'Memory Diagnostic (mdsched)'
                Title    = "Memory Diagnostic did not complete cleanly (Event ID $evId)."
                Action   = 'Run mdsched.exe manually to re-test your computer memory.'
            })
        }
    } else {
        if ($null -ne $memCard) {
            $memCard.Status = 'ATTENTION'
            $memCard.Summary = 'No Windows Memory Diagnostic result event was found after restart.'
            $memCard.Details = 'The Windows Memory Diagnostic event (Microsoft-Windows-MemoryDiagnostics-Results) was not recorded since the scan began.'
        }
        $attentionList.Add([PSCustomObject]@{
            Severity = 'Info'
            Source   = 'Memory Diagnostic (mdsched)'
            Title    = 'Memory Diagnostic result was not found after restart.'
            Action   = 'Run mdsched.exe manually if you want to verify RAM health.'
        })
    }
}

if ([bool](Get-SafeProp $state 'OfflineChkdskScheduled' $false)) {
    $wininitEvent = $null
    try {
        $wininitEvent = Get-WinEvent -FilterHashtable @{
            LogName      = 'Application'
            ProviderName = 'Wininit'
            Id           = 1001
            StartTime    = $scanStart
        } -MaxEvents 1 -ErrorAction SilentlyContinue
    } catch {
        $wininitEvent = $null
    }

    $chkdskCard = $resultsList | Where-Object { (Get-SafeProp $_ 'Id' '') -eq 'chkdsk' } | Select-Object -First 1
    if ($null -ne $wininitEvent -and $null -ne $chkdskCard) {
        $wMsg = ([string]$wininitEvent.Message).Trim()
        $chkdskCard.Details = ($chkdskCard.Details + "`r`n`r`n--- Boot-Time Offline CHKDSK (Wininit Event 1001) ---`r`n" + $wMsg)
        if ($wMsg -match 'made corrections|repaired|recovered|Windows has checked the file system and found no problems') {
            $chkdskCard.Summary = $chkdskCard.Summary + ' Boot-time offline CHKDSK completed.'
            if ($wMsg -match 'made corrections') {
                $fixedList.Add([PSCustomObject]@{
                    Source      = 'CHKDSK (Boot-Time Offline Repair)'
                    Description = 'Boot-time CHKDSK repaired file system issues on the system drive during restart.'
                })
            }
        }
    }
}

$state | Add-Member -NotePropertyName FixedItems -NotePropertyValue @($fixedList.ToArray()) -Force
$state | Add-Member -NotePropertyName AttentionItems -NotePropertyValue @($attentionList.ToArray()) -Force
$state | Add-Member -NotePropertyName Results -NotePropertyValue @($resultsList.ToArray()) -Force
$state | Add-Member -NotePropertyName PostRebootFinalized -NotePropertyValue $true -Force
$state | Add-Member -NotePropertyName FinalizedTimeDisplay -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force

$html = New-ScanHtmlReport -State $state
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$desktopPath = [string](Get-SafeProp $state 'DesktopReportPath' '')
$archivePath = [string](Get-SafeProp $state 'ArchiveReportPath' '')
$openedPath = ''

foreach ($p in @($archivePath, $desktopPath)) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    try {
        $parent = Split-Path -Path $p -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            [void](New-Item -Path $parent -ItemType Directory -Force)
        }
        [System.IO.File]::WriteAllText($p, $html, $utf8NoBom)
        $openedPath = $p
    } catch {
        # Ignore secondary path write error
    }
}

if (-not [string]::IsNullOrWhiteSpace($desktopPath) -and (Test-Path -LiteralPath $desktopPath)) {
    $openedPath = $desktopPath
}

$shouldOpen = [bool](Get-SafeProp $state 'OpenReport' $true)
if ($shouldOpen -and -not [string]::IsNullOrWhiteSpace($openedPath) -and (Test-Path -LiteralPath $openedPath)) {
    try {
        Start-Process -FilePath $openedPath
    } catch {
        # Ignore browser launch failures
    }
}

try {
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
} catch {
    # Ignore cleanup error
}
'@

    $script = $body.Replace('__SAFE_PROP__', $safePropCode).Replace('__REPORT_FUNC__', $reportFuncCode)
    return $script
}

function Invoke-WindowsScanAndFix {
    $sysDir = Join-Path $env:SystemRoot 'System32'
    if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Sysnative\cmd.exe')) {
        $sysDir = Join-Path $env:SystemRoot 'Sysnative'
    }

    $osCaption = 'Windows'
    try {
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $osCaption = [string](Get-SafeProp $osInfo 'Caption' 'Windows')
    } catch {
        $osCaption = 'Windows'
    }

    # Interactive Pre-Run Options Menu
    $config = New-DefaultScanConfig
    $config = Show-OptionsMenu -Config $config -OSCaption $osCaption
    if ($null -eq $config) {
        Write-Host ''
        Write-Host '  Scan cancelled. Nothing was modified.' -ForegroundColor Gray
        exit 0
    }

    $scanStart = Get-Date
    $stamp = $scanStart.ToString('yyyy-MM-dd_HH-mm-ss')

    $scriptDir = [string]$env:_SCRIPT_DIR
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = (Get-Location).Path
    }
    $scriptDir = $scriptDir.TrimEnd('\')

    $desktopDir = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktopDir)) {
        $desktopDir = Join-Path $env:USERPROFILE 'Desktop'
    }

    $runDir = Join-Path $scriptDir "Reports\Run_$stamp"
    try {
        if (-not (Test-Path -LiteralPath $runDir)) {
            [void](New-Item -Path $runDir -ItemType Directory -Force -ErrorAction Stop)
        }
        $probe = Join-Path $runDir '.write_test'
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        $runDir = Join-Path $env:TEMP "WindowsScanAndFix\Run_$stamp"
        [void](New-Item -Path $runDir -ItemType Directory -Force)
    }

    $localStateDir = Join-Path $env:LOCALAPPDATA 'WindowsScanAndFix'
    if (-not (Test-Path -LiteralPath $localStateDir)) {
        [void](New-Item -Path $localStateDir -ItemType Directory -Force)
    }

    $rawLogPath = Join-Path $runDir 'raw_scan_log.txt'
    $energyHtmlPath = Join-Path $runDir 'energy-report.html'
    $batteryHtmlPath = Join-Path $runDir 'battery-report.html'
    $archiveReportPath = Join-Path $runDir 'Windows_Scan_Report.html'
    $desktopReportPath = Join-Path $desktopDir "Windows_Scan_Report_$stamp.html"

    Write-RawLog '=== Windows Scan and Fix Log ===' $rawLogPath
    Write-RawLog ('Started: ' + $scanStart.ToString('yyyy-MM-dd HH:mm:ss')) $rawLogPath
    Write-RawLog ('Computer: ' + $env:COMPUTERNAME + ' | User: ' + $env:USERNAME + ' | OS: ' + $osCaption) $rawLogPath
    Write-RawLog ('Preset: ' + $config.Preset + ' | Defender: ' + $config.DefenderMode + ' | AutoRestart: ' + $config.AutoRestart) $rawLogPath
    Write-RawLog '' $rawLogPath

    $fixedItems = New-Object 'System.Collections.Generic.List[object]'
    $attentionItems = New-Object 'System.Collections.Generic.List[object]'
    $results = New-Object 'System.Collections.Generic.List[object]'
    $ui = New-ScanUiState -Config $config -ScanStart $scanStart -RawLogPath $rawLogPath

    $dismRepairable = $false
    $memDiagScheduled = $false
    $offlineChkdskScheduled = $false

    function Set-StepRunning {
        param([int]$Order, [string]$Command)
        $row = $ui.Steps | Where-Object { $_.Order -eq $Order } | Select-Object -First 1
        if ($null -ne $row) {
            $row.State = 'RUNNING'
            $row.SummaryLine = 'Running...'
        }
        $ui.ActiveOrder = $Order
        $ui.ActiveCommand = $Command
        $ui.FixedCount = $fixedItems.Count
        $ui.AttentionCount = $attentionItems.Count
        Render-ScanDashboard -UiState $ui
    }

    function Set-StepDone {
        param([int]$Order, [string]$Status, [string]$DurationText, [string]$SummaryLine)
        $row = $ui.Steps | Where-Object { $_.Order -eq $Order } | Select-Object -First 1
        if ($null -ne $row) {
            $row.State = $Status
            $row.DurationText = $DurationText
            $row.SummaryLine = $SummaryLine
        }
        $ui.FixedCount = $fixedItems.Count
        $ui.AttentionCount = $attentionItems.Count
    }

    function Add-SkippedStep {
        param([int]$Order, [string]$Id, [string]$Name, [string]$Command)
        $results.Add([PSCustomObject]@{
            Id=$Id; Order=$Order; Name=$Name; Command=$Command
            Status='SKIPPED'; Duration='0s'
            Summary='Skipped in pre-run options menu.'
            Details=''; ExtraLinkPath=''; ExtraLinkLabel=''
        })
    }

    # ------------------------------------------------------------------
    # STEP 1/15: Physical Disk Health & Free Space (Get-PhysicalDisk)
    # ------------------------------------------------------------------
    if (-not $config.Enabled[1]) {
        Add-SkippedStep 1 'disk_health' '1. Physical Disk Health & Free Space' 'Get-PhysicalDisk + Free Space'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 1 'Get-PhysicalDisk | Get-StorageReliabilityCounter + Free Space'
        Write-RawLog '--- [1/15] Get-PhysicalDisk & Free Space ---' $rawLogPath
        try {
            $disks = @(Get-PhysicalDisk -ErrorAction Stop)
            if ($disks.Count -eq 0) {
                $dur = Format-DurationSpan ((Get-Date) - $stepStart)
                $results.Add([PSCustomObject]@{
                    Id='disk_health'; Order=1; Name='1. Physical Disk Health & Free Space'; Command='Get-PhysicalDisk'
                    Status='ATTENTION'; Duration=$dur
                    Summary='No physical disks were returned by Get-PhysicalDisk.'
                    Details='Get-PhysicalDisk returned 0 devices.'
                    ExtraLinkPath=''; ExtraLinkLabel=''
                })
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Info'; Source='Physical Disks (Get-PhysicalDisk)'
                    Title='No physical disks were reported.'
                    Action='Verify storage drivers or check Disk Management if disks are missing.'
                })
                Set-StepDone 1 'ATTENTION' $dur 'No physical disks returned'
            } else {
                $diskLines = New-Object 'System.Collections.Generic.List[string]'
                $diskHasIssue = $false
                foreach ($d in $disks) {
                    Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Inspecting disks & SMART...'
                    $devId = [string](Get-SafeProp $d 'DeviceId' '?')
                    $fname = [string](Get-SafeProp $d 'FriendlyName' 'Unknown Disk')
                    $media = [string](Get-SafeProp $d 'MediaType' 'Unknown')
                    $bus = [string](Get-SafeProp $d 'BusType' 'Unknown')
                    $sizeGb = [math]::Round(([double](Get-SafeProp $d 'Size' 0)) / 1GB, 1)
                    $health = [string](Get-SafeProp $d 'HealthStatus' 'Unknown')
                    $opStat = [string](Get-SafeProp $d 'OperationalStatus' 'Unknown')

                    $smartNote = 'SMART counters unavailable on this controller'
                    $temp = $null; $wear = $null; $rErr = $null; $wErr = $null; $hours = $null
                    try {
                        $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                        if ($null -ne $rel) {
                            $temp = Get-SafeProp $rel 'Temperature' $null
                            $wear = Get-SafeProp $rel 'Wear' $null
                            $rErr = Get-SafeProp $rel 'ReadErrorsUncorrected' $null
                            $wErr = Get-SafeProp $rel 'WriteErrorsUncorrected' $null
                            $hours = Get-SafeProp $rel 'PowerOnHours' $null
                            $smartNote = "Temp=$($temp)C, Wear=$($wear)%, UncorrectedReadErr=$rErr, UncorrectedWriteErr=$wErr, PowerOnHours=$hours"
                        }
                    } catch {}

                    $diskLines.Add("Disk ${devId}: $fname ($media / $bus, ${sizeGb} GB) | Health=$health | OpStatus=$opStat | $smartNote")

                    if ($health -ne 'Healthy' -or $opStat -notmatch '^OK') {
                        $diskHasIssue = $true
                        $attentionItems.Add([PSCustomObject]@{
                            Severity='High'; Source='Physical Disks (Get-PhysicalDisk)'
                            Title="Drive '$fname' reports Health='$health' ($opStat)."
                            Action='Back up important data immediately and check drive health or SATA/NVMe connections.'
                        })
                    }
                    if (($null -ne $rErr -and [int64]$rErr -gt 0) -or ($null -ne $wErr -and [int64]$wErr -gt 0)) {
                        $diskHasIssue = $true
                        $attentionItems.Add([PSCustomObject]@{
                            Severity='High'; Source='Physical Disks (SMART Counters)'
                            Title="Drive '$fname' reports uncorrected read/write errors (Read=$rErr, Write=$wErr)."
                            Action='Back up data right away; physical media errors indicate potential drive failure.'
                        })
                    }
                    if ($null -ne $wear -and [int]$wear -ge 80) {
                        $diskHasIssue = $true
                        $attentionItems.Add([PSCustomObject]@{
                            Severity='Medium'; Source='Physical Disks (SSD Wear)'
                            Title="SSD '$fname' wear indicator is at ${wear}%."
                            Action='Plan a backup and future SSD replacement.'
                        })
                    }
                    if ($null -ne $temp -and [int]$temp -ge 70) {
                        $diskHasIssue = $true
                        $attentionItems.Add([PSCustomObject]@{
                            Severity='Medium'; Source='Physical Disks (Temperature)'
                            Title="Drive '$fname' temperature is elevated (${temp}C)."
                            Action='Check PC airflow, dust filters, and drive cooling.'
                        })
                    }
                }

                $diskLines.Add('')
                $diskLines.Add('Fixed Volume Free Space:')
                $fixedVols = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Sort-Object DeviceID)
                foreach ($fv in $fixedVols) {
                    $did = [string](Get-SafeProp $fv 'DeviceID' '')
                    $sz = [double](Get-SafeProp $fv 'Size' 0)
                    $fr = [double](Get-SafeProp $fv 'FreeSpace' 0)
                    if ($sz -le 0) { continue }
                    $frGb = [math]::Round($fr / 1GB, 1)
                    $szGb = [math]::Round($sz / 1GB, 1)
                    $frPct = [math]::Round(($fr / $sz) * 100, 1)
                    $diskLines.Add("  $did ${frGb} GB free of ${szGb} GB (${frPct}% free)")

                    if ($did -ieq $env:SystemDrive -and ($frGb -lt 5 -or $frPct -lt 5)) {
                        $diskHasIssue = $true
                        $attentionItems.Add([PSCustomObject]@{
                            Severity='High'; Source="Disk Space ($did)"
                            Title="System drive $did is critically low on free space (${frGb} GB / ${frPct}% free)."
                            Action='Free up space right away (Windows Updates, apps, and virtual memory need at least 15-20 GB free).'
                        })
                    } elseif (($did -ieq $env:SystemDrive -and ($frGb -lt 15 -or $frPct -lt 10)) -or ($frPct -lt 8 -and $frGb -lt 10)) {
                        $diskHasIssue = $true
                        $attentionItems.Add([PSCustomObject]@{
                            Severity='Medium'; Source="Disk Space ($did)"
                            Title="Drive $did is running low on free space (${frGb} GB / ${frPct}% free)."
                            Action='Review Storage Sense or uninstall unused apps/large files to keep SSD performance healthy.'
                        })
                    }
                }

                $detailsTxt = $diskLines -join "`r`n"
                Write-RawLog $detailsTxt $rawLogPath
                $status = if ($diskHasIssue) { 'ATTENTION' } else { 'OK' }
                $summary = if ($diskHasIssue) {
                    "Checked $($disks.Count) disk(s) & $($fixedVols.Count) volume(s); warning(s) detected."
                } else {
                    "All $($disks.Count) disk(s) Healthy with adequate free space."
                }
                $dur = Format-DurationSpan ((Get-Date) - $stepStart)
                $results.Add([PSCustomObject]@{
                    Id='disk_health'; Order=1; Name='1. Physical Disk Health & Free Space'; Command='Get-PhysicalDisk | Get-StorageReliabilityCounter + Free Space'
                    Status=$status; Duration=$dur; Summary=$summary; Details=$detailsTxt; ExtraLinkPath=''; ExtraLinkLabel=''
                })
                Set-StepDone 1 $status $dur $summary
            }
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='disk_health'; Order=1; Name='1. Physical Disk Health & Free Space'; Command='Get-PhysicalDisk'
                Status='ERROR'; Duration=$dur; Summary="Query error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 1 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 2/15: Power, Energy & Battery Diagnostics (powercfg /energy)
    # ------------------------------------------------------------------
    if (-not $config.Enabled[2]) {
        Add-SkippedStep 2 'power_energy' '2. Power, Energy & Battery Diagnostics' 'powercfg /energy (+ /batteryreport)'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 2 'powercfg /energy (60s trace) + /batteryreport'
        Write-RawLog "`r`n--- [2/15] powercfg /energy & /batteryreport ---" $rawLogPath
        try {
            $pwrTick = {
                param($h)
                $sec = [math]::Min(60, [int][math]::Floor(((Get-Date) - $stepStart).TotalSeconds))
                $txt = if ([string]::IsNullOrWhiteSpace($h)) { "Tracing idle power (${sec}s / 60s)..." } else { "$h (${sec}s / 60s)" }
                Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $txt
            }
            $pwrRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'powercfg.exe') -Arguments "/energy /output `"$energyHtmlPath`" /duration 60" -OnTick $pwrTick
            $pwrOut = ($pwrRes.Output + "`r`n" + $pwrRes.Error).Trim()
            Write-RawLog $pwrOut $rawLogPath

            $errCount = 0; $warnCount = 0; $infoCount = 0
            if ($pwrOut -match '(\d+)\s+Errors?') { $errCount = [int]$matches[1] }
            if ($pwrOut -match '(\d+)\s+Warnings?') { $warnCount = [int]$matches[1] }
            if ($pwrOut -match '(\d+)\s+Informational') { $infoCount = [int]$matches[1] }

            $topErrors = New-Object 'System.Collections.Generic.List[string]'
            if (Test-Path -LiteralPath $energyHtmlPath) {
                try {
                    $eHtml = [System.IO.File]::ReadAllText($energyHtmlPath, [System.Text.Encoding]::UTF8)
                    $mList = [regex]::Matches($eHtml, '(?is)<tr[^>]*class="[^"]*err-tr[^"]*"[^>]*>([\s\S]*?)</tr>')
                    if ($mList.Count -eq 0) {
                        $mList = [regex]::Matches($eHtml, '(?is)<div[^>]*class="[^"]*error-log-entry[^"]*"[^>]*>[\s\S]*?<div[^>]*class="[^"]*log-entry-header[^"]*"[^>]*>([\s\S]*?)</div>')
                    }
                    foreach ($m in $mList) {
                        $clean = [System.Net.WebUtility]::HtmlDecode(($m.Groups[1].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim())
                        if (-not [string]::IsNullOrWhiteSpace($clean) -and -not $topErrors.Contains($clean)) {
                            $topErrors.Add($clean)
                            if ($topErrors.Count -ge 10) { break }
                        }
                    }
                } catch {}
            }

            $batteryNote = 'Battery: None (desktop)'
            $batteryLowHealth = $false
            try {
                $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
                if ($batteries.Count -gt 0) {
                    $batRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'powercfg.exe') -Arguments "/batteryreport /output `"$batteryHtmlPath`"" -OnTick { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Generating battery report...' }
                    Write-RawLog ($batRes.Output + "`r`n" + $batRes.Error).Trim() $rawLogPath
                    if (Test-Path -LiteralPath $batteryHtmlPath) {
                        $bHtml = [System.IO.File]::ReadAllText($batteryHtmlPath, [System.Text.Encoding]::UTF8)
                        $designCap = 0; $fullCap = 0
                        if ($bHtml -match 'DESIGN CAPACITY</td>\s*<td[^>]*>([\d,]+)\s*mWh') { $designCap = [int]($matches[1] -replace ',', '') }
                        if ($bHtml -match 'FULL CHARGE CAPACITY</td>\s*<td[^>]*>([\d,]+)\s*mWh') { $fullCap = [int]($matches[1] -replace ',', '') }
                        if ($designCap -gt 0 -and $fullCap -gt 0) {
                            $batPct = [math]::Round(($fullCap / $designCap) * 100, 1)
                            $batteryNote = "Battery Health: ${batPct}%"
                            if ($batPct -lt 70) {
                                $batteryLowHealth = $true
                                $attentionItems.Add([PSCustomObject]@{
                                    Severity='Medium'; Source='Battery Health (powercfg /batteryreport)'
                                    Title="Laptop battery capacity degraded to ${batPct}% of design capacity."
                                    Action="Open $batteryHtmlPath to inspect battery wear."
                                })
                            }
                        } else {
                            $batteryNote = "Battery report saved"
                        }
                    }
                }
            } catch {}

            $detailsList = New-Object 'System.Collections.Generic.List[string]'
            $detailsList.Add("Errors: $errCount | Warnings: $warnCount | Informational: $infoCount")
            $detailsList.Add($batteryNote)
            if ($topErrors.Count -gt 0) {
                $detailsList.Add('')
                $detailsList.Add('Top Error Entries:')
                foreach ($te in $topErrors) { $detailsList.Add("  - $te") }
            }
            if (-not [string]::IsNullOrWhiteSpace($pwrOut)) {
                $detailsList.Add('')
                $detailsList.Add($pwrOut)
            }

            if ($errCount -gt 0 -or $batteryLowHealth) {
                $status = 'ATTENTION'
                $summary = "$errCount error(s), $warnCount warning(s). $batteryNote"
                if ($errCount -gt 0) {
                    $topSnippet = if ($topErrors.Count -gt 0) { ' Top finding: ' + $topErrors[0] } else { '' }
                    $attentionItems.Add([PSCustomObject]@{
                        Severity='Medium'; Source='Power & Energy (powercfg /energy)'
                        Title="Powercfg energy trace reported $errCount error(s) and $warnCount warning(s)."
                        Action="Open $energyHtmlPath to review power policy, USB suspend, or sleep issues.$topSnippet"
                    })
                }
            } elseif ($pwrRes.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $energyHtmlPath)) {
                $status = 'ATTENTION'
                $summary = "powercfg /energy exited $($pwrRes.ExitCode) (no report)."
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Info'; Source='Power & Energy (powercfg /energy)'
                    Title='Powercfg /energy could not generate an energy report.'
                    Action='Some virtual machines or hardware configs do not support energy tracing.'
                })
            } else {
                $status = 'OK'
                $summary = "0 errors ($warnCount warning(s)). $batteryNote"
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $energyLink = if (Test-Path -LiteralPath $energyHtmlPath) { $energyHtmlPath } else { '' }
            $results.Add([PSCustomObject]@{
                Id='power_energy'; Order=2; Name='2. Power, Energy & Battery Diagnostics'; Command="powercfg /energy /output `"$energyHtmlPath`" (+ /batteryreport if laptop)"
                Status=$status; Duration=$dur; Summary=$summary; Details=($detailsList -join "`r`n")
                ExtraLinkPath=$energyLink
                ExtraLinkLabel='Open energy-report.html'
            })
            Set-StepDone 2 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='power_energy'; Order=2; Name='2. Power, Energy & Battery Diagnostics'; Command='powercfg /energy'
                Status='ERROR'; Duration=$dur; Summary="Failed: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 2 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 3/15: Reliability History, BSODs & Hardware Error Logs
    # ------------------------------------------------------------------
    if (-not $config.Enabled[3]) {
        Add-SkippedStep 3 'reliability' '3. Reliability History & Crash/Hardware Logs' 'perfmon /rel + WHEA/Disk/Minidumps'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 3 'perfmon /rel (WMI) + WHEA/Disk Event Logs + Minidumps'
        Write-RawLog "`r`n--- [3/15] Reliability History (perfmon /rel) + Hardware/BSOD Logs ---" $rawLogPath
        try {
            Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Querying Reliability Monitor database...'
            $metrics = @(Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Sort-Object TimeGenerated -Descending)
            $latestScore = if ($metrics.Count -gt 0) { [math]::Round([double](Get-SafeProp $metrics[0] 'SystemStabilityIndex' 0), 2) } else { $null }

            $cutoff = (Get-Date).AddDays(-30)
            $records = @(Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction Stop | Where-Object {
                $tg = Get-SafeProp $_ 'TimeGenerated' $null
                $null -ne $tg -and $tg -ge $cutoff
            })

            $osCrashes = 0; $appIssues = 0; $updateFails = 0; $msiFails = 0
            $grouped = @{}
            foreach ($rec in $records) {
                $src = [string](Get-SafeProp $rec 'SourceName' '')
                $evId = [int](Get-SafeProp $rec 'EventIdentifier' -1)
                $prod = [string](Get-SafeProp $rec 'ProductName' '')
                $msg = [string](Get-SafeProp $rec 'Message' '')
                $timeGen = Get-SafeProp $rec 'TimeGenerated' ([datetime]::MinValue)

                if ($src -eq 'Microsoft-Windows-WindowsUpdateClient' -and $evId -eq 19) { continue }
                if ($src -eq 'MsiInstaller' -and $evId -in @(1034, 1035, 1038)) { continue }
                if ($src -eq 'MsiInstaller' -and $evId -eq 1033 -and ($msg -match 'status:\s*0\b' -or $msg -match 'completed successfully')) { continue }

                $cat = $null
                if ($src -in @('BugCheck', 'Microsoft-Windows-WER-SystemErrorReporting') -or
                    ($src -eq 'EventLog' -and $evId -eq 6008) -or
                    ($src -eq 'Microsoft-Windows-Kernel-Power' -and $evId -eq 41) -or
                    ($src -eq 'Windows Error Reporting' -and $msg -match 'BlueScreen|LiveKernelEvent')) {
                    $cat = 'OS/Hardware Crash or Unexpected Shutdown'; $osCrashes++
                } elseif ($src -eq 'Application Error' -and $evId -eq 1000) {
                    $cat = 'Application Crash'; $appIssues++
                } elseif ($src -eq 'Application Hang' -and $evId -eq 1002) {
                    $cat = 'Application Hang'; $appIssues++
                } elseif ($src -eq 'Microsoft-Windows-WindowsUpdateClient' -and $evId -eq 20) {
                    $cat = 'Windows Update Failure'; $updateFails++
                } elseif ($src -eq 'MsiInstaller' -and $evId -eq 1033) {
                    $cat = 'Installer Failure'; $msiFails++
                } elseif ($msg -match 'stopped working|unexpectedly|hardware error|faulting|failed') {
                    $cat = 'Other Failure'
                }

                if ($null -ne $cat) {
                    $label = if (-not [string]::IsNullOrWhiteSpace($prod)) { $prod } else { $src }
                    $key = "$cat|$label"
                    if (-not $grouped.ContainsKey($key)) {
                        $grouped[$key] = [PSCustomObject]@{ Category=$cat; Item=$label; Count=0; Latest=$timeGen }
                    }
                    $grouped[$key].Count++
                    if ($timeGen -gt $grouped[$key].Latest) { $grouped[$key].Latest = $timeGen }
                }
            }

            Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Scanning WHEA/Disk logs & minidumps...'
            $hwEvents = @()
            try {
                $hwEvents = @(Get-WinEvent -FilterHashtable @{
                    LogName      = 'System'
                    ProviderName = @('Microsoft-Windows-WHEA-Logger', 'disk', 'stornvme', 'Ntfs', 'Microsoft-Windows-WER-SystemErrorReporting')
                    Level        = @(1, 2)
                    StartTime    = $cutoff
                } -MaxEvents 25 -ErrorAction SilentlyContinue)
            } catch { $hwEvents = @() }

            $minidumps = @()
            $dumpDir = Join-Path $env:SystemRoot 'Minidump'
            if (Test-Path -LiteralPath $dumpDir) {
                $minidumps = @(Get-ChildItem -LiteralPath $dumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoff } | Sort-Object LastWriteTime -Descending)
            }

            $scoreText = if ($null -ne $latestScore) { "$latestScore/10" } else { 'N/A' }
            $relLines = New-Object 'System.Collections.Generic.List[string]'
            $relLines.Add("Current System Stability Index: $scoreText")
            $relLines.Add("Last 30 Days: OS/Unexpected Shutdowns=$osCrashes, App Crashes/Hangs=$appIssues, Update Failures=$updateFails, Installer Failures=$msiFails")
            $relLines.Add("Hardware/Disk Critical+Error Events (30d): $($hwEvents.Count) | BSOD Minidumps (30d): $($minidumps.Count)")
            $topGrouped = @($grouped.Values | Sort-Object @{Expression='Count';Descending=$true}, @{Expression='Latest';Descending=$true} | Select-Object -First 12)
            if ($topGrouped.Count -gt 0) {
                $relLines.Add('')
                $relLines.Add('Most Frequent Recent Issues:')
                foreach ($g in $topGrouped) {
                    $relLines.Add("  - [$($g.Category)] $($g.Item): $($g.Count)x (latest: $($g.Latest.ToString('yyyy-MM-dd HH:mm')))")
                }
            }
            if ($hwEvents.Count -gt 0) {
                $relLines.Add('')
                $relLines.Add('Recent System Hardware / Disk / BugCheck Events:')
                foreach ($he in ($hwEvents | Select-Object -First 8)) {
                    $firstLine = (([string]$he.Message) -split "`r?`n")[0]
                    if ($firstLine.Length -gt 140) { $firstLine = $firstLine.Substring(0, 140) + '...' }
                    $relLines.Add("  - [$($he.TimeCreated.ToString('yyyy-MM-dd HH:mm'))] $($he.ProviderName) (ID $($he.Id)): $firstLine")
                }
            }
            if ($minidumps.Count -gt 0) {
                $relLines.Add('')
                $relLines.Add('Recent BSOD Minidump Files:')
                foreach ($md in ($minidumps | Select-Object -First 5)) {
                    $relLines.Add("  - $($md.FullName) ($($md.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))")
                }
            }
            $relDetails = $relLines -join "`r`n"
            Write-RawLog $relDetails $rawLogPath

            if ($hwEvents.Count -gt 0 -or $minidumps.Count -gt 0) {
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source='Hardware / Crash Logs (System Event Log)'
                    Title="Found $($hwEvents.Count) hardware/disk error event(s) and $($minidumps.Count) BSOD minidump(s) in the last 30 days."
                    Action='Review Reliability details or inspect Event Viewer -> Windows Logs -> System.'
                })
            }
            if ($osCrashes -gt 0) {
                $status = 'ATTENTION'
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source='Reliability History (perfmon /rel)'
                    Title="$osCrashes OS crash(es) or unexpected shutdown(s) in the last 30 days (Stability: $scoreText)."
                    Action='Press Win+R and run "perfmon /rel" to inspect crash events on the timeline.'
                })
            } elseif ($hwEvents.Count -gt 0 -or $minidumps.Count -gt 0) {
                $status = 'ATTENTION'
            } elseif (($null -ne $latestScore -and $latestScore -lt 5.0) -or $appIssues -ge 5 -or $updateFails -gt 0) {
                $status = 'ATTENTION'
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Medium'; Source='Reliability History (perfmon /rel)'
                    Title="Stability Index is $scoreText ($appIssues app crash/hang(s), $updateFails failed update(s) in last 30 days)."
                    Action='Run "perfmon /rel" to see which apps or updates had issues.'
                })
            } else {
                $status = 'OK'
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $summary = "Stability $scoreText | OS:$osCrashes App:$appIssues UpdFail:$updateFails HW:$($hwEvents.Count)"
            $results.Add([PSCustomObject]@{
                Id='reliability'; Order=3; Name='3. Reliability History & Crash/Hardware Logs'; Command='perfmon /rel + WHEA/Disk/NTFS Event Logs + Minidumps'
                Status=$status; Duration=$dur; Summary=$summary; Details=$relDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 3 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='reliability'; Order=3; Name='3. Reliability History & Crash/Hardware Logs'; Command='perfmon /rel (WMI query)'
                Status='ERROR'; Duration=$dur; Summary="Query error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 3 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 4/15: Device Manager & Broken Drivers (Win32_PnPEntity)
    # ------------------------------------------------------------------
    if (-not $config.Enabled[4]) {
        Add-SkippedStep 4 'drivers' '4. Device Manager & Driver Health' 'Get-CimInstance Win32_PnPEntity'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 4 'Get-CimInstance Win32_PnPEntity (Device Manager errors)'
        Write-RawLog "`r`n--- [4/15] Device Manager Broken Drivers (Win32_PnPEntity) ---" $rawLogPath
        try {
            $codeMap = @{
                1='Device not configured correctly'; 10='Device failed to start'; 12='Not enough free resources'
                18='Reinstall drivers for this device'; 19='Registry configuration damaged'; 22='Device disabled by user'
                28='Drivers are not installed'; 31='Windows cannot load required drivers'; 32='Driver service disabled'
                37='Driver failed initialization'; 39='Driver corrupted or missing'; 43='Device reported problems and was stopped'
                45='Device not currently connected'; 48='Driver blocked due to compatibility issues'
                52='Unsigned driver blocked by Windows'; 56='Windows still setting up class configuration'
            }
            $pnpErrs = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop)
            $brokenDevs = New-Object 'System.Collections.Generic.List[string]'
            $infoDevs = New-Object 'System.Collections.Generic.List[string]'

            foreach ($dev in $pnpErrs) {
                $dName = [string](Get-SafeProp $dev 'Name' 'Unknown Device')
                $dCode = [int](Get-SafeProp $dev 'ConfigManagerErrorCode' 0)
                $dId = [string](Get-SafeProp $dev 'DeviceID' '')
                $desc = if ($codeMap.ContainsKey($dCode)) { $codeMap[$dCode] } else { "Error Code $dCode" }
                $entry = "$dName [Code $dCode - $desc] ($dId)"
                if ($dCode -eq 22 -or ($dCode -eq 56 -and $dName -match 'Wi-Fi Direct|WAN Miniport|Virtual')) {
                    $infoDevs.Add($entry)
                } else {
                    $brokenDevs.Add($entry)
                }
            }

            $pnpDetailLines = New-Object 'System.Collections.Generic.List[string]'
            $pnpDetailLines.Add("Broken / Problem Devices: $($brokenDevs.Count)")
            foreach ($b in $brokenDevs) { $pnpDetailLines.Add("  [ERROR] $b") }
            if ($infoDevs.Count -gt 0) {
                $pnpDetailLines.Add('')
                $pnpDetailLines.Add("Disabled or Idle Virtual Devices (Informational): $($infoDevs.Count)")
                foreach ($inf in $infoDevs) { $pnpDetailLines.Add("  [INFO]  $inf") }
            }
            $pnpDetails = $pnpDetailLines -join "`r`n"
            Write-RawLog $pnpDetails $rawLogPath

            if ($brokenDevs.Count -gt 0) {
                $status = 'ATTENTION'
                $summary = "$($brokenDevs.Count) device(s) with driver errors"
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Medium'; Source='Device Manager (Drivers)'
                    Title="$($brokenDevs.Count) device(s) have broken or missing drivers."
                    Action='Open Device Manager (Win+X -> Device Manager) and update/reinstall drivers with a warning icon.'
                })
            } else {
                $status = 'OK'
                $summary = "No broken drivers ($($infoDevs.Count) disabled/virtual info)"
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='drivers'; Order=4; Name='4. Device Manager & Driver Health'; Command='Get-CimInstance Win32_PnPEntity (ConfigManagerErrorCode <> 0)'
                Status=$status; Duration=$dur; Summary=$summary; Details=$pnpDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 4 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='drivers'; Order=4; Name='4. Device Manager & Driver Health'; Command='Win32_PnPEntity'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 4 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 5/15: Windows Security & Memory Integrity (HVCI) Posture
    # ------------------------------------------------------------------
    if (-not $config.Enabled[5]) {
        Add-SkippedStep 5 'security_posture' '5. Windows Security & Memory Integrity (HVCI)' 'Win32_DeviceGuard + Firewall + Defender'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 5 'Win32_DeviceGuard (HVCI) + Firewall + Defender status'
        Write-RawLog "`r`n--- [5/15] Security Posture & Memory Integrity (HVCI) ---" $rawLogPath
        try {
            $secLines = New-Object 'System.Collections.Generic.List[string]'
            $secIssues = 0
            $hvciOn = $false
            try {
                $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop
                $runningSvcs = @(Get-SafeProp $dg 'SecurityServicesRunning' @())
                $vbsState = [int](Get-SafeProp $dg 'VirtualizationBasedSecurityStatus' 0)
                $hvciOn = ($runningSvcs -contains 2)
                $secLines.Add("Core Isolation - Memory Integrity (HVCI): $(if ($hvciOn) { 'ENABLED (Running)' } else { 'DISABLED (Not running)' }) [VBS Status=$vbsState]")
                if (-not $hvciOn) {
                    $secIssues++
                    $attentionItems.Add([PSCustomObject]@{
                        Severity='Medium'; Source='Windows Security (Memory Integrity)'
                        Title='Core Isolation Memory Integrity (HVCI) is turned OFF.'
                        Action='Open Windows Security -> Device security -> Core isolation details to review or enable Memory Integrity.'
                    })
                }
            } catch {
                $secLines.Add("Core Isolation - Memory Integrity (HVCI): Unavailable ($($_.Exception.Message))")
            }

            try {
                $fwProfiles = @(Get-NetFirewallProfile -ErrorAction Stop)
                $disabledFw = @($fwProfiles | Where-Object { -not [bool](Get-SafeProp $_ 'Enabled' $false) })
                foreach ($fp in $fwProfiles) {
                    $secLines.Add("Windows Firewall ($($fp.Name)): $(if ($fp.Enabled) { 'Enabled' } else { 'DISABLED' })")
                }
                if ($disabledFw.Count -gt 0) {
                    $secIssues++
                    $names = ($disabledFw | ForEach-Object { $_.Name }) -join ', '
                    $attentionItems.Add([PSCustomObject]@{
                        Severity='High'; Source='Windows Firewall'
                        Title="Windows Firewall is DISABLED for profile(s): $names."
                        Action='Open Windows Security -> Firewall & network protection and enable the firewall.'
                    })
                }
            } catch {
                $secLines.Add("Windows Firewall: Could not query ($($_.Exception.Message))")
            }

            try {
                $mpSt = Get-MpComputerStatus -ErrorAction Stop
                $rtp = [bool](Get-SafeProp $mpSt 'RealTimeProtectionEnabled' $false)
                $avOn = [bool](Get-SafeProp $mpSt 'AntivirusEnabled' $false)
                $tamper = Get-SafeProp $mpSt 'IsTamperProtected' $null
                $secLines.Add("Microsoft Defender Real-Time Protection: $(if ($rtp) { 'Enabled' } else { 'DISABLED' }) | AntivirusEnabled=$avOn | TamperProtection=$tamper")
                if (-not $rtp) {
                    $secIssues++
                    $attentionItems.Add([PSCustomObject]@{
                        Severity='High'; Source='Windows Security (Defender)'
                        Title='Microsoft Defender Real-Time Protection is OFF.'
                        Action='Check Windows Security -> Virus & threat protection (ignore if using a third-party AV).'
                    })
                }
            } catch {
                $secLines.Add("Microsoft Defender Status: Could not query ($($_.Exception.Message))")
            }

            $secDetails = $secLines -join "`r`n"
            Write-RawLog $secDetails $rawLogPath
            $status = if ($secIssues -gt 0) { 'ATTENTION' } else { 'OK' }
            $summary = if ($secIssues -gt 0) {
                "$secIssues protection setting(s) OFF (HVCI: $(if ($hvciOn) { 'ON' } else { 'OFF' }))"
            } else {
                'HVCI, Firewall & Defender Real-Time all ON'
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='security_posture'; Order=5; Name='5. Windows Security & Memory Integrity (HVCI)'; Command='Win32_DeviceGuard + Get-NetFirewallProfile + Get-MpComputerStatus'
                Status=$status; Duration=$dur; Summary=$summary; Details=$secDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 5 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='security_posture'; Order=5; Name='5. Windows Security & Memory Integrity (HVCI)'; Command='DeviceGuard + Firewall + Defender'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 5 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 6/15: WMI Repository Verification & Auto-Salvage (winmgmt)
    # ------------------------------------------------------------------
    if (-not $config.Enabled[6]) {
        Add-SkippedStep 6 'wmi_repo' '6. WMI Repository Verification & Repair' 'winmgmt /verifyrepository'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 6 'winmgmt /verifyrepository (+ /salvagerepository if needed)'
        Write-RawLog "`r`n--- [6/15] winmgmt /verifyrepository ---" $rawLogPath
        try {
            $winmgmtExe = Join-Path $sysDir 'Wbem\WinMgmt.exe'
            if (-not (Test-Path -LiteralPath $winmgmtExe)) { $winmgmtExe = 'winmgmt.exe' }
            $wmiTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $(if ($h) { $h } else { 'Checking WMI repository...' }) }
            $wmiVer = Invoke-ConsoleTool -FilePath $winmgmtExe -Arguments '/verifyrepository' -OnTick $wmiTick
            $wmiOut = ($wmiVer.Output + "`r`n" + $wmiVer.Error).Trim()
            Write-RawLog $wmiOut $rawLogPath

            if ($wmiVer.ExitCode -eq 0 -and $wmiOut -match 'is consistent') {
                $status = 'OK'
                $summary = 'WMI repository is consistent'
                $wmiDetails = $wmiOut
            } else {
                Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Repairing WMI (/salvagerepository)...'
                $wmiSalv = Invoke-ConsoleTool -FilePath $winmgmtExe -Arguments '/salvagerepository' -OnTick { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Running winmgmt /salvagerepository...' }
                $salvOut = ($wmiSalv.Output + "`r`n" + $wmiSalv.Error).Trim()
                Write-RawLog $salvOut $rawLogPath
                $wmiDetails = "Verify:`r`n$wmiOut`r`n`r`nSalvage:`r`n$salvOut"

                if ($wmiSalv.ExitCode -eq 0 -and $salvOut -match 'consistent|salvaged') {
                    $status = 'FIXED'
                    $summary = 'Repaired WMI repository via /salvagerepository'
                    $fixedItems.Add([PSCustomObject]@{
                        Source      = 'WMI Repository (winmgmt)'
                        Description = 'Detected WMI repository inconsistency and repaired it safely using winmgmt /salvagerepository.'
                    })
                } else {
                    $status = 'ATTENTION'
                    $summary = "WMI salvage exited with code $($wmiSalv.ExitCode)"
                    $attentionItems.Add([PSCustomObject]@{
                        Severity='Medium'; Source='WMI Repository (winmgmt)'
                        Title='WMI repository reported an inconsistency that /salvagerepository could not fully clear.'
                        Action='After restarting, re-run "winmgmt /verifyrepository" as Administrator.'
                    })
                }
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='wmi_repo'; Order=6; Name='6. WMI Repository Verification & Repair'; Command='winmgmt /verifyrepository (+ /salvagerepository if inconsistent)'
                Status=$status; Duration=$dur; Summary=$summary; Details=$wmiDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 6 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='wmi_repo'; Order=6; Name='6. WMI Repository Verification & Repair'; Command='winmgmt /verifyrepository'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 6 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 7/15: DISM Health Scan (/ScanHealth)
    # ------------------------------------------------------------------
    if (-not $config.Enabled[7]) {
        Add-SkippedStep 7 'dism_scan' '7. DISM Component Store Scan' 'DISM /Online /Cleanup-Image /ScanHealth'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 7 'DISM /Online /Cleanup-Image /ScanHealth'
        Write-RawLog "`r`n--- [7/15] DISM /ScanHealth ---" $rawLogPath
        try {
            $dismTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $(if ($h) { "DISM ScanHealth: $h" } else { 'Scanning Windows component store...' }) }
            $dismScan = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'DISM.exe') -Arguments '/Online /Cleanup-Image /ScanHealth' -OnTick $dismTick
            $scanOut = ($dismScan.Output + "`r`n" + $dismScan.Error).Trim()
            Write-RawLog $scanOut $rawLogPath

            $dismRepairable = ($scanOut -match 'component store is repairable')
            $dismHealthy = ($scanOut -match 'No component store corruption detected')
            $dismUnrepairable = ($scanOut -match 'not repairable|cannot be repaired')

            if ($dismScan.ExitCode -eq 0 -and $dismHealthy) {
                $status = 'OK'
                $summary = 'No component store corruption detected'
            } elseif ($dismRepairable) {
                $status = 'ATTENTION'
                $summary = 'Repairable corruption found (Step 8 will fix)'
            } elseif ($dismUnrepairable) {
                $status = 'ATTENTION'
                $summary = 'Unrepairable component store corruption'
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source='DISM (/ScanHealth)'
                    Title='DISM reported component store corruption that may require an external repair source.'
                    Action='Check C:\Windows\Logs\DISM\dism.log or run an in-place Windows repair upgrade.'
                })
            } else {
                $status = 'ATTENTION'
                $summary = "DISM /ScanHealth exited with code $($dismScan.ExitCode)"
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='dism_scan'; Order=7; Name='7. DISM Component Store Scan'; Command='DISM /Online /Cleanup-Image /ScanHealth'
                Status=$status; Duration=$dur; Summary=$summary; Details=$scanOut; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 7 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='dism_scan'; Order=7; Name='7. DISM Component Store Scan'; Command='DISM /Online /Cleanup-Image /ScanHealth'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 7 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 8/15: DISM Image Repair (/RestoreHealth) + /StartComponentCleanup
    # ------------------------------------------------------------------
    if (-not $config.Enabled[8]) {
        Add-SkippedStep 8 'dism_restore' '8. DISM Component Store Repair & Cleanup' 'DISM /RestoreHealth + /StartComponentCleanup'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 8 'DISM /Online /Cleanup-Image /RestoreHealth + /StartComponentCleanup'
        Write-RawLog "`r`n--- [8/15] DISM /RestoreHealth & /StartComponentCleanup ---" $rawLogPath
        try {
            $rTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $(if ($h) { "DISM RestoreHealth: $h" } else { 'Running DISM /RestoreHealth...' }) }
            $dismRestore = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'DISM.exe') -Arguments '/Online /Cleanup-Image /RestoreHealth' -OnTick $rTick
            $restOut = ($dismRestore.Output + "`r`n" + $dismRestore.Error).Trim()
            Write-RawLog $restOut $rawLogPath

            $cleanupNote = ''
            $cleanupOut = ''
            if ($dismRestore.ExitCode -in @(0, 3010)) {
                $cTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $(if ($h) { "DISM ComponentCleanup: $h" } else { 'Running DISM /StartComponentCleanup...' }) }
                $dismClean = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'DISM.exe') -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -OnTick $cTick
                $cleanupOut = ($dismClean.Output + "`r`n" + $dismClean.Error).Trim()
                Write-RawLog $cleanupOut $rawLogPath
                if ($dismClean.ExitCode -in @(0, 3010)) { $cleanupNote = ' + WinSxS cleaned' }

                $rebootNote = if ($dismRestore.ExitCode -eq 3010) { ' (restart required)' } else { '' }
                if ($dismRepairable) {
                    $status = 'FIXED'
                    $summary = "Repaired component store$cleanupNote$rebootNote"
                    $fixedItems.Add([PSCustomObject]@{
                        Source      = 'DISM (/RestoreHealth + /StartComponentCleanup)'
                        Description = "Repaired Windows component store corruption and cleaned superseded WinSxS packages$rebootNote."
                    })
                } else {
                    $status = 'OK'
                    $summary = "Component store healthy$cleanupNote$rebootNote"
                }
            } else {
                $status = 'ATTENTION'
                $summary = "DISM /RestoreHealth error code $($dismRestore.ExitCode)"
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source='DISM (/RestoreHealth)'
                    Title="DISM /RestoreHealth failed with exit code $($dismRestore.ExitCode)."
                    Action='Ensure internet access (Windows Update) is working and inspect C:\Windows\Logs\DISM\dism.log.'
                })
            }

            $combinedDism = if (-not [string]::IsNullOrWhiteSpace($cleanupOut)) {
                "=== /RestoreHealth ===`r`n$restOut`r`n`r`n=== /StartComponentCleanup ===`r`n$cleanupOut"
            } else { $restOut }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='dism_restore'; Order=8; Name='8. DISM Component Store Repair & Cleanup'; Command='DISM /Online /Cleanup-Image /RestoreHealth + /StartComponentCleanup'
                Status=$status; Duration=$dur; Summary=$summary; Details=$combinedDism; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 8 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='dism_restore'; Order=8; Name='8. DISM Component Store Repair & Cleanup'; Command='DISM /Online /Cleanup-Image /RestoreHealth'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            $attentionItems.Add([PSCustomObject]@{
                Severity='High'; Source='DISM (/RestoreHealth)'
                Title='DISM /RestoreHealth encountered an exception.'
                Action=$errMsg
            })
            Set-StepDone 8 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 9/15: System File Checker (sfc /scannow)
    # ------------------------------------------------------------------
    if (-not $config.Enabled[9]) {
        Add-SkippedStep 9 'sfc' '9. System File Checker' 'sfc /scannow'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 9 'sfc /scannow'
        Write-RawLog "`r`n--- [9/15] sfc /scannow ---" $rawLogPath
        try {
            $sfcTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $(if ($h) { "SFC verification: $h" } else { 'Scanning protected Windows system files...' }) }
            $sfcRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'sfc.exe') -Arguments '/scannow' -Encoding 'Unicode' -OnTick $sfcTick
            $sfcOut = ($sfcRes.Output + "`r`n" + $sfcRes.Error).Trim()
            Write-RawLog $sfcOut $rawLogPath

            $sfcDetails = $sfcOut
            if ($sfcOut -match 'found corrupt files and successfully repaired them') {
                $status = 'FIXED'
                $summary = 'Found and repaired corrupt system files'
                $fixedItems.Add([PSCustomObject]@{
                    Source      = 'System File Checker (sfc /scannow)'
                    Description = 'Found and repaired corrupt Windows system files.'
                })
            } elseif ($sfcOut -match 'did not find any integrity violations') {
                $status = 'OK'
                $summary = 'No system file integrity violations found'
            } elseif ($sfcOut -match 'unable to fix some of them') {
                $status = 'ATTENTION'
                $summary = 'Corrupt files found; some could not be repaired'
                $cbsPath = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
                if (Test-Path -LiteralPath $cbsPath) {
                    try {
                        $cannotFix = @(Get-Content -LiteralPath $cbsPath -Tail 2000 -ErrorAction SilentlyContinue | Where-Object { $_ -match '\[SR\] Cannot repair' } | Select-Object -Last 10)
                        if ($cannotFix.Count -gt 0) {
                            $sfcDetails += "`r`n`r`n--- Recent [SR] Cannot repair lines from CBS.log ---`r`n" + ($cannotFix -join "`r`n")
                        }
                    } catch {}
                }
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source='System File Checker (sfc /scannow)'
                    Title='SFC found corrupt system files that could not be repaired.'
                    Action='Check the SFC section details or C:\Windows\Logs\CBS\CBS.log for "[SR] Cannot repair" entries.'
                })
            } elseif ($sfcOut -match 'system repair pending') {
                $status = 'ATTENTION'
                $summary = 'Pending system repair waiting for restart'
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Medium'; Source='System File Checker (sfc /scannow)'
                    Title='A pending system repair blocked SFC from running.'
                    Action='After restarting, run "sfc /scannow" once more as Administrator.'
                })
            } elseif ($sfcRes.ExitCode -ne 0) {
                $status = 'ATTENTION'
                $summary = "sfc /scannow exited with code $($sfcRes.ExitCode)"
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source='System File Checker (sfc /scannow)'
                    Title="sfc /scannow returned exit code $($sfcRes.ExitCode)."
                    Action='Review C:\Windows\Logs\CBS\CBS.log or re-run sfc /scannow elevated.'
                })
            } else {
                $status = 'OK'
                $summary = 'sfc /scannow completed cleanly'
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='sfc'; Order=9; Name='9. System File Checker'; Command='sfc /scannow'
                Status=$status; Duration=$dur; Summary=$summary; Details=$sfcDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 9 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='sfc'; Order=9; Name='9. System File Checker'; Command='sfc /scannow'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            $attentionItems.Add([PSCustomObject]@{
                Severity='High'; Source='System File Checker (sfc /scannow)'
                Title='sfc /scannow encountered an exception.'
                Action=$errMsg
            })
            Set-StepDone 9 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 10/15: CHKDSK on ALL Connected Drives
    # ------------------------------------------------------------------
    if (-not $config.Enabled[10]) {
        Add-SkippedStep 10 'chkdsk' '10. All Connected Drives Scan' 'chkdsk <Drive>: /scan (all drives)'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 10 'chkdsk <Drive>: /scan (all mounted Fixed/Removable drives)'
        Write-RawLog "`r`n--- [10/15] chkdsk on all connected drives ---" $rawLogPath
        try {
            $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object {
                $dl = Get-SafeProp $_ 'DriveLetter' $null
                $dt = [string](Get-SafeProp $_ 'DriveType' '')
                $sz = [int64](Get-SafeProp $_ 'Size' 0)
                $op = [string](Get-SafeProp $_ 'OperationalStatus' '')
                $dl -and ($dt -in @('Fixed', 'Removable')) -and ($sz -gt 0) -and ($op -eq 'OK')
            } | Sort-Object DriveLetter)

            if ($vols.Count -eq 0) {
                $ldisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2 OR DriveType=3' -ErrorAction SilentlyContinue | Sort-Object DeviceID)
                $vols = @($ldisks | ForEach-Object {
                    [PSCustomObject]@{
                        DriveLetter     = ([string]$_.DeviceID).TrimEnd(':')
                        FileSystemType  = [string](Get-SafeProp $_ 'FileSystem' '')
                        FileSystemLabel = [string](Get-SafeProp $_ 'VolumeName' '')
                    }
                })
            }

            $driveSummaries = New-Object 'System.Collections.Generic.List[string]'
            $driveOutputs = New-Object 'System.Collections.Generic.List[string]'
            $anyDriveFixed = $false
            $anyDriveNeedsAttention = $false

            foreach ($v in $vols) {
                $drive = "$($v.DriveLetter):"
                $fs = [string](Get-SafeProp $v 'FileSystemType' '')
                $lbl = [string](Get-SafeProp $v 'FileSystemLabel' '')
                $labelTag = if ([string]::IsNullOrWhiteSpace($lbl)) { $fs } else { "$lbl, $fs" }
                Write-RawLog "--- Drive $drive ($labelTag) ---" $rawLogPath

                $dTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $(if ($h) { "CHKDSK ${drive} $h" } else { "Scanning drive $drive ($fs)..." }) }

                if ($fs -ieq 'NTFS') {
                    $chkRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'chkdsk.exe') -Arguments "$drive /scan" -OnTick $dTick
                    $chkOut = ($chkRes.Output + "`r`n" + $chkRes.Error).Trim()
                    Write-RawLog $chkOut $rawLogPath
                    $driveOutputs.Add("=== Drive $drive ($labelTag) [chkdsk $drive /scan, exit $($chkRes.ExitCode)] ===`r`n$chkOut")

                    if ($chkRes.ExitCode -eq 0 -and -not ($chkOut -match 'Windows found problems|errors found|offline repair|spotfix')) {
                        $driveSummaries.Add("$drive Clean")
                    } elseif ($chkRes.ExitCode -eq 1 -or ($chkOut -match 'made corrections to the file system|successfully scanned.*fixed')) {
                        $anyDriveFixed = $true
                        $driveSummaries.Add("$drive Fixed")
                        $fixedItems.Add([PSCustomObject]@{
                            Source      = "CHKDSK ($drive)"
                            Description = "Found and fixed file system errors online on drive $drive ($labelTag)."
                        })
                    } else {
                        $anyDriveNeedsAttention = $true
                        if ($drive -ieq $env:SystemDrive) {
                            $schedOut = & "$sysDir\cmd.exe" /c "echo Y| `"$sysDir\chkdsk.exe`" $drive /f" 2>&1 | Out-String
                            Write-RawLog $schedOut $rawLogPath
                            $offlineChkdskScheduled = $true
                            $driveSummaries.Add("$drive Queued /f on reboot")
                            $attentionItems.Add([PSCustomObject]@{
                                Severity='Medium'; Source="CHKDSK ($drive)"
                                Title="Drive $drive needs offline file system repair."
                                Action='An offline repair has been queued for the next restart. Check the post-reboot report for Wininit results.'
                            })
                        } else {
                            $driveSummaries.Add("$drive Needs /f")
                            $attentionItems.Add([PSCustomObject]@{
                                Severity='Medium'; Source="CHKDSK ($drive)"
                                Title="File system issues detected on drive $drive ($labelTag)."
                                Action="Close open files on $drive and run `"chkdsk $drive /f`" from an elevated prompt."
                            })
                        }
                    }
                } elseif ($fs -iin @('FAT', 'FAT32', 'EXFAT')) {
                    $chkRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'chkdsk.exe') -Arguments "$drive" -OnTick $dTick
                    $chkOut = ($chkRes.Output + "`r`n" + $chkRes.Error).Trim()
                    Write-RawLog $chkOut $rawLogPath
                    $driveOutputs.Add("=== Drive $drive ($labelTag) [chkdsk $drive, exit $($chkRes.ExitCode)] ===`r`n$chkOut")

                    if ($chkRes.ExitCode -eq 0 -and -not ($chkOut -match 'errors found|found problems')) {
                        $driveSummaries.Add("$drive Clean")
                    } else {
                        $anyDriveNeedsAttention = $true
                        $driveSummaries.Add("$drive Needs /f")
                        $attentionItems.Add([PSCustomObject]@{
                            Severity='Medium'; Source="CHKDSK ($drive)"
                            Title="File system issues detected on $fs drive $drive ($labelTag)."
                            Action="Back up data on $drive and run `"chkdsk $drive /f`" as Administrator."
                        })
                    }
                } else {
                    $driveSummaries.Add("$drive Skipped ($fs)")
                    $driveOutputs.Add("=== Drive $drive ($labelTag) ===`r`nSkipped because filesystem '$fs' does not use standard chkdsk /scan.")
                }
            }

            $chkStatus = if ($anyDriveNeedsAttention) { 'ATTENTION' } elseif ($anyDriveFixed) { 'FIXED' } else { 'OK' }
            $chkSummary = "$($vols.Count) drive(s): " + ($driveSummaries -join ', ')
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='chkdsk'; Order=10; Name='10. All Connected Drives Scan'; Command='chkdsk <Drive>: /scan (all mounted Fixed/Removable drives)'
                Status=$chkStatus; Duration=$dur; Summary=$chkSummary; Details=($driveOutputs -join "`r`n`r`n"); ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 10 $chkStatus $dur $chkSummary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='chkdsk'; Order=10; Name='10. All Connected Drives Scan'; Command='chkdsk <Drive>: /scan'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 10 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 11/15: SSD TRIM Optimization & Safe Stale Temp Cleanup
    # ------------------------------------------------------------------
    if (-not $config.Enabled[11]) {
        Add-SkippedStep 11 'opt_cleanup' '11. SSD TRIM & Safe Temp Cleanup' 'Optimize-Volume -ReTrim + Stale Temp (>24h)'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 11 'Optimize-Volume -ReTrim + Stale Temp (>24h) Cleanup'
        Write-RawLog "`r`n--- [11/15] SSD ReTrim & Stale Temp Cleanup ---" $rawLogPath
        try {
            $optLines = New-Object 'System.Collections.Generic.List[string]'
            $trimmedDrives = New-Object 'System.Collections.Generic.List[string]'

            try {
                $ssdDiskIds = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { (Get-SafeProp $_ 'MediaType' '') -eq 'SSD' } | ForEach-Object { [int](Get-SafeProp $_ 'DeviceId' -1) })
                $ssdLetters = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and ($_.DiskNumber -in $ssdDiskIds) } | Select-Object -ExpandProperty DriveLetter -Unique | Sort-Object)
                foreach ($ltr in $ssdLetters) {
                    Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint "Running SSD TRIM on ${ltr}:..."
                    try {
                        Optimize-Volume -DriveLetter $ltr -ReTrim -ErrorAction Stop
                        $trimmedDrives.Add("${ltr}:")
                        $optLines.Add("SSD TRIM completed on ${ltr}:")
                    } catch {
                        $optLines.Add("SSD TRIM skipped on ${ltr}: ($($_.Exception.Message))")
                    }
                }
                if ($ssdLetters.Count -eq 0) { $optLines.Add('No SSD drive letters detected for ReTrim.') }
            } catch {
                $optLines.Add("SSD ReTrim check error: $($_.Exception.Message)")
            }

            Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Cleaning stale temp files (>24h old)...'
            $tempCut = (Get-Date).AddHours(-24)
            $bytesFreed = [int64]0
            $filesRemoved = 0
            $tempTargets = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) | Select-Object -Unique
            foreach ($tDir in $tempTargets) {
                if ([string]::IsNullOrWhiteSpace($tDir) -or -not (Test-Path -LiteralPath $tDir)) { continue }
                $staleFiles = @(Get-ChildItem -LiteralPath $tDir -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.LastWriteTime -lt $tempCut -and $_.Name -notlike 'Windows_Scan_and_Fix_*'
                })
                foreach ($sf in $staleFiles) {
                    try {
                        $sz = $sf.Length
                        Remove-Item -LiteralPath $sf.FullName -Force -ErrorAction Stop
                        $bytesFreed += $sz
                        $filesRemoved++
                    } catch {}
                }
            }
            $mbFreed = [math]::Round($bytesFreed / 1MB, 1)
            $optLines.Add("Stale temp files removed (>24h old): $filesRemoved file(s), ${mbFreed} MB reclaimed.")

            $optDetails = $optLines -join "`r`n"
            Write-RawLog $optDetails $rawLogPath

            $didWork = ($trimmedDrives.Count -gt 0 -or $mbFreed -ge 10)
            if ($didWork) {
                $parts = New-Object 'System.Collections.Generic.List[string]'
                if ($trimmedDrives.Count -gt 0) { $parts.Add("Ran SSD TRIM on $($trimmedDrives -join ', ')") }
                if ($mbFreed -ge 10) { $parts.Add("cleaned $filesRemoved stale temp file(s) (${mbFreed} MB freed)") }
                $fixedItems.Add([PSCustomObject]@{
                    Source      = 'SSD Optimization & Temp Cleanup'
                    Description = ($parts -join ' and ') + '.'
                })
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $st = if ($didWork) { 'FIXED' } else { 'OK' }
            $summary = "TRIM: $(if ($trimmedDrives.Count -gt 0) { $trimmedDrives -join ',' } else { 'None' }) | Freed: ${mbFreed} MB ($filesRemoved files)"
            $results.Add([PSCustomObject]@{
                Id='opt_cleanup'; Order=11; Name='11. SSD TRIM & Safe Temp Cleanup'; Command='Optimize-Volume -ReTrim + Stale Temp (>24h) Cleanup'
                Status=$st; Duration=$dur; Summary=$summary; Details=$optDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 11 $st $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='opt_cleanup'; Order=11; Name='11. SSD TRIM & Safe Temp Cleanup'; Command='Optimize-Volume -ReTrim'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 11 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 12/15: Network Stack, DNS & Clock Sync Repair
    # ------------------------------------------------------------------
    if (-not $config.Enabled[12]) {
        Add-SkippedStep 12 'network_time' '12. Network Stack, DNS & Clock Sync' 'ipconfig /flushdns + netsh winsock reset + w32tm /resync'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 12 'ipconfig /flushdns + netsh winsock reset + w32tm /resync'
        Write-RawLog "`r`n--- [12/15] ipconfig /flushdns + netsh winsock reset + w32tm /resync ---" $rawLogPath
        try {
            $netLines = New-Object 'System.Collections.Generic.List[string]'
            $netOk = $true
            $nTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Refreshing DNS, Winsock & clock...' }

            $dnsRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'ipconfig.exe') -Arguments '/flushdns' -OnTick $nTick
            $netLines.Add("=== ipconfig /flushdns (exit $($dnsRes.ExitCode)) ===`r`n$($dnsRes.Output.Trim())")

            $wsRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'netsh.exe') -Arguments 'winsock reset' -OnTick $nTick
            $netLines.Add("=== netsh winsock reset (exit $($wsRes.ExitCode)) ===`r`n$($wsRes.Output.Trim())")
            if ($wsRes.ExitCode -ne 0) { $netOk = $false }

            $timeNote = 'Clock sync skipped'
            try {
                $w32Svc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
                if ($null -ne $w32Svc -and $w32Svc.Status -ne 'Running' -and $w32Svc.StartType -ne 'Disabled') {
                    Start-Service -Name 'W32Time' -ErrorAction SilentlyContinue
                }
                $tmRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'w32tm.exe') -Arguments '/resync /nowait' -OnTick $nTick
                $netLines.Add("=== w32tm /resync /nowait (exit $($tmRes.ExitCode)) ===`r`n$(($tmRes.Output + ' ' + $tmRes.Error).Trim())")
                $timeNote = if ($tmRes.ExitCode -eq 0) { 'Clock synced' } else { "Clock sync exit $($tmRes.ExitCode)" }
            } catch {
                $netLines.Add("Clock resync error: $($_.Exception.Message)")
            }

            $netDetails = $netLines -join "`r`n`r`n"
            Write-RawLog $netDetails $rawLogPath

            if ($dnsRes.ExitCode -eq 0 -or $wsRes.ExitCode -eq 0) {
                $fixedItems.Add([PSCustomObject]@{
                    Source      = 'Network Stack & Clock Sync'
                    Description = "Flushed DNS cache, reset Winsock catalog (applies on restart; Wi-Fi/static IPs preserved), and ran Windows Time sync ($timeNote)."
                })
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $st = if ($netOk) { 'FIXED' } else { 'ATTENTION' }
            $summary = "DNS flushed, Winsock reset, $timeNote"
            $results.Add([PSCustomObject]@{
                Id='network_time'; Order=12; Name='12. Network Stack, DNS & Clock Sync'; Command='ipconfig /flushdns + netsh winsock reset + w32tm /resync'
                Status=$st; Duration=$dur; Summary=$summary; Details=$netDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 12 $st $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='network_time'; Order=12; Name='12. Network Stack, DNS & Clock Sync'; Command='ipconfig /flushdns + netsh winsock reset'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 12 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 13/15: Core Windows Services Health & Auto-Recovery
    # ------------------------------------------------------------------
    if (-not $config.Enabled[13]) {
        Add-SkippedStep 13 'core_services' '13. Core Windows Services Health' 'Get-Service / Start-Service'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 13 'Checking & recovering core Windows services'
        Write-RawLog "`r`n--- [13/15] Core Windows Services ---" $rawLogPath
        try {
            $alwaysRun = @('EventLog', 'Dnscache', 'Dhcp', 'mpssvc', 'WinDefend')
            $updateSvcs = @('wuauserv', 'BITS', 'CryptSvc', 'TrustedInstaller')
            $svcLines = New-Object 'System.Collections.Generic.List[string]'
            $restartedSvcs = New-Object 'System.Collections.Generic.List[string]'
            $svcProblems = New-Object 'System.Collections.Generic.List[string]'

            foreach ($sName in $alwaysRun) {
                $svc = Get-Service -Name $sName -ErrorAction SilentlyContinue
                if ($null -eq $svc) { continue }
                $stType = [string]$svc.StartType
                if ($svc.Status -eq 'Running') {
                    $svcLines.Add("  [OK]       $sName ($($svc.DisplayName)) - Running ($stType)")
                } elseif ($stType -eq 'Disabled') {
                    $svcLines.Add("  [DISABLED] $sName ($($svc.DisplayName)) - Disabled")
                    if ($sName -ne 'WinDefend') { $svcProblems.Add("$sName is Disabled") }
                } else {
                    try {
                        Start-Service -Name $sName -ErrorAction Stop
                        $restartedSvcs.Add($sName)
                        $svcLines.Add("  [FIXED]    $sName ($($svc.DisplayName)) - Was stopped; started successfully")
                    } catch {
                        $svcProblems.Add("$sName stopped and failed to start ($($_.Exception.Message))")
                        $svcLines.Add("  [ERROR]    $sName ($($svc.DisplayName)) - Failed to start: $($_.Exception.Message)")
                    }
                }
            }

            foreach ($sName in $updateSvcs) {
                $svc = Get-Service -Name $sName -ErrorAction SilentlyContinue
                if ($null -eq $svc) { continue }
                $stType = [string]$svc.StartType
                if ($stType -eq 'Disabled') {
                    $svcProblems.Add("$sName (Windows Update component) is Disabled")
                    $svcLines.Add("  [WARN]     $sName ($($svc.DisplayName)) - Disabled")
                } else {
                    $svcLines.Add("  [OK]       $sName ($($svc.DisplayName)) - $($svc.Status) ($stType)")
                }
            }

            $svcDetails = $svcLines -join "`r`n"
            Write-RawLog $svcDetails $rawLogPath

            if ($restartedSvcs.Count -gt 0) {
                $fixedItems.Add([PSCustomObject]@{
                    Source      = 'Core Windows Services'
                    Description = "Automatically started stopped core service(s): $($restartedSvcs -join ', ')."
                })
            }
            if ($svcProblems.Count -gt 0) {
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Medium'; Source='Core Windows Services'
                    Title="$($svcProblems.Count) core Windows service issue(s) found."
                    Action="Review Services (services.msc): $($svcProblems -join '; ')."
                })
            }

            $svcStatus = if ($svcProblems.Count -gt 0) { 'ATTENTION' } elseif ($restartedSvcs.Count -gt 0) { 'FIXED' } else { 'OK' }
            $svcSummary = if ($svcProblems.Count -gt 0) {
                "$($svcProblems.Count) issue(s), restarted $($restartedSvcs.Count)"
            } elseif ($restartedSvcs.Count -gt 0) {
                "Recovered: $($restartedSvcs -join ', ')"
            } else {
                'All core networking, firewall & update services healthy'
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='core_services'; Order=13; Name='13. Core Windows Services Health'; Command='Get-Service / Start-Service (EventLog, Dnscache, Dhcp, mpssvc, WinDefend, wuauserv, BITS, CryptSvc)'
                Status=$svcStatus; Duration=$dur; Summary=$svcSummary; Details=$svcDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 13 $svcStatus $dur $svcSummary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='core_services'; Order=13; Name='13. Core Windows Services Health'; Command='Get-Service'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 13 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # STEP 14/15: Microsoft Defender Scan (Start-MpScan)
    # ------------------------------------------------------------------
    $defMode = $config.DefenderMode
    if (-not $config.Enabled[14] -or $defMode -eq 'Off') {
        Add-SkippedStep 14 'defender' '14. Microsoft Defender Scan' 'Start-MpScan (Disabled)'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 14 "Start-MpScan -ScanType $defMode"
        Write-RawLog "`r`n--- [14/15] Start-MpScan -ScanType $defMode ---" $rawLogPath
        $psRun = $null
        try {
            $mpStart = Get-Date
            $psRun = [powershell]::Create()
            [void]$psRun.AddScript({
                param($Mode)
                $ProgressPreference = 'SilentlyContinue'
                try { Update-MpSignature -ErrorAction Ignore } catch {}
                Start-MpScan -ScanType $Mode -ErrorAction Stop
            }).AddArgument($defMode)

            $async = $psRun.BeginInvoke()
            while (-not $async.IsCompleted) {
                Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint "Microsoft Defender ($defMode) scanning..."
                Start-Sleep -Milliseconds 250
            }
            [void]$psRun.EndInvoke($async)
            if ($psRun.HadErrors -and $psRun.Streams.Error.Count -gt 0) {
                throw $psRun.Streams.Error[0].Exception
            }

            $detections = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object {
                $detTime = Get-SafeProp $_ 'InitialDetectionTime' ([datetime]::MinValue)
                $detTime -ge $mpStart.AddMinutes(-1)
            })
            $activeThreats = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object {
                [bool](Get-SafeProp $_ 'IsActive' $false)
            })
            $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
            $sigVer = [string](Get-SafeProp $mpStatus 'AntivirusSignatureVersion' 'Unknown')

            $mpDetailLines = New-Object 'System.Collections.Generic.List[string]'
            $mpDetailLines.Add("Scan Type: $defMode")
            $mpDetailLines.Add("Antivirus Signature Version: $sigVer")
            $mpDetailLines.Add("Detections during this scan: $($detections.Count)")
            $mpDetailLines.Add("Active threats remaining: $($activeThreats.Count)")

            if ($activeThreats.Count -gt 0) {
                foreach ($at in $activeThreats) {
                    $mpDetailLines.Add("  - ACTIVE THREAT: $([string](Get-SafeProp $at 'ThreatName' 'Unknown Threat'))")
                }
                $status = 'ATTENTION'
                $summary = "$($activeThreats.Count) active threat(s) found!"
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source="Microsoft Defender ($defMode)"
                    Title="$($activeThreats.Count) active threat(s) remain after Microsoft Defender $defMode."
                    Action='Open Windows Security -> Virus & threat protection -> Protection history immediately.'
                })
            } elseif ($detections.Count -gt 0) {
                $status = 'FIXED'
                $summary = "Detected & remediated $($detections.Count) threat(s)"
                $fixedItems.Add([PSCustomObject]@{
                    Source      = "Microsoft Defender ($defMode)"
                    Description = "Antivirus scan detected and quarantined/remediated $($detections.Count) threat(s)."
                })
            } else {
                $status = 'OK'
                $summary = "Clean - no threats found ($defMode)"
            }

            $mpDetails = $mpDetailLines -join "`r`n"
            Write-RawLog $mpDetails $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='defender'; Order=14; Name="14. Microsoft Defender ($defMode)"; Command="Start-MpScan -ScanType $defMode"
                Status=$status; Duration=$dur; Summary=$summary; Details=$mpDetails; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 14 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $mpHelp = 'Ensure Microsoft Defender service is enabled, or check your third-party antivirus if Defender is intentionally disabled.'
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='defender'; Order=14; Name="14. Microsoft Defender ($defMode)"; Command="Start-MpScan -ScanType $defMode"
                Status='ATTENTION'; Duration=$dur; Summary="Did not complete: $errMsg"; Details="$errMsg`r`n$mpHelp"
                ExtraLinkPath=''; ExtraLinkLabel=''
            })
            $attentionItems.Add([PSCustomObject]@{
                Severity='Medium'; Source="Microsoft Defender ($defMode)"
                Title="Microsoft Defender $defMode could not run."
                Action="$errMsg. $mpHelp"
            })
            Set-StepDone 14 'ATTENTION' $dur "Could not run ($errMsg)"
        } finally {
            if ($null -ne $psRun) { $psRun.Dispose() }
        }
    }

    # ------------------------------------------------------------------
    # STEP 15/15: Windows Memory Diagnostic (mdsched / bcdedit {memdiag})
    # ------------------------------------------------------------------
    if (-not $config.Enabled[15]) {
        Add-SkippedStep 15 'memdiag' '15. Windows Memory Diagnostic (RAM Test)' 'mdsched.exe (bcdedit /bootsequence {memdiag})'
    } else {
        $stepStart = Get-Date
        Set-StepRunning 15 'mdsched.exe (bcdedit /bootsequence {memdiag})'
        Write-RawLog "`r`n--- [15/15] Windows Memory Diagnostic ({memdiag}) ---" $rawLogPath
        try {
            $mTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Queuing Windows Memory Diagnostic...' }
            $bcdEnum = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'bcdedit.exe') -Arguments '/enum {memdiag}' -OnTick $mTick
            $bcdOut = ($bcdEnum.Output + "`r`n" + $bcdEnum.Error).Trim()
            Write-RawLog $bcdOut $rawLogPath

            if ($bcdEnum.ExitCode -eq 0) {
                $bcdSeq = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'bcdedit.exe') -Arguments '/bootsequence {memdiag}' -OnTick $mTick
                $seqOut = ($bcdSeq.Output + "`r`n" + $bcdSeq.Error).Trim()
                Write-RawLog $seqOut $rawLogPath

                if ($bcdSeq.ExitCode -eq 0) {
                    $memDiagScheduled = $true
                    $status = 'PENDING'
                    $summary = 'Queued for next restart (results added after login)'
                    $details = "bcdedit /bootsequence {memdiag} succeeded.`r`n`r`n$bcdOut"
                } else {
                    $status = 'ATTENTION'
                    $summary = "bcdedit /bootsequence exit $($bcdSeq.ExitCode)"
                    $details = $seqOut
                    $attentionItems.Add([PSCustomObject]@{
                        Severity='Medium'; Source='Memory Diagnostic (mdsched)'
                        Title='Could not automatically schedule the Windows Memory Diagnostic.'
                        Action='Press Win+R, run "mdsched.exe", and choose "Restart now and check for problems".'
                    })
                }
            } else {
                $status = 'ATTENTION'
                $summary = '{memdiag} boot entry not found'
                $details = $bcdOut
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Medium'; Source='Memory Diagnostic (mdsched)'
                    Title='Windows Memory Diagnostic boot entry ({memdiag}) was not found.'
                    Action='Run "mdsched.exe" manually to schedule a RAM test.'
                })
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='memdiag'; Order=15; Name='15. Windows Memory Diagnostic (RAM Test)'; Command='mdsched.exe (bcdedit /bootsequence {memdiag})'
                Status=$status; Duration=$dur; Summary=$summary; Details=$details; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 15 $status $dur $summary
        } catch {
            $errMsg = $_.Exception.Message
            Write-RawLog "ERROR: $errMsg" $rawLogPath
            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $results.Add([PSCustomObject]@{
                Id='memdiag'; Order=15; Name='15. Windows Memory Diagnostic (RAM Test)'; Command='mdsched.exe'
                Status='ERROR'; Duration=$dur; Summary="Error: $errMsg"; Details=$errMsg; ExtraLinkPath=''; ExtraLinkLabel=''
            })
            Set-StepDone 15 'ERROR' $dur $errMsg
        }
    }

    # ------------------------------------------------------------------
    # Save Report, Register Post-Reboot Finalizer (if needed), Final View
    # ------------------------------------------------------------------
    $scanEnd = Get-Date
    $totalDuration = Format-DurationSpan ($scanEnd - $scanStart)

    $state = [PSCustomObject]@{
        ComputerName           = $env:COMPUTERNAME
        UserName               = $env:USERNAME
        OSCaption              = $osCaption
        TimestampDisplay       = $scanStart.ToString('yyyy-MM-dd HH:mm:ss')
        ScanStartIso           = $scanStart.ToString('o')
        ScanEndIso             = $scanEnd.ToString('o')
        DurationDisplay        = $totalDuration
        PostRebootFinalized    = $false
        FinalizedTimeDisplay   = ''
        MemDiagScheduled       = $memDiagScheduled
        OfflineChkdskScheduled = $offlineChkdskScheduled
        OpenReport             = [bool]$config.OpenReport
        DesktopReportPath      = $desktopReportPath
        ArchiveReportPath      = $archiveReportPath
        RawLogPath             = $rawLogPath
        EnergyHtmlPath         = $energyHtmlPath
        FixedItems             = @($fixedItems.ToArray())
        AttentionItems         = @($attentionItems.ToArray())
        Results                = @($results.ToArray())
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $prelimHtml = New-ScanHtmlReport -State $state
    [System.IO.File]::WriteAllText($archiveReportPath, $prelimHtml, $utf8NoBom)
    try {
        [System.IO.File]::WriteAllText($desktopReportPath, $prelimHtml, $utf8NoBom)
    } catch {
        Write-RawLog "Desktop copy failed: $($_.Exception.Message)" $rawLogPath
    }

    if ($config.AutoRestart -or $memDiagScheduled -or $offlineChkdskScheduled) {
        $statePath = Join-Path $localStateDir 'scan_state.json'
        $finalizePath = Join-Path $localStateDir 'finalize_report.ps1'
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), $utf8NoBom)
        [System.IO.File]::WriteAllText($finalizePath, (Get-FinalizeScriptText), $utf8NoBom)

        try {
            $runOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
            if (-not (Test-Path -LiteralPath $runOnceKey)) {
                [void](New-Item -Path $runOnceKey -Force)
            }
            $psPath = Join-Path $sysDir 'WindowsPowerShell\v1.0\powershell.exe'
            $runOnceCmd = "`"$psPath`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$finalizePath`" -StatePath `"$statePath`""
            Set-ItemProperty -Path $runOnceKey -Name 'WindowsScanAndFixReport' -Value $runOnceCmd -ErrorAction Stop
            Write-RawLog "Registered HKCU RunOnce: $runOnceCmd" $rawLogPath
        } catch {
            Write-RawLog "Failed to register RunOnce: $($_.Exception.Message)" $rawLogPath
        }
    }

    # Final polished dashboard + concise findings
    Render-ScanDashboard -UiState $ui -Final

    Write-Host "  SCAN COMPLETE  |  Total Duration: $totalDuration" -ForegroundColor Green
    Write-Host ''
    Write-Host '  WHAT WAS FIXED:' -ForegroundColor Cyan
    if ($fixedItems.Count -eq 0) {
        Write-Host '    (No automatic repairs were needed)' -ForegroundColor Gray
    } else {
        foreach ($fi in $fixedItems) {
            Write-Host "    [FIX]  $($fi.Source): $($fi.Description)" -ForegroundColor Green
        }
    }
    Write-Host ''
    Write-Host '  THINGS YOU MAY NEED TO LOOK AT:' -ForegroundColor Yellow
    if ($attentionItems.Count -eq 0) {
        Write-Host '    (Nothing needs your attention right now)' -ForegroundColor Gray
    } else {
        foreach ($ai in $attentionItems) {
            Write-Host "    [$($ai.Severity)] $($ai.Source): $($ai.Title)" -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host "  Report : $desktopReportPath" -ForegroundColor White
    Write-Host "  Raw Log: $rawLogPath" -ForegroundColor DarkGray
    Write-Host ''

    if ($config.AutoRestart) {
        if ($config.OpenReport) {
            Write-Host '  After restart, your updated report (with RAM test results) will open automatically.' -ForegroundColor Gray
        }
        Write-Host "  Restarting in $($config.RestartDelaySec) seconds... Close this window or press Ctrl+C to cancel." -ForegroundColor Magenta
        for ($sec = [int]$config.RestartDelaySec; $sec -gt 0; $sec--) {
            Write-Host -NoNewline ("`r  Restarting in {0,2}s...   " -f $sec) -ForegroundColor Magenta
            Start-Sleep -Seconds 1
        }
        Write-Host ''
        & "$sysDir\shutdown.exe" /r /t 5 /d p:2:2 /c "Windows Scan and Fix complete. Restarting your computer now..."
        exit 0
    } else {
        if ($config.OpenReport) {
            $openTarget = if (Test-Path -LiteralPath $desktopReportPath) { $desktopReportPath } else { $archiveReportPath }
            try { Start-Process -FilePath $openTarget } catch {}
        }
        if ($memDiagScheduled -or $offlineChkdskScheduled) {
            Write-Host '  NOTE: Boot-time tests (Memory Diagnostic / CHKDSK) will run on your next manual restart.' -ForegroundColor Yellow
        }
        Write-Host '  Done! Press Enter to close this window.' -ForegroundColor Cyan
        [void](Read-Host)
        exit 0
    }
}

if (-not $SkipRun) {
    Invoke-WindowsScanAndFix
}
