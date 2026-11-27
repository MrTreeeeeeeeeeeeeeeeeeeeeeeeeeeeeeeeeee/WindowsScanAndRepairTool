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
"%_PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "try { $q = [char]34; $ch = Join-Path $env:SystemRoot 'System32\conhost.exe'; if (Test-Path -LiteralPath $ch) { Start-Process -FilePath $ch -ArgumentList ($q + $env:_SELF + $q + ' --elevated') -Verb RunAs -ErrorAction Stop } else { Start-Process -FilePath $env:_SELF -ArgumentList '--elevated' -Verb RunAs -ErrorAction Stop } } catch { exit 1 }"
if errorlevel 1 (
    echo.
    echo [CANCELLED] Administrator access was declined or could not be started.
    echo.
    pause
    exit /b 1
)
exit /b 0

:run_engine
chcp 65001 >nul 2>&1
set "_SELF=%~f0"
set "_SCRIPT_DIR=%~dp0"
set "_PS_TMP=%TEMP%\Windows_Scan_and_Fix_%RANDOM%_%RANDOM%.ps1"

"%_PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$raw = [System.IO.File]::ReadAllText($env:_SELF, [System.Text.Encoding]::UTF8); $m = '#__' + 'PS_ENGINE_START__'; $i = $raw.LastIndexOf($m); if ($i -lt 0) { throw 'Embedded PowerShell engine not found.' }; $ps = $raw.Substring($i + $m.Length); [System.IO.File]::WriteAllText($env:_PS_TMP, $ps, (New-Object System.Text.UTF8Encoding($true)))"
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

$script:TuiCaps = $null

function Initialize-TuiConsole {
    if ($null -ne $script:TuiCaps -and $script:TuiCaps.Initialized) {
        return $script:TuiCaps
    }

    $caps = [PSCustomObject]@{
        Initialized     = $true
        UseVt           = $false
        UseUnicode      = $false
        IsWt            = (-not [string]::IsNullOrEmpty($env:WT_SESSION))
        CanResizeFont   = $false
        FontSizePx      = 24
        OrigFontFace    = ''
        OrigFontSizeY   = 0
        OrigFontWeight  = 400
        OrigBg          = $null
        OrigFg          = $null
        OrigEnc         = $null
    }

    $isRedirected = $false
    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { $isRedirected = $true }
    } catch {
        $isRedirected = $true
    }

    if (-not $isRedirected) {
        try {
            $caps.OrigBg = [Console]::BackgroundColor
            $caps.OrigFg = [Console]::ForegroundColor
            $caps.OrigEnc = [Console]::OutputEncoding
        } catch {}

        try {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $caps.UseUnicode = $true
        } catch {}

        try {
            if (-not ('TuiVtConsole' -as [type])) {
                Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class TuiVtConsole {
    private const int STD_OUTPUT_HANDLE = -11;
    private const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    public struct COORD {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFOEX {
        public uint cbSize;
        public uint nFont;
        public COORD dwFontSize;
        public uint FontFamily;
        public uint FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FaceName;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool GetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern COORD GetLargestConsoleWindowSize(IntPtr hConsoleOutput);

    public static bool EnableVirtualTerminal() {
        IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return false;
        uint mode;
        if (!GetConsoleMode(handle, out mode)) return false;
        if ((mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0) return true;
        return SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }

    public static bool TryGetFont(out string face, out int height, out int weight) {
        face = "";
        height = 0;
        weight = 400;
        IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return false;
        CONSOLE_FONT_INFOEX info = new CONSOLE_FONT_INFOEX();
        info.cbSize = (uint)Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
        if (!GetCurrentConsoleFontEx(handle, false, ref info)) return false;
        face = info.FaceName ?? "";
        height = info.dwFontSize.Y;
        weight = (int)info.FontWeight;
        return true;
    }

    public static bool TrySetFont(string face, int height, int weight) {
        IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return false;
        CONSOLE_FONT_INFOEX info = new CONSOLE_FONT_INFOEX();
        info.cbSize = (uint)Marshal.SizeOf(typeof(CONSOLE_FONT_INFOEX));
        info.FontFamily = 54;
        info.FontWeight = (uint)weight;
        info.dwFontSize.X = 0;
        info.dwFontSize.Y = (short)height;
        info.FaceName = face;
        return SetCurrentConsoleFontEx(handle, false, ref info);
    }

    public static int[] GetLargestWindowSize() {
        IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return new int[] { 0, 0 };
        COORD c = GetLargestConsoleWindowSize(handle);
        return new int[] { c.X, c.Y };
    }
}
'@
            }
            $caps.UseVt = [TuiVtConsole]::EnableVirtualTerminal()

            if (-not $caps.IsWt) {
                $fFace = ''
                $fH = 0
                $fW = 400
                if ([TuiVtConsole]::TryGetFont([ref]$fFace, [ref]$fH, [ref]$fW)) {
                    $caps.CanResizeFont = $true
                    $caps.OrigFontFace = $fFace
                    $caps.OrigFontSizeY = $fH
                    $caps.OrigFontWeight = $fW
                }
            }
        } catch {
            $caps.UseVt = $false
        }

        try {
            [Console]::BackgroundColor = [ConsoleColor]::Black
            [Console]::ForegroundColor = [ConsoleColor]::Gray
        } catch {}
    }

    $script:TuiCaps = $caps

    if ($caps.CanResizeFont) {
        $chosen = 24
        foreach ($candidate in @(26, 24, 22, 20)) {
            if ([TuiVtConsole]::TrySetFont('Consolas', $candidate, 400)) {
                $largest = [TuiVtConsole]::GetLargestWindowSize()
                if ($largest[0] -ge 96 -and $largest[1] -ge 24) {
                    $chosen = $candidate
                    break
                }
            }
        }
        [void](Set-TuiFontSize -HeightPx $chosen)
    }

    return $caps
}

function Set-TuiFontSize {
    param(
        [Parameter(Mandatory = $true)][int]$HeightPx
    )

    if ($null -eq $script:TuiCaps -or -not $script:TuiCaps.CanResizeFont) { return $false }
    $clamped = [math]::Max(16, [math]::Min(36, $HeightPx))
    $ok = $false
    try {
        $ok = [TuiVtConsole]::TrySetFont('Consolas', $clamped, 400)
        if ($ok) {
            $script:TuiCaps.FontSizePx = $clamped
            $largest = [TuiVtConsole]::GetLargestWindowSize()
            if ($largest[0] -ge 60 -and $largest[1] -ge 16) {
                $targetW = [math]::Max(76, [math]::Min(108, $largest[0] - 2))
                $targetH = [math]::Max(20, [math]::Min(28, $largest[1] - 2))
                if ($targetW -gt $largest[0]) { $targetW = $largest[0] }
                if ($targetH -gt $largest[1]) { $targetH = $largest[1] }
                try {
                    if ([Console]::WindowWidth -gt $targetW -or [Console]::WindowHeight -gt $targetH) {
                        [Console]::SetWindowSize([math]::Min([Console]::WindowWidth, $targetW), [math]::Min([Console]::WindowHeight, $targetH))
                    }
                    [Console]::SetBufferSize($targetW, $targetH)
                    [Console]::SetWindowSize($targetW, $targetH)
                } catch {}
            }
        }
    } catch {
        $ok = $false
    }
    return $ok
}

function Reset-TuiConsole {
    if ($null -eq $script:TuiCaps) { return }
    try {
        if ($script:TuiCaps.UseVt) {
            $e = [char]0x1B
            [Console]::Write("${e}[0m")
        }
    } catch {}
    try { [Console]::CursorVisible = $true } catch {}
    try {
        if ($script:TuiCaps.CanResizeFont -and $script:TuiCaps.OrigFontSizeY -gt 0 -and -not [string]::IsNullOrWhiteSpace($script:TuiCaps.OrigFontFace)) {
            [void][TuiVtConsole]::TrySetFont($script:TuiCaps.OrigFontFace, $script:TuiCaps.OrigFontSizeY, $script:TuiCaps.OrigFontWeight)
        }
    } catch {}
    try {
        if ($null -ne $script:TuiCaps.OrigBg) { [Console]::BackgroundColor = $script:TuiCaps.OrigBg }
        if ($null -ne $script:TuiCaps.OrigFg) { [Console]::ForegroundColor = $script:TuiCaps.OrigFg }
    } catch {}
}

function Get-TuiGlyphs {
    $useUni = ($null -ne $script:TuiCaps -and $script:TuiCaps.UseUnicode)
    if ($useUni) {
        $isWt = ($null -ne $script:TuiCaps -and $script:TuiCaps.IsWt)
        $spinner = if ($isWt) {
            @(
                [string][char]0x280B, [string][char]0x2819, [string][char]0x2839, [string][char]0x2838,
                [string][char]0x283C, [string][char]0x2834, [string][char]0x2826, [string][char]0x2827,
                [string][char]0x2807, [string][char]0x280F
            )
        } else {
            @('|', '/', '-', '\')
        }
        $checkGlyph = if ($isWt) { [string][char]0x2713 } else { [string][char]0x221A }
        return [PSCustomObject]@{
            Chevron  = [string][char]0x203A
            Dot      = [string][char]0x00B7
            Rule     = [string][char]0x2500
            BarFill  = [string][char]0x2501
            BarTrack = [string][char]0x2500
            Check    = $checkGlyph
            Fixed    = '+'
            Warn     = '!'
            Err      = [string][char]0x00D7
            Pending  = [string][char]0x25CB
            Queued   = [string][char]0x00B7
            Skipped  = [string][char]0x2013
            ArrowUp  = [string][char]0x2191
            ArrowDn  = [string][char]0x2193
            Spinner  = $spinner
        }
    }
    return [PSCustomObject]@{
        Chevron  = '>'
        Dot      = '*'
        Rule     = '-'
        BarFill  = '#'
        BarTrack = '-'
        Check    = 'v'
        Fixed    = '+'
        Warn     = '!'
        Err      = 'x'
        Pending  = 'o'
        Queued   = '.'
        Skipped  = '-'
        ArrowUp  = '^'
        ArrowDn  = 'v'
        Spinner  = @('|', '/', '-', '\')
    }
}

function Get-TuiAnsi {
    $e = [char]0x1B
    return [PSCustomObject]@{
        Reset      = "${e}[0m"
        Home       = "${e}[H"
        ClearAll   = "${e}[48;2;12;12;12m${e}[2J${e}[H"
        ClearBelow = "${e}[48;2;12;12;12m${e}[J"
        ClearLine  = "${e}[K"
        BgDark     = "${e}[48;2;12;12;12m"
        FgBright   = "${e}[38;2;242;242;242;48;2;12;12;12m"
        FgText     = "${e}[38;2;216;216;216;48;2;12;12;12m"
        FgMuted    = "${e}[38;2;124;124;124;48;2;12;12;12m"
        FgDim      = "${e}[38;2;84;84;84;48;2;12;12;12m"
        TabActive  = "${e}[4;38;2;255;255;255;48;2;12;12;12m"
        TabIdle    = "${e}[38;2;128;128;128;48;2;12;12;12m"
        SelPrimary = "${e}[38;2;12;12;12;48;2;242;242;242m"
        SelSecond  = "${e}[38;2;18;18;18;48;2;206;206;206m"
        SelFill    = "${e}[48;2;242;242;242m"
        KeyBold    = "${e}[1;38;2;242;242;242;48;2;12;12;12m"
        KeyLabel   = "${e}[38;2;182;182;182;48;2;12;12;12m"
        FgOk       = "${e}[38;2;134;239;172;48;2;12;12;12m"
        FgFixed    = "${e}[38;2;125;211;252;48;2;12;12;12m"
        FgWarn     = "${e}[38;2;252;211;77;48;2;12;12;12m"
        FgErr      = "${e}[38;2;252;165;165;48;2;12;12;12m"
        FgPending  = "${e}[38;2;196;181;253;48;2;12;12;12m"
    }
}

function Get-ConsoleSafeWidth {
    $w = 90
    try {
        $cw = [Console]::WindowWidth
        if ($cw -ge 40) { $w = $cw - 1 }
    } catch {
        $w = 90
    }
    return $w
}

function Get-ConsoleSafeHeight {
    $h = 30
    try {
        $ch = [Console]::WindowHeight
        if ($ch -ge 12) { $h = $ch }
    } catch {
        $h = 30
    }
    return $h
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

function Format-CleanToolOutput {
    param([AllowEmptyString()][string]$Text)
    $Text = $Text -replace '[^\r\n]*\r(?!\n)', ''
    $Text = $Text -replace '(?m)^[ \t]*\[[= \t\d.%]+\][ \t]*\r?$', ''
    return ($Text -replace '(?m)^(?:[ \t]*\r?\n){2,}', [Environment]::NewLine).Trim()
}

function Get-EnergyReportErrors {
    param([string]$Html)
    $pattern = '(?is)<div\s+class="\s*error-log-entry\s*"\s*>(.*?)(?=<div\s+class="\s*log-entry\s*"|$)'
    foreach ($entry in [regex]::Matches($Html, $pattern)) {
        $lines = @(foreach ($part in [regex]::Matches($entry.Groups[1].Value, '(?is)<div\s+class="log-entry-(?:header|description)"\s*>(.*?)</div>|<tr\b[^>]*>(.*?)</tr>')) {
            $value = $part.Groups[1].Value + $part.Groups[2].Value
            $clean = [Net.WebUtility]::HtmlDecode(($value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim())
            if (-not [string]::IsNullOrWhiteSpace($clean)) { $clean }
        })
        if ($lines.Count -gt 0) {
            $title = $lines[0]
            if ($title.EndsWith(':')) {
                $detailSuffix = if ($lines.Count -ge 3) { $lines[2] -replace '^Device Name\s+', '' } elseif ($lines.Count -ge 2) { $lines[1] } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($detailSuffix)) {
                    $title = $title.TrimEnd(':') + ': ' + $detailSuffix
                } else {
                    $title = $title.TrimEnd(':')
                }
            }
            [PSCustomObject]@{ Title=$title; Text=($lines -join ' | ') }
        }
    }
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
        [PSCustomObject]@{ Order=1;  Id='disk_health';      Group='Hardware';      ShortName='Physical Disks & Free Space';  Tag='Get-PhysicalDisk + SMART';     Description='Check drive health, SMART counters, and low free space' }
        [PSCustomObject]@{ Order=2;  Id='power_energy';     Group='Hardware';      ShortName='Power, Energy & Battery';      Tag='powercfg /energy (60s)';       Description='Run 60s idle energy trace and laptop battery report' }
        [PSCustomObject]@{ Order=3;  Id='reliability';      Group='Hardware';      ShortName='Reliability & Crash Logs';     Tag='perfmon /rel + WHEA/BSOD';     Description='Read stability score, app crashes, WHEA & BSOD dumps' }
        [PSCustomObject]@{ Order=4;  Id='drivers';          Group='Hardware';      ShortName='Device Manager Drivers';       Tag='Broken/missing drivers';       Description='Find hardware devices with broken or missing drivers' }
        [PSCustomObject]@{ Order=5;  Id='security_posture'; Group='System Repair'; ShortName='Security & Memory Integrity';  Tag='HVCI + Firewall + Defender';   Description='Verify Core Isolation HVCI, Firewall, and Defender status' }
        [PSCustomObject]@{ Order=6;  Id='wmi_repo';         Group='System Repair'; ShortName='WMI Repository Repair';        Tag='winmgmt /verify & /salvage';   Description='Verify WMI database consistency and salvage if needed' }
        [PSCustomObject]@{ Order=7;  Id='dism_scan';        Group='System Repair'; ShortName='DISM Component Store Scan';    Tag='DISM /ScanHealth';             Description='Scan the Windows component store for image corruption' }
        [PSCustomObject]@{ Order=8;  Id='dism_restore';     Group='System Repair'; ShortName='DISM Repair & Cleanup';        Tag='DISM /RestoreHealth + Clean';  Description='Repair component store corruption and clean old updates' }
        [PSCustomObject]@{ Order=9;  Id='sfc';              Group='System Repair'; ShortName='System File Integrity';        Tag='sfc /scannow';                 Description='Scan and repair protected Windows system files' }
        [PSCustomObject]@{ Order=10; Id='chkdsk';           Group='System Repair'; ShortName='All Connected Drives Scan';    Tag='chkdsk /scan (all drives)';    Description='Run chkdsk /scan across all mounted connected drives' }
        [PSCustomObject]@{ Order=11; Id='opt_cleanup';      Group='Maintenance';   ShortName='SSD TRIM & Safe Temp Cleanup'; Tag='ReTrim + Temp > 24h';          Description='Optimize SSDs with ReTrim and remove temp files > 24h' }
        [PSCustomObject]@{ Order=12; Id='network_time';     Group='Maintenance';   ShortName='Network, DNS & Clock Sync';    Tag='flushdns + winsock + w32tm';   Description='Flush DNS cache, reset Winsock, and sync system clock' }
        [PSCustomObject]@{ Order=13; Id='core_services';    Group='Maintenance';   ShortName='Core Windows Services';        Tag='Recover stopped services';     Description='Recover stopped networking, firewall & update services' }
        [PSCustomObject]@{ Order=14; Id='defender';         Group='Maintenance';   ShortName='Microsoft Defender Scan';      Tag='Start-MpScan';                 Description='Update virus definitions and run Defender antivirus scan' }
        [PSCustomObject]@{ Order=15; Id='memdiag';          Group='Restart';       ShortName='Windows Memory Diagnostic';    Tag='RAM test on restart';          Description='Queue one-time RAM test to run on next restart' }
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

function Format-DefenderModeLabel {
    param([string]$Mode)
    switch ($Mode) {
        'FullScan'  { return 'Full Scan' }
        'QuickScan' { return 'Quick Scan' }
        default     { return 'Off' }
    }
}

function Format-PresetLabel {
    param([string]$Preset)
    switch ($Preset) {
        'Full'  { return 'Full Scan' }
        'Quick' { return 'Quick Tune-Up' }
        default { return 'Custom' }
    }
}

function New-TuiMenuState {
    return [PSCustomObject]@{
        View              = 'Main'
        TabIndex          = 0
        CursorIndex       = 0
        ScrollTop         = 0
        SearchActive      = $false
        SearchQuery       = ''
        ReturnView        = 'Main'
        ReturnTabIndex    = 0
        ReturnCursorIndex = 0
        Notice            = ''
    }
}

function Get-TuiMenuViewModel {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State
    )

    $g = Get-TuiGlyphs
    $chev = $g.Chevron
    $tabs = @('General', 'Hardware', 'System Repair', 'Maintenance', 'Restart')
    $enabledCount = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
    $defLabel = Format-DefenderModeLabel $Config.DefenderMode
    $presetLabel = Format-PresetLabel $Config.Preset
    $canResizeFont = ($null -ne $script:TuiCaps -and $script:TuiCaps.CanResizeFont)
    $fontPx = if ($null -ne $script:TuiCaps) { [int]$script:TuiCaps.FontSizePx } else { 24 }
    $rows = New-Object 'System.Collections.Generic.List[object]'

    $mode = 'Tabs'
    $title = ''
    $subtitle = ''
    $showSearch = $false
    $hints = New-Object 'System.Collections.Generic.List[object]'

    if ($State.View -eq 'Main') {
        if ($State.SearchActive) {
            $showSearch = $true
            $q = $State.SearchQuery.Trim()

            if ([string]::IsNullOrEmpty($q)) {
                $allBox = if ($enabledCount -eq 15) { '[x]' } elseif ($enabledCount -eq 0) { '[ ]' } else { '[-]' }
                $rows.Add([PSCustomObject]@{
                    Id='toggle_all'; Kind='ToggleAllChecks'; Order=0; TargetView=''; ValueArg=''; DividerAfter=$true
                    Primary="$allBox Enable all checks"; Secondary="$enabledCount/15 on"
                    Description='Toggle all 15 diagnostic and repair checks on or off'; IsMuted=$false
                })
            }

            $allSearchable = New-Object 'System.Collections.Generic.List[object]'
            $allSearchable.Add([PSCustomObject]@{
                Id='start'; Kind='Start'; Order=0; TargetView=''; ValueArg=''; DividerAfter=$false
                Primary='Start scan'; Secondary="$enabledCount/15 ready $chev"
                Description='Run enabled checks and generate HTML report'; IsMuted=($enabledCount -eq 0); SearchText='start run scan begin go'
            })
            $allSearchable.Add([PSCustomObject]@{
                Id='preset'; Kind='SubView'; Order=0; TargetView='Preset'; ValueArg=''; DividerAfter=$false
                Primary='Preset'; Secondary="$presetLabel $chev"
                Description='Apply Full Scan or Quick Tune-Up profile'; IsMuted=$false; SearchText='preset full quick custom profile'
            })
            $allSearchable.Add([PSCustomObject]@{
                Id='open_report'; Kind='ToggleOpenReport'; Order=0; TargetView=''; ValueArg=''; DividerAfter=$false
                Primary='Open report'; Secondary=$(if ($Config.OpenReport) { '[x] On' } else { '[ ] Off' })
                Description='Open HTML report automatically in your browser'
                IsMuted=(-not [bool]$Config.OpenReport); SearchText='open html report browser automatically'
            })
            if ($canResizeFont) {
                $allSearchable.Add([PSCustomObject]@{
                    Id='text_size'; Kind='SubView'; Order=0; TargetView='TextSize'; ValueArg=''; DividerAfter=$false
                    Primary='Text size'; Secondary="${fontPx}px $chev"
                    Description='Adjust console font size (or press + / -)'
                    IsMuted=$false; SearchText='text font size zoom bigger larger smaller scale'
                })
            }
            foreach ($s in $Config.StepDefs) {
                $isOn = [bool]$Config.Enabled[$s.Order]
                $valTxt = if ($s.Order -eq 14) { "$defLabel $chev" } elseif ($isOn) { '[x] On' } else { '[ ] Off' }
                $kind = if ($s.Order -eq 14) { 'StepDefender' } else { 'StepToggle' }
                $allSearchable.Add([PSCustomObject]@{
                    Id=$s.Id; Kind=$kind; Order=$s.Order; TargetView=$(if ($s.Order -eq 14) { 'Defender' } else { '' }); ValueArg=''; DividerAfter=$false
                    Primary="$($s.Order). $($s.ShortName)"; Secondary=$valTxt
                    Description=$s.Description; IsMuted=(-not $isOn)
                    SearchText="$($s.Order) $($s.ShortName) $($s.Tag) $($s.Description) $($s.Group)"
                })
            }
            $allSearchable.Add([PSCustomObject]@{
                Id='restart'; Kind='ToggleRestart'; Order=0; TargetView=''; ValueArg=''; DividerAfter=$false
                Primary='Auto-restart'; Secondary=$(if ($Config.AutoRestart) { '[x] On' } else { '[ ] Off' })
                Description='Restart automatically after all checks finish'
                IsMuted=(-not [bool]$Config.AutoRestart); SearchText='auto restart reboot shutdown'
            })
            $allSearchable.Add([PSCustomObject]@{
                Id='restart_delay'; Kind='SubView'; Order=0; TargetView='RestartDelay'; ValueArg=''; DividerAfter=$false
                Primary='Restart countdown'; Secondary="$($Config.RestartDelaySec)s $chev"
                Description='Wait time before rebooting (15s, 30s, or 60s)'
                IsMuted=(-not [bool]$Config.AutoRestart); SearchText='restart countdown delay seconds timer'
            })

            foreach ($item in $allSearchable) {
                if ([string]::IsNullOrEmpty($q) -or $item.SearchText.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $rows.Add($item)
                }
            }
        } else {
            switch ($State.TabIndex) {
                0 {
                    $startSec = if ($enabledCount -gt 0) { "$enabledCount/15 ready $chev" } else { "0/15 none $chev" }
                    $rows.Add([PSCustomObject]@{
                        Id='start'; Kind='Start'; Order=0; TargetView=''; ValueArg=''; DividerAfter=$false
                        Primary='Start scan'; Secondary=$startSec
                        Description='Run enabled checks and generate HTML report'; IsMuted=($enabledCount -eq 0)
                    })
                    $rows.Add([PSCustomObject]@{
                        Id='preset'; Kind='SubView'; Order=0; TargetView='Preset'; ValueArg=''; DividerAfter=$false
                        Primary='Preset'; Secondary="$presetLabel $chev"
                        Description='Apply Full Scan or Quick Tune-Up profile'; IsMuted=$false
                    })
                    $rows.Add([PSCustomObject]@{
                        Id='open_report'; Kind='ToggleOpenReport'; Order=0; TargetView=''; ValueArg=''; DividerAfter=$false
                        Primary='Open report'; Secondary=$(if ($Config.OpenReport) { '[x] On' } else { '[ ] Off' })
                        Description=$(if ($Config.AutoRestart) { 'Reopen updated HTML report automatically after restart' } else { 'Open HTML report in default browser when finished' })
                        IsMuted=(-not [bool]$Config.OpenReport)
                    })
                    if ($canResizeFont) {
                        $rows.Add([PSCustomObject]@{
                            Id='text_size'; Kind='SubView'; Order=0; TargetView='TextSize'; ValueArg=''; DividerAfter=$false
                            Primary='Text size'; Secondary="${fontPx}px $chev"
                            Description='Adjust console font size (or press + / -)'
                            IsMuted=$false
                        })
                    }
                    $rows.Add([PSCustomObject]@{
                        Id='exit'; Kind='Exit'; Order=0; TargetView=''; ValueArg=''; DividerAfter=$false
                        Primary='Exit'; Secondary="Close $chev"
                        Description='Exit Windows Scan & Fix without making any changes'
                        IsMuted=$false
                    })
                }
                1 {
                    foreach ($s in ($Config.StepDefs | Where-Object { $_.Group -eq 'Hardware' })) {
                        $isOn = [bool]$Config.Enabled[$s.Order]
                        $rows.Add([PSCustomObject]@{
                            Id=$s.Id; Kind='StepToggle'; Order=$s.Order; TargetView=''; ValueArg=''; DividerAfter=$false
                            Primary="$($s.Order). $($s.ShortName)"; Secondary=$(if ($isOn) { '[x] On' } else { '[ ] Off' })
                            Description=$s.Description; IsMuted=(-not $isOn)
                        })
                    }
                }
                2 {
                    foreach ($s in ($Config.StepDefs | Where-Object { $_.Group -eq 'System Repair' })) {
                        $isOn = [bool]$Config.Enabled[$s.Order]
                        $rows.Add([PSCustomObject]@{
                            Id=$s.Id; Kind='StepToggle'; Order=$s.Order; TargetView=''; ValueArg=''; DividerAfter=$false
                            Primary="$($s.Order). $($s.ShortName)"; Secondary=$(if ($isOn) { '[x] On' } else { '[ ] Off' })
                            Description=$s.Description; IsMuted=(-not $isOn)
                        })
                    }
                }
                3 {
                    foreach ($s in ($Config.StepDefs | Where-Object { $_.Group -eq 'Maintenance' })) {
                        $isOn = [bool]$Config.Enabled[$s.Order]
                        $isDef = ($s.Order -eq 14)
                        $rows.Add([PSCustomObject]@{
                            Id=$s.Id; Kind=$(if ($isDef) { 'StepDefender' } else { 'StepToggle' }); Order=$s.Order
                            TargetView=$(if ($isDef) { 'Defender' } else { '' }); ValueArg=''; DividerAfter=$false
                            Primary="$($s.Order). $($s.ShortName)"
                            Secondary=$(if ($isDef) { "$defLabel $chev" } elseif ($isOn) { '[x] On' } else { '[ ] Off' })
                            Description=$s.Description; IsMuted=(-not $isOn)
                        })
                    }
                }
                4 {
                    $rows.Add([PSCustomObject]@{
                        Id='restart'; Kind='ToggleRestart'; Order=0; TargetView=''; ValueArg=''; DividerAfter=$false
                        Primary='Auto-restart'; Secondary=$(if ($Config.AutoRestart) { '[x] On' } else { '[ ] Off' })
                        Description='Automatically restart PC after all checks finish'
                        IsMuted=(-not [bool]$Config.AutoRestart)
                    })
                    $rows.Add([PSCustomObject]@{
                        Id='restart_delay'; Kind='SubView'; Order=0; TargetView='RestartDelay'; ValueArg=''; DividerAfter=$false
                        Primary='Restart countdown'; Secondary="$($Config.RestartDelaySec)s $chev"
                        Description='Wait time before rebooting (15s, 30s, or 60s)'
                        IsMuted=(-not [bool]$Config.AutoRestart)
                    })
                    $memStep = $Config.StepDefs | Where-Object { $_.Order -eq 15 } | Select-Object -First 1
                    $memOn = [bool]$Config.Enabled[15]
                    $rows.Add([PSCustomObject]@{
                        Id='memdiag'; Kind='StepToggle'; Order=15; TargetView=''; ValueArg=''; DividerAfter=$false
                        Primary="15. $($memStep.ShortName)"; Secondary=$(if ($memOn) { '[x] On' } else { '[ ] Off' })
                        Description=$(if ($Config.AutoRestart) { 'Run Windows RAM test during automatic restart' } else { 'Queue Windows RAM test for next manual restart' })
                        IsMuted=(-not $memOn)
                    })
                }
            }
        }
    } elseif ($State.View -eq 'Preset') {
        $mode = 'SubView'
        $title = 'Preset'
        $subtitle = if ($Config.Preset -eq 'Custom') {
            "Currently Custom ($enabledCount/15 checks). Pick a preset to reset all tabs."
        } else {
            'Apply a scan profile across all tabs'
        }
        $isFull = ($Config.Preset -eq 'Full')
        $isQuick = ($Config.Preset -eq 'Quick')
        $rows.Add([PSCustomObject]@{
            Id='preset_full'; Kind='PickPreset'; Order=0; TargetView=''; ValueArg='Full'; DividerAfter=$false
            Primary="1. $(if ($isFull) { '[x]' } else { '[ ]' }) Full Scan"; Secondary=''
            Description='All 15 checks, Full Defender scan, RAM test, and auto-restart'; IsMuted=$false
        })
        $rows.Add([PSCustomObject]@{
            Id='preset_quick'; Kind='PickPreset'; Order=0; TargetView=''; ValueArg='Quick'; DividerAfter=$false
            Primary="2. $(if ($isQuick) { '[x]' } else { '[ ]' }) Quick Tune-Up"; Secondary=''
            Description='13 checks, Quick Defender scan, skips 60s energy trace and reboot'; IsMuted=$false
        })
    } elseif ($State.View -eq 'Defender') {
        $mode = 'SubView'
        $title = 'Microsoft Defender Scan'
        $subtitle = 'Configure antivirus scan depth for Step 14'
        $rows.Add([PSCustomObject]@{
            Id='def_full'; Kind='PickDefender'; Order=14; TargetView=''; ValueArg='FullScan'; DividerAfter=$false
            Primary="1. $(if ($Config.DefenderMode -eq 'FullScan') { '[x]' } else { '[ ]' }) Full Scan"; Secondary=''
            Description='Update definitions and scan the entire system (thorough, slower)'; IsMuted=$false
        })
        $rows.Add([PSCustomObject]@{
            Id='def_quick'; Kind='PickDefender'; Order=14; TargetView=''; ValueArg='QuickScan'; DividerAfter=$false
            Primary="2. $(if ($Config.DefenderMode -eq 'QuickScan') { '[x]' } else { '[ ]' }) Quick Scan"; Secondary=''
            Description='Update definitions and scan common malware locations (faster)'; IsMuted=$false
        })
        $rows.Add([PSCustomObject]@{
            Id='def_off'; Kind='PickDefender'; Order=14; TargetView=''; ValueArg='Off'; DividerAfter=$false
            Primary="3. $(if ($Config.DefenderMode -eq 'Off') { '[x]' } else { '[ ]' }) Off"; Secondary=''
            Description='Skip the Microsoft Defender antivirus scan for this run'; IsMuted=$false
        })
    } elseif ($State.View -eq 'RestartDelay') {
        $mode = 'SubView'
        $title = 'Restart Countdown'
        $subtitle = 'Choose how long to wait before restarting after scan completes'
        foreach ($opt in @(
            @{ Num=1; Sec=15; Desc='Short countdown before automatic restart' },
            @{ Num=2; Sec=30; Desc='Default countdown with time to cancel if needed' },
            @{ Num=3; Sec=60; Desc='Extended countdown to review summary before reboot' }
        )) {
            $mark = if ([int]$Config.RestartDelaySec -eq $opt.Sec) { '[x]' } else { '[ ]' }
            $rows.Add([PSCustomObject]@{
                Id="delay_$($opt.Sec)"; Kind='PickRestartDelay'; Order=0; TargetView=''; ValueArg=[string]$opt.Sec; DividerAfter=$false
                Primary="$($opt.Num). $mark $($opt.Sec) seconds"; Secondary=''
                Description=$opt.Desc; IsMuted=$false
            })
        }
    } elseif ($State.View -eq 'TextSize') {
        $mode = 'SubView'
        $title = 'Text Size'
        $subtitle = 'Choose console font height (space previews, enter confirms)'
        foreach ($opt in @(
            @{ Num=1; Px=20; Name='Normal (20px)';      Desc='Compact text for smaller laptop screens' },
            @{ Num=2; Px=24; Name='Large (24px)';       Desc='Comfortable default size for 1080p monitors' },
            @{ Num=3; Px=28; Name='Extra Large (28px)'; Desc='High-readability text for large or HiDPI displays' },
            @{ Num=4; Px=32; Name='Huge (32px)';        Desc='Maximum readability for 1440p / 4K displays' }
        )) {
            $mark = if ($fontPx -eq $opt.Px) { '[x]' } else { '[ ]' }
            $rows.Add([PSCustomObject]@{
                Id="font_$($opt.Px)"; Kind='PickFontSize'; Order=0; TargetView=''; ValueArg=[string]$opt.Px; DividerAfter=$false
                Primary="$($opt.Num). $mark $($opt.Name)"; Secondary=''
                Description=$opt.Desc; IsMuted=$false
            })
        }
    }

    # Build context-sensitive footer keybind hints
    $curRow = if ($rows.Count -gt 0 -and $State.CursorIndex -ge 0 -and $State.CursorIndex -lt $rows.Count) {
        $rows[$State.CursorIndex]
    } elseif ($rows.Count -gt 0) {
        $rows[0]
    } else {
        $null
    }

    if ($State.View -eq 'Main') {
        if ($State.SearchActive) {
            $enterLbl = if ($null -ne $curRow -and $curRow.Kind -eq 'Start') { 'start' } elseif ($null -ne $curRow -and $curRow.Kind -in @('SubView', 'StepDefender')) { 'open' } else { 'toggle' }
            $hints.Add([PSCustomObject]@{ Key='enter'; Label=$enterLbl })
            $hints.Add([PSCustomObject]@{ Key='esc'; Label='clear search' })
        } else {
            $enterLbl = 'toggle'
            if ($null -ne $curRow) {
                if ($curRow.Kind -eq 'Start') { $enterLbl = 'start' }
                elseif ($curRow.Kind -eq 'Exit') { $enterLbl = 'exit' }
                elseif ($curRow.Kind -in @('SubView', 'StepDefender')) { $enterLbl = 'open' }
            }
            $hints.Add([PSCustomObject]@{ Key='left/right'; Label='group' })
            $hints.Add([PSCustomObject]@{ Key='/'; Label='search' })
            $hints.Add([PSCustomObject]@{ Key='enter'; Label=$enterLbl })
            $hints.Add([PSCustomObject]@{ Key='s'; Label='start scan' })
            if ($canResizeFont) {
                $hints.Add([PSCustomObject]@{ Key='+/-'; Label='text size' })
            }
            $hints.Add([PSCustomObject]@{ Key='esc'; Label='close' })
        }
    } else {
        $hints.Add([PSCustomObject]@{ Key='enter'; Label='select' })
        $hints.Add([PSCustomObject]@{ Key='esc'; Label='back' })
    }

    return [PSCustomObject]@{
        Mode              = $mode
        Tabs              = $tabs
        ActiveTabIndex    = $State.TabIndex
        Title             = $title
        Subtitle          = $subtitle
        ShowSearch        = $showSearch
        SearchQuery       = $State.SearchQuery
        SearchPlaceholder = 'Type to search'
        Rows              = @($rows.ToArray())
        Hints             = @($hints.ToArray())
        EnabledCount      = $enabledCount
        PresetLabel       = $presetLabel
        Notice            = $State.Notice
    }
}

function Invoke-TuiMenuKey {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$KeyName,
        [string]$KeyChar = '',
        [bool]$ShiftPressed = $false
    )

    $State.Notice = ''
    $vm = Get-TuiMenuViewModel -Config $Config -State $State
    $rows = $vm.Rows
    $rowCount = $rows.Count
    if ($rowCount -eq 0) {
        $State.CursorIndex = 0
    } else {
        if ($State.CursorIndex -lt 0) { $State.CursorIndex = 0 }
        if ($State.CursorIndex -ge $rowCount) { $State.CursorIndex = $rowCount - 1 }
    }
    $current = if ($rowCount -gt 0) { $rows[$State.CursorIndex] } else { $null }

    $isTextSearchMode = ($State.View -eq 'Main' -and $State.SearchActive)

    # Vertical navigation works identically across all views
    if ($KeyName -eq 'UpArrow') {
        if ($rowCount -gt 0) { $State.CursorIndex = if ($State.CursorIndex -le 0) { $rowCount - 1 } else { $State.CursorIndex - 1 } }
        return 'Continue'
    }
    if ($KeyName -eq 'DownArrow') {
        if ($rowCount -gt 0) { $State.CursorIndex = if ($State.CursorIndex -ge ($rowCount - 1)) { 0 } else { $State.CursorIndex + 1 } }
        return 'Continue'
    }
    if ($KeyName -eq 'Home') {
        $State.CursorIndex = 0; $State.ScrollTop = 0
        return 'Continue'
    }
    if ($KeyName -eq 'End') {
        if ($rowCount -gt 0) { $State.CursorIndex = $rowCount - 1 }
        return 'Continue'
    }
    if ($KeyName -eq 'PageUp') {
        $State.CursorIndex = [math]::Max(0, $State.CursorIndex - 6)
        return 'Continue'
    }
    if ($KeyName -eq 'PageDown') {
        if ($rowCount -gt 0) { $State.CursorIndex = [math]::Min($rowCount - 1, $State.CursorIndex + 6) }
        return 'Continue'
    }

    # Escape behavior: clear search -> go back -> exit
    if ($KeyName -eq 'Escape') {
        if ($State.View -eq 'Main') {
            if ($State.SearchActive) {
                $State.SearchActive = $false
                $State.SearchQuery = ''
                $State.CursorIndex = 0
                $State.ScrollTop = 0
                return 'Continue'
            }
            return 'Exit'
        }
        $State.View = $State.ReturnView
        $State.TabIndex = $State.ReturnTabIndex
        $State.CursorIndex = $State.ReturnCursorIndex
        $State.ScrollTop = 0
        $State.SearchQuery = ''
        return 'Continue'
    }

    # Tab switching on Main (when not searching)
    if ($State.View -eq 'Main' -and -not $State.SearchActive) {
        $tabCount = $vm.Tabs.Count
        if ($KeyName -eq 'LeftArrow' -or ($KeyName -eq 'Tab' -and $ShiftPressed)) {
            $State.TabIndex = if ($State.TabIndex -le 0) { $tabCount - 1 } else { $State.TabIndex - 1 }
            $State.CursorIndex = 0
            $State.ScrollTop = 0
            return 'Continue'
        }
        if ($KeyName -eq 'RightArrow' -or $KeyName -eq 'Tab') {
            $State.TabIndex = if ($State.TabIndex -ge ($tabCount - 1)) { 0 } else { $State.TabIndex + 1 }
            $State.CursorIndex = 0
            $State.ScrollTop = 0
            return 'Continue'
        }
        if ($KeyChar -eq '/') {
            $State.SearchActive = $true
            $State.SearchQuery = ''
            $State.CursorIndex = 0
            $State.ScrollTop = 0
            return 'Continue'
        }
        if ($KeyChar -in @('+', '=') -and $null -ne $script:TuiCaps -and $script:TuiCaps.CanResizeFont) {
            $nextPx = [math]::Min(36, [int]$script:TuiCaps.FontSizePx + 2)
            if (Set-TuiFontSize -HeightPx $nextPx) { $State.Notice = "Text size: ${nextPx}px" }
            return 'Continue'
        }
        if ($KeyChar -eq '-' -and $null -ne $script:TuiCaps -and $script:TuiCaps.CanResizeFont) {
            $nextPx = [math]::Max(16, [int]$script:TuiCaps.FontSizePx - 2)
            if (Set-TuiFontSize -HeightPx $nextPx) { $State.Notice = "Text size: ${nextPx}px" }
            return 'Continue'
        }
    }

    # Text search editing (Main '/' search mode)
    if ($isTextSearchMode) {
        if ($KeyName -eq 'Backspace') {
            if ($State.SearchQuery.Length -gt 0) {
                $State.SearchQuery = $State.SearchQuery.Substring(0, $State.SearchQuery.Length - 1)
                $State.CursorIndex = 0
                $State.ScrollTop = 0
            } else {
                $State.SearchActive = $false
                $State.CursorIndex = 0
                $State.ScrollTop = 0
            }
            return 'Continue'
        }

        if ($KeyName -ne 'Enter') {
            $isSpaceToggle = ($KeyName -eq 'Spacebar' -and [string]::IsNullOrEmpty($State.SearchQuery))
            if (-not $isSpaceToggle -and -not [string]::IsNullOrEmpty($KeyChar)) {
                $code = [int][char]$KeyChar[0]
                if ($code -ge 32 -and $code -ne 127) {
                    $State.SearchQuery += $KeyChar
                    $State.CursorIndex = 0
                    $State.ScrollTop = 0
                    return 'Continue'
                }
            }
        }
    }

    # Quick keyboard shortcuts on Main (when not typing search)
    if ($State.View -eq 'Main' -and -not $State.SearchActive -and -not [string]::IsNullOrEmpty($KeyChar)) {
        $up = $KeyChar.ToUpperInvariant()
        if ($up -eq 'S') {
            $enabledCount = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
            if ($enabledCount -eq 0) {
                $State.Notice = 'Enable at least one check before starting.'
                return 'Continue'
            }
            return 'Start'
        }
        if ($up -eq 'F') {
            [void](Apply-ScanConfigInput -Config $Config -InputLine 'F')
            $State.Notice = 'Applied Full Scan preset.'
            return 'Continue'
        }
        if ($up -eq 'Q') {
            [void](Apply-ScanConfigInput -Config $Config -InputLine 'Q')
            $State.Notice = 'Applied Quick Tune-Up preset.'
            return 'Continue'
        }
        if ($up -eq 'A') {
            [void](Apply-ScanConfigInput -Config $Config -InputLine 'A')
            $State.Notice = 'Enabled all 15 checks.'
            return 'Continue'
        }
        if ($up -eq 'N') {
            [void](Apply-ScanConfigInput -Config $Config -InputLine 'N')
            $State.Notice = 'Disabled all checks.'
            return 'Continue'
        }
    }

    # Number keys 1..4 in numbered picker sub-views
    if ($State.View -in @('Preset', 'Defender', 'RestartDelay', 'TextSize') -and $KeyChar -match '^[1-4]$') {
        $idx = [int]$KeyChar - 1
        if ($idx -ge 0 -and $idx -lt $rowCount) {
            $State.CursorIndex = $idx
            $current = $rows[$idx]
            $KeyName = 'Enter'
        }
    }

    # Activate / Toggle on Enter or Spacebar
    if ($null -ne $current -and ($KeyName -eq 'Enter' -or $KeyName -eq 'Spacebar')) {
        switch ($current.Kind) {
            'Start' {
                $enabledCount = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
                if ($enabledCount -eq 0) {
                    $State.Notice = 'Enable at least one check before starting.'
                    return 'Continue'
                }
                return 'Start'
            }
            'Exit' {
                return 'Exit'
            }
            'SubView' {
                if ($KeyName -eq 'Spacebar' -and $current.TargetView -eq 'Preset') {
                    $nextPreset = if ($Config.Preset -eq 'Full') { 'Q' } else { 'F' }
                    [void](Apply-ScanConfigInput -Config $Config -InputLine $nextPreset)
                    return 'Continue'
                }
                if ($KeyName -eq 'Spacebar' -and $current.TargetView -eq 'RestartDelay') {
                    $Config.RestartDelaySec = switch ([int]$Config.RestartDelaySec) { 15 { 30 } 30 { 60 } default { 15 } }
                    return 'Continue'
                }
                if ($KeyName -eq 'Spacebar' -and $current.TargetView -eq 'TextSize' -and $null -ne $script:TuiCaps -and $script:TuiCaps.CanResizeFont) {
                    $nextPx = switch ([int]$script:TuiCaps.FontSizePx) { { $_ -lt 24 } { 24 } { $_ -lt 28 } { 28 } { $_ -lt 32 } { 32 } default { 20 } }
                    [void](Set-TuiFontSize -HeightPx $nextPx)
                    return 'Continue'
                }

                $State.ReturnView = $State.View
                $State.ReturnTabIndex = $State.TabIndex
                $State.ReturnCursorIndex = $State.CursorIndex
                $State.View = $current.TargetView
                $State.SearchQuery = ''
                $State.ScrollTop = 0

                if ($current.TargetView -eq 'Preset') {
                    $State.CursorIndex = if ($Config.Preset -eq 'Quick') { 1 } else { 0 }
                } elseif ($current.TargetView -eq 'Defender') {
                    $State.CursorIndex = switch ($Config.DefenderMode) { 'FullScan' { 0 } 'QuickScan' { 1 } default { 2 } }
                } elseif ($current.TargetView -eq 'RestartDelay') {
                    $State.CursorIndex = switch ([int]$Config.RestartDelaySec) { 15 { 0 } 30 { 1 } default { 2 } }
                } elseif ($current.TargetView -eq 'TextSize') {
                    $curPx = if ($null -ne $script:TuiCaps) { [int]$script:TuiCaps.FontSizePx } else { 24 }
                    $State.CursorIndex = if ($curPx -le 21) { 0 } elseif ($curPx -le 26) { 1 } elseif ($curPx -le 30) { 2 } else { 3 }
                } else {
                    $State.CursorIndex = 0
                }
                return 'Continue'
            }
            'StepDefender' {
                if ($KeyName -eq 'Spacebar') {
                    [void](Apply-ScanConfigInput -Config $Config -InputLine 'D')
                    return 'Continue'
                }
                $State.ReturnView = $State.View
                $State.ReturnTabIndex = $State.TabIndex
                $State.ReturnCursorIndex = $State.CursorIndex
                $State.View = 'Defender'
                $State.SearchQuery = ''
                $State.ScrollTop = 0
                $State.CursorIndex = switch ($Config.DefenderMode) { 'FullScan' { 0 } 'QuickScan' { 1 } default { 2 } }
                return 'Continue'
            }
            'StepToggle' {
                $ord = [int]$current.Order
                $newVal = -not [bool]$Config.Enabled[$ord]
                $Config.Enabled[$ord] = $newVal
                $Config.Preset = 'Custom'
                if ($ord -eq 14) {
                    if ($newVal -and $Config.DefenderMode -eq 'Off') { $Config.DefenderMode = 'FullScan' }
                    if (-not $newVal) { $Config.DefenderMode = 'Off' }
                }
                return 'Continue'
            }
            'ToggleAllChecks' {
                $enabledCount = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
                if ($enabledCount -eq 15) {
                    [void](Apply-ScanConfigInput -Config $Config -InputLine 'N')
                } else {
                    [void](Apply-ScanConfigInput -Config $Config -InputLine 'A')
                }
                return 'Continue'
            }
            'ToggleRestart' {
                $Config.AutoRestart = -not [bool]$Config.AutoRestart
                $Config.Preset = 'Custom'
                return 'Continue'
            }
            'ToggleOpenReport' {
                $Config.OpenReport = -not [bool]$Config.OpenReport
                return 'Continue'
            }
            'PickPreset' {
                if ($current.ValueArg -eq 'Full') {
                    [void](Apply-ScanConfigInput -Config $Config -InputLine 'F')
                } elseif ($current.ValueArg -eq 'Quick') {
                    [void](Apply-ScanConfigInput -Config $Config -InputLine 'Q')
                }
                if ($KeyName -eq 'Enter') {
                    $State.View = $State.ReturnView
                    $State.TabIndex = $State.ReturnTabIndex
                    $State.CursorIndex = $State.ReturnCursorIndex
                    $State.ScrollTop = 0
                }
                return 'Continue'
            }
            'PickDefender' {
                $Config.DefenderMode = $current.ValueArg
                $Config.Enabled[14] = ($current.ValueArg -ne 'Off')
                $Config.Preset = 'Custom'
                if ($KeyName -eq 'Enter') {
                    $State.View = $State.ReturnView
                    $State.TabIndex = $State.ReturnTabIndex
                    $State.CursorIndex = $State.ReturnCursorIndex
                    $State.ScrollTop = 0
                }
                return 'Continue'
            }
            'PickRestartDelay' {
                $Config.RestartDelaySec = [int]$current.ValueArg
                if ($KeyName -eq 'Enter') {
                    $State.View = $State.ReturnView
                    $State.TabIndex = $State.ReturnTabIndex
                    $State.CursorIndex = $State.ReturnCursorIndex
                    $State.ScrollTop = 0
                }
                return 'Continue'
            }
            'PickFontSize' {
                [void](Set-TuiFontSize -HeightPx ([int]$current.ValueArg))
                if ($KeyName -eq 'Enter') {
                    $State.View = $State.ReturnView
                    $State.TabIndex = $State.ReturnTabIndex
                    $State.CursorIndex = $State.ReturnCursorIndex
                    $State.ScrollTop = 0
                }
                return 'Continue'
            }
        }
    }

    return 'Continue'
}

function Render-TuiMenuFrame {
    param(
        [Parameter(Mandatory = $true)]$ViewModel,
        [Parameter(Mandatory = $true)]$State,
        [int]$Width,
        [int]$Height,
        [switch]$FullClear
    )

    $caps = Initialize-TuiConsole
    $g = Get-TuiGlyphs
    $rows = $ViewModel.Rows
    $rowCount = $rows.Count

    # Compute responsive column widths matching the clean aligned monochrome grid
    $hasSec = $false
    $maxPri = 0
    $maxSec = 0
    foreach ($r in $rows) {
        if ($r.Primary.Length -gt $maxPri) { $maxPri = $r.Primary.Length }
        if (-not [string]::IsNullOrEmpty($r.Secondary)) {
            $hasSec = $true
            if ($r.Secondary.Length -gt $maxSec) { $maxSec = $r.Secondary.Length }
        }
    }

    if ($hasSec) {
        $col1W = [math]::Max(18, [math]::Min(30, $maxPri + 3))
        $col2W = [math]::Max(13, [math]::Min(18, $maxSec + 4))
    } else {
        $col1W = [math]::Max(20, [math]::Min(36, $maxPri + 3))
        $col2W = 0
    }
    if (($col1W + $col2W + 18) -gt $Width) {
        $col1W = [math]::Max(14, [math]::Min($col1W, [int]($Width * 0.42)))
        if ($hasSec) { $col2W = [math]::Max(10, [math]::Min($col2W, [int]($Width * 0.22))) }
    }
    $descMax = [math]::Max(0, $Width - 2 - $col1W - $col2W - 1)

    # Calculate vertical viewport budget
    $headerLines = if ($ViewModel.Mode -eq 'Tabs') {
        if ($ViewModel.ShowSearch) { 4 } else { 2 }
    } else {
        if ($ViewModel.ShowSearch) { 5 } else { 3 }
    }
    $footerLines = if (-not [string]::IsNullOrWhiteSpace($ViewModel.Notice)) { 3 } else { 2 }
    $extraDividerLines = @($rows | Where-Object { $_.DividerAfter }).Count
    $availRows = [math]::Max(4, $Height - $headerLines - $footerLines - 2)

    if ($rowCount -eq 0) {
        $State.CursorIndex = 0
        $State.ScrollTop = 0
    } else {
        if ($State.CursorIndex -ge $rowCount) { $State.CursorIndex = $rowCount - 1 }
        if ($State.CursorIndex -lt 0) { $State.CursorIndex = 0 }
        $visBudget = [math]::Max(3, $availRows - $extraDividerLines)
        if ($State.CursorIndex -lt $State.ScrollTop) { $State.ScrollTop = $State.CursorIndex }
        if ($State.CursorIndex -ge ($State.ScrollTop + $visBudget)) { $State.ScrollTop = $State.CursorIndex - $visBudget + 1 }
        $maxScroll = [math]::Max(0, $rowCount - $visBudget)
        if ($State.ScrollTop -gt $maxScroll) { $State.ScrollTop = $maxScroll }
        $endIdx = [math]::Min($rowCount - 1, $State.ScrollTop + $visBudget - 1)
    }

    if ($caps.UseVt) {
        $a = Get-TuiAnsi
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append($(if ($FullClear) { $a.ClearAll } else { $a.Home }))

        # Top header
        if ($ViewModel.Mode -eq 'Tabs') {
            [void]$sb.Append($a.BgDark + ' ')
            $tabTextLen = 1
            for ($t = 0; $t -lt $ViewModel.Tabs.Count; $t++) {
                $tName = $ViewModel.Tabs[$t]
                if ($t -gt 0) {
                    [void]$sb.Append($a.BgDark + '  ')
                    $tabTextLen += 2
                }
                if ($t -eq $ViewModel.ActiveTabIndex -and -not $ViewModel.ShowSearch) {
                    [void]$sb.Append($a.TabActive + " $tName " + $a.Reset + $a.BgDark)
                    $tabTextLen += ($tName.Length + 2)
                } else {
                    [void]$sb.Append($a.TabIdle + " $tName ")
                    $tabTextLen += ($tName.Length + 2)
                }
            }
            $metaStr = "$env:COMPUTERNAME $($g.Dot) $($ViewModel.EnabledCount)/15"
            $gap = $Width - $tabTextLen - $metaStr.Length - 1
            if ($gap -ge 3) {
                [void]$sb.Append((' ' * $gap) + $a.FgDim + $metaStr)
            }
            [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
            [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
        } else {
            [void]$sb.Append($a.FgBright + '  ' + (Truncate-Text $ViewModel.Title ($Width - 2)) + $a.BgDark + $a.ClearLine + "`r`n")
            [void]$sb.Append($a.FgMuted + '  ' + (Truncate-Text $ViewModel.Subtitle ($Width - 2)) + $a.BgDark + $a.ClearLine + "`r`n")
            [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
        }

        # Inline search input (Screenshot 3 style / Main '/' search)
        if ($ViewModel.ShowSearch) {
            if ([string]::IsNullOrEmpty($ViewModel.SearchQuery)) {
                $ph = if ($ViewModel.Mode -eq 'Tabs') { "/ $($ViewModel.SearchPlaceholder)" } else { $ViewModel.SearchPlaceholder }
                [void]$sb.Append($a.FgMuted + '  ' + $ph + $a.BgDark + $a.ClearLine + "`r`n")
            } else {
                $prefix = if ($ViewModel.Mode -eq 'Tabs') { '/ ' } else { '' }
                $qDisp = Truncate-Text ($prefix + $ViewModel.SearchQuery) ($Width - 4)
                [void]$sb.Append($a.FgBright + '  ' + $qDisp + $a.FgDim + '_' + $a.BgDark + $a.ClearLine + "`r`n")
            }
            [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
        }

        # Optional top scroll indicator
        if ($rowCount -gt 0 -and $State.ScrollTop -gt 0) {
            [void]$sb.Append($a.FgDim + "  $($g.ArrowUp) $($State.ScrollTop) more above" + $a.BgDark + $a.ClearLine + "`r`n")
        }

        # Rows
        if ($rowCount -eq 0) {
            [void]$sb.Append($a.FgMuted + '  No matching items' + $a.BgDark + $a.ClearLine + "`r`n")
        } else {
            for ($i = $State.ScrollTop; $i -le $endIdx; $i++) {
                $r = $rows[$i]
                $isSel = ($i -eq $State.CursorIndex)
                $priText = (Truncate-Text $r.Primary ($col1W - 1)).PadRight($col1W)
                $secText = if ($hasSec) { (Truncate-Text $r.Secondary ($col2W - 1)).PadRight($col2W) } else { '' }
                $descText = if ($descMax -gt 0) { Truncate-Text $r.Description $descMax } else { '' }

                if ($isSel) {
                    $rightPart = ($secText + $descText).TrimEnd()
                    [void]$sb.Append($a.SelPrimary + "$($g.Chevron) " + $priText)
                    if (-not [string]::IsNullOrEmpty($rightPart)) {
                        [void]$sb.Append($a.SelSecond + $rightPart)
                    }
                    [void]$sb.Append($a.SelFill + $a.ClearLine + $a.Reset + "`r`n")
                } else {
                    $priColor = if ($r.IsMuted) { $a.FgMuted } else { $a.FgBright }
                    [void]$sb.Append($a.BgDark + '  ' + $priColor + $priText)
                    if ($hasSec) {
                        [void]$sb.Append($a.FgMuted + $secText)
                    }
                    if (-not [string]::IsNullOrEmpty($descText)) {
                        [void]$sb.Append($a.FgMuted + $descText)
                    }
                    [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
                }

                if ($r.DividerAfter) {
                    $ruleW = [math]::Max(12, [math]::Min($col1W - 2, $Width - 4))
                    [void]$sb.Append($a.FgDim + '  ' + ($g.Rule * $ruleW) + $a.BgDark + $a.ClearLine + "`r`n")
                }
            }
        }

        # Optional bottom scroll indicator
        if ($rowCount -gt 0 -and $endIdx -lt ($rowCount - 1)) {
            $rem = ($rowCount - 1) - $endIdx
            [void]$sb.Append($a.FgDim + "  $($g.ArrowDn) $rem more below" + $a.BgDark + $a.ClearLine + "`r`n")
        }

        # Blank line + optional subtle notice + footer keybind hints
        [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
        if (-not [string]::IsNullOrWhiteSpace($ViewModel.Notice)) {
            [void]$sb.Append($a.FgWarn + '  ' + (Truncate-Text $ViewModel.Notice ($Width - 2)) + $a.BgDark + $a.ClearLine + "`r`n")
        }

        [void]$sb.Append($a.BgDark + '  ')
        for ($h = 0; $h -lt $ViewModel.Hints.Count; $h++) {
            $hint = $ViewModel.Hints[$h]
            if ($h -gt 0) {
                [void]$sb.Append($a.FgDim + " $($g.Dot) ")
            }
            [void]$sb.Append($a.KeyBold + $hint.Key + ' ' + $a.KeyLabel + $hint.Label)
        }
        [void]$sb.Append($a.BgDark + $a.ClearLine + $a.ClearBelow + $a.Reset)
        [Console]::Write($sb.ToString())
        return
    }

    # Graceful non-VT console fallback
    try { [Console]::SetCursorPosition(0, 0) } catch {}
    if ($FullClear) { try { Clear-Host } catch {} }
    if ($ViewModel.Mode -eq 'Tabs') {
        Write-Host ' ' -NoNewline
        for ($t = 0; $t -lt $ViewModel.Tabs.Count; $t++) {
            $tName = $ViewModel.Tabs[$t]
            if ($t -gt 0) { Write-Host '  ' -NoNewline }
            if ($t -eq $ViewModel.ActiveTabIndex -and -not $ViewModel.ShowSearch) {
                Write-Host "[$tName]" -ForegroundColor White -NoNewline
            } else {
                Write-Host " $tName " -ForegroundColor DarkGray -NoNewline
            }
        }
        Write-Host ''
        Write-Host ''
    } else {
        Write-Host ('  ' + (Truncate-Text $ViewModel.Title ($Width - 2))).PadRight($Width) -ForegroundColor White
        Write-Host ('  ' + (Truncate-Text $ViewModel.Subtitle ($Width - 2))).PadRight($Width) -ForegroundColor DarkGray
        Write-Host ''.PadRight($Width)
    }

    if ($ViewModel.ShowSearch) {
        $sLine = if ([string]::IsNullOrEmpty($ViewModel.SearchQuery)) { '  ' + $ViewModel.SearchPlaceholder } else { '  / ' + $ViewModel.SearchQuery }
        Write-Host ($sLine.PadRight($Width)) -ForegroundColor $(if ([string]::IsNullOrEmpty($ViewModel.SearchQuery)) { 'DarkGray' } else { 'White' })
        Write-Host ''.PadRight($Width)
    }

    if ($rowCount -eq 0) {
        Write-Host ('  No matching items'.PadRight($Width)) -ForegroundColor DarkGray
    } else {
        for ($i = $State.ScrollTop; $i -le $endIdx; $i++) {
            $r = $rows[$i]
            $isSel = ($i -eq $State.CursorIndex)
            $ptr = if ($isSel) { "$($g.Chevron) " } else { '  ' }
            $priText = (Truncate-Text $r.Primary ($col1W - 1)).PadRight($col1W)
            $secText = if ($hasSec) { (Truncate-Text $r.Secondary ($col2W - 1)).PadRight($col2W) } else { '' }
            $descText = if ($descMax -gt 0) { Truncate-Text $r.Description $descMax } else { '' }
            $line = ($ptr + $priText + $secText + $descText).PadRight($Width)
            if ($line.Length -gt $Width) { $line = $line.Substring(0, $Width) }

            if ($isSel) {
                Write-Host $line -ForegroundColor Black -BackgroundColor Gray
            } elseif ($r.IsMuted) {
                Write-Host $line -ForegroundColor DarkGray
            } else {
                Write-Host $line -ForegroundColor White
            }
            if ($r.DividerAfter) {
                Write-Host (('  ' + ($g.Rule * [math]::Max(12, $col1W - 2))).PadRight($Width)) -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ''.PadRight($Width)
    $hintPairs = @($ViewModel.Hints | ForEach-Object { "$($_.Key) $($_.Label)" })
    Write-Host (('  ' + ($hintPairs -join " $($g.Dot) ")).PadRight($Width)) -ForegroundColor Gray -NoNewline
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

    $caps = Initialize-TuiConsole
    $state = New-TuiMenuState
    $lastW = -1
    $lastH = -1
    $lastSig = ''

    try {
        try { [Console]::CursorVisible = $false } catch {}

        while ($true) {
            $w = Get-ConsoleSafeWidth
            $h = Get-ConsoleSafeHeight
            $sig = "$($state.View)|$($state.TabIndex)|$($state.SearchActive)|$($state.SearchQuery)"
            $needClear = ($w -ne $lastW -or $h -ne $lastH) -or (-not $caps.UseVt -and $sig -ne $lastSig)
            if ($w -ne $lastW -or $h -ne $lastH) {
                $lastW = $w
                $lastH = $h
            }
            $lastSig = $sig

            $vm = Get-TuiMenuViewModel -Config $Config -State $state
            Render-TuiMenuFrame -ViewModel $vm -State $state -Width $w -Height $h -FullClear:$needClear

            $keyInfo = [Console]::ReadKey($true)
            $keyName = $keyInfo.Key.ToString()
            $keyChar = if ($keyInfo.KeyChar -eq [char]0) { '' } else { [string]$keyInfo.KeyChar }
            $shift = (($keyInfo.Modifiers -band [ConsoleModifiers]::Shift) -ne 0)

            $action = Invoke-TuiMenuKey -Config $Config -State $state -KeyName $keyName -KeyChar $keyChar -ShiftPressed $shift
            if ($action -eq 'Start') { return $Config }
            if ($action -eq 'Exit')  { return $null }
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
            SummaryLine  = if ($isOn) { 'Queued' } else { 'Skipped' }
        })
    }

    return [PSCustomObject]@{
        Steps           = $rows
        ScanStart       = $ScanStart
        PresetLabel     = (Format-PresetLabel $Config.Preset)
        ActiveOrder     = 0
        ActiveCommand   = ''
        FixedCount      = 0
        AttentionCount  = 0
        RawLogPath      = $RawLogPath
        SpinIdx         = 0
        TotalEnabled    = @($Config.Enabled.Values | Where-Object { $_ -eq $true }).Count
        DoneCount       = 0
        HeaderRow       = -1
        ActiveRowLine   = -1
        ActiveRowLabel  = ''
        StatusRow       = -1
        LastHeaderSec   = ''
        LastWidth       = -1
        LastHeight      = -1
    }
}

function Render-ScanDashboard {
    param(
        [Parameter(Mandatory = $true)]$UiState,
        [switch]$Final,
        [switch]$NoClear
    )

    $caps = Initialize-TuiConsole
    $g = Get-TuiGlyphs
    $w = Get-ConsoleSafeWidth
    $h = Get-ConsoleSafeHeight

    $doneCount = @($UiState.Steps | Where-Object { $_.State -in @('OK', 'FIXED', 'ATTENTION', 'PENDING', 'ERROR') }).Count
    $UiState.DoneCount = $doneCount
    $totalEn = [math]::Max(1, [int]$UiState.TotalEnabled)
    $pct = [math]::Min(100, [int][math]::Floor(($doneCount * 100.0) / $totalEn))
    if ($Final) { $pct = 100 }

    $barLen = [math]::Max(16, [math]::Min(36, $w - 20))
    $filled = [int][math]::Round(($pct / 100.0) * $barLen)
    $elapsedStr = Format-ClockSpan ((Get-Date) - $UiState.ScanStart)
    $UiState.LastHeaderSec = $elapsedStr

    $needFullClear = ($UiState.LastWidth -ne $w -or $UiState.LastHeight -ne $h)
    $UiState.LastWidth = $w
    $UiState.LastHeight = $h

    # Determine visible step window if terminal height is compact
    $steps = $UiState.Steps
    $startIdx = 0
    $endIdx = $steps.Count - 1
    $maxRows = [math]::Max(6, $h - 8)
    if (-not $Final -and $steps.Count -gt $maxRows) {
        $activeIdx = 0
        for ($idx = 0; $idx -lt $steps.Count; $idx++) {
            if ($steps[$idx].Order -eq $UiState.ActiveOrder) { $activeIdx = $idx; break }
        }
        $startIdx = [math]::Max(0, [math]::Min($steps.Count - $maxRows, $activeIdx - [int]($maxRows / 2)))
        $endIdx = [math]::Min($steps.Count - 1, $startIdx + $maxRows - 1)
    }

    $nameColW = 30
    $durColW = 7
    $sumMax = [math]::Max(10, $w - (4 + 4 + $nameColW + 1 + $durColW + 2))
    $spinChar = $g.Spinner[$UiState.SpinIdx % $g.Spinner.Count]

    $UiState.ActiveRowLine = -1
    $UiState.ActiveRowLabel = ''

    if ($caps.UseVt) {
        $a = Get-TuiAnsi
        if (-not $NoClear) {
            try { [Console]::CursorVisible = [bool]$Final } catch {}
        }

        $sb = New-Object System.Text.StringBuilder
        if (-not $NoClear) {
            [void]$sb.Append($(if ($needFullClear) { $a.ClearAll } else { $a.Home }))
        }

        # Row 1: Title + right-aligned live timer & step count
        $UiState.HeaderRow = 1
        $titleLeft = 'Windows Scan & Fix'
        $metaRight = "$elapsedStr $($g.Dot) $doneCount/$totalEn"
        $titleGap = [math]::Max(2, $w - 2 - $titleLeft.Length - $metaRight.Length - 1)
        [void]$sb.Append($a.FgBright + '  ' + $titleLeft + (' ' * $titleGap) + $a.FgMuted + $metaRight + $a.BgDark + $a.ClearLine + "`r`n")

        # Row 2: Subtitle
        $subText = "$($UiState.PresetLabel) $($g.Dot) $env:COMPUTERNAME $($g.Dot) $($UiState.FixedCount) fixed $($g.Dot) $($UiState.AttentionCount) alerts"
        [void]$sb.Append($a.FgMuted + '  ' + (Truncate-Text $subText ($w - 2)) + $a.BgDark + $a.ClearLine + "`r`n")

        # Row 3: Thin monochrome progress bar
        $fillPart = $g.BarFill * $filled
        $trackPart = $g.BarTrack * ($barLen - $filled)
        $pctText = ('{0,3}%' -f $pct)
        [void]$sb.Append($a.BgDark + '  ' + $a.FgBright + $fillPart + $a.FgDim + $trackPart + '  ' + $a.FgMuted + $pctText + $a.BgDark + $a.ClearLine + "`r`n")

        # Row 4: Blank
        [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
        $curLine = 5

        for ($i = $startIdx; $i -le $endIdx; $i++) {
            $row = $steps[$i]
            $numStr = ('{0:00}' -f $row.Order)
            $nameCol = (Truncate-Text $row.ShortName ($nameColW - 1)).PadRight($nameColW)
            $durCol = if ([string]::IsNullOrWhiteSpace($row.DurationText)) { (' ' * $durColW) } else { ('{0,6} ' -f $row.DurationText) }
            $sumTxt = Truncate-Text $row.SummaryLine $sumMax

            if ($row.State -eq 'RUNNING') {
                $UiState.ActiveRowLine = $curLine
                $UiState.ActiveRowLabel = "$numStr. $nameCol"
                [void]$sb.Append($a.SelPrimary + "$($g.Chevron) $spinChar $numStr. $nameCol")
                [void]$sb.Append($a.SelSecond + "$durCol $sumTxt")
                [void]$sb.Append($a.SelFill + $a.ClearLine + $a.Reset + "`r`n")
            } else {
                $glyph = $g.Queued
                $glyphCol = $a.FgDim
                $lblCol = $a.FgDim
                $sumCol = $a.FgDim
                switch ($row.State) {
                    'OK'        { $glyph = $g.Check;   $glyphCol = $a.FgOk;      $lblCol = $a.FgText;   $sumCol = $a.FgMuted }
                    'FIXED'     { $glyph = $g.Fixed;   $glyphCol = $a.FgFixed;   $lblCol = $a.FgBright; $sumCol = $a.FgMuted }
                    'ATTENTION' { $glyph = $g.Warn;    $glyphCol = $a.FgWarn;    $lblCol = $a.FgBright; $sumCol = $a.FgWarn }
                    'PENDING'   { $glyph = $g.Pending; $glyphCol = $a.FgPending; $lblCol = $a.FgText;   $sumCol = $a.FgMuted }
                    'ERROR'     { $glyph = $g.Err;     $glyphCol = $a.FgErr;     $lblCol = $a.FgErr;    $sumCol = $a.FgErr }
                    'SKIPPED'   { $glyph = $g.Skipped; $glyphCol = $a.FgDim;     $lblCol = $a.FgDim;    $sumCol = $a.FgDim }
                    default     { $glyph = $g.Queued;  $glyphCol = $a.FgDim;     $lblCol = $a.FgDim;    $sumCol = $a.FgDim }
                }
                [void]$sb.Append($a.BgDark + '  ' + $glyphCol + $glyph + ' ' + $lblCol + "$numStr. $nameCol" + $a.FgDim + $durCol + ' ' + $sumCol + $sumTxt + $a.BgDark + $a.ClearLine + "`r`n")
            }
            $curLine++
        }

        [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
        $curLine++

        if (-not $Final) {
            $UiState.StatusRow = $curLine
            $cmdHint = Truncate-Text ("Step $($UiState.ActiveOrder)/15 $($g.Dot) 00:00 $($g.Dot) $($UiState.ActiveCommand)") ($w - 5)
            [void]$sb.Append($a.BgDark + '  ' + $a.FgBright + $spinChar + ' ' + $a.FgMuted + $cmdHint + $a.BgDark + $a.ClearLine + $a.ClearBelow + $a.Reset)
        } else {
            $UiState.StatusRow = -1
            [void]$sb.Append($a.ClearBelow + $a.Reset)
            try { [Console]::CursorVisible = $true } catch {}
        }

        [Console]::Write($sb.ToString())
        return
    }

    # Graceful non-VT console fallback
    if (-not $NoClear) {
        try { [Console]::CursorVisible = [bool]$Final } catch {}
        try { if ($needFullClear) { Clear-Host } else { [Console]::SetCursorPosition(0, 0) } } catch {}
    }

    try { $UiState.HeaderRow = [Console]::CursorTop } catch { $UiState.HeaderRow = -1 }
    $titleLeft = 'Windows Scan & Fix'
    $metaRight = "$elapsedStr $($g.Dot) $doneCount/$totalEn"
    $titleGap = [math]::Max(2, $w - 2 - $titleLeft.Length - $metaRight.Length - 1)
    Write-Host (('  ' + $titleLeft + (' ' * $titleGap) + $metaRight).PadRight($w)) -ForegroundColor White
    $subText = "$($UiState.PresetLabel) $($g.Dot) $env:COMPUTERNAME $($g.Dot) $($UiState.FixedCount) fixed $($g.Dot) $($UiState.AttentionCount) alerts"
    Write-Host (('  ' + (Truncate-Text $subText ($w - 2))).PadRight($w)) -ForegroundColor DarkGray
    Write-Host (('  ' + ($g.BarFill * $filled) + ($g.BarTrack * ($barLen - $filled)) + ('  {0,3}%' -f $pct)).PadRight($w)) -ForegroundColor Gray
    Write-Host ''.PadRight($w)

    for ($i = $startIdx; $i -le $endIdx; $i++) {
        $row = $steps[$i]
        $numStr = ('{0:00}' -f $row.Order)
        $nameCol = (Truncate-Text $row.ShortName ($nameColW - 1)).PadRight($nameColW)
        $durCol = if ([string]::IsNullOrWhiteSpace($row.DurationText)) { (' ' * $durColW) } else { ('{0,6} ' -f $row.DurationText) }
        $sumTxt = Truncate-Text $row.SummaryLine $sumMax
        if ($row.State -eq 'RUNNING') {
            $line = ("$($g.Chevron) $spinChar $numStr. $nameCol$durCol $sumTxt").PadRight($w)
            if ($line.Length -gt $w) { $line = $line.Substring(0, $w) }
            Write-Host $line -ForegroundColor Black -BackgroundColor Gray
        } else {
            $glyph = switch ($row.State) { 'OK' { $g.Check } 'FIXED' { $g.Fixed } 'ATTENTION' { $g.Warn } 'ERROR' { $g.Err } 'PENDING' { $g.Pending } 'SKIPPED' { $g.Skipped } default { $g.Queued } }
            $fg = switch ($row.State) { 'OK' { 'Gray' } 'FIXED' { 'White' } 'ATTENTION' { 'Yellow' } 'ERROR' { 'Red' } 'PENDING' { 'Gray' } default { 'DarkGray' } }
            $line = ("  $glyph $numStr. $nameCol$durCol $sumTxt").PadRight($w)
            if ($line.Length -gt $w) { $line = $line.Substring(0, $w) }
            Write-Host $line -ForegroundColor $fg
        }
    }

    Write-Host ''.PadRight($w)
    if (-not $Final) {
        try { $UiState.StatusRow = [Console]::CursorTop } catch { $UiState.StatusRow = -1 }
        $cmdHint = '  ' + $spinChar + ' ' + (Truncate-Text ("Step $($UiState.ActiveOrder)/15 $($g.Dot) 00:00 $($g.Dot) $($UiState.ActiveCommand)") ($w - 5))
        Write-Host ($cmdHint.PadRight($w)) -ForegroundColor Gray -NoNewline
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

    $caps = Initialize-TuiConsole
    $g = Get-TuiGlyphs
    $UiState.SpinIdx = ($UiState.SpinIdx + 1) % $g.Spinner.Count
    $spin = $g.Spinner[$UiState.SpinIdx]
    $stepClock = Format-ClockSpan ((Get-Date) - $StepStart)
    $totalClock = Format-ClockSpan ((Get-Date) - $UiState.ScanStart)
    $w = Get-ConsoleSafeWidth
    $detail = if ([string]::IsNullOrWhiteSpace($Hint)) { $UiState.ActiveCommand } else { $Hint }
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'Working...' }

    if ($caps.UseVt) {
        $e = [char]0x1B
        $a = Get-TuiAnsi
        $sb = New-Object System.Text.StringBuilder

        # Update top-right elapsed timer live every second
        if ($totalClock -ne $UiState.LastHeaderSec -and $UiState.HeaderRow -gt 0) {
            $UiState.LastHeaderSec = $totalClock
            $titleLeft = 'Windows Scan & Fix'
            $totalEn = [math]::Max(1, [int]$UiState.TotalEnabled)
            $metaRight = "$totalClock $($g.Dot) $($UiState.DoneCount)/$totalEn"
            $titleGap = [math]::Max(2, $w - 2 - $titleLeft.Length - $metaRight.Length - 1)
            [void]$sb.Append("${e}[$($UiState.HeaderRow);1H" + $a.FgBright + '  ' + $titleLeft + (' ' * $titleGap) + $a.FgMuted + $metaRight + $a.BgDark + $a.ClearLine)
        }

        # Animate spinner inside the inverted active step row
        if ($UiState.ActiveRowLine -gt 0 -and -not [string]::IsNullOrEmpty($UiState.ActiveRowLabel)) {
            [void]$sb.Append("${e}[$($UiState.ActiveRowLine);1H" + $a.SelPrimary + "$($g.Chevron) $spin ")
        }

        # Update live footer status line
        if ($UiState.StatusRow -gt 0) {
            $statusTxt = Truncate-Text ("Step $($UiState.ActiveOrder)/15 $($g.Dot) $stepClock $($g.Dot) $detail") ($w - 5)
            [void]$sb.Append("${e}[$($UiState.StatusRow);1H" + $a.BgDark + '  ' + $a.FgBright + $spin + ' ' + $a.FgMuted + $statusTxt + $a.BgDark + $a.ClearLine)
        }

        [void]$sb.Append($a.Reset)
        try { [Console]::Write($sb.ToString()) } catch {}
        return
    }

    # Non-VT fallback
    $line = '  ' + $spin + ' ' + (Truncate-Text ("Step $($UiState.ActiveOrder)/15 $($g.Dot) $stepClock $($g.Dot) $detail") ($w - 5))
    $padded = $line.PadRight($w)
    try {
        if ($UiState.StatusRow -ge 0) {
            [Console]::SetCursorPosition(0, $UiState.StatusRow)
            [Console]::Write($padded)
        } else {
            [Console]::Write("`r" + $padded)
        }
    } catch {}
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

    function Get-CardAccentClass {
        param([string]$Status)
        switch ($Status) {
            'OK'        { return 'accent-ok' }
            'FIXED'     { return 'accent-fixed' }
            'ATTENTION' { return 'accent-warn' }
            'PENDING'   { return 'accent-pending' }
            'ERROR'     { return 'accent-err' }
            default     { return 'accent-skip' }
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

    function Get-SeverityRank {
        param([string]$Severity)
        switch ($Severity) {
            'High'   { return 0 }
            'Medium' { return 1 }
            default  { return 2 }
        }
    }

    $fixedItems = @(Get-SafeProp $State 'FixedItems' @() | Where-Object { $null -ne $_ })
    $maintItems = @(Get-SafeProp $State 'MaintenanceItems' @() | Where-Object { $null -ne $_ })
    $rawAttention = @(Get-SafeProp $State 'AttentionItems' @() | Where-Object { $null -ne $_ })
    $attentionItems = @($rawAttention | Sort-Object { Get-SeverityRank ([string](Get-SafeProp $_ 'Severity' 'Info')) })
    $results = @(Get-SafeProp $State 'Results' @() | Where-Object { $null -ne $_ } | Sort-Object { [int](Get-SafeProp $_ 'Order' 99) })

    $okCount = @($results | Where-Object { (Get-SafeProp $_ 'Status' '') -eq 'OK' }).Count
    $fixedCardCount = @($results | Where-Object { (Get-SafeProp $_ 'Status' '') -eq 'FIXED' }).Count
    $skippedCount = @($results | Where-Object { (Get-SafeProp $_ 'Status' '') -eq 'SKIPPED' }).Count
    $runCount = $results.Count - $skippedCount
    $fixedCount = $fixedItems.Count
    $maintCount = $maintItems.Count
    $attentionCount = $attentionItems.Count
    $totalCount = $results.Count

    $highCount = @($attentionItems | Where-Object { (Get-SafeProp $_ 'Severity' '') -eq 'High' }).Count
    $pendingCount = @($results | Where-Object { (Get-SafeProp $_ 'Status' '') -eq 'PENDING' }).Count

    if ($highCount -gt 0) {
        $overallLabel = 'ACTION NEEDED'
        $overallClass = 'overall-err'
        $overallDesc = "$highCount high-priority alert(s) and $attentionCount total item(s) require your review below."
    } elseif ($attentionCount -gt 0) {
        $overallLabel = 'REVIEW RECOMMENDED'
        $overallClass = 'overall-warn'
        $overallDesc = "$attentionCount item(s) flagged for your review below."
    } elseif ($pendingCount -gt 0) {
        $overallLabel = 'RESTART PENDING'
        $overallClass = 'overall-pending'
        $overallDesc = 'Pre-restart checks finished; Memory Diagnostic will complete during restart.'
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
    [void]$sb.AppendLine('  :root { --bg:#f1f5f9; --card:#ffffff; --text:#0f172a; --muted:#64748b; --border:#e2e8f0; --ok:#15803d; --ok-bg:#dcfce7; --fixed:#0369a1; --fixed-bg:#e0f2fe; --warn:#b45309; --warn-bg:#fef3c7; --err:#b91c1c; --err-bg:#fee2e2; --pend:#6d28d9; --pend-bg:#ede9fe; --maint:#475569; --maint-bg:#f1f5f9; }')
    [void]$sb.AppendLine('  * { box-sizing:border-box; }')
    [void]$sb.AppendLine('  body { margin:0; padding:24px 18px 40px; font-family:"Segoe UI",system-ui,-apple-system,sans-serif; background:var(--bg); color:var(--text); line-height:1.55; }')
    [void]$sb.AppendLine('  .wrap { max-width:980px; margin:0 auto; }')
    [void]$sb.AppendLine('  .hero { background:linear-gradient(135deg,#0f172a 0%,#1e293b 100%); color:#f8fafc; border-radius:14px; padding:26px 28px; margin-bottom:18px; box-shadow:0 6px 20px rgba(15,23,42,0.16); }')
    [void]$sb.AppendLine('  .hero-top { display:flex; flex-wrap:wrap; justify-content:space-between; align-items:flex-start; gap:16px; }')
    [void]$sb.AppendLine('  .hero h1 { margin:0 0 8px 0; font-size:24px; font-weight:700; letter-spacing:-0.01em; }')
    [void]$sb.AppendLine('  .meta-row { display:flex; flex-wrap:wrap; gap:8px; margin-top:4px; }')
    [void]$sb.AppendLine('  .meta-chip { background:rgba(255,255,255,0.09); border:1px solid rgba(255,255,255,0.12); color:#e2e8f0; font-size:12px; padding:3px 10px; border-radius:999px; }')
    [void]$sb.AppendLine('  .overall-pill { padding:8px 16px; border-radius:999px; font-size:12px; font-weight:700; letter-spacing:0.06em; white-space:nowrap; }')
    [void]$sb.AppendLine('  .overall-ok { background:#16a34a; color:#ffffff; }')
    [void]$sb.AppendLine('  .overall-fixed { background:#0284c7; color:#ffffff; }')
    [void]$sb.AppendLine('  .overall-warn { background:#d97706; color:#ffffff; }')
    [void]$sb.AppendLine('  .overall-err { background:#dc2626; color:#ffffff; }')
    [void]$sb.AppendLine('  .overall-pending { background:#7c3aed; color:#ffffff; }')
    [void]$sb.AppendLine('  .hero-sub { margin-top:14px; padding-top:12px; border-top:1px solid rgba(255,255,255,0.12); font-size:14px; color:#e2e8f0; }')
    [void]$sb.AppendLine('  .kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; margin-bottom:20px; }')
    [void]$sb.AppendLine('  .kpi { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:14px 16px; box-shadow:0 1px 3px rgba(15,23,42,0.04); }')
    [void]$sb.AppendLine('  .kpi-num { font-size:26px; font-weight:700; line-height:1.1; }')
    [void]$sb.AppendLine('  .kpi-lbl { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:0.06em; margin-top:4px; font-weight:600; }')
    [void]$sb.AppendLine('  .kpi-sub { font-size:12px; color:var(--muted); margin-top:2px; }')
    [void]$sb.AppendLine('  .section { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:20px 22px; margin-bottom:18px; box-shadow:0 1px 3px rgba(15,23,42,0.04); }')
    [void]$sb.AppendLine('  .sec-head { display:flex; justify-content:space-between; align-items:center; gap:12px; flex-wrap:wrap; border-bottom:1px solid var(--border); padding-bottom:10px; margin-bottom:14px; }')
    [void]$sb.AppendLine('  .sec-head h2 { margin:0; font-size:17px; font-weight:700; }')
    [void]$sb.AppendLine('  .btn-toggle { border:1px solid var(--border); background:#f8fafc; color:#334155; font-size:12px; font-weight:600; padding:5px 11px; border-radius:6px; cursor:pointer; }')
    [void]$sb.AppendLine('  .btn-toggle:hover { background:#e2e8f0; }')
    [void]$sb.AppendLine('  .empty-note { color:var(--muted); font-size:14px; margin:2px 0; }')
    [void]$sb.AppendLine('  .bullet-list { list-style:none; padding:0; margin:0; display:flex; flex-direction:column; gap:10px; }')
    [void]$sb.AppendLine('  .bullet-item { padding:12px 15px; border-radius:8px; border:1px solid var(--border); border-left:4px solid var(--border); background:#f8fafc; }')
    [void]$sb.AppendLine('  .bullet-fixed { border-left-color:#0284c7; background:#f0f9ff; }')
    [void]$sb.AppendLine('  .bullet-high { border-left-color:#dc2626; background:#fef2f2; }')
    [void]$sb.AppendLine('  .bullet-med { border-left-color:#d97706; background:#fffbeb; }')
    [void]$sb.AppendLine('  .bullet-info { border-left-color:#0284c7; background:#f8fafc; }')
    [void]$sb.AppendLine('  .bullet-maint { border-left-color:#64748b; background:#f8fafc; padding:10px 14px; }')
    [void]$sb.AppendLine('  .item-head { display:flex; align-items:center; gap:8px; flex-wrap:wrap; margin-bottom:4px; }')
    [void]$sb.AppendLine('  .sev { font-size:11px; font-weight:700; padding:2px 8px; border-radius:999px; text-transform:uppercase; letter-spacing:0.04em; }')
    [void]$sb.AppendLine('  .sev-high { background:var(--err-bg); color:var(--err); }')
    [void]$sb.AppendLine('  .sev-med { background:var(--warn-bg); color:var(--warn); }')
    [void]$sb.AppendLine('  .sev-info { background:var(--fixed-bg); color:var(--fixed); }')
    [void]$sb.AppendLine('  .src-tag { font-size:12px; font-weight:600; color:var(--muted); }')
    [void]$sb.AppendLine('  .item-title { font-size:14px; font-weight:600; color:var(--text); word-break:break-word; }')
    [void]$sb.AppendLine('  .action-text { font-size:13px; color:#334155; margin-top:4px; word-break:break-word; }')
    [void]$sb.AppendLine('  .check-card { border:1px solid var(--border); border-left:4px solid var(--border); border-radius:10px; padding:14px 16px; margin-bottom:12px; background:#ffffff; }')
    [void]$sb.AppendLine('  .check-card:last-child { margin-bottom:0; }')
    [void]$sb.AppendLine('  .accent-ok { border-left-color:#16a34a; }')
    [void]$sb.AppendLine('  .accent-fixed { border-left-color:#0284c7; }')
    [void]$sb.AppendLine('  .accent-warn { border-left-color:#d97706; }')
    [void]$sb.AppendLine('  .accent-err { border-left-color:#dc2626; }')
    [void]$sb.AppendLine('  .accent-pending { border-left-color:#7c3aed; }')
    [void]$sb.AppendLine('  .accent-skip { border-left-color:#cbd5e1; opacity:0.8; }')
    [void]$sb.AppendLine('  .check-head { display:flex; justify-content:space-between; align-items:center; gap:10px; flex-wrap:wrap; }')
    [void]$sb.AppendLine('  .check-title { font-size:15px; font-weight:700; }')
    [void]$sb.AppendLine('  .badge { font-size:11px; font-weight:700; padding:3px 10px; border-radius:999px; text-transform:uppercase; letter-spacing:0.04em; }')
    [void]$sb.AppendLine('  .badge-ok { background:var(--ok-bg); color:var(--ok); }')
    [void]$sb.AppendLine('  .badge-fixed { background:var(--fixed-bg); color:var(--fixed); }')
    [void]$sb.AppendLine('  .badge-warn { background:var(--warn-bg); color:var(--warn); }')
    [void]$sb.AppendLine('  .badge-err { background:var(--err-bg); color:var(--err); }')
    [void]$sb.AppendLine('  .badge-pending { background:var(--pend-bg); color:var(--pend); }')
    [void]$sb.AppendLine('  .badge-skip { background:#f1f5f9; color:#64748b; }')
    [void]$sb.AppendLine('  .badge-maint { background:var(--maint-bg); color:var(--maint); }')
    [void]$sb.AppendLine('  .badge-info { background:#e2e8f0; color:#334155; }')
    [void]$sb.AppendLine('  .check-meta { font-size:12px; color:var(--muted); margin:4px 0 6px 0; font-family:Consolas,monospace; }')
    [void]$sb.AppendLine('  .check-sum { font-size:14px; margin:4px 0 8px 0; }')
    [void]$sb.AppendLine('  details { margin-top:6px; }')
    [void]$sb.AppendLine('  summary { cursor:pointer; font-size:13px; font-weight:600; color:#0369a1; user-select:none; }')
    [void]$sb.AppendLine('  pre { background:#0f172a; color:#e2e8f0; padding:12px 14px; border-radius:8px; overflow:auto; max-height:420px; font-size:12px; line-height:1.45; margin:8px 0 0 0; white-space:pre-wrap; word-break:break-word; }')
    [void]$sb.AppendLine('  .ext-link { display:inline-block; margin-top:6px; font-size:13px; color:#0284c7; text-decoration:none; font-weight:600; }')
    [void]$sb.AppendLine('  .ext-link:hover { text-decoration:underline; }')
    [void]$sb.AppendLine('  .footer { font-size:12px; color:var(--muted); padding:8px 4px; display:flex; flex-direction:column; gap:4px; }')
    [void]$sb.AppendLine('  code { background:#e2e8f0; padding:1px 5px; border-radius:4px; font-family:Consolas,monospace; font-size:12px; color:#0f172a; }')
    [void]$sb.AppendLine('  @media print { body { background:#ffffff; padding:0; } .hero { background:#0f172a !important; -webkit-print-color-adjust:exact; print-color-adjust:exact; } .btn-toggle { display:none; } pre { max-height:none; } }')
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')
    [void]$sb.AppendLine('<div class="wrap">')

    # Hero
    [void]$sb.AppendLine('  <div class="hero">')
    [void]$sb.AppendLine('    <div class="hero-top">')
    [void]$sb.AppendLine('      <div>')
    [void]$sb.AppendLine('        <h1>Windows Scan &amp; Fix Report</h1>')
    [void]$sb.AppendLine('        <div class="meta-row">')
    [void]$sb.AppendLine("          <span class=""meta-chip"">PC: <strong>$computerName</strong></span>")
    [void]$sb.AppendLine("          <span class=""meta-chip"">User: <strong>$userName</strong></span>")
    [void]$sb.AppendLine("          <span class=""meta-chip"">$osCaption</span>")
    [void]$sb.AppendLine("          <span class=""meta-chip"">Started: $timestampDisplay</span>")
    [void]$sb.AppendLine("          <span class=""meta-chip"">Duration: $durationDisplay</span>")
    if ($postReboot -and -not [string]::IsNullOrWhiteSpace($finalizedTime)) {
        [void]$sb.AppendLine("          <span class=""meta-chip"">Post-Reboot: $(Escape-Html $finalizedTime)</span>")
    }
    [void]$sb.AppendLine('        </div>')
    [void]$sb.AppendLine('      </div>')
    [void]$sb.AppendLine("      <div class=""overall-pill $overallClass"">$overallLabel</div>")
    [void]$sb.AppendLine('    </div>')
    [void]$sb.AppendLine("    <div class=""hero-sub"">$(Escape-Html $overallDesc)</div>")
    [void]$sb.AppendLine('  </div>')

    # KPIs
    $runSub = if ($skippedCount -gt 0) { "of $totalCount ($skippedCount skipped)" } else { "of $totalCount checks" }
    $attnColor = if ($highCount -gt 0) { 'var(--err)' } elseif ($attentionCount -gt 0) { 'var(--warn)' } else { 'var(--ok)' }
    $attnSub = if ($highCount -gt 0) { "$highCount high priority" } elseif ($attentionCount -gt 0) { 'review recommended' } else { 'all clear' }
    $fixedSub = if ($fixedCardCount -gt 0) { "$fixedCardCount check(s) repaired" } else { 'no repairs needed' }
    [void]$sb.AppendLine('  <div class="kpis">')
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"">$runCount</div><div class=""kpi-lbl"">Checks Run</div><div class=""kpi-sub"">$runSub</div></div>")
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"" style=""color:var(--fixed)"">$fixedCount</div><div class=""kpi-lbl"">Issues Fixed</div><div class=""kpi-sub"">$fixedSub</div></div>")
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"" style=""color:$attnColor"">$attentionCount</div><div class=""kpi-lbl"">Need Attention</div><div class=""kpi-sub"">$attnSub</div></div>")
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"" style=""color:var(--ok)"">$okCount</div><div class=""kpi-lbl"">Passed Clean</div><div class=""kpi-sub"">healthy checks</div></div>")
    [void]$sb.AppendLine("    <div class=""kpi""><div class=""kpi-num"" style=""color:var(--maint)"">$maintCount</div><div class=""kpi-lbl"">Maintenance</div><div class=""kpi-sub"">routine tune-ups</div></div>")
    [void]$sb.AppendLine('  </div>')

    # Section 1: What Was Fixed
    [void]$sb.AppendLine('  <div class="section">')
    [void]$sb.AppendLine('    <div class="sec-head"><h2>1. What Was Fixed</h2></div>')
    if ($fixedCount -eq 0) {
        [void]$sb.AppendLine('    <p class="empty-note">No repairs were needed &ndash; Windows system files, component store, drives, and security checks were already healthy.</p>')
    } else {
        [void]$sb.AppendLine('    <ul class="bullet-list">')
        foreach ($item in $fixedItems) {
            $src = Escape-Html ([string](Get-SafeProp $item 'Source' 'Repair'))
            $desc = Escape-Html ([string](Get-SafeProp $item 'Description' ''))
            [void]$sb.AppendLine("      <li class=""bullet-item bullet-fixed""><div class=""item-head""><span class=""badge badge-fixed"">FIXED</span><span class=""src-tag"">$src</span></div><div class=""item-title"">$desc</div></li>")
        }
        [void]$sb.AppendLine('    </ul>')
    }
    [void]$sb.AppendLine('  </div>')

    # Section 2: Things You May Need to Look At (sorted High -> Medium -> Info)
    [void]$sb.AppendLine('  <div class="section">')
    [void]$sb.AppendLine('    <div class="sec-head"><h2>2. Things You May Need to Look At</h2></div>')
    if ($attentionCount -eq 0) {
        [void]$sb.AppendLine('    <p class="empty-note">Nothing requires your attention right now.</p>')
    } else {
        [void]$sb.AppendLine('    <ul class="bullet-list">')
        foreach ($item in $attentionItems) {
            $sev = [string](Get-SafeProp $item 'Severity' 'Info')
            $sevClass = Get-SeverityClass $sev
            $bulletCls = switch ($sev) { 'High' { 'bullet-high' } 'Medium' { 'bullet-med' } default { 'bullet-info' } }
            $src = Escape-Html ([string](Get-SafeProp $item 'Source' 'Check'))
            $title = Escape-Html ([string](Get-SafeProp $item 'Title' ''))
            $action = Escape-Html ([string](Get-SafeProp $item 'Action' ''))
            [void]$sb.AppendLine("      <li class=""bullet-item $bulletCls""><div class=""item-head""><span class=""sev $sevClass"">$(Escape-Html $sev)</span><span class=""src-tag"">$src</span></div><div class=""item-title"">$title</div><div class=""action-text""><strong>Next step:</strong> $action</div></li>")
        }
        [void]$sb.AppendLine('    </ul>')
    }
    [void]$sb.AppendLine('  </div>')

    # Section 3: Routine Maintenance Performed
    [void]$sb.AppendLine('  <div class="section">')
    [void]$sb.AppendLine('    <div class="sec-head"><h2>3. Routine Maintenance Performed</h2></div>')
    if ($maintCount -eq 0) {
        [void]$sb.AppendLine('    <p class="empty-note">No routine maintenance tasks were run.</p>')
    } else {
        [void]$sb.AppendLine('    <ul class="bullet-list">')
        foreach ($item in $maintItems) {
            $src = Escape-Html ([string](Get-SafeProp $item 'Source' 'Maintenance'))
            $desc = Escape-Html ([string](Get-SafeProp $item 'Description' ''))
            [void]$sb.AppendLine("      <li class=""bullet-item bullet-maint""><div class=""item-head""><span class=""badge badge-maint"">MAINT</span><span class=""src-tag"">$src</span></div><div class=""action-text"" style=""margin-top:0"">$desc</div></li>")
        }
        [void]$sb.AppendLine('    </ul>')
    }
    [void]$sb.AppendLine('  </div>')

    # Section 4: Detailed Results
    [void]$sb.AppendLine('  <div class="section">')
    [void]$sb.AppendLine("    <div class=""sec-head""><h2>4. Detailed Results (All $totalCount Checks)</h2><button type=""button"" class=""btn-toggle"" onclick=""var d=document.querySelectorAll('.check-card details');var open=Array.prototype.some.call(d,function(x){return !x.open;});d.forEach(function(x){x.open=open;});this.textContent=open?'Collapse All Details':'Expand All Details';"">Expand All Details</button></div>")
    foreach ($r in $results) {
        $name = Escape-Html ([string](Get-SafeProp $r 'Name' ''))
        $cmd = Escape-Html ([string](Get-SafeProp $r 'Command' ''))
        $status = [string](Get-SafeProp $r 'Status' 'INFO')
        $badgeClass = Get-BadgeClass $status
        $accentClass = Get-CardAccentClass $status
        $dur = Escape-Html ([string](Get-SafeProp $r 'Duration' ''))
        $summary = Escape-Html ([string](Get-SafeProp $r 'Summary' ''))
        $details = [string](Get-SafeProp $r 'Details' '')
        $extraPath = [string](Get-SafeProp $r 'ExtraLinkPath' '')
        $extraLabel = Escape-Html ([string](Get-SafeProp $r 'ExtraLinkLabel' 'Open report'))

        [void]$sb.AppendLine("    <div class=""check-card $accentClass"">")
        [void]$sb.AppendLine('      <div class="check-head">')
        [void]$sb.AppendLine("        <div class=""check-title"">$name</div>")
        [void]$sb.AppendLine("        <span class=""badge $badgeClass"">$(Escape-Html $status)</span>")
        [void]$sb.AppendLine('      </div>')
        [void]$sb.AppendLine("      <div class=""check-meta"">$cmd | Duration: $dur</div>")
        [void]$sb.AppendLine("      <div class=""check-sum"">$summary</div>")
        if (-not [string]::IsNullOrWhiteSpace($extraPath)) {
            try { $fileUri = [System.Uri]::new($extraPath).AbsoluteUri }
            catch { $fileUri = 'file:///' + ($extraPath.Replace('\', '/').TrimStart('/') -replace ' ', '%20') }
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
    [void]$sb.AppendLine("    <div><strong>Saved Reports:</strong> Desktop: <code>$desktopReportPath</code> | Archive: <code>$archiveReportPath</code></div>")
    [void]$sb.AppendLine("    <div><strong>Logs:</strong> Scan log: <code>$rawLogPath</code> | PowerCfg: <code>$energyHtmlPath</code> | SFC: <code>C:\Windows\Logs\CBS\CBS.log</code> | DISM: <code>C:\Windows\Logs\DISM\dism.log</code></div>")
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

$state | Add-Member -NotePropertyName MaintenanceItems -NotePropertyValue @(Get-SafeProp $state 'MaintenanceItems' @()) -Force
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
        Reset-TuiConsole
        try { Clear-Host } catch {}
        Write-Host ''
        Write-Host '  Scan cancelled. Nothing was modified.' -ForegroundColor DarkGray
        exit 0
    }

    try {
        try {
            if (-not ('ScanExecutionState' -as [type])) {
                Add-Type -ErrorAction Stop -TypeDefinition @'
using System.Runtime.InteropServices;

public static class ScanExecutionState {
    public const uint Continuous = 0x80000000u;
    public const uint SystemRequired = 0x00000001u;

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@
            }
            [void][ScanExecutionState]::SetThreadExecutionState([ScanExecutionState]::Continuous -bor [ScanExecutionState]::SystemRequired)
        } catch {}

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
    $dismHealthy = $false
    $maintenanceItems = New-Object 'System.Collections.Generic.List[object]'
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
                            $smartNote = @(
                                if ($null -ne $temp) { "Temp=$($temp)C" }
                                if ($null -ne $wear) { "Wear=$($wear)%" }
                                if ($null -ne $rErr) { "UncorrectedReadErr=$rErr" }
                                if ($null -ne $wErr) { "UncorrectedWriteErr=$wErr" }
                                if ($null -ne $hours) { "PowerOnHours=$hours" }
                            ) -join ', '
                            if ([string]::IsNullOrWhiteSpace($smartNote)) {
                                $smartNote = 'SMART counters unavailable on this controller'
                            }
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

            $energyErrors = @()
            if (Test-Path -LiteralPath $energyHtmlPath) {
                try { $energyErrors = @(Get-EnergyReportErrors ([IO.File]::ReadAllText($energyHtmlPath))) } catch {}
            }
            $topErrors = @($energyErrors | ForEach-Object { $_.Text })
            $desktopConfirmed = $false

            $batteryNote = 'Battery: status unavailable'
            $batteryLowHealth = $false
            try {
                $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
                $desktopConfirmed = $batteries.Count -eq 0
                if ($desktopConfirmed) { $batteryNote = 'Battery: None (desktop)' }
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
                $detailsList.Add('Error Entries:')
                foreach ($te in $topErrors) { $detailsList.Add("  - $te") }
            }
            if (-not [string]::IsNullOrWhiteSpace($pwrOut)) {
                $detailsList.Add('')
                $detailsList.Add($pwrOut)
            }

            $otherEnergyErrors = @($energyErrors | Where-Object {
                $_.Title -notmatch '^(Power Policy:\s*(Power Plan Personality is High Performance|Disk idle is disabled|Minimum processor performance state|PCI Express ASPM)|Platform Power Management Capabilities:\s*PCI Express Active-State Power Management)'
            })
            $powerPlanErrCount = [math]::Max(0, $energyErrors.Count - $otherEnergyErrors.Count)
            if ($desktopConfirmed -and $errCount -gt 0 -and $energyErrors.Count -eq $errCount -and $otherEnergyErrors.Count -eq 0) {
                $status = 'OK'
                $summary = "$errCount High Performance power-plan note(s) (intentional on desktop). $batteryNote"
                $detailsList.Add('Note: Desktop High Performance power settings are typically intentional.')
            } elseif ($errCount -gt 0 -or $batteryLowHealth) {
                $status = 'ATTENTION'
                $breakdown = if ($desktopConfirmed -and $powerPlanErrCount -gt 0) {
                    "$errCount error(s) ($powerPlanErrCount desktop High Performance, $($otherEnergyErrors.Count) other), $warnCount warning(s)"
                } else {
                    "$errCount error(s), $warnCount warning(s)"
                }
                $summary = "$breakdown. $batteryNote"
                if ($errCount -gt 0) {
                    $topSnippet = if ($otherEnergyErrors.Count -gt 0) { ' Top finding: ' + $otherEnergyErrors[0].Title } elseif ($topErrors.Count -gt 0) { ' Top finding: ' + $topErrors[0] } else { '' }
                    $attentionItems.Add([PSCustomObject]@{
                        Severity='Medium'; Source='Power & Energy (powercfg /energy)'
                        Title="Powercfg energy trace reported $breakdown."
                        Action="Open energy-report.html to review USB suspend, sleep, or driver power issues.$topSnippet"
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

            $osCrashes = 0; $appIssues = 0; $osUpdateFails = 0; $storeUpdateFails = 0; $msiFails = 0
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
                    if ($prod -match '^[0-9A-Z]{12}-') {
                        $cat = 'Microsoft Store App Update Failure'; $storeUpdateFails++
                    } else {
                        $cat = 'Windows OS Update Failure'; $osUpdateFails++
                    }
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

            $topApps = @($grouped.Values | Where-Object { $_.Category -in @('Application Crash', 'Application Hang') } |
                Group-Object Item | ForEach-Object {
                    [PSCustomObject]@{ Name=$_.Name; Count=($_.Group | Measure-Object Count -Sum).Sum }
                } | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count)x)" })
            $topAppsNote = if ($topApps.Count -gt 0) { ' Top apps: ' + ($topApps -join ', ') + '.' } else { '' }
            $scoreText = if ($null -ne $latestScore) { "$latestScore/10" } else { 'N/A' }
            $relLines = New-Object 'System.Collections.Generic.List[string]'
            $relLines.Add("Current System Stability Index: $scoreText")
            $relLines.Add("Last 30 Days: OS/Unexpected Shutdowns=$osCrashes, App Crashes/Hangs=$appIssues, OsUpdateFails=$osUpdateFails, StoreUpdateFails=$storeUpdateFails, Installer Failures=$msiFails")
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
                    Action='Review Reliability details or inspect Event Viewer -> Windows Logs -> System.' + $topAppsNote
                })
            }
            if ($osCrashes -gt 0) {
                $status = 'ATTENTION'
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source='Reliability History (perfmon /rel)'
                    Title="$osCrashes OS crash(es) or unexpected shutdown(s) in the last 30 days (Stability: $scoreText)."
                    Action='Press Win+R and run "perfmon /rel" to inspect crash events on the timeline.' + $topAppsNote
                })
            } elseif ($hwEvents.Count -gt 0 -or $minidumps.Count -gt 0) {
                $status = 'ATTENTION'
            } elseif (($null -ne $latestScore -and $latestScore -lt 5.0) -or $appIssues -ge 5 -or $osUpdateFails -gt 0) {
                $status = 'ATTENTION'
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Medium'; Source='Reliability History (perfmon /rel)'
                    Title="Stability Index is $scoreText ($appIssues app crash/hang(s), $osUpdateFails failed Windows OS update(s) in last 30 days)."
                    Action='Run "perfmon /rel" to see which apps or updates had issues.' + $topAppsNote
                })
            } else {
                $status = 'OK'
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $summary = "Stability $scoreText | OS:$osCrashes App:$appIssues UpdFail:$osUpdateFails HW:$($hwEvents.Count)"
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
            $scanOut = Format-CleanToolOutput ($dismScan.Output + "`r`n" + $dismScan.Error)
            Write-RawLog $scanOut $rawLogPath

            $dismRepairable = ($scanOut -match 'component store is repairable')
            $dismHealthy = ($dismScan.ExitCode -eq 0 -and $scanOut -match 'No component store corruption detected')
            $dismUnrepairable = ($scanOut -match 'not repairable|cannot be repaired')

            if ($dismScan.ExitCode -eq 0 -and $dismHealthy) {
                $status = 'OK'
                $summary = 'No component store corruption detected'
            } elseif ($dismRepairable) {
                $status = 'ATTENTION'
                $summary = 'Repairable corruption found'
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
            if ($dismHealthy) {
                $dismRestore = [PSCustomObject]@{ ExitCode=0; Output='/RestoreHealth skipped because Step 7 confirmed the component store is healthy.'; Error='' }
            } else {
                $dismRestore = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'DISM.exe') -Arguments '/Online /Cleanup-Image /RestoreHealth' -OnTick $rTick
            }
            $restOut = Format-CleanToolOutput ($dismRestore.Output + "`r`n" + $dismRestore.Error)
            Write-RawLog $restOut $rawLogPath

            $cleanupNote = ''
            $cleanupOut = ''
            if ($dismRestore.ExitCode -in @(0, 3010)) {
                if ($dismRepairable -and -not $dismHealthy) {
                    $scanCard = $results | Where-Object { $_.Id -eq 'dism_scan' } | Select-Object -First 1
                    if ($null -ne $scanCard) {
                        $scanCard.Status = 'OK'
                        $scanCard.Summary = 'Repairable corruption detected -> Repaired in Step 8'
                        Set-StepDone 7 $scanCard.Status $scanCard.Duration $scanCard.Summary
                    }
                    $fixedItems.Add([PSCustomObject]@{
                        Source      = 'DISM (/RestoreHealth)'
                        Description = 'Repaired Windows component store corruption.'
                    })
                }
                $cTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $(if ($h) { "DISM ComponentCleanup: $h" } else { 'Running DISM /StartComponentCleanup...' }) }
                $dismClean = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'DISM.exe') -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -OnTick $cTick
                $cleanupOut = Format-CleanToolOutput ($dismClean.Output + "`r`n" + $dismClean.Error)
                Write-RawLog $cleanupOut $rawLogPath
                if ($dismClean.ExitCode -in @(0, 3010)) {
                    $cleanupNote = ' | WinSxS cleanup completed'
                    if ($dismClean.ExitCode -eq 3010) { $cleanupNote += ' (restart required)' }
                    $maintenanceItems.Add([PSCustomObject]@{ Source='DISM (/StartComponentCleanup)'; Description='Completed routine WinSxS component cleanup.' })
                } else {
                    $cleanupNote = " | WinSxS cleanup exited $($dismClean.ExitCode)"
                    $attentionItems.Add([PSCustomObject]@{
                        Severity='Medium'; Source='DISM (/StartComponentCleanup)'
                        Title="WinSxS cleanup exited $($dismClean.ExitCode)."
                        Action='Inspect C:\Windows\Logs\DISM\dism.log.'
                    })
                }

                $rebootNote = if ($dismRestore.ExitCode -eq 3010) { ' (restart required)' } else { '' }
                if ($dismRepairable -and -not $dismHealthy) {
                    $status = 'FIXED'
                    $summary = "Repaired component store$cleanupNote$rebootNote"
                } else {
                    $status = if ($dismClean.ExitCode -in @(0, 3010)) { 'OK' } else { 'ATTENTION' }
                    $restoreNote = if ($dismHealthy) { $restOut } else { 'Component store healthy' }
                    $summary = "$restoreNote$cleanupNote$rebootNote"
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
            $sfcOut = Format-CleanToolOutput ($sfcRes.Output + "`r`n" + $sfcRes.Error)
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
                    $chkOut = Format-CleanToolOutput ($chkRes.Output + "`r`n" + $chkRes.Error)
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
                    $chkOut = Format-CleanToolOutput ($chkRes.Output + "`r`n" + $chkRes.Error)
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

            if ($trimmedDrives.Count -gt 0) {
                $maintenanceItems.Add([PSCustomObject]@{ Source='SSD Optimization'; Description="Ran SSD TRIM on $($trimmedDrives -join ', ')." })
            }
            $largeCleanup = $bytesFreed -ge 100MB
            if ($filesRemoved -gt 0) {
                $cleanupItem = [PSCustomObject]@{ Source='Temp Cleanup'; Description="Removed $filesRemoved stale temp file(s) ($($mbFreed) MB freed)." }
                if ($largeCleanup) { $fixedItems.Add($cleanupItem) }
                else { $maintenanceItems.Add($cleanupItem) }
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $st = if ($largeCleanup) { 'FIXED' } else { 'OK' }
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
            $nTick = { param($h) Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint 'Refreshing DNS, Winsock & clock...' }

            $dnsRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'ipconfig.exe') -Arguments '/flushdns' -OnTick $nTick
            $netLines.Add("=== ipconfig /flushdns (exit $($dnsRes.ExitCode)) ===`r`n$($dnsRes.Output.Trim())")

            $wsRes = Invoke-ConsoleTool -FilePath (Join-Path $sysDir 'netsh.exe') -Arguments 'winsock reset' -OnTick $nTick
            $netLines.Add("=== netsh winsock reset (exit $($wsRes.ExitCode)) ===`r`n$($wsRes.Output.Trim())")
            $netOk = $dnsRes.ExitCode -eq 0 -and $wsRes.ExitCode -eq 0

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

            $netActions = @(
                if ($dnsRes.ExitCode -eq 0) { 'Flushed DNS cache' }
                if ($wsRes.ExitCode -eq 0) { 'Reset Winsock catalog (applies on restart)' }
                if ($timeNote -eq 'Clock synced') { 'Requested Windows Time resync' }
            )
            if ($netActions.Count -gt 0) {
                $maintenanceItems.Add([PSCustomObject]@{ Source='Network Stack & Clock Sync'; Description=($netActions -join '. ') + '.' })
            }

            $dur = Format-DurationSpan ((Get-Date) - $stepStart)
            $st = if ($netOk) { 'OK' } else { 'ATTENTION' }
            if (-not $netOk) {
                $attentionItems.Add([PSCustomObject]@{
                    Severity='Medium'; Source='Network Stack & Clock Sync'
                    Title="Network stack refresh had a non-zero exit (DNS: $($dnsRes.ExitCode), Winsock: $($wsRes.ExitCode))."
                    Action='Inspect Step 12 details or run "ipconfig /flushdns" and "netsh winsock reset" as Administrator.'
                })
            }
            $summary = if ($netOk) { "DNS flushed, Winsock reset, $timeNote" } else { "DNS exit $($dnsRes.ExitCode) | Winsock exit $($wsRes.ExitCode) | $timeNote" }
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
            $nextPoll = $mpStart
            $liveHint = "Microsoft Defender ($defMode) scanning..."
            while (-not $async.IsCompleted) {
                $now = Get-Date
                if ($now -ge $nextPoll) {
                    $nextPoll = $now.AddSeconds(10)
                    try {
                        $events = @(Get-WinEvent -FilterHashtable @{
                            LogName='Microsoft-Windows-Windows Defender/Operational'; Id=1116; StartTime=$mpStart
                        } -MaxEvents 1 -ErrorAction Stop)
                        if ($events.Count -gt 0) {
                            $nameNode = ([xml]$events[0].ToXml()).SelectSingleNode('//*[local-name()="Data" and @Name="Threat Name"]')
                            $liveHint = 'Microsoft Defender detected a threat'
                            if ($null -ne $nameNode -and -not [string]::IsNullOrWhiteSpace($nameNode.InnerText)) { $liveHint += ": $($nameNode.InnerText)" }
                        }
                    } catch {}
                }
                Update-ActiveStatusLine -UiState $ui -StepStart $stepStart -Hint $liveHint
                Start-Sleep -Milliseconds 250
            }
            [void]$psRun.EndInvoke($async)
            if ($psRun.HadErrors -and $psRun.Streams.Error.Count -gt 0) {
                throw $psRun.Streams.Error[0].Exception
            }

            $detections = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object {
                $detTime = Get-SafeProp $_ 'InitialDetectionTime' ([datetime]::MinValue)
                $detTime -ge $mpStart.AddSeconds(-5)
            })
            $threats = @(Get-MpThreat -ErrorAction SilentlyContinue)
            $activeThreats = @($threats | Where-Object { [bool](Get-SafeProp $_ 'IsActive' $false) })
            $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
            $sigVer = [string](Get-SafeProp $mpStatus 'AntivirusSignatureVersion' 'Unknown')

            $mpDetailLines = New-Object 'System.Collections.Generic.List[string]'
            $mpDetailLines.Add("Scan Type: $defMode")
            $mpDetailLines.Add("Antivirus Signature Version: $sigVer")
            $mpDetailLines.Add("Detections during this scan: $($detections.Count)")
            $mpDetailLines.Add("Active threats remaining: $($activeThreats.Count)")

            $pendingThreats = @()
            $remediatedThreats = @()
            $seenThreatIds = @()
            foreach ($detection in $detections) {
                $id = Get-SafeProp $detection 'ThreatID' $null
                $threat = $null
                if ($null -ne $id) {
                    $seenThreatIds += $id
                    $threat = $threats | Where-Object { (Get-SafeProp $_ 'ThreatID' $null) -eq $id } | Select-Object -First 1
                }
                $name = Get-SafeProp $threat 'ThreatName' (Get-SafeProp $detection 'ThreatName' "Threat ID $id")
                $paths = @(@(Get-SafeProp $detection 'Resources' @()) + @(Get-SafeProp $threat 'Resources' @()) |
                    Where-Object { $_ } | Sort-Object -Unique)
                $brief = $name
                if ($paths.Count -gt 0) { $brief += " [$($paths -join ', ')]" }
                $sevId = Get-SafeProp $threat 'SeverityID' (Get-SafeProp $detection 'SeverityID' $null)
                $sevLabel = switch ([string]$sevId) {
                    '1' { 'Low' }
                    '2' { 'Moderate' }
                    '4' { 'High' }
                    '5' { 'Severe' }
                    default { if ($null -ne $sevId) { "Level $sevId" } else { 'Unknown' } }
                }
                $threatStatus = Get-SafeProp $detection 'ThreatStatusID' 'Unknown'
                $active = [bool](Get-SafeProp $threat 'IsActive' $false)
                $actionSuccess = [bool](Get-SafeProp $detection 'ActionSuccess' $false)
                $statusLabel = switch ([string]$threatStatus) {
                    '1' { 'Detected' }
                    '2' { 'Cleaned' }
                    '3' { 'Quarantined' }
                    '4' { 'Removed' }
                    '5' { 'Allowed' }
                    '6' { 'Blocked' }
                    default { 'Unresolved' }
                }
                $mpDetailLines.Add("  - $brief | Severity: $sevLabel | Status: $statusLabel | Active: $active | Remediated: $actionSuccess")
                if (-not $active -and $actionSuccess -and ([string]$threatStatus -in @('2', '3', '4', '6'))) {
                    $remediatedThreats += $brief
                } else {
                    $pendingThreats += $brief
                }
            }
            foreach ($threat in $activeThreats) {
                if ($seenThreatIds -contains (Get-SafeProp $threat 'ThreatID' $null)) { continue }
                $name = Get-SafeProp $threat 'ThreatName' 'Unknown threat'
                $paths = @(Get-SafeProp $threat 'Resources' @() | Where-Object { $_ })
                $brief = $name
                if ($paths.Count -gt 0) { $brief += " [$($paths -join ', ')]" }
                $sevId = Get-SafeProp $threat 'SeverityID' $null
                $sevLabel = switch ([string]$sevId) {
                    '1' { 'Low' }
                    '2' { 'Moderate' }
                    '4' { 'High' }
                    '5' { 'Severe' }
                    default { if ($null -ne $sevId) { "Level $sevId" } else { 'Unknown' } }
                }
                $mpDetailLines.Add("  - $brief | Severity: $sevLabel | Status: Active")
                $pendingThreats += $brief
            }

            if ($remediatedThreats.Count -gt 0) {
                $fixedItems.Add([PSCustomObject]@{
                    Source="Microsoft Defender ($defMode)"
                    Description="Remediated: $($remediatedThreats -join '; ')"
                })
            }
            if ($pendingThreats.Count -gt 0) {
                $status = 'ATTENTION'
                $summary = "$($pendingThreats.Count) threat detection(s) require review"
                $attentionItems.Add([PSCustomObject]@{
                    Severity='High'; Source="Microsoft Defender ($defMode)"
                    Title="Threats requiring review: $($pendingThreats -join '; ')"
                    Action='Open Windows Security -> Virus & threat protection -> Protection history.'
                })
            } elseif ($remediatedThreats.Count -gt 0) {
                $status = 'FIXED'
                $summary = "Remediated $($remediatedThreats.Count) detection(s)"
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
        MaintenanceItems       = @($maintenanceItems.ToArray())
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

    # Final polished dashboard + concise monochrome findings
    Render-ScanDashboard -UiState $ui -Final

    $caps = Initialize-TuiConsole
    $g = Get-TuiGlyphs
    $w = Get-ConsoleSafeWidth

    if ($caps.UseVt) {
        $a = Get-TuiAnsi
        $sb = New-Object System.Text.StringBuilder
        $ruleW = [math]::Max(18, [math]::Min(36, $w - 4))
        [void]$sb.Append($a.FgDim + '  ' + ($g.Rule * $ruleW) + $a.BgDark + $a.ClearLine + "`r`n")
        [void]$sb.Append($a.FgBright + '  Scan complete' + $a.FgMuted + "  $($g.Dot)  Total duration: $totalDuration" + $a.BgDark + $a.ClearLine + "`r`n")
        [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")

        [void]$sb.Append($a.FgBright + '  Fixed' + $a.BgDark + $a.ClearLine + "`r`n")
        if ($fixedItems.Count -eq 0) {
            [void]$sb.Append($a.FgMuted + '    No automatic repairs were needed' + $a.BgDark + $a.ClearLine + "`r`n")
        } else {
            foreach ($fi in $fixedItems) {
                [void]$sb.Append($a.BgDark + '    ' + $a.FgFixed + $g.Fixed + ' ' + $a.FgText + "$($fi.Source): " + $a.FgMuted + $fi.Description + $a.BgDark + $a.ClearLine + "`r`n")
            }
        }

        [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
        [void]$sb.Append($a.FgBright + '  Needs attention' + $a.BgDark + $a.ClearLine + "`r`n")
        if ($attentionItems.Count -eq 0) {
            [void]$sb.Append($a.FgMuted + '    Nothing requires your attention right now' + $a.BgDark + $a.ClearLine + "`r`n")
        } else {
            $sortedAttn = @($attentionItems | Sort-Object { switch ([string]$_.Severity) { 'High' { 0 } 'Medium' { 1 } default { 2 } } })
            foreach ($ai in $sortedAttn) {
                $sevCol = switch ([string]$ai.Severity) { 'High' { $a.FgErr } 'Medium' { $a.FgWarn } default { $a.FgMuted } }
                [void]$sb.Append($a.BgDark + '    ' + $sevCol + "[$($ai.Severity)] " + $a.FgText + "$($ai.Source): " + $a.FgMuted + $ai.Title + $a.BgDark + $a.ClearLine + "`r`n")
            }
        }

        if ($maintenanceItems.Count -gt 0) {
            [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
            [void]$sb.Append($a.FgBright + '  Maintenance' + $a.BgDark + $a.ClearLine + "`r`n")
            foreach ($mi in $maintenanceItems) {
                [void]$sb.Append($a.BgDark + '    ' + $a.FgDim + $g.Dot + ' ' + $a.FgText + "$($mi.Source): " + $a.FgMuted + $mi.Description + $a.BgDark + $a.ClearLine + "`r`n")
            }
        }

        [void]$sb.Append($a.BgDark + $a.ClearLine + "`r`n")
        [void]$sb.Append($a.FgMuted + '  Report   ' + $a.FgText + $desktopReportPath + $a.BgDark + $a.ClearLine + "`r`n")
        [void]$sb.Append($a.FgMuted + '  Raw log  ' + $a.FgDim + $rawLogPath + $a.BgDark + $a.ClearLine + "`r`n")
        [void]$sb.Append($a.BgDark + $a.ClearLine + $a.Reset + "`r`n")
        [Console]::Write($sb.ToString())
    } else {
        Write-Host ('  ' + ($g.Rule * [math]::Max(18, [math]::Min(36, $w - 4)))) -ForegroundColor DarkGray
        Write-Host "  Scan complete  $($g.Dot)  Total duration: $totalDuration" -ForegroundColor White
        Write-Host ''
        Write-Host '  Fixed' -ForegroundColor White
        if ($fixedItems.Count -eq 0) {
            Write-Host '    No automatic repairs were needed' -ForegroundColor DarkGray
        } else {
            foreach ($fi in $fixedItems) {
                Write-Host "    + $($fi.Source): $($fi.Description)" -ForegroundColor Gray
            }
        }
        Write-Host ''
        Write-Host '  Needs attention' -ForegroundColor White
        if ($attentionItems.Count -eq 0) {
            Write-Host '    Nothing requires your attention right now' -ForegroundColor DarkGray
        } else {
            $sortedAttn = @($attentionItems | Sort-Object { switch ([string]$_.Severity) { 'High' { 0 } 'Medium' { 1 } default { 2 } } })
            foreach ($ai in $sortedAttn) {
                $aiColor = switch ([string]$ai.Severity) { 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'Gray' } }
                Write-Host "    [$($ai.Severity)] $($ai.Source): $($ai.Title)" -ForegroundColor $aiColor
            }
        }
        if ($maintenanceItems.Count -gt 0) {
            Write-Host ''
            Write-Host '  Maintenance' -ForegroundColor White
            foreach ($mi in $maintenanceItems) {
                Write-Host "    $($g.Dot) $($mi.Source): $($mi.Description)" -ForegroundColor Gray
            }
        }
        Write-Host ''
        Write-Host "  Report   $desktopReportPath" -ForegroundColor Gray
        Write-Host "  Raw log  $rawLogPath" -ForegroundColor DarkGray
        Write-Host ''
    }

    $doRestart = [bool]$config.AutoRestart
    if ($doRestart) {
        if ($config.OpenReport) {
            Write-Host '  After restart, your updated report (with RAM test results) will open automatically.' -ForegroundColor DarkGray
        }
        $restartCancelled = $false
        $restartNow = $false
        $deadline = (Get-Date).AddSeconds([int]$config.RestartDelaySec)
        $lastShownSec = -1
        $canReadKeys = $true
        try { if ([Console]::IsInputRedirected) { $canReadKeys = $false } } catch { $canReadKeys = $false }

        while ((Get-Date) -lt $deadline) {
            $remSec = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            if ($remSec -lt 0) { $remSec = 0 }
            if ($remSec -ne $lastShownSec) {
                $lastShownSec = $remSec
                if ($caps.UseVt) {
                    $a = Get-TuiAnsi
                    [Console]::Write("`r" + $a.BgDark + '  ' + $a.FgBright + ("Restarting in {0,2}s" -f $remSec) + $a.FgDim + " $($g.Dot) " + $a.KeyBold + 'esc ' + $a.KeyLabel + 'cancel' + $a.FgDim + " $($g.Dot) " + $a.KeyBold + 'enter ' + $a.KeyLabel + 'restart now' + $a.BgDark + $a.ClearLine + $a.Reset)
                } else {
                    Write-Host -NoNewline ("`r  Restarting in {0,2}s  (Esc: cancel | Enter: restart now)   " -f $remSec) -ForegroundColor Gray
                }
            }
            if ($canReadKeys) {
                try {
                    if ([Console]::KeyAvailable) {
                        $ck = [Console]::ReadKey($true)
                        $ckName = $ck.Key.ToString()
                        $ckChar = if ($ck.KeyChar -eq [char]0) { '' } else { ([string]$ck.KeyChar).ToUpperInvariant() }
                        if ($ckName -eq 'Escape' -or $ckChar -eq 'C') {
                            $restartCancelled = $true
                            break
                        }
                        if ($ckName -eq 'Enter') {
                            $restartNow = $true
                            break
                        }
                    }
                } catch {}
            }
            Start-Sleep -Milliseconds 100
        }
        Write-Host ''

        if (-not $restartCancelled) {
            & "$sysDir\shutdown.exe" /r /t 5 /d p:2:2 /c "Windows Scan and Fix complete. Restarting your computer now..."
            return
        }

        Write-Host '  Automatic restart cancelled.' -ForegroundColor Gray
        $doRestart = $false
    }

    if (-not $doRestart) {
        if ($config.OpenReport) {
            $openTarget = if (Test-Path -LiteralPath $desktopReportPath) { $desktopReportPath } else { $archiveReportPath }
            try { Start-Process -FilePath $openTarget } catch {}
        }
        if ($memDiagScheduled -or $offlineChkdskScheduled) {
            Write-Host '  Note: Boot-time tests (Memory Diagnostic / CHKDSK) will run on your next manual restart.' -ForegroundColor Yellow
        }
        Write-Host ''
        if ($caps.UseVt) {
            $a = Get-TuiAnsi
            [Console]::Write($a.BgDark + '  ' + $a.KeyBold + 'enter ' + $a.KeyLabel + 'close' + $a.BgDark + $a.ClearLine + $a.Reset)
        } else {
            Write-Host '  enter close' -ForegroundColor Gray -NoNewline
        }
        $canReadKeys = $true
        try { if ([Console]::IsInputRedirected) { $canReadKeys = $false } } catch { $canReadKeys = $false }
        if ($canReadKeys) {
            while ($true) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq [ConsoleKey]::Enter -or $k.Key -eq [ConsoleKey]::Escape) { break }
            }
        } else {
            [void](Read-Host)
        }
        Write-Host ''
        return
    }
    } finally {
        try { [void][ScanExecutionState]::SetThreadExecutionState([ScanExecutionState]::Continuous) } catch {}
        Reset-TuiConsole
    }
}

if (-not $SkipRun) {
    Invoke-WindowsScanAndFix
}
