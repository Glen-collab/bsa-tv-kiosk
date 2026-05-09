#!/bin/bash
# bsa-tv-kiosk install.sh
# Run on a freshly-imaged Pi (Bookworm or Trixie). Idempotent — safe to
# re-run. Lays down every file at its deploy path, enables the systemd
# units, drops the sudoers file, fixes labwc autostart, and reboots.
#
#   curl -fsSL https://raw.githubusercontent.com/Glen-collab/bsa-tv-kiosk/main/install.sh | sudo bash
# OR locally:
#   sudo bash install.sh
#
# After this runs:
#   - On boot, if WiFi works: kiosk loads the workout TV page
#   - On boot, if WiFi missing/wrong: BSA-Kiosk-Setup AP comes up, coach
#     enters new SSID + coach code on phone, kiosk reloads automatically

set -euo pipefail

# Anchor to the repo root regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES="$SCRIPT_DIR/files"
PI_HOME="/home/pi"
PI_UID="$(id -u pi 2>/dev/null || echo 1000)"
PI_GID="$(id -g pi 2>/dev/null || echo 1000)"

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root: sudo bash install.sh" >&2
  exit 1
fi

if [ ! -d "$FILES" ]; then
  echo "files/ directory missing — are you in the repo root?" >&2
  exit 1
fi

echo "==> installing dependencies"
apt-get update -qq
# chromium ships under different names on Bookworm/Trixie; both are tried
apt-get install -y --no-install-recommends \
  curl unclutter network-manager python3 \
  chromium chromium-browser 2>/dev/null || true

echo "==> deploying captive portal"
install -m 0755 -o root -g root "$FILES/bsa-setup-portal.py"      /usr/local/sbin/bsa-setup-portal.py
install -m 0755 -o root -g root "$FILES/wifi-connect-wrapper.sh"  /usr/local/sbin/wifi-connect-wrapper.sh
install -d -m 0755 /usr/share/bsa-setup
install -m 0644 -o root -g root "$FILES/index.html"               /usr/share/bsa-setup/index.html
install -m 0644 -o root -g root "$FILES/wifi-connect.service"     /etc/systemd/system/wifi-connect.service

echo "==> deploying kiosk command agent"
install -m 0755 -o root -g root "$FILES/bsa-kiosk-agent.py"       /usr/local/sbin/bsa-kiosk-agent.py
install -m 0644 -o root -g root "$FILES/bsa-kiosk-agent.service"  /etc/systemd/system/bsa-kiosk-agent.service

echo "==> deploying sudoers (allows agent to run reboot/shutdown without password)"
install -d -m 0750 /etc/sudoers.d
install -m 0440 -o root -g root "$FILES/010_pi-kiosk-agent"       /etc/sudoers.d/010_pi-kiosk-agent
visudo -c -f /etc/sudoers.d/010_pi-kiosk-agent  # syntax check

echo "==> deploying kiosk autostart"
install -d -m 0755 -o "$PI_UID" -g "$PI_GID" "$PI_HOME/.config/labwc"
install -m 0755 -o "$PI_UID" -g "$PI_GID" "$FILES/labwc-autostart"      "$PI_HOME/.config/labwc/autostart"
install -m 0644 -o "$PI_UID" -g "$PI_GID" "$FILES/setup-instructions.html" "$PI_HOME/setup-instructions.html"

echo "==> ensuring log file exists with right perms"
touch /var/log/wifi-connect-wrapper.log
chmod 0664 /var/log/wifi-connect-wrapper.log

echo "==> installing Tailscale (remote SSH from anywhere)"
# Adds Tailscale's official apt repo + installs the daemon. Doesn't
# enroll the device — that's a one-time `tailscale up` step (see Next
# steps below). Skip this entire block if Tailscale is already present.
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt-get update -qq
  apt-get install -y tailscale
else
  echo "    tailscale already installed"
fi

echo "==> enabling systemd services"
systemctl daemon-reload
systemctl enable wifi-connect.service
systemctl enable bsa-kiosk-agent.service
systemctl enable --now tailscaled

echo
echo "================================================================"
echo "  Install complete."
echo
echo "  Next steps:"
echo "    1. Enroll this Pi in your Tailnet (one-time, opens a browser):"
echo "         sudo tailscale up --ssh --hostname=bsa-tv-\$(hostname)"
echo "       After this, you can SSH it from any of your Tailscale devices"
echo "       at any network: ssh pi@bsa-tv-<hostname>"
echo
echo "    2. If you DON'T have a coach code yet, reboot and the kiosk"
echo "       will show 'Connect to BSA-Kiosk-Setup' — pair your phone,"
echo "       enter your gym WiFi + coach code."
echo
echo "    3. If you ALREADY have a coach code (e.g. dev/QA), put it in"
echo "       /home/pi/bsa-config:"
echo "         echo '{\"coach_code\":\"YOURCODE\"}' | sudo -u pi tee /home/pi/bsa-config"
echo
echo "    4. Reboot to start the kiosk:  sudo reboot"
echo "================================================================"
