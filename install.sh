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

echo "==> enabling systemd services"
systemctl daemon-reload
systemctl enable wifi-connect.service
systemctl enable bsa-kiosk-agent.service

echo
echo "================================================================"
echo "  Install complete."
echo
echo "  Next steps:"
echo "    1. If you DON'T have a coach code yet, you can reboot now and"
echo "       the kiosk will show 'Connect to BSA-Kiosk-Setup' — pair"
echo "       your phone, enter your gym WiFi + coach code."
echo "    2. If you ALREADY have a coach code (e.g. dev/QA), put it in"
echo "       /home/pi/bsa-config:"
echo "         echo '{\"coach_code\":\"YOURCODE\"}' | sudo -u pi tee /home/pi/bsa-config"
echo "    3. Reboot to start the kiosk:  sudo reboot"
echo "================================================================"
