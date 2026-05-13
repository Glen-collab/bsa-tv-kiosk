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
systemctl start pi-arcade.service 2>/dev/null || true

# Kill the workout Chromium — labwc-autostart's respawn loop picks the
# new URL from /tmp/bsa-mode on the next iteration.
pkill -x chromium 2>/dev/null
pkill -f "/usr/bin/chromium" 2>/dev/null

echo "arcade mode requested (system=$SYSTEM)"
