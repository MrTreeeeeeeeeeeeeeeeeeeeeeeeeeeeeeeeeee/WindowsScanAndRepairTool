# Windows Scan & Fix Tool

A single, double-clickable script (`Windows_Scan_and_Fix.bat`) that runs built-in Windows health checks and repairs, restarts your computer to run a RAM test, and automatically opens a plain-English HTML report when you sign back in.

## How to Use

1. **Save any open work** before starting.
2. Double-click **`Windows_Scan_and_Fix.bat`**.
3. Click **Yes** on the Administrator (UAC) prompt.
4. Let it run — it starts after a 5-second countdown. Because it includes a **Microsoft Defender Full Scan**, expect **30 minutes to 2+ hours** depending on your drives.
5. When finished, it counts down **30 seconds** and **restarts automatically** to run the Windows Memory Diagnostic.
6. After you sign back into Windows, your finished **HTML report opens automatically** in your browser showing:
   - **What Was Fixed**
   - **Things You May Need to Look At**
   - **Detailed Results** for all 15 checks

> **Need to cancel?** Close the window or press `Ctrl+C` during the 5-second start countdown or the 30-second countdown before restart.

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
14. **Microsoft Defender Full Scan** — Updates virus definitions and runs a full antivirus scan (`Start-MpScan -ScanType FullScan`).
15. **Windows Memory Diagnostic** — Queues a one-time RAM test on restart (`mdsched.exe` / `{memdiag}`) and adds the result to your report after reboot.

## Where Reports Are Saved

- **Desktop:** `Windows_Scan_Report_<timestamp>.html`
- **Archive folder (next to the script):** `Reports\Run_<timestamp>\`
  - `Windows_Scan_Report.html` — Full interactive report
  - `energy-report.html` — Detailed `powercfg /energy` output
  - `battery-report.html` — Laptop battery report (when a battery is detected)
  - `raw_scan_log.txt` — Full raw console output from every step

## Requirements

- Windows 10 or Windows 11
- Administrator privileges (prompted automatically on double-click)
