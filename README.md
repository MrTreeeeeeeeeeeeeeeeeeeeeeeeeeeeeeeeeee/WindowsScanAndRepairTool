# Windows Scan & Fix Tool

`Windows_Scan_and_Fix.bat` is a single file you double-click to check and repair common Windows issues. It runs built-in Windows maintenance tools, shows live progress while it works, and opens a plain-English report in your browser showing what it fixed and what still needs your attention.

## Quick start

1. Save any open work before you begin.
2. Double-click `Windows_Scan_and_Fix.bat`.
3. Click **Yes** when Windows asks for administrator permission.
4. Choose a preset or customize the checks in the menu:
   - Press `Enter` on `[ START SCAN ]` (or press `S`) to run the default **Full Scan**.
   - Press `Q`, then `S` for a **Quick Tune-Up** if you do not want your PC to restart.
5. Wait for the scan to finish. A progress bar, elapsed timer, and per-step status update on screen while raw command output is saved silently to `raw_scan_log.txt`.

### What happens when it finishes

- **If "Restart PC When Done" is on:** A 30-second countdown starts so you have time to cancel (close the window or press `Ctrl+C`). Your PC then restarts to run the Windows Memory Diagnostic and opens the updated report automatically once you sign back in.
- **If "Restart PC When Done" is off:** The report opens right away with no restart.

## Presets and menu controls

The pre-run menu lets you toggle any of the 15 checks, choose whether to restart when done, and choose whether to open the report automatically.

### Presets

- **Full Scan (`F`, default):** Runs all 15 checks, including a Microsoft Defender Full Scan, the Windows Memory Diagnostic, and an automatic restart.
- **Quick Tune-Up (`Q`):** Takes about 10 to 15 minutes. Uses a Microsoft Defender Quick Scan and skips the 60-second energy trace, the RAM test, and the reboot.

### Keyboard controls

| Key | Action |
|---|---|
| `Up / Down` | Move through the 15 checks and bottom options |
| `Space / Enter` | Turn a check or option on (`[x]`) or off (`[ ]`); on Microsoft Defender, cycles `FullScan` / `QuickScan` / `Off` |
| `Left / Right` | Cycle Microsoft Defender mode when highlighted |
| `S` (or `Enter` on `[ START SCAN ]`) | Start the scan |
| `F` / `Q` | Switch to Full Scan or Quick Tune-Up |
| `A` / `N` | Select all or deselect all checks |
| `Esc` | Exit without making changes |

## What it checks and fixes

Each step matches its number in the menu.

### Hardware, power, and crashes

1. **Physical Disk Health & Free Space:** Checks drive health, SMART counters (temperature, SSD wear, read/write errors), and low free disk space (`Get-PhysicalDisk`).
2. **Power, Energy & Battery:** Runs a 60-second idle energy trace (`powercfg /energy`) and creates a laptop battery health report (`powercfg /batteryreport`) if a battery is present.
3. **Reliability History & Crash Logs:** Reads your Windows stability score, recent crashes, and failed updates (`perfmon /rel`), plus 30-day hardware/disk error events (WHEA) and blue-screen minidumps (BSOD).
4. **Device Manager Drivers:** Looks for hardware devices with missing or broken drivers.

### Security and Windows repair

5. **Windows Security & Memory Integrity:** Checks Core Isolation Memory Integrity (HVCI), Windows Firewall profiles, and Defender Real-Time Protection.
6. **WMI Repository Repair:** Verifies the WMI database (`winmgmt /verifyrepository`) and repairs it with `/salvagerepository` if it is inconsistent.
7. **DISM Component Store Scan:** Scans the Windows system image for corruption (`DISM /Online /Cleanup-Image /ScanHealth`).
8. **DISM Repair & Cleanup:** Repairs component store corruption (`DISM /RestoreHealth`) and removes leftover files from superseded updates (`DISM /StartComponentCleanup`).
9. **System File Integrity:** Scans and repairs protected Windows system files (`sfc /scannow`).
10. **All Connected Drives Scan:** Runs `chkdsk /scan` on all mounted NTFS drives (and standard `chkdsk` on FAT32/exFAT drives). If the system drive needs an offline fix, it queues a boot-time repair.

### Cleanup, network, and final scans

11. **SSD TRIM & Safe Temp Cleanup:** Runs TRIM optimization on SSDs (`Optimize-Volume -ReTrim`) and deletes temporary files older than 24 hours.
12. **Network, DNS & Clock Sync:** Clears DNS (`ipconfig /flushdns`), resets Winsock (`netsh winsock reset`, which keeps your Wi-Fi passwords and static IPs), and syncs the system clock (`w32tm /resync`).
13. **Core Windows Services:** Starts stopped core services (Event Log, DNS, DHCP, Firewall, Defender) and checks Windows Update service health.
14. **Microsoft Defender Scan:** Updates virus definitions and runs a Full or Quick antivirus scan (`Start-MpScan`).
15. **Windows Memory Diagnostic:** Queues a one-time RAM test on restart (`mdsched.exe` / `{memdiag}`) and adds the result to your report after reboot.

## Where reports are saved

A copy of your report goes straight to your Desktop, and a full archive is saved next to the script:

- **Desktop:** `Windows_Scan_Report_<timestamp>.html`
- **Archive folder:** `Reports\Run_<timestamp>\`
  - `Windows_Scan_Report.html`: Full interactive report (*What Was Fixed*, *Things You May Need to Look At*, and expandable details)
  - `energy-report.html`: Detailed `powercfg /energy` output
  - `battery-report.html`: Laptop battery report (when a battery is detected)
  - `raw_scan_log.txt`: Full raw console output from every step

## Requirements

- Windows 10 or Windows 11
- Administrator privileges (prompted automatically on double-click)
