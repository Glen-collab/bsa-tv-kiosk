# BSA TV Kiosk

Plug-and-play Raspberry Pi kiosk for **Be Strong Again** gym TVs.

A coach plugs in the Pi, picks their gym's WiFi from their phone, types
their coach code, and 30 seconds later the gym TV is showing today's
workout — pulled live from `app.bestrongagain.com` for that coach.

---

## Quick start (a coach receiving a fresh kiosk)

1. Plug the Pi into the gym TV (HDMI + power).
2. The TV will say **"Connect to BSA-Kiosk-Setup"**.
3. On your phone, open WiFi settings → join `BSA-Kiosk-Setup` (no password).
4. Your phone pops up a setup page automatically. Pick your gym's WiFi,
   type the password, type your coach code (e.g. `GLENM7NUS`), tap
   **Connect Gym TV**.
5. About 30 seconds later, the TV switches to today's workout.

That's it. The Pi remembers the WiFi and coach code forever — every
reboot from now on jumps straight to the workout.

To reconfigure (new gym, new coach), hold the power button to force-off
the Pi, plug back in, and during boot before WiFi associates, the
captive portal will fire again. Or have your coach trigger
**Reboot TV** from the dashboard.

---

## Quick start (a developer flashing a new SD card)

1. **Image SD with Raspberry Pi Imager**:
   - OS: Raspberry Pi OS 64-bit (Trixie)
   - **OS Customization** → set hostname `bsa-tv`, user `pi` / `pi`,
     enable SSH, configure your dev WiFi (so the Pi comes up on your
     network and you can install over SSH).
2. **Boot the Pi, find its IP** (`nmap -sn 192.168.1.0/24`, or check
   the router DHCP table for `bsa-tv`).
3. **Install over SSH**:
   ```
   ssh pi@<pi-ip>
   git clone https://github.com/Glen-collab/bsa-tv-kiosk.git
   cd bsa-tv-kiosk
   sudo bash install.sh
   sudo reboot
   ```
4. After reboot, kiosk shows **"Connect to BSA-Kiosk-Setup"**. Follow
   the coach quickstart above. (You can also pre-bake `/home/pi/bsa-config`
   to skip the captive portal in dev — see install output.)

---

## What's deployed where

| Source (in repo)                       | Pi path                                      |
|----------------------------------------|----------------------------------------------|
| `files/bsa-setup-portal.py`            | `/usr/local/sbin/bsa-setup-portal.py`        |
| `files/wifi-connect-wrapper.sh`        | `/usr/local/sbin/wifi-connect-wrapper.sh`    |
| `files/wifi-connect.service`           | `/etc/systemd/system/wifi-connect.service`   |
| `files/index.html`                     | `/usr/share/bsa-setup/index.html`            |
| `files/bsa-kiosk-agent.py`             | `/usr/local/sbin/bsa-kiosk-agent.py`         |
| `files/bsa-kiosk-agent.service`        | `/etc/systemd/system/bsa-kiosk-agent.service`|
| `files/010_pi-kiosk-agent`             | `/etc/sudoers.d/010_pi-kiosk-agent`          |
| `files/labwc-autostart`                | `/home/pi/.config/labwc/autostart`           |
| `files/setup-instructions.html`        | `/home/pi/setup-instructions.html`           |

`install.sh` puts everything in place and enables both systemd units.

---

## How the boot flow works

```
power on
  │
  ▼
NetworkManager tries every saved WiFi
  │
  ▼
wifi-connect.service runs (oneshot)
  │
  ├── 60s grace, probes app.bestrongagain.com
  │
  ├── ONLINE? → exit, kiosk loads /tv/static
  │
  └── OFFLINE? → bsa-setup-portal.py
        │
        ├── Brings up open AP "BSA-Kiosk-Setup" at 192.168.42.1
        ├── Serves form (WiFi picker + coach code)
        ├── On submit: nmcli connect, save coach code, kick chromium
        └── exit 0 → kiosk reloads with new config
```

In parallel, `labwc-autostart` runs the Chromium kiosk in a respawn
loop. Each respawn re-reads `/home/pi/bsa-config` and picks:
- **Coach code present** → `https://bestrongagain.netlify.app/tv/static?coach=<CODE>&device=<SERIAL>`
- **No coach code** → `file:///home/pi/setup-instructions.html` (the
  "Connect to BSA-Kiosk-Setup" page)

Once running, `bsa-kiosk-agent.service` polls
`https://app.bestrongagain.com/api/kiosk/commands?coach_code=<CODE>` every
10s and executes shutdown/reboot/reload commands a coach issues from
their dashboard.

---

## Recent fixes

- **Apr 26** — Pi 4 swap; `--force-device-scale-factor=2` for 4K LG TV;
  dash-safe URL build in autostart.
- **May 9** — Captive portal AP rebuilt from scratch (`nmcli c add type
  wifi`) instead of via `wifi hotspot`. Old path injected WPA which left
  NM stuck demanding `wep-key0` and the AP never came up. Wrapper now
  does a real internet probe and deletes stuck NM profiles.

See `docs/TROUBLESHOOTING.md` for recovery procedures when something
goes sideways at a gym you can't SSH into.

---

## Repos this connects to

- **`Glen-collab/WorkoutTracker`** — hosts the `/tv/static` page that
  the kiosk Chromium loads. Routing in `src/App.jsx`, view in
  `src/components/tv/TVStatic.jsx`.
- **`Glen-collab/bsa-coach-platform`** — backend for `/api/kiosk/*` (the
  command queue + `tv-config` per-device media overrides).
- **`Glen-collab/workoutbuilder`** — coach-facing program builder (not
  reached by the kiosk directly).
