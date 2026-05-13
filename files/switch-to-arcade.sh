#!/bin/bash
# switch-to-arcade.sh — flip the Pi from workout-TV mode to retro arcade.
# Called by bsa-kiosk-agent.py when /api/kiosk/tv-config shows
# display_mode == game_nes | game_snes.
#
# Usage: switch-to-arcade.sh <nes|snes>
#
# Side-effects:
#   • kills the workout Chromium kiosk
#   • execs RetroArch full-screen with the requested core
#   • logs to /tmp/retroarch.log
#
# RetroArch + cores + ROMs are NOT installed by this script — see
# docs/RETRO_GAMES_PLAN.md for the one-time Pi setup.

set -u

SYSTEM="${1:-}"
case "$SYSTEM" in
  nes)  CORE="/usr/lib/libretro/fceumm_libretro.so" ; ROM_DIR="/home/pi/roms/nes"  ;;
  snes) CORE="/usr/lib/libretro/snes9x_libretro.so" ; ROM_DIR="/home/pi/roms/snes" ;;
  *)
    echo "usage: $0 <nes|snes>" >&2
    exit 2
    ;;
esac

if [ ! -f "$CORE" ]; then
  echo "RetroArch core missing: $CORE" >&2
  exit 3
fi

# Pick the first ROM in the system dir. The mode-switch is "drop the
# user into something playable" — game-selection UX comes from the
# RetroArch quick-menu (start to open).
ROM="$(ls -1 "$ROM_DIR"/*.{nes,smc,sfc,zip} 2>/dev/null | head -1)"
if [ -z "$ROM" ]; then
  echo "No ROMs found in $ROM_DIR" >&2
  exit 4
fi

# Kill the workout Chromium and any prior RetroArch so the next one
# owns the display cleanly.
pkill -x chromium      2>/dev/null
pkill -f "/usr/bin/chromium" 2>/dev/null
pkill -x retroarch     2>/dev/null
sleep 1

export DISPLAY=:0
export XAUTHORITY="$(ls /tmp/serverauth.* 2>/dev/null | head -1)"

# Run as the pi user, full-screen.
nohup retroarch -L "$CORE" "$ROM" --fullscreen \
  >/tmp/retroarch.log 2>&1 &

echo "arcade mode active (system=$SYSTEM rom=$(basename "$ROM") pid=$!)"
