# Second Pi Setup Checklist

Step-by-step for adding a second (or third, fourth…) gym TV to your
existing setup. Each Pi is independent — different programs, different
display modes, all controlled from the same dashboard.

**Time estimate:** ~30 min total (mostly waiting for SD flash + boot).

---

## 1. Hardware to buy

- [ ] **Raspberry Pi 4** (4GB or 8GB — 2GB works but tight). Don't get a Pi 5 yet; bsa-tv-kiosk hasn't been validated on Pi 5.
- [ ] **micro-SD card** — 32GB SanDisk Extreme or similar A2-rated card. Cheap cards = corruption headaches.
- [ ] **USB-C power supply** — official Pi 4 PSU (5V 3A). Not optional; underpowered ones throttle Chromium.
- [ ] **micro-HDMI to HDMI cable** — Pi 4 has micro-HDMI ports. Use the **HDMI 0** port (closest to USB-C).
- [ ] Optional but recommended: a small **Pi case with fan** — Chromium runs warm.
- [ ] Optional: USB pad / Flirc / TV remote with CEC support if you want hardware navigation. Phone Remote Control works without any of these.

Glen's current Pi (`bsa-tv` at home/gym 1) is the reference build. Match
it.

---

## 2. Flash the SD card (5 min)

On your laptop with **Raspberry Pi Imager**:

- [ ] OS: **Raspberry Pi OS (64-bit)** — Trixie (Debian 13). Not Bookworm.
- [ ] Click **gear icon (OS customization)** before writing — critical:
  - [ ] Hostname: `bsa-tv-2` (or whatever you want — must be unique across your tailnet)
  - [ ] Username: `pi` / Password: `pi`
  - [ ] WiFi: pre-fill your HOME WiFi (so first boot works at home)
  - [ ] Enable SSH (use password auth)
  - [ ] Timezone: pick yours
- [ ] Write the image. Eject.

---

## 3. First boot at home (5 min)

- [ ] Insert SD, plug in HDMI to any TV/monitor (or skip if doing headless), plug in USB-C power.
- [ ] Wait ~60s for first boot. Pi shows the desktop.
- [ ] Find its IP — easiest: log into your home router and look for `bsa-tv-2` in the DHCP table. Or run `nmap -sn 192.168.1.0/24` from your laptop.

---

## 4. Install bsa-tv-kiosk (~10 min)

From your laptop:

```bash
ssh pi@<new-pi-ip>
# password: pi
git clone https://github.com/Glen-collab/bsa-tv-kiosk.git
cd bsa-tv-kiosk
sudo bash install.sh
```

This installs:
- The captive portal stack (so the Pi can be reconfigured at any gym)
- The kiosk agent (lets you reboot/shutdown remotely from the dashboard)
- labwc autostart (Chromium kiosk launcher)
- Tailscale binary (not yet enrolled — next step)

---

## 5. Enroll Tailscale (one-time auth, ~2 min)

```bash
sudo tailscale up --ssh --hostname=bsa-tv-2
```

- [ ] Open the URL it prints on your phone or laptop
- [ ] Log into the **same Tailscale account** you used for the first Pi (Glen's: wisco.barbell@gmail.com)
- [ ] Approve the device. It joins your tailnet.

Verify from your laptop:
```bash
ssh pi@bsa-tv-2  # via Tailscale, works from anywhere now
```

---

## 6. Test at home before taking it to the gym (~2 min)

- [ ] Reboot the Pi: `sudo reboot`
- [ ] After ~60s, Pi should show "Connect to BSA-Kiosk-Setup" on the home TV (because no coach code yet)
- [ ] On your phone: join WiFi `BSA-Kiosk-Setup` (no password)
- [ ] Captive portal pops up automatically. Enter your gym's WiFi name + password, enter your coach code (`GLENM7NUS`)
- [ ] Pi reboots automatically, joins WiFi, loads `app.bestrongagain.com/api/kiosk/tv-config?coach=GLENM7NUS&device=<this-pi's-serial>`
- [ ] On `app.bestrongagain.com/gym-tv` you'll now see **Your Devices (2)** — both Pis listed.
- [ ] Rename it: tap the new device's "Rename" button, call it something like "Cardio room TV"

If anything goes wrong here, see `docs/TROUBLESHOOTING.md`.

---

## 7. Take it to the gym

Unplug, take to gym, plug into TV + power. **Same captive portal flow as
step 6** if the gym WiFi changed (it shouldn't if you set it up at home
with the gym WiFi pre-baked — see step 2 OS customization).

If the gym WiFi was already configured during step 6's at-home test, Pi
just joins it automatically on power-on and shows the workout within ~60s.

---

## 8. Per-device control via Remote Control

On `app.bestrongagain.com/gym-tv` you'll see two device cards now. Each
has:
- Its own "On TV now" banner (which program is loaded)
- Its own 📱 Remote Control button
- Its own program tile grid

Tap Remote Control on the new device → control that TV independently of
the first. Pick a different program, leaderboard mode, gender filter, etc.

**Common test-day setup:** TV 1 shows the day's workout for everyone
working out, TV 2 shows the live leaderboard scoreboard for the metric
being tested.

---

## Recovery shortcuts (in case something goes sideways at the gym)

| Symptom | Fix |
|---|---|
| TV is stuck on "Connect to BSA-Kiosk-Setup" after captive portal flow | Tap any program tile on the dashboard — it auto-flips display_mode back to 'workout' |
| Can't SSH from home | Tailscale is your safety net. `ssh pi@bsa-tv-2` works from any network |
| Pi unresponsive, dashboard reboot doesn't fire | Power cycle. If it boots into the captive portal flow, you can reconfigure WiFi |
| Need to wipe and start over | Pull SD, re-image. ~5 min. |

---

## After the second Pi is live

Maybe order a third for the lobby? Or buy a USB game pad for the
gamepad-mode navigation Glen added earlier (works without Flirc).
The system scales linearly per Pi with no architectural changes.

---

## Source-of-truth files

- Repo: [Glen-collab/bsa-tv-kiosk](https://github.com/Glen-collab/bsa-tv-kiosk)
- Install script: `install.sh` (idempotent — safe to re-run)
- Captive portal: `files/bsa-setup-portal.py`, `files/index.html`
- Kiosk agent: `files/bsa-kiosk-agent.py`
- Troubleshooting: `docs/TROUBLESHOOTING.md`
