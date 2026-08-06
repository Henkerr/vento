<div align="center">

<img src="assets/logo.png" width="128" alt="Vento">

# Vento

**Fan monitoring and control for Windows**

[![Windows](https://img.shields.io/badge/Windows-10%2F11-blue?logo=windows)](https://github.com/Henkerr/vento)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

### [⬇ Download Vento](https://github.com/Henkerr/vento/releases/latest/download/VentoSetup.exe)

<sub>Windows 10/11 · needs administrator rights for the fan sensors · updates itself from then on</sub>

<sub>Or use the [download page](https://henkerr.github.io/vento/) — one button, with the install steps.</sub>

</div>

A lightweight fan monitoring and control panel for Windows that lives in your system tray.

Vento reads CPU/GPU temperatures and fan speeds through [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) and drives the motherboard's fan channels with five modes — including a Quiet mode that temporarily boosts the fans when things get hot and drops back down once they cool.

## Features

- **Live dashboard** — CPU/GPU temperature with color-coded bars, 10-minute history sparklines, CPU / case / GPU fan RPM.
- **Five fan modes** — Quiet, Normal, Performance, Curve (temperature-based fan curve over 40/55/70/80 °C points), Auto (BIOS curve). Switchable from the window or the tray menu; the last chosen mode is restored at launch.
- **Cooling boost (Quiet mode)** — when CPU or GPU passes a threshold (default 75 °C) the case fans ramp up; once temps fall below the resume threshold (default 65 °C) they return to Quiet speed. Hysteresis prevents oscillation.
- **Game boost** — sustained GPU load (default >80 % for 30 s) switches to Performance automatically and returns to your previous mode after 2 minutes of idle, with a configurable post-game cooldown (default 15 s of extra full-speed cooling) before handing back. Forgetting to change modes before a game is no longer a problem.
- **Mode panel** — the dashboard shows the active mode's settings right under the mode selector: fan percentages, boost temperatures, or curve points depending on the mode. Slider changes apply to the fans instantly, and a Reset button restores that mode's defaults. A live graph tracks CPU and case fan RPM over the last 10 minutes.
- **Start with Windows without UAC prompts** — offered as a checkbox in the installer and in Settings. It registers a highest-privilege scheduled task, so logon skips the elevation dialog; the app starts 15 s after sign-in and repoints the task at itself if the folder ever moves.
- **Auto-update** — checks GitHub Releases at launch; one tray click downloads the new installer and updates silently.
- **Safety guard** — in any manual mode, if CPU/GPU exceeds a hard limit (default 85/83 °C) Vento forces Auto and notifies you.
- **System tray** — close/minimize hides to tray; tray tooltip shows live temps; right-click menu switches modes; optional start-minimized.
- **Customizable** — fan speeds per mode, boost thresholds, safety limits, update interval, accent color, tray behavior. All in the in-app Settings panel, persisted to `settings.json`.
- **Portable** — a folder, a script, and the sensor DLLs. Nothing is written outside the app folder, except the optional "Start with Windows" scheduled task and update downloads in `%TEMP%`.

## Requirements

- Windows 10/11, PowerShell 5.1 (built in)
- Administrator rights (required for SuperIO sensor access)
- .NET Framework 4.7.2+ (built into Windows 10/11)

## Getting started

**Installer (recommended):** download [`VentoSetup.exe`](https://github.com/Henkerr/vento/releases/latest/download/VentoSetup.exe) and run it. You get Start Menu / desktop shortcuts, a run-at-startup task (checked by default, changeable later in Settings), and a clean uninstaller.

**From source:** clone the repository and double-click `Vento.vbs` (or build `Vento.exe`, see below), then accept the admin prompt.

## Building

No SDK needed — everything uses tools already on Windows (plus Inno Setup for the installer):

```powershell
build\make-icon.ps1     # regenerates assets\vento.ico + assets\logo.png
build\build-exe.ps1     # compiles Vento.exe (launcher with icon + UAC manifest)
ISCC.exe installer\vento.iss   # builds dist\VentoSetup.exe (Inno Setup 6)
```

Release history is in [CHANGELOG.md](CHANGELOG.md).

## Configuration

Everything editable in the UI is stored in `settings.json` (created on first save). Two extra keys are file-only, for remapping which SuperIO channels drive which fans on your board:

```json
{
  "cpuFanChannel": "Fan #1",
  "caseFanChannel": "Fan #2"
}
```

If a named channel doesn't exist, Vento falls back to the first/second fan channel it finds. All remaining channels are left on the BIOS default curve.

## Safety notes

- The case fan hub is never driven below 20 %, the CPU fan never below 30 %.
- On exit (including crashes) all fan channels are handed back to the BIOS.
- Vento refuses to run alongside FanControl — two programs writing to the same SuperIO registers is a bad idea.

## How it works

One script, two threads: an MTA runspace owns LibreHardwareMonitor exclusively (polling sensors and applying modes), while the STA thread runs the WPF window and tray icon. They communicate through a synchronized hashtable — the UI never touches the hardware directly.

## License

Vento is MIT-licensed — see [LICENSE](LICENSE).
Bundled third-party libraries in `lib/` (LibreHardwareMonitorLib and dependencies) have their own licenses — see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
