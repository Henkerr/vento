# Changelog

All notable changes to Vento. Versions follow [semantic versioning](https://semver.org).

Downloads for every release are on the [releases page](https://github.com/Henkerr/vento/releases).

---

## 1.8.5 — 2026-10-28

Lights page: the color loop editor gets its own color picker, and a strip that stopped advertising
is reconnected directly. Nothing changes for anyone else.

---

## 1.8.4 — 2026-10-28

The Lights page could not reach Bluetooth in 1.8.3; fixed. Nothing changes for anyone else.

---

## 1.8.3 — 2026-10-28

Fixes for the opt-in Lights page: the right brightness command, only the effects the strip runs,
and sliders that send once you let go instead of flooding the strip. Nothing changes for anyone else.

---

## 1.8.2 — 2026-10-28

Groundwork for an opt-in page for a Bluetooth LED strip. It stays hidden unless switched on for this PC,
so nothing changes for anyone else. The tray flyout and every other page are as in 1.8.1.

---

## 1.8.1 — 2026-10-27

Every page, live. The new design now drives everything the old window did, and a bit more.

### Added
- **Fans:** each mode's sliders, the Quiet cooling boost, a drag-the-points curve editor showing
  where the fans sit right now, and a 10-minute activity chart. Reset to defaults per mode.
- **Alerts:** comfort targets, safety limits (named after your actual CPU and GPU), game
  detection (switch to Performance or Curve, how busy the GPU must be, how long to keep going
  after), and a switch for Windows notifications with a test button.
- **Profiles:** cards for every profile with Apply and Edit, a New profile dialog (name, color,
  fans, overlay, display preset), rename and delete for your own profiles, and profile chips on
  Home. The tray menu and the hotkey stay in step.
- **Displays:** a card per monitor read over DDC/CI - brightness, contrast, color preset, input
  (with a 12-second automatic way back), and *More controls* for sharpness, volume, RGB gain,
  picture mode, resets and power. Presets in one tap, your own presets with +, match brightness
  across displays, the night schedule, and Identify.
- **Overlay:** layout, the metrics and a color for each, theme, corner, size, opacity, drag it
  anywhere on screen, show mode, hide from capture, second display - with a live preview.
- **Settings:** record shortcuts right in the list (conflicts are named on the row), start with
  Windows, start in the tray, keep running in the tray, sensor refresh rate, automatic updates
  and a *Check for updates* button - also in the tray menu.
- **Tray flyout:** a left click on the tray icon opens a Quick Settings style panel with the fan
  modes, overlay, this mode's case fan speed, temperatures and your device's battery. The expand button in its corner opens the full window.
- **Fan driver watch:** if the PawnIO driver goes missing, Home says so (and Windows notifies),
  offers to install the official package, and asks for a restart once it is back.
- **Every connected Bluetooth device** now shows on Home and the Devices page, with the battery
  level Windows reports for it - headphones, mice, keyboards, controllers. Paired devices that
  aren't connected stay out of the list. AirPods add left / right / case from their own
  broadcast, and **Check now** reads them on the spot.
- **Low-battery alert** for any connected device, with your own threshold and an on/off switch,
  and a choice of how often Vento checks in the background.
- **Pick the Home temperature.** Click the label above the big number: hottest (automatic), CPU,
  GPU, SSD or motherboard.

### Fixed
- The Home Devices card showed AirPods even when they weren't connected.

---

## 1.8.0 — 2026-10-27

A new look, built like Windows 11.

### Added
- **Glass main window.** Mica backdrop, a Settings-style side menu and your Windows accent
  color, updated live when you change it. Pick Mica, Mica Alt or Acrylic in Settings.
- **New Home.** The hottest sensor against its comfort target, a 10-minute chart, headroom
  meter, every sensor and fan at a glance, and one-click fan modes.
- **AirPods battery** on Home, with an on-demand Bluetooth listener and a battery-only tray
  flyout.
- **New logo and app icon.**

### Known gaps
- This is the first stage of the redesign: Home is fully live. Fans, Alerts, Profiles,
  Displays, Devices, Overlay and Settings pages show the new design and are being wired to
  the engine in the next updates. Your existing settings, hotkeys, overlay and profiles
  keep working in the background.

---

## 1.7.3 — 2026-09-03

The sleep fix that actually reaches the chip.

### Fixed
- **Fans really do return to your mode after sleep now.** The previous wake fixes re-applied
  your fan mode, but the monitoring library underneath skips hardware writes when it believes
  the value hasn't changed — and after sleep the chip has forgotten the setting while the
  library still remembers it. Those re-applies never reached the hardware, which is exactly
  why switching modes by hand always worked. The wake-up path now drops fan control to its
  default first, so the re-apply is a real mode change and a real write. Verified against
  the library's source, and re-asserted at 5, 15 and 45 seconds after wake for good measure.

---

## 1.7.2 — 2026-09-01

Steadier wake-ups and instant displays.

### Fixed
- **Fans now really return to your mode after sleep.** The wake-up re-apply used to fire
  once, so early that the motherboard's own resume would quietly override it back to full
  speed — Vento now re-asserts your fan mode a few more times while the machine settles.
- **The overlay no longer vanishes mid-game on a single failed sensor read** — a momentary
  GPU-load hiccup now gets the same 60-second grace as menus and loading screens.
- Long display scene names on profile tiles (like CINEMA) are no longer cut off — the tile
  summary got its own second line.
- If the overlay window can't be created, Vento now writes the reason to error.log instead
  of retrying silently forever.

### Changed
- **Displays re-opens in a fraction of the time.** Vento now remembers each display's
  verified control set for the session, so re-opening the panel only re-reads the current
  values — about five times faster on real hardware. A discovery that looks glitchy is
  never memorised; the next open probes in full again.
- The installer now asks you to close a running Vento instead of overwriting its files in
  use, and states Windows 10 or newer as required.

---

## 1.7.1 — 2026-08-29

Polish and fixes for the 1.7 features.

### Changed
- **Displays open faster.** Each monitor's map and sliders now appear the moment its
  brightness is read, instead of waiting for the full control probe to finish — the panel
  fills in the advertised controls a moment later rather than showing nothing for a few seconds.
- **Shortcut keys are shown as keycaps.** The Shortcuts section now shows `Ctrl` `Alt` `Shift`
  `Win` `Esc` `Del` as little keyboard keys instead of a wordy sentence.

### Fixed
- **Naming a profile after an existing one no longer deletes the other one.** Vento now asks
  for a different name instead of silently overwriting. Built-in profiles (GAMING / MOVIE /
  WORK) can be re-tuned but not renamed, so they can't be lost or duplicated.
- **Applying a profile from the Settings panel no longer loses its overlay choice** when you
  then press Save.
- **Clearer shortcut messages** — a combination shared by two Vento shortcuts is now called out
  separately from one already claimed by another app.
- Hardening around the display read so a rescan can't stall the panel or drop the selected
  display, and a mid-read fault can't wedge it on "Reading monitors…".

---

## 1.7.0 — 2026-08-28

One name for the whole machine.

### Added
- **Vento profiles.** A profile is your whole setup under one name — a fan mode, the
  overlay, and a display scene, switched together. **GAMING**, **MOVIE** and **WORK** come
  built in; make your own with any name and colour under Settings › Profiles. Switch from the
  new **Profiles** submenu in the tray, or bind a key to cycle through them. Profiles reference
  the display scenes you already have (DAY, GAME, …) rather than replacing them.
- **Global shortcuts.** Bind keys that work anywhere, even inside a game — toggle the overlay,
  jump straight to Quiet / Normal / Performance / Auto, or cycle your Vento profiles. Set them
  under Settings › Shortcuts: click a field and press the combination (a modifier is required).
- **Hide the overlay from screen capture.** A new option under Settings › Overlay keeps the
  overlay on your screen but out of every recording, stream and screen share — your
  temperatures and system info never leak to an audience. (Windows 10 2004 or newer.)

### Changed
- The tray menu now carries a **Profiles** submenu, next to the fan modes.

### Fixed
- **The right GPU on multi-GPU machines.** On laptops with both an integrated and a discrete
  chip — and on desktops with more than one card — Vento could latch onto the idle integrated
  GPU and report its temperature instead of the card actually doing the work. It now scores
  every GPU it finds (real temperature sensor, live load, discrete name) and reads the one
  that's genuinely in use.
- **A single bad sensor no longer stops monitoring.** Each device is now read on its own, and
  a stray error on any one tick is caught and written to `error.log` instead of taking the
  whole loop down — so one flaky reading can't freeze the temperatures and fan control for
  everything else.
- **Downloaded updates are verified before they run.** Each release now ships a SHA-256
  checksum, and Vento checks the file it downloaded against it. If they don't match, the
  download is refused and Vento points you to the release page to update by hand.

### Changed
- **Fits on short screens.** On small laptops and low-resolution displays where the window ran
  past the bottom edge, Vento now scales itself down to fit the available height. Normal-height
  screens are untouched.

---

## 1.6.1 — 2026-08-28

### Fixed
- **Fans stayed loud after waking from sleep.** On resume the motherboard hands its fan
  channels back to the BIOS (often full speed), and Vento only re-applied a fixed mode when
  the mode changed — so Quiet stayed loud until you toggled the mode. Vento now notices the
  wake and re-applies the active mode on its own.

### Changed
- The README now covers everything Vento does — the overlay and FPS, display control, and
  notifications — not just the fans.

---

## 1.6.0 — 2026-08-28

Frames.

### Added
- **Frame rate (FPS) in the overlay.** A new metric shows the real per-game frame rate,
  measured the way PresentMon does — a live ETW trace of the display present stream, counted
  per process. No bundled tools and no vendor SDK, so it works on any GPU; verified against
  NVIDIA's own counter in-game to the frame. The number follows the focused game (or the
  busiest thing presenting behind a borderless overlay) and never counts Vento itself. Turn
  it on under Settings › Overlay; it leads the overlay as its hero metric. If another tracing
  tool has claimed all of Windows' trace sessions, or an anti-cheat blocks the trace, FPS
  quietly reads `--` rather than failing.

---

## 1.5.0 — 2026-08-21

The assistant release: Vento steps beyond the fans.

### Added
- **In-game overlay (OSD), fully yours.** A click-through, always-on-top readout with seven
  layouts (Blade, Strip, Hero, Pills, Ghost, Micro, Thermo Edge), six themes (Sirocco Ice,
  Ember, Venom, Violet Drive, Crimson, Mono) that walk their own cool/warm/hot accents with
  the thermal state, and per-metric custom colors on top. Metrics are toggleable — CPU/GPU/
  SSD/board temperatures, GPU load, RAM usage, fan speeds. Pick the corner, scale it 75–200%,
  park it on the secondary monitor, or flip it from the tray menu. Shows automatically while
  a game is running ("While gaming"), always, or never. Every choice is remembered. Works
  over borderless and windowed games; true exclusive fullscreen hides any overlay.
- **Monitor control over DDC/CI.** A new MONITORS panel (title-bar button next to Settings)
  drives every connected display over the same channel its own buttons use. Values are read
  fresh from the monitors on every open, and only the controls a display actually advertises
  are shown.
  - **Your desk, drawn to scale.** The displays appear in the panel exactly as they sit on
    the desktop — right sizes, right positions, the primary marked. Each screen carries its
    own brightness: the number large in the middle, its blade docked along the bottom edge.
    Click a screen to point the rest of the panel at it; IDENTIFY blinks them so the numbers
    on the map can be matched to the panels on the desk.
  - **Contrast, color presets and input source** for the selected display, with the live
    refresh rate and active input read from the monitor itself.
  - **An ADVANCED sheet** for the deeper controls: the display's own picture modes
    (Productivity, Movie, Games, Professional and whatever else it offers), a continuous
    color-temperature slider in kelvin, per-channel RGB gain, sharpness, speaker volume and
    mute, restore factory colors or levels, a guarded factory reset, and switching the
    display off from software.
  - **Display profiles.** DAY, NIGHT, CINEMA and GAME apply a brightness/contrast/color-preset
    recipe in one tap — to every display or only the selected one, your choice — each with its
    own identity color that tints the panel while it is active. Add your own with + NEW: name
    it, pick any color, and it stores what the displays are showing right now; right-click any
    profile to rename, recolor, re-capture or delete it.
    The built-in recipes are not invented numbers: brightness tracks the room (~120–150 cd/m²
    lit, 80–100 cd/m² dark, and 100 cd/m² for film, the ITU-R BT.2035 reference viewing
    environment), contrast stays at the factory value because raising it past default clips
    highlight detail, and 6500 K is the D65 white point sRGB, Rec.709 and DCI-P3-D65 all
    master to. NIGHT's warmer 5000 K is a deliberate comfort choice.
  - **Night shift.** A schedule band shows the whole day as a 24-hour timeline with the night
    window lit and a blade at the current time. Inside the window Vento applies the night
    profile; on the way out it restores whatever was active before.
  - A sync switch still makes one set of sliders drive every display at once, and the footer
    reports what the display says about itself — panel type, hours powered on, MCCS version,
    and how many controls it exposes.
  - **Safety.** Vento only ever writes control codes a display advertises, and never writes
    into the manufacturer-private range, where vendors keep service menus and, on some models,
    panel locks. Switching input reverts itself after twelve seconds unless you keep it, so a
    display that lands on a dead port comes back on its own. Turning a display off prefers the
    sleep that wakes with video; when a display only offers a hard power-down, the button says
    so. Factory reset asks first.
- **Game action is now a choice.** When a game is detected, Vento can switch to Performance
  (as before), follow the temperature Curve, or do nothing — picked in Settings. Old
  `gameBoost` settings migrate automatically (on → Performance, off → Do nothing).

- **The overlay moves and fades on your terms.** "Move overlay" in the tray menu (or MOVE
  FREELY in Settings) unlocks the HUD in place: it grows a dashed frame, drags anywhere with
  the mouse — any screen, any spot — and the scroll wheel sets its opacity while you watch.
  Tap its ✓ DONE pill and it locks back to click-through. The dragged position sticks across
  restarts; picking a corner in Settings snaps it back. Opacity also lives in Settings as a
  slider (30–100%) that previews live on the real overlay. And the overlay carries its own
  handle: rest the mouse on it for a moment and a small pin fades in — click it and you are
  moving. Games hide or capture the cursor, so the pin never appears mid-game.
- **RAM temperature, where the sticks report one.** Modules with an SPD thermal sensor
  (every DDR5 stick, some DDR4) now feed the overlay's RAM readout: it shows usage and the
  hottest module together. Sticks without a sensor simply keep the plain usage number.
- **Real Windows notifications.** A new version and a temperature warning now arrive as
  proper toasts: they wait in the notification centre instead of flashing for a few seconds,
  and the update toast carries an **Install now** button that starts the update straight from
  the notification. Machines where toasts are unavailable fall back to the old tray balloon.

### Changed
- Game detection itself now runs independently of the chosen action, so the overlay's
  "While gaming" mode works even when the fans are left alone.

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
