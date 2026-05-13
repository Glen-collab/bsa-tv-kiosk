#!/bin/bash
# switch-to-workouts.sh — flip the Pi from arcade mode back to the
# workout-TV kiosk. Called by:
#   • bsa-kiosk-agent.py when /api/kiosk/tv-config flips display_mode
#     back to 'workout' (admin pressed Stop on the dashboard)
#   • pi_arcade_kiosk's /api/exit-to-workouts when the user picked the
#     on-screen "← Back to Workouts" tile with a gamepad / touch
#
# Mechanism: clear /tmp/bsa-mode (so labwc-autostart's pick_url reverts
# to the workout URL on respawn), kill any in-progress retroarch, and
# pkill the arcade Chromium so labwc respawns into the workout view.

set -u

rm -f /tmp/bsa-mode 2>/dev/null

# Stop any in-progress emulator first so the workout view doesn't have
# to fight retroarch for the display.
pkill -x retroarch 2>/dev/null

# Kill the arcade Chromium — labwc-autostart's respawn picks the
# (now-default) workout URL on the next iteration.
pkill -x chromium 2>/dev/null
pkill -f "/usr/bin/chromium" 2>/dev/null

# Free RAM — the Flask launcher isn't needed until the next arcade flip.
# sudo per the sudoers entry in 010_pi-kiosk-agent.
sudo systemctl stop pi-arcade.service 2>/dev/null || true

echo "workout mode requested"
