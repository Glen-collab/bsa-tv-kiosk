# BSA Kiosk → Retro Arcade Integration

The gym TV Pi can flip from the workout-TV view (default) into a
NES or SNES arcade picker, driven from the admin's GymTV dashboard
page. Built and tested 2026-05-13. See git log on the three repos
below for individual commits.

## What this gives you

- **Phone → TV flip.** Admin opens `app.bestrongagain.com/gym-tv` on
  their phone, sees a per-device **Game Mode** card with NES / SNES /
  Stop buttons (admin-role only). Tap NES → within ~10s the gym TV
  flips to the NES picker.
- **Arcade-cabinet UX on the TV.** Press Start 2P pixel font, neon
  red (NES) / purple (SNES) accent, CRT scanlines, focused-tile glow.
- **D-pad / keyboard navigation.** Spatial selection (nearest tile in
  requested direction); arrows or D-pad to move, Enter / A to launch,
  Esc / B jumps to the **← Back to Workouts** tile.
- **Attract mode.** Picker sits idle 30s → Pi auto-launches the next
  game in a curated demo rotation (DK Country, Super Metroid, etc.).
  F4 a demo → picker resumes → 30s of grace → next demo. Real arcade
  behavior.
- **Play counts.** Persistent in `~/pi_arcade_kiosk/backend/plays.json`.
  Top 20 most-played section above the A-Z grid.

## Three-repo architecture

```
[admin phone] ────────────────────────────────────────────────────┐
       │ tap ▶ NES                                                │
       ▼                                                          │
[bsa-coach-platform]   POST /api/kiosk/device/set-display          │
   backend/kiosk.py    { device_id, mode: "game_nes" }             │
   migrations/019      UPDATE coach_devices SET display_mode=...   │
       │                                                          │
       │ next 10s poll                                            │
       ▼                                                          │
[bsa-tv-kiosk]         GET /api/kiosk/tv-config?coach=&device=     │
   bsa-kiosk-agent.py  → sees display_mode change                  │
       │                                                          │
       ▼                                                          │
   switch-to-arcade.sh nes                                         │
     • pkill retroarch                                             │
     • echo "arcade-nes" > /tmp/bsa-mode                           │
     • sudo systemctl start pi-arcade.service                      │
     • TCP probe :8088 (≤3s)                                       │
     • pkill chromium                                              │
       │                                                          │
       ▼                                                          │
   labwc-autostart respawn loop                                    │
     • pick_url reads /tmp/bsa-mode                                │
     • returns http://localhost:8088/?system=nes                   │
     • chromium relaunches into the arcade picker                  │
       │                                                          │
       ▼                                                          │
[pi-arcade-kiosk]    Flask serves the picker (port 8088)           │
   backend/app.py    scans ~/pi_arcade_kiosk/roms/{nes,snes}/      │
   frontend/         old-arcade UI; gamepad + keyboard nav         │
       │                                                          │
       │ user picks a tile (or attract timer fires)                │
       ▼                                                          │
   POST /api/launch  → subprocess.Popen([LAUNCHER, system, rom])   │
       │                                                          │
       ▼                                                          │
   launcher/launch_game.sh                                         │
     • exports XDG_RUNTIME_DIR + WAYLAND_DISPLAY                   │
     • exec retroarch -L <core>.so <rom_path>                      │
       │                                                          │
       ▼                                                          │
   RetroArch full-screens, overlays Chromium                       │
                                                                  │
[exit path] ← user clicks "← Back to Workouts" tile               │
   POST /api/exit-to-workouts                                     │
     • Flask calls public /api/kiosk/exit-game-mode (syncs DB)─────┘
     • exec /usr/local/sbin/switch-to-workouts.sh
       • rm /tmp/bsa-mode
       • pkill retroarch + chromium
       • sudo systemctl stop pi-arcade.service
       • labwc respawns chromium into workout URL
```

## Repos + key files

### Glen-collab/bsa-coach-platform (EC2)

| File | What it does |
|---|---|
| `migrations/019_kiosk_game_mode.sql` | Adds `game_nes` / `game_snes` to `coach_devices.display_mode` CHECK |
| `backend/kiosk.py` | `device_set_display` accepts the new modes; new public `exit_game_mode` endpoint for Pi-driven exits |
| `src/components/GameModeCard.jsx` | Admin GymTV card — wired to `api.kioskDeviceSetDisplay`. Stop button disabled unless `display_mode IN (game_nes, game_snes)` |
| `src/pages/GymTV.jsx` | Renders `<GameModeCard>` admin-only; passes `load()` as `onChange` so the card refreshes after a flip |

Deploy: `scp backend/kiosk.py` + `npm run build && scp -r dist/* …`
then `sudo systemctl restart bestrongagain.service`.

### Glen-collab/bsa-tv-kiosk (Pi)

| File | What it does |
|---|---|
| `files/bsa-kiosk-agent.py` | Polls `/tv-config` every 10s; on `display_mode` transition, execs the right script. Identity = (coach_code, /proc/cpuinfo serial) |
| `files/switch-to-arcade.sh` | Writes `/tmp/bsa-mode = arcade-<sys>`, starts pi-arcade, pkills retroarch + chromium |
| `files/switch-to-workouts.sh` | Clears `/tmp/bsa-mode`, pkills retroarch + chromium, stops pi-arcade |
| `files/labwc-autostart` | `pick_url()` reads `/tmp/bsa-mode` first; values `arcade-nes` / `arcade-snes` return the Pi Arcade Flask URL |
| `files/010_pi-kiosk-agent` | Sudoers — adds `systemctl start/stop pi-arcade.service` to NOPASSWD list |
| `install.sh` | Idempotent installer; lays scripts at `/usr/local/sbin/` |

Deploy: `cd ~/bsa-tv-kiosk && git pull && sudo bash install.sh`
then `sudo systemctl restart bsa-kiosk-agent`.

### Glen-collab/pi-arcade-kiosk (Pi — separate install)

| File | What it does |
|---|---|
| `backend/app.py` | Flask on :8088. Routes: `/api/games`, `/api/launch`, `/api/quit`, `/api/status`, `/api/exit-to-workouts` |
| `backend/games.json` | Optional per-ROM title/description overrides (auto-derived from filename otherwise) |
| `backend/plays.json` | Persistent play counts |
| `launcher/launch_game.sh` | Maps system → libretro core (`nestopia` for NES, `snes9x` for SNES), detects Wayland env, execs retroarch |
| `frontend/index.html`, `app.js`, `style.css` | Arcade UI + spatial navigation (Gamepad API + keyboard) + attract mode |
| `install/install.sh` | apt-installs retroarch + cores; lays the systemd unit (`pi-arcade.service`) disabled |
| `install/retroarch.cfg` | F4 = quit, F1 = menu. Memory-tuned (no shaders, no rewind) |

Deploy: `cd ~/pi_arcade_kiosk && git pull && sudo bash install/install.sh`.

## Disk layout on the Pi

```
~/pi_arcade_kiosk/
  roms/nes/      ← 52 curated classics (incl. Contra, Mario Bros 1/2/3 in
                   SMB+Duck Hunt cart, Mega Man 1/2/3/6, Zelda, Metroid,
                   Tecmo Bowl + Super Bowl, RBI Baseball, etc.)
  roms/snes/     ← 54 curated classics (Chrono Trigger, Donkey Kong
                   Country 1/2/3, Super Mario All-Stars+World, Super
                   Metroid, Street Fighter II + Turbo + Alpha 2 + Super,
                   Mortal Kombat 1/2/3, Mega Man X 1/2/3 + VII, Super
                   Star Wars trilogy, TMNT IV - Turtles in Time, etc.)
/usr/local/sbin/
  bsa-kiosk-agent.py
  switch-to-arcade.sh
  switch-to-workouts.sh
/etc/systemd/system/
  bsa-kiosk-agent.service     ← enabled, runs at boot
  pi-arcade.service           ← disabled; switch-to-arcade.sh starts on demand
/etc/sudoers.d/
  010_pi-kiosk-agent          ← reboot/shutdown/pkill + systemctl start/stop pi-arcade
```

## Storage caveat

Pi 4 SD currently 7 GB total (OS takes ~5 GB). After ROMs the card is
~93% full with only ~170 MB free. Full library (~1 GB across both
systems) won't fit. Long-term fix is one of:

- Bigger SD card (32 GB+) and reflash via `install.sh`
- USB drive mounted at `~/pi_arcade_kiosk/roms/` so the ROM corpus
  lives off-card
- Curated subset (current state)

## Picker controls

| Action | Keyboard | Gamepad |
|---|---|---|
| Move selection | ↑ ↓ ← → | D-pad **or** left analog stick |
| Launch focused tile | Enter | A (button 0) |
| Jump to "Back to Workouts" tile | Esc | B (button 1) |
| In-game quit (back to grid) | F4 | (RetroArch hotkey — needs mapping when controllers arrive) |

Hold-to-repeat: 350 ms before repeat kicks in, then one tick per 90 ms.

## Attract mode

After 30 s of picker idle, the next game in a curated rotation
auto-launches. Each game's built-in attract sequence then plays
(title screen → demo gameplay → loop). Any keypress / mousemove /
mousedown on the picker resets the idle timer. F4 ends the current
attract → picker resumes → 30 s of grace → next demo in the cycle.

**NES rotation:** Contra → SMB+Duck Hunt → Pac-Man → Mega Man 2 →
Donkey Kong Classics → Tetris.

**SNES rotation:** Donkey Kong Country → SMB All-Stars+SMW → Super
Metroid → Chrono Trigger → Street Fighter II → Killer Instinct →
Yoshi's Island.

`pi-arcade` exposes `GET /api/status` returning `{ playing: bool }`
so the picker JS pauses its idle countdown while RetroArch is alive
and resets it cleanly on RetroArch exit.

## Bluetooth SNES controllers (when they arrive)

Glen ordered knockoff BT SNES pads — pair them on the Pi:

```bash
ssh pi@100.107.197.36
bluetoothctl
  power on
  agent on
  scan on
  # put pad in pairing mode (usually Start+Select held)
  pair <MAC>
  trust <MAC>
  connect <MAC>
  exit
```

Once paired, the pad shows up at `/dev/input/event*`. The Chromium
Gamepad API picks it up automatically; the picker should react to
the D-pad + A/B buttons immediately on next page load.

For RetroArch input mapping (since cheap pads rarely match the
standard libretro layout out of the box):

```bash
# In RetroArch: Settings → Input → Port 1 Controls → "Bind All"
# Press each button as prompted. Save the autoconfig profile so
# future games pick it up.
```

To make F4 (quit-to-picker) easier, map a controller chord to
RetroArch's exit hotkey in `~/.config/retroarch/retroarch.cfg`:

```
input_enable_hotkey_btn = "8"     # Select (or another rarely-used button)
input_exit_emulator_btn = "9"     # Start — so Select+Start quits
```

After mapping, the gym kid hold-Select+presses-Start to end a game
without needing a keyboard.

## Bugs caught + fixed this session

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Frontend popup still shown on production after wiring | EC2 still had the old `dd98828` build | Built + scp'd `dist/` to `/var/www/bestrongagain/` |
| 2 | `apt: Unable to locate package libretro-fceumm` | Trixie repos dropped FCEUmm | Switched NES core to `libretro-nestopia` |
| 3 | `apt: Unable to locate package libretro-snes9x` (initial wrong assumption) | Available, just installed alongside Nestopia | install.sh installs both |
| 4 | Flask scanner missed `.zip` ROMs | `ROM_EXTS` only matched bare extensions | Added `.zip` to per-system list (both Nestopia and snes9x read zips) |
| 5 | `launch_game.sh` lost +x bit after `git checkout --` | install.sh's `chmod +x` ran but git tracked mode was 100644 | Baked exec bit into the tracked file via `git update-index --chmod=+x` |
| 6 | `/api/launch` 500 with `PermissionError` on exec | Bug 5 → exec not executable | Same fix |
| 7 | `systemctl start pi-arcade.service` silently failed | Agent runs as user pi; polkit denies system-service control | Sudoers entry + `sudo` in switch scripts |
| 8 | Chromium hit connection-refused before Flask was up | Flask `Type=simple` returns before bind, labwc 3 s respawn too tight | TCP-probe loop (≤3 s) in switch-to-arcade.sh |
| 9 | retroarch opened with no window | `pi-arcade.service` is system-scope `User=pi`; no Wayland env in service environment | `launch_game.sh` detects + exports `XDG_RUNTIME_DIR` + `WAYLAND_DISPLAY` |
| 10 | Tailscale SSH 5-min cache miss-out / per-session approval | Default Tailscale SSH policy | Glen authorizes via URL when needed; future: ACL auto-approve rule |
| 11 | NES→SNES flip left Contra running fullscreen | switch-to-arcade.sh didn't pkill retroarch | Added `pkill -x retroarch` to the script |
| 12 | Flask still reported `playing:true` after retroarch died | retroarch was a `<defunct>` zombie; SIGTERM took time | `pkill -9` flushed it; in production, `subprocess.Popen.poll()` reaps eventually |

## Quick recipes

### Force a flip from the CLI (for testing without admin UI)

```bash
ssh pi@100.107.197.36
/usr/local/sbin/switch-to-arcade.sh nes
# or
/usr/local/sbin/switch-to-arcade.sh snes
# or
/usr/local/sbin/switch-to-workouts.sh
```

### Add ROMs from your Desktop / external drive

```bash
# From the Windows machine, in any shell with tar:
cd "F:/3538 NES ROMS .../USA"
ls *.nes | grep -iE "<your pattern>" > /tmp/list.txt
tar cf - -T /tmp/list.txt | ssh pi@100.107.197.36 \
  "cd ~/pi_arcade_kiosk/roms/nes && tar xf -"
```

### Confirm Pi state

```bash
ssh pi@100.107.197.36
cat /tmp/bsa-mode 2>/dev/null || echo "(workout)"
pgrep -af chromium | grep -oE "http[s]?://[^ ]+" | head -1
systemctl is-active pi-arcade.service bsa-kiosk-agent
curl -s http://localhost:8088/api/status
df -h /
```

### Tail the agent log

```bash
sudo journalctl -u bsa-kiosk-agent -f
```
