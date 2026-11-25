# Windows Scan & Fix Tool

A single, double-clickable CLI app (`Windows_Scan_and_Fix.bat`) with an interactive pre-run options menu and live progress dashboard. It runs built-in Windows health checks and repairs, optionally restarts your computer to run a RAM test, and opens a plain-English HTML report showing what was fixed and anything that needs your attention.

## How to Use

1. **Save any open work** before starting.
2. Double-click **`Windows_Scan_and_Fix.bat`**.
3. Click **Yes** on the Administrator (UAC) prompt.
4. In the **interactive settings list**, use your **Up/Down arrow keys** to move through the checks and options, and press **Space** or **Enter** to check/uncheck items (or just press **Enter** on **`[ START SCAN ]`** to run with the default Full Scan preset):
   - **`Up / Down`** — Move through all 15 checks, **Restart PC When Done**, and **Open HTML Report Automatically**
   - **`Space / Enter`** — Toggle `[x]` / `[ ]` (on Microsoft Defender, cycles `FullScan` / `QuickScan` / `Off`; `Left / Right` arrows also cycle it)
   - **`S`** (or **`Enter`** on **`[ START SCAN ]`**) — Start the scan
   - **`F`** — Full Scan preset (all 15 checks, Defender Full Scan, Memory Test, auto-restart)
   - **`Q`** — Quick Tune-Up preset (~10–15 min, Defender Quick Scan, skips 60s energy trace & reboot)
   - **`A` / `N`** — Select All / Deselect All (**`Esc`** to exit)
5. Watch progress in the **live CLI dashboard** (overall progress bar, color-coded step statuses, spinner, elapsed timer, and live percentages — raw tool output is captured silently to `raw_scan_log.txt`).
6. When finished:
   - If **Restart = Yes**: counts down **30 seconds** (close the window or press `Ctrl+C` to cancel), restarts to run the Windows Memory Diagnostic, and automatically opens the updated HTML report once you sign back in.
   - If **Restart = No**: opens the HTML report right away without restarting.

## What It Checks & Fixes (15 Steps)

1. **Physical Disk Health & Free Space** — Checks drive health, SMART counters (temperature, SSD wear, read/write errors), and low free disk space (`Get-PhysicalDisk`).
2. **Power, Energy & Battery** — Runs a 60-second idle energy trace (`powercfg /energy`) and generates a laptop battery health report (`powercfg /batteryreport`) if a battery is present.
3. **Reliability History & Crash Logs** — Reads Reliability Monitor stability score and recent crashes/failed updates (`perfmon /rel` data), plus 30-day WHEA hardware/disk error events and BSOD minidumps.
4. **Device Manager Drivers** — Checks for hardware devices with missing or broken drivers.
5. **Windows Security & Memory Integrity** — Checks Core Isolation Memory Integrity (HVCI), Windows Firewall profiles, and Defender Real-Time Protection.
6. **WMI Repository Repair** — Verifies the WMI database (`winmgmt /verifyrepository`) and repairs it with `/salvagerepository` if inconsistent.
7. **DISM Component Store Scan** — Scans the Windows system image for corruption (`DISM /Online /Cleanup-Image /ScanHealth`).
8. **DISM Repair & Cleanup** — Repairs component store corruption (`DISM /RestoreHealth`) and cleans superseded update bloat (`DISM /StartComponentCleanup`).
9. **System File Integrity** — Scans and repairs protected Windows system files (`sfc /scannow`).
10. **All Connected Drives Scan** — Runs `chkdsk /scan` on all mounted NTFS drives (and standard `chkdsk` on FAT32/exFAT drives), queuing boot-time repair if the system drive needs an offline fix.
11. **SSD TRIM & Safe Temp Cleanup** — Runs TRIM optimization on SSDs (`Optimize-Volume -ReTrim`) and removes temporary files older than 24 hours.
12. **Network, DNS & Clock Sync** — Flushes DNS (`ipconfig /flushdns`), resets Winsock (`netsh winsock reset` — preserves Wi-Fi passwords and static IPs), and syncs system time (`w32tm /resync`).
13. **Core Windows Services** — Automatically starts stopped core services (Event Log, DNS, DHCP, Firewall, Defender) and checks Windows Update service health.
14. **Microsoft Defender Scan** — Updates virus definitions and runs a Full or Quick antivirus scan (`Start-MpScan`).
15. **Windows Memory Diagnostic** — Queues a one-time RAM test on restart (`mdsched.exe` / `{memdiag}`) and adds the result to your report after reboot.

## Where Reports Are Saved

- **Desktop:** `Windows_Scan_Report_<timestamp>.html`
- **Archive folder (next to the script):** `Reports\Run_<timestamp>\`
  - `Windows_Scan_Report.html` — Full interactive report (*What Was Fixed*, *Things You May Need to Look At*, and expandable details)
  - `energy-report.html` — Detailed `powercfg /energy` output
  - `battery-report.html` — Laptop battery report (when a battery is detected)
  - `raw_scan_log.txt` — Full raw console output captured silently from every step

## Requirements

- Windows 10 or Windows 11
- Administrator privileges (prompted automatically on double-click)
