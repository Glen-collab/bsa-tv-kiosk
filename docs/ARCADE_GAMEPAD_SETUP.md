# Arcade Gamepad Setup

Sibling doc to `ARCADE_KIOSK.md`. Covers the controller layer of the
gym Pi arcade — pairing, RetroArch input mapping, the multi-pad picker
path, per-launch RetroArch overrides, and the "Load Game" remote
button. Built and validated 2026-05-17 with one paired DragonRise pad.

## Hardware

- **Pads:** cheap SNES-knockoff wireless gamepads, two-pack with two
  small USB dongles (one per pad). Each pad uses 2× AAA.
- **They are NOT Bluetooth.** The dongles do proprietary 2.4 GHz; the
  Pi sees them as plain USB HID. `bluetoothctl` will never list them.
- **Kernel ID:** `0079:0126` (DragonRise Inc. Controller). Kernel name
  reports as just `Controller`.
- **Topology on this kiosk:** two dongles plugged into the Pi's USB
  hub. Each pad's radio bonds to one specific dongle. When a pad has
  dead batteries / is unpaired / is off, its dongle still enumerates
  to the Pi but no `js`/`event` events flow.

## Pairing a pad to its dongle

Out of the box, one pad in the pack came pre-bonded to one dongle.
The other pair is not yet paired. Standard knockoff sync routine:

1. Plug both dongles into the Pi (or unplug-replug the relevant one).
2. Install 2× fresh AAA in the pad. Confirm any power switch is ON.
3. Press and hold the small SYNC button on the dongle (or the bottom
   button on some variants) until its LED blinks.
4. On the pad: hold **Start + Select** until the pad's LED blinks
   slowly, then becomes solid → paired.

Once paired, verify with this on the Pi:

```bash
ssh pi@100.107.197.36
rm -f /tmp/js*.bin
(timeout 8 dd if=/dev/input/js0 of=/tmp/js0.bin bs=8 2>/dev/null) &
(timeout 8 dd if=/dev/input/js1 of=/tmp/js1.bin bs=8 2>/dev/null) &
wait
# Mash buttons on the pad during those 8s. >19 events per file means
# the pad is actually transmitting to its dongle. Each js device
# always emits 19 init-state events on first read regardless.
```

If a pad shows only 19 events (152 bytes) it's not transmitting —
re-do the sync above or check batteries before debugging software.

## RetroArch autoconfig

`~/.config/retroarch/autoconfig/udev/DragonRise-Generic-USB-Joystick.cfg`
(on the Pi only — not in any repo yet):

```cfg
input_driver = "udev"
input_device = "Controller"
input_vendor_id = "121"
input_product_id = "294"

input_b_btn = "2"
input_a_btn = "1"
input_y_btn = "3"
input_x_btn = "0"
input_l_btn = "4"
input_r_btn = "5"
input_select_btn = "8"
input_start_btn = "9"

input_up_axis = "-1"
input_down_axis = "+1"
input_left_axis = "-0"
input_right_axis = "+0"

input_enable_hotkey_btn = "8"     # Select
input_exit_emulator_btn = "9"     # Start → Select+Start quits to picker
input_menu_toggle_btn = "0"       # X (Select+X toggles RetroArch menu)
```

`input_device = "Controller"` matches what the DragonRise dongle reports
to the kernel. Both pads share the same VID/PID/name, so one profile
covers both. RetroArch loads this on the next game launch — it does
not pick it up live for the currently running game.

## Per-launch RetroArch overrides

The picker JS knows two things at launch time that the base
retroarch.cfg can't:

1. **Which physical pad fired the launch button.** Without telling
   RetroArch, Player 1 defaults to the first udev-enumerated pad,
   which is often the silent dongle.
2. **How many pads are actually transmitting events.** Without
   telling RetroArch, both enumerated pads are exposed to games —
   MK3 reads "2 controllers plugged in" and auto-jumps to VS mode
   regardless of whether the second one ever fires.

The picker sends both signals to `/api/launch`, Flask forwards them
as positional args to `launch_game.sh`, the launcher writes:

```
/tmp/retroarch-launch-override.cfg
  input_max_users           = "<count of pads active in last 30 s>"
  input_player1_joypad_index = "<index of pad that fired launch>"
```

…and launches `retroarch --appendconfig /tmp/retroarch-launch-override.cfg`.
Base `retroarch.cfg` stays untouched.

### Effect

| Pads firing in last 30 s | `input_max_users` | In-game result |
|---|---|---|
| 1 (current state) | 1 | Single-player. MK3 stays out of auto-VS. |
| 2 (when pad 2 is paired + pressing) | 2 | 2-player lights up automatically. |
| 0 (no recent activity, e.g. mouse launch) | 1 | Safe default. |

## Multi-pad picker

`pi_arcade_kiosk/frontend/app.js` polls every connected gamepad each
frame and ORs their inputs together. Whichever pad is actually firing
events drives the picker — regardless of which dongle is `js0` vs `js1`
in the kernel.

A few other picker quirks worth knowing:

- **Picker is deaf while a game is running.** `wasPlaying` tracks
  `/api/status`. Without this guard, Chromium polls the gamepad even
  when RetroArch is the foreground window — pressing A in a fighting
  game would launch the next alphabetical tile behind RetroArch.
- **Attract idle timer resets on gamepad input.** Earlier bug: D-pad
  navigation didn't reset the timer, so attract launched a game mid-
  selection and clobbered the user's pick.
- **On picker page load, any orphaned RetroArch is killed via
  `/api/quit`.** Chromium respawns (mode flips, `pkill chromium`,
  agent reload) used to leave a live game running underneath the
  reloaded picker; the load-time quit cleans state.
- **Per-pad activity tracking.** Map `gp.index → lastActivityMs`
  updated by any pressed button or out-of-deadzone axis. Counts
  feed `num_users` at launch.
- **Face buttons 0–3 all launch.** Cheap pads don't expose Chromium's
  "standard" mapping, so the physical "A" button can land on any of
  the four face-button indices. Accept all four. Deliberately NOT
  including Start (9) — Start is half of the Select+Start exit
  chord, and Chromium still sees the press in the background; would
  auto-relaunch the focused tile on every game-exit otherwise.

## Load Game button (3-repo)

Phone-driven "kill the running game and drop back to the picker
without leaving arcade mode." Reuses the existing kiosk command
queue (same plumbing as shutdown / reboot / reload).

Flow:

```
[admin phone GymTV] 🎮 Load Game
       │
       ▼  POST /api/kiosk/pi-quit-game  (bsa-coach-platform backend)
       │  → queue kiosk_commands row (command='quit_game', expires +5min)
       │
       ▼  Pi agent polls /api/kiosk/commands every ~10s
       │  → sees quit_game, ACKs
       │
       ▼  POST http://localhost:8088/api/quit  (pi-arcade Flask)
       │  → SIGTERM the current_proc retroarch
       │
       ▼  Picker JS's /api/status poll sees playing:false within 5s
          wasPlaying flips back to false, gamepad input live again.
```

The button on GameModeCard is enabled only when the device is in
`game_nes` or `game_snes` mode.

## File map (everything touched 2026-05-17)

### `pi_arcade_kiosk` (Desktop repo, deploys to `/home/pi/pi_arcade_kiosk/` on Pi)

| File | Change |
|---|---|
| `frontend/app.js` | Multi-pad polling, activity tracker, wasPlaying guard, attract-race fix, load-time `/api/quit`, face-button-0-3 launch, joypad_index + num_users sent to backend |
| `backend/app.py` | `/api/launch` accepts `joypad_index` + `num_users` body params, forwards to launcher |
| `launcher/launch_game.sh` | Accepts 3rd/4th args, writes `/tmp/retroarch-launch-override.cfg`, launches `retroarch --appendconfig` |

### `bsa-tv-kiosk` (Desktop repo, installs to `/usr/local/sbin/` etc.)

| File | Change |
|---|---|
| `files/bsa-kiosk-agent.py` | New `quit_game` command handler — POSTs `http://localhost:8088/api/quit` |
| `docs/ARCADE_GAMEPAD_SETUP.md` | This doc |

### `bsa-coach-platform` (Desktop repo, deploys to EC2 + Netlify-style dist)

| File | Change |
|---|---|
| `backend/kiosk.py` | `quit_game` added to `_ALLOWED_COMMANDS`, new `/api/kiosk/pi-quit-game` endpoint |
| `src/utils/api.jsx` | `kioskPiQuitGame()` request helper |
| `src/components/GameModeCard.jsx` | New "🎮 Load Game" button between SNES and Stop |

### Pi-only (not in any repo)

| Path | Purpose |
|---|---|
| `~/.config/retroarch/autoconfig/udev/DragonRise-Generic-USB-Joystick.cfg` | Button + axis mapping for both DragonRise pads |
| `/tmp/retroarch-launch-override.cfg` | Per-launch override (rewritten each `/api/launch`) |

## Deploy

Pi-arcade changes (frontend/backend/launcher):

```bash
scp pi_arcade_kiosk/frontend/app.js     pi@100.107.197.36:~/pi_arcade_kiosk/frontend/
scp pi_arcade_kiosk/backend/app.py      pi@100.107.197.36:~/pi_arcade_kiosk/backend/
scp pi_arcade_kiosk/launcher/launch_game.sh pi@100.107.197.36:~/pi_arcade_kiosk/launcher/
ssh pi@100.107.197.36 \
  "chmod +x ~/pi_arcade_kiosk/launcher/launch_game.sh && \
   sudo systemctl restart pi-arcade.service && \
   pkill chromium  # picks up new JS on respawn"
```

Pi agent change:

```bash
scp bsa-tv-kiosk/files/bsa-kiosk-agent.py pi@100.107.197.36:/tmp/
ssh pi@100.107.197.36 \
  "sudo install -m 755 /tmp/bsa-kiosk-agent.py /usr/local/sbin/bsa-kiosk-agent.py && \
   sudo systemctl restart bsa-kiosk-agent.service"
```

EC2 backend + frontend:

```bash
# backend
scp -i polly-connect-key.pem bsa-coach-platform/backend/kiosk.py \
   ec2-user@3.19.135.182:/tmp/
ssh -i polly-connect-key.pem ec2-user@3.19.135.182 \
  "sudo mv /tmp/kiosk.py /opt/bestrongagain/kiosk.py && \
   sudo systemctl restart bestrongagain.service"

# frontend
cd bsa-coach-platform && npm run build
ssh -i polly-connect-key.pem ec2-user@3.19.135.182 'mkdir -p /tmp/dist-new'
scp -i polly-connect-key.pem -r dist/. ec2-user@3.19.135.182:/tmp/dist-new/
ssh -i polly-connect-key.pem ec2-user@3.19.135.182 \
  "sudo rm -rf /var/www/bestrongagain/assets && \
   sudo cp -r /tmp/dist-new/. /var/www/bestrongagain/ && \
   sudo rm -rf /tmp/dist-new"
```

## Known limits / future

- **Pad 2 still needs pairing.** Hardware works but the pad's radio
  isn't bonded to its dongle yet. Until paired, `js0` (typically)
  stays silent and `num_users` will remain 1.
- **MK3 (and similar) has a built-in character-select / tower-select
  timer.** Not a bug, can't be disabled without a ROM patch.
- **No 2P opt-in UI.** Multi-user is fully automatic via activity
  detection. If someone wants 2-player on a game where pad 2's user
  is passive (just watching), they'd need to wiggle the D-pad once
  during picker time so the activity tracker counts them.
- **Picker tracks gamepad activity but not which physical kid is
  Player 2.** RetroArch assigns Player 2 = next enumerated pad
  beyond the one that fired the launch. If you ever have 3+ pads,
  Player 2 may surprise you. Out of scope for now.
- **DragonRise autoconfig isn't in the bsa-tv-kiosk repo.** Lives
  only on the Pi at `~/.config/retroarch/autoconfig/udev/`. New Pi
  flashes would need it copied in. Worth adding to `bsa-tv-kiosk/files/`
  + `install.sh` when next Pi gets set up.
