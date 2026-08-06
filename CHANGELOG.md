# Changelog

All notable changes to Vento. Versions follow [semantic versioning](https://semver.org).

Downloads for every release are on the [releases page](https://github.com/Henkerr/vento/releases).

---

## 1.2.2 — 2026-08-06

Autostart was in the app since 1.1.0, but nothing told you it was there and nothing told you
when it failed. This release makes it work by default.

### Added
- **The installer now offers "Start Vento automatically when Windows starts"**, checked by
  default. Previously the only way to find the setting was scrolling to the bottom of the
  Settings panel. The wizard hands the job to `app.ps1 -RegisterAutostart`, so the installer and
  the in-app checkbox go through the same code — and the app's own silent updater skips the
  step, so an autostart you switched off stays off.
- **`app.ps1 -RegisterAutostart` / `-UnregisterAutostart`** — registers or removes the logon task
  and exits, without loading the UI or touching the hardware.

### Fixed
- **A failed autostart registration was silent.** `Set-AutoStart` swallowed every exception in an
  empty `catch`, so ticking the checkbox and pressing Save looked identical whether the task was
  created or not. It now reports the error, shows it, and puts the checkbox back to the real
  state.
- **A logon task whose target folder had moved kept pointing at nothing**, so nothing started at
  sign-in. Vento now repairs the task at launch — but only when the registered path is actually
  gone, so a second copy you deliberately autostart is left alone.

### Changed
- The logon task waits **15 s** after sign-in before starting, so it no longer races the shell
  and the SuperIO driver, and it runs with the app folder as its working directory.
- Task settings gained `StartWhenAvailable` and `MultipleInstances = IgnoreNew`.
- The installer asset is now named `VentoSetup.exe` instead of `VentoSetup-x.y.z.exe`, so
  `releases/latest/download/VentoSetup.exe` always resolves to the current build.
- Project page at [henkerr.github.io/vento](https://henkerr.github.io/vento/).

---

## 1.2.1 — 2026-08-05

### Added
- The last fan mode you chose is saved and applied at startup. Automatic switches — game boost,
  the safety guard — do not overwrite the remembered choice.

### Fixed
- `settings.json` files still pointing the updater at the pre-release `blakfy/vento` repo, which
  never existed, are migrated to `Henkerr/vento`.

---

## 1.2.0 — 2026-08-05

### Added
- **Mode panel on the dashboard.** The active mode's settings — fan percentages, boost
  temperatures, curve points — sit right under the mode selector and apply to the fans while you
  drag, with a per-mode Reset button.
- **Fan activity graph** — 10 minutes of CPU and case fan RPM history.
- **Post-game cooldown** — 0–60 s of extra full-speed cooling after a game ends, with a live
  countdown in the status bar.

### Fixed
- Worker timing uses real elapsed time, so a forced sensor pass can no longer inflate the
  game-boost and cooldown accumulators.
- Pending debounced settings writes are flushed on exit instead of being lost.

---

## 1.1.0 — 2026-08-03

First public release. A single-file PowerShell 5.1 + WPF app driving motherboard fan channels
through LibreHardwareMonitor:

- Five modes — Quiet, Normal, Performance, Curve, Auto (BIOS).
- Quiet-mode cooling boost with hysteresis, and a GPU-load game boost.
- Temperature sparklines and a tray-first UI.
- Safety guard that forces Auto past a hard temperature limit.
- Silent auto-update from GitHub Releases.
- UAC-free autostart via a scheduled task.
- Inno Setup installer and a tag-driven release workflow.
