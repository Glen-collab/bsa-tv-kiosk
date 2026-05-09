# Retro Games + BSA Kiosk on One Pi 4

Planning doc — not yet implemented. Combines the workout-tracker
kiosk and the existing `pi_arcade_kiosk` project so one Pi 4 runs
both modes on the same gym TV.

---

## Goal

Make the gym Pi 4 dual-purpose:
- **Default:** BSA workout TV (`/tv/static`)
- **Toggle:** NES/SNES retro arcade
- Same hardware, same gamepad, same TV, no extra wiring

End-state: a coach plugs in the Pi → sees workouts. Holds a gamepad
combo → flips into games. Holds it again → back to workouts.

## What already exists

### `Glen-collab/bsa-tv-kiosk` (this repo)
- Chromium kiosk in respawn loop via `labwc-autostart`
- Captive portal for first-time WiFi/coach-code setup
- `bsa-kiosk-agent` polling backend for reboot/reload commands
- `install.sh` for one-command Pi setup

### `pi_arcade_kiosk` (Desktop, not yet a GitHub repo)
- Flask backend (`:8088`) serving a tile grid of ROMs
- `launcher/launch_game.sh` — auto-detects retroarch core, execs full-screen
- Frontend: HTML grid, click → POST `/api/launch` → spawn RetroArch
- ROMs in `roms/nes/`, catalog in `backend/games.json`
- Designed for Pi Zero 2 W; "drops onto Pi 4 with SNES + PS1" already
  noted as future work
- Currently a manual `sudo systemctl start pi-arcade` thing — not
  always-on

## Architecture for merging

Two viable paths:

### Path A: Mode switcher daemon (recommended)
- `labwc-autostart` boots Chromium kiosk as today (default = workouts)
- Add `bsa-mode-switcher.py` that watches `/dev/input/event*` for the
  gamepad and detects a hotkey combo (e.g., Start + Select held 3s)
- On combo: kill Chromium, start `pi-arcade` Flask + open Chromium
  pointed at `localhost:8088`
- Combo again: kill arcade Chromium, restart workout Chromium
- Flask + RetroArch never touch each other; switcher is a thin
  process-control layer
- ~50 lines of Python, one systemd unit

### Path B: Always-on launcher tile
- First screen on boot is a 2-tile picker ("Workouts" / "Games")
- Picks via gamepad/CEC remote
- Lower friction for end users discovering the modes
- Higher friction for daily use ("I just want my workout, why this
  picker first") — adds 1 click to every gym session

**Why Path A:** the gym is 95% workout TV, 5% maybe-someone-wants-to-play.
Default → workouts is the right boot state. Tile-picker is
extra-tap-tax on the common case. Combo-switch is invisible until
needed.

## Mode switcher — design sketch

```
/usr/local/sbin/bsa-mode-switcher.py
  ├── opens /dev/input/by-id/<gamepad>
  ├── tracks Start + Select held simultaneously
  ├── after 3000ms hold:
  │     reads /tmp/bsa-mode (default: "workouts")
  │     if workouts: stop labwc-autostart Chromium, start pi-arcade
  │                  service + launch Chromium @ localhost:8088
  │     if games:    stop pi-arcade + arcade Chromium, restart
  │                  workout Chromium
  │     writes new mode to /tmp/bsa-mode
  └── runs as user pi via systemd
```

Gamepad detection is by event code, not key — works with NES USB pads
(8-button) and Xbox-style pads alike. The combo "Start + Select" is
universal across retro-style USB pads.

## Phases

| # | Work | Effort |
|---|---|---|
| 1 | Move `pi_arcade_kiosk` into a GitHub repo (`Glen-collab/pi-arcade-kiosk`) | 30 min |
| 2 | Install RetroArch + cores on the Pi 4, validate NES + SNES | 1 hr |
| 3 | Decide ROM distribution model (see below) | discussion |
| 4 | Write `bsa-mode-switcher.py` + systemd unit | 2 hr |
| 5 | Add to `bsa-tv-kiosk/install.sh` behind `--with-games` flag | 30 min |
| 6 | Document mode-switch combo on first-boot setup screen | 30 min |
| 7 | Per-coach toggle in dashboard ("enable games on this kiosk") | 1 hr |

**Total:** ~6 hours of work spread across 2-3 sessions.

## Open questions

- **ROMs** — Glen owns the games legally (cartridges + dumps for
  personal use), but redistributing to coaches is a different legal
  posture. Options: customer brings their own ROM SD, Glen ships an
  ROM-loaded kit only to customers who own the cartridges, or skip
  games entirely on shipped kits and keep this as a Glen-only feature.
- **Performance** — Pi 4 handles NES/SNES at 60fps with rewind +
  shaders off. PS1 is borderline (Crash Bandicoot fine, Tekken 3 not).
  `pi_arcade_kiosk/ARCHITECTURE.md` already calls this out.
- **Audio** — gym TVs may not have audio enabled; mute by default in
  retroarch.cfg, customer un-mutes via TV's own remote.
- **Coach awareness** — should the dashboard show "this kiosk is in
  game mode" so the coach knows their workout TV is currently a NES?
  Probably yes; piggyback on existing kiosk-agent telemetry.
- **Workout interruption** — if a client is mid-workout and someone
  flips to games, do we save state? Currently the workout tracker is
  read-only on `/tv/static` — no client-side state to lose. Flip is
  safe.

## Out of scope (for this doc)

- EmulationStation / RetroPie integration — too heavy
- Online multiplayer / netplay — not needed
- ROM scraping / box art — `games.json` catalog is fine
- Save states UI — RetroArch defaults are fine, F2/F4 keys
- Steam-style game library cloud sync — not relevant

---

**Status:** scoping. Ready to start Phase 1 (move `pi_arcade_kiosk` to
GitHub) whenever Glen green-lights it.
