#!/bin/bash
# switch-to-workouts.sh — flip the Pi from arcade mode back to the
# workout-TV kiosk. Called by bsa-kiosk-agent.py when
# /api/kiosk/tv-config shows display_mode == workout (after having
# been in a game_* mode).
#
# Side-effects:
#   • kills RetroArch
#   • respawns the Chromium workout kiosk via labwc-autostart's
#     existing wrapper

set -u

pkill -x retroarch 2>/dev/null
sleep 1

# The workout Chromium is normally respawned by labwc-autostart in a
# loop. If our switch-to-arcade.sh killed it, autostart should pick it
# back up — but to be safe, nudge labwc to re-read autostart so the
# kiosk loop relaunches without waiting for the next respawn tick.
pkill -HUP labwc 2>/dev/null

echo "workout mode requested (retroarch killed; labwc HUPed)"
