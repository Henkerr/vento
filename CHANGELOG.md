# Changelog

All notable changes to Vento. Versions follow [semantic versioning](https://semver.org).

Downloads for every release are on the [releases page](https://github.com/Henkerr/vento/releases).

---

## 1.4.2 — 2026-08-14

### Fixed
- **The tray icon is back.** The Sirocco rewrite lost the single line that assigns the icon to
  the NotifyIcon, and an icon-less NotifyIcon renders as nothing at all — Vento has been
  invisible in the tray since 1.4.0. Every "where is the tray icon" symptom traced back to
  this. Sorry.

---

## 1.4.1 — 2026-08-14

Tray and window reachability fixes, straight from the 1.4.0 field test.

### Fixed
- **Launching Vento while it is already running now brings the window forward** instead of
  showing a dead "already running" box. If the tray icon is hidden or lost, the Start Menu is
  always a way back to the window.
- **The tray icon survives Explorer restarts.** Vento runs elevated, so Explorer's
  `TaskbarCreated` broadcast never reached it and the icon stayed gone; the message is now let
  through and the icon re-registers itself.

---

## 1.4.0 — 2026-08-13

The Sirocco release: the whole window is now lit by the machine's thermal state. One position —
the hottest sensor's distance to its own comfort target — drives every color in the UI, smoothly
blended from a cool blue through warm coral to hot red.

### Added
- **Dynamic thermal palette.** Every brush in the window (background light, accents, cards,
  charts) is re-tinted continuously from the thermal position; no more fixed accent color.
- **Hero orb and halo gauge.** The hottest sensor's temperature sits in a glowing orb wrapped by
  a 240° arc that fills along the cool → warm → hot scale, with a state badge in the title bar
  and a one-line summary of what the fans are doing about it.
- **Fan rotor icons spin at the real fan RPM** on the CPU / case / GPU cards, and pause when a
  fan stops.
- **Sora typeface** (SIL OFL 1.1) is bundled and used for all UI text; the license is listed in
  THIRD-PARTY-NOTICES.md.
- **Mode panel slider tiles.** Each per-mode setting is an inset tile with the setting name, a
  large value and a full-width slider, instead of the old cramped label-slider-value rows.
- **COMFORT TARGETS settings section.** The per-sensor thresholds that drive the palette, the
  hero copy and the per-card warning chips are now sliders (CPU/GPU 50–80 °C, SSD/board
  45–75 °C). Defaults: 65/65/60/62.
- **Hardware model names are legible now** — larger, brighter, stripped of marketing prefixes
  ("NVIDIA GeForce RTX 2060 SUPER" → "RTX 2060 SUPER"), with the full name as a tooltip.
- **In-window update notice.** When a newer release exists, a notification card drops in from
  the top of the window ("Vento x.y.z is available — Install now / Later") and a clickable
  "UPDATE x.y.z" pill stays in the title bar. One click downloads and silently installs. The
  tray balloon was easy to miss and the tray menu item easy to never discover.
- **Fader-style sliders.** The filled side is an accent gradient and the handle is a slim pill
  instead of the stock ball, across the mode panel and the settings overlay.

### Changed
- The board card's default warning threshold moved from 50 °C to 62 °C — SuperIO board sensors
  idle in the high 50s on many boards, which parked the whole UI in the hot palette.
- The window is taller again (890 → 966 px) for the hero and the mode tiles.

### Fixed
- **Rendering cost dropped from about half a CPU core to ~5%.** The rotor and glow animations
  now composite cached bitmaps instead of re-rendering vector subtrees every frame, and are
  capped at 30 fps.

---

## 1.3.0 — 2026-08-10

The dashboard now covers the rest of the machine's temperatures: SSD and motherboard cards sit
right under CPU and GPU, in the same style.

### Added
- **SSD TEMPERATURE card** — same design as the CPU/GPU cards: big color-coded value, bar and a
  10-minute history sparkline, with the drive model underneath. When several drives are present
  the hottest one is shown; NVMe drives are preferred, SATA SSDs are the fallback, and spinning
  disks are excluded from the recurring poll so steady-state SMART reads can't keep a sleeping
  HDD awake (drive detection at launch still touches each disk once). Colors shift at 60/70 °C.
- **BOARD TEMPERATURE card** — motherboard temperature from the SuperIO chip in the same card
  style, colored at 50/60 °C, with the motherboard model underneath. Sensor names vary per chip,
  so Vento picks a plausible one automatically; a new file-only `"mbTempSensor"` key in
  `settings.json` overrides the choice (`"auto"` by default).

### Changed
- The window is taller (724 → 890 px) to make room for the new row; the fan activity graph keeps
  its size.

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
- The installer asset is now named `VentoSetup.exe` instead of `VentoSetup-x.y.z.exe`, so every
  release carries the same asset name.
- Added a project page under `docs/`, which points at the Releases page for downloads.

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
