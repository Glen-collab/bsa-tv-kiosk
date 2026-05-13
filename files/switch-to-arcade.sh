#!/bin/bash
# switch-to-arcade.sh — flip the Pi from workout-TV mode to retro arcade.
# Called by bsa-kiosk-agent.py when /api/kiosk/tv-config shows
# display_mode == game_nes | game_snes.
#
# Usage: switch-to-arcade.sh <nes|snes>
#
# Mechanism: writes /tmp/bsa-mode so labwc-autostart's pick_url returns
# the local Pi Arcade Flask URL on the next respawn, then pkills the
# current Chromium kiosk so the respawn fires immediately. Best-effort
# starts the pi-arcade systemd service (no-op if already running or if
# the pi_arcade_kiosk package isn't installed — Chromium will show a
# clear "site can't be reached" page in that case).

set -u

SYSTEM="${1:-}"
case "$SYSTEM" in
  nes|snes) ;;
  *)
    echo "usage: $0 <nes|snes>" >&2
    exit 2
    ;;
esac

echo "arcade-$SYSTEM" > /tmp/bsa-mode

# Best-effort start of the local arcade Flask. Failures are non-fatal
# so a Pi without pi_arcade_kiosk installed still flips cleanly (and
# the user sees a Chromium load-failed page that points at the config).
# Uses sudo because the agent runs as user pi and pi-arcade.service is
# system-scoped; sudoers entry in 010_pi-kiosk-agent lets this through
# without a password prompt.
sudo systemctl start pi-arcade.service 2>/dev/null || true

# Briefly wait for Flask to bind :8088 so Chromium's respawn lands on a
# listening port instead of getting connection-refused. Flask boots in
# ~1s on a Pi 4; cap the wait so a missing install doesn't block.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if (echo > /dev/tcp/127.0.0.1/8088) 2>/dev/null; then break; fi
  sleep 0.3
done

# Kill the workout Chromium — labwc-autostart's respawn loop picks the
# new URL from /tmp/bsa-mode on the next iteration.
pkill -x chromium 2>/dev/null
pkill -f "/usr/bin/chromium" 2>/dev/null

echo "arcade mode requested (system=$SYSTEM)"
