# Provisioning a New Gym TV Pi — Full Runbook

End-to-end steps to turn a fresh Raspberry Pi 5 into a **workout TV + retro
arcade**, done entirely over SSH from a Windows laptop that's on the same
Tailnet. Captures every gotcha we hit setting up the 4th TV so it goes smooth
next time.

> Naming: each Pi is `bsa-tv-N`. Set the hostname to `bsa-tv-N` in Imager so the
> Tailnet name comes out clean — enroll with `--hostname=bsa-tv-N` (NOT
> `--hostname=bsa-tv-$(hostname)`, which double-prefixes to `bsa-tv-bsa-tv-N`).

---

## 0. Flash the SD (Raspberry Pi Imager)

- OS: **Raspberry Pi OS 64-bit** (Bookworm/Trixie).
- ⚙️ gear / OS customization:
  - **Hostname:** `bsa-tv-N`
  - **User / pass:** `pi` / `pi` (Imager remembers the password and grays the
    confirm fields on later flashes — that's expected).
  - **WiFi:** the network the TV will live on (SSID + pass, country US).
  - **Enable SSH → "Allow public-key authentication"** and **paste the laptop's
    public key** (`~/.ssh/id_ed25519.pub`). ⭐ **Do this** — it skips the
    `ssh-copy-id` dance below.
- Write, insert into the Pi, connect **HDMI to TV + power**.

### Gotcha: forgot to paste the key in Imager?
`bsa-tv-N.local` will be up but reject your key. Add it from **Git Bash** (not
cmd.exe — and the Claude-prompt `!` prefix is NOT a terminal command):
```
ssh-copy-id pi@bsa-tv-N.local          # password: pi
```
cmd.exe one-liner alternative (single line, no `&&` chain to mangle on paste):
```
ssh -o StrictHostKeyChecking=accept-new pi@bsa-tv-N.local "install -Dm600 /dev/stdin .ssh/authorized_keys" < %USERPROFILE%\.ssh\id_ed25519.pub
```

---

## 1. Passwordless sudo

Fresh Pi OS asks for a sudo password, which hangs non-interactive SSH. Wire
NOPASSWD once (the `pi` password is `pi`):
```
ssh pi@bsa-tv-N.local "echo pi | sudo -S bash -c 'echo \"pi ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/010-pi-nopasswd && chmod 440 /etc/sudoers.d/010-pi-nopasswd'; sudo -n true && echo NOPASSWD_OK"
```

---

## 2. Workout-TV kiosk

```
ssh pi@bsa-tv-N.local
  sudo apt-get install -y git
  git clone https://github.com/Glen-collab/bsa-tv-kiosk.git ~/bsa-tv-kiosk
  cd ~/bsa-tv-kiosk && sudo bash install.sh          # ~2-3 min (chromium, tailscale, agent)
  # bake the coach code so it skips the captive portal and boots to the workout:
  echo '{"coach_code":"YOURCODE"}' | sudo -u pi tee /home/pi/bsa-config
```
`install.sh` is long-ish — run it detached + poll if doing it remotely:
`sudo nohup bash install.sh > /tmp/install.log 2>&1 &` then `grep -q 'Install complete' /tmp/install.log`.

### Enroll Tailscale (one click)
```
sudo tailscale up --ssh --hostname=bsa-tv-N
```
It prints a `https://login.tailscale.com/a/...` URL — open it, log in with the
Tailscale account, done. The Pi now answers at `bsa-tv-N` on the Tailnet from
anywhere.

### Reboot into the kiosk
```
sudo reboot
```
Comes back showing `…/tv/static?coach=YOURCODE&device=<serial>`. Verify:
`pgrep -af chromium | grep tv/static` and `systemctl is-active bsa-kiosk-agent`.

---

## 3. Retro arcade (optional second mode)

Install the arcade software (coexists with the workout kiosk — it only adds
RetroArch + cores + the on-demand `pi-arcade` Flask service; it does NOT touch
the Chromium/labwc autostart):
```
# from the laptop, push the project (or git clone on the Pi):
scp -r backend frontend launcher install docs README.md ARCHITECTURE.md .gitignore pi@bsa-tv-N.local:~/pi_arcade_kiosk/
ssh pi@bsa-tv-N.local "cd ~/pi_arcade_kiosk && sudo nohup bash install/install.sh > /tmp/arcade-install.log 2>&1 &"
# installs retroarch + nestopia/snes9x/mgba + parallel_n64 core + ~436 controller profiles
```

### Copying the ROM library from an existing Pi — the tricky part
The clean source is an already-set-up Pi (e.g. `bsa-tv-3`, ~7.5 GB / 1,788
games). Two gotchas, both solved by going **Pi-to-Pi over Tailscale**:

1. **The laptop's Git Bash has NO `rsync`** → any relay-through-laptop rsync
   fails with `rsync: command not found`. Don't relay through the laptop.
2. **The two Pis can't reach each other on the LAN** (gym WiFi client-isolation
   — even on the same /24 you get "No route to host"). **Tailscale bridges them
   anyway.**

So: authorize the new Pi's key on the source Pi, then rsync **on the new Pi**,
pulling from the source's **Tailnet IP**, under `nohup` (runs on the Pi,
survives laptop sleep, resumable):
```
# 1. give bsa-tv-N a key + authorize it on the source Pi (run from laptop):
KEY=$(ssh pi@bsa-tv-N.local "test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519 >/dev/null; cat ~/.ssh/id_ed25519.pub")
echo "$KEY" | ssh pi@bsa-tv-SOURCE.local "cat >> ~/.ssh/authorized_keys"

# 2. pull ROMs on bsa-tv-N from the SOURCE's tailnet IP (find via `tailscale ip -4` on the source):
ssh pi@bsa-tv-N.local "
  rsync -a -e 'ssh -o StrictHostKeyChecking=accept-new' pi@<SOURCE_TAILNET_IP>:pi_arcade_kiosk/backend/games.json ~/pi_arcade_kiosk/backend/games.json
  nohup rsync -a --partial -e 'ssh -o StrictHostKeyChecking=accept-new' pi@<SOURCE_TAILNET_IP>:pi_arcade_kiosk/roms/ ~/pi_arcade_kiosk/roms/ > /tmp/romsync.log 2>&1 &
"
```
~11 MB/s over Tailscale → ~11 min for 7.5 GB. Verify:
```
curl -s http://127.0.0.1:8088/api/games | grep -o '"id":' | wc -l   # after `sudo systemctl start pi-arcade`
```
The `pi-arcade` service stays **inactive at boot by design** — the dashboard's
Game Mode flip (or `switch-to-arcade.sh`) starts it on demand.

---

## 4. Light up the dashboard Game Mode buttons

The admin **Game Mode** card shows one button per system in the device's
`available_systems` column (table: `coach_devices`). A freshly-registered Pi
**defaults to `nes,snes`**, so N64/GBA buttons are missing until you fix it.
Set it to match what the Pi actually has (Pi 4s are often NES/SNES-only for
space; Pi 5s get all four):
```sql
-- on the EC2 box: psql "$DATABASE_URL" -c "..."
UPDATE coach_devices SET available_systems='gba,n64,nes,snes'
WHERE device_serial='<the-pi-serial>';
```
Find the serial in the workout kiosk URL (`&device=<serial>`) or the device row.
Refresh the dashboard → all four buttons appear. (The registration endpoint
*accepts* a `?systems=` param; the kiosk agent just doesn't send the real list
yet — a future improvement is to have it auto-report from the `roms/<sys>/`
folders that actually contain games.)

---

## Power note
Pi 5 wants a real **5V/5A (27W) USB-C** brick on its own outlet. A Pi dropping
out the instant you plug in another one is usually a **shared/loose supply**, not
the Pi — check the outlet/connection first before blaming the board.

---

## Quick verification checklist

- [ ] `ssh pi@bsa-tv-N` works over Tailnet (and `bsa-tv-N.local` on LAN)
- [ ] `systemctl is-active bsa-kiosk-agent` → active
- [ ] Chromium on `…/tv/static?coach=...` after reboot
- [ ] `curl :8088/api/games | grep -c '"id":'` → expected game count (arcade)
- [ ] Dashboard Game Mode shows the right system buttons for the device
