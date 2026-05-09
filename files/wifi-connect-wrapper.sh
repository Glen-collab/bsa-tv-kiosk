#!/bin/bash
# wifi-connect-wrapper.sh
# Boot-time gate: only fire the captive portal if the Pi truly has no
# working internet. Runs from systemd as `wifi-connect.service`.
#
# Tests three things in sequence:
#   1. nmcli wlan0 reports `connected`  (NM state)
#   2. We can route to the public internet (ping/HTTP probe)
#
# If both pass within the grace period, exit 0 and the kiosk autostart
# loads the workout URL.  If neither, launch the captive portal — this
# means the Pi is at a new gym whose WiFi we've never seen before.

set -u

GRACE_SECS=60
PROBE_URL="https://app.bestrongagain.com/api/kiosk/health"
PROBE_FALLBACK="http://connectivitycheck.gstatic.com/generate_204"
PORTAL="/usr/local/sbin/bsa-setup-portal.py"
LOG="/var/log/wifi-connect-wrapper.log"

log() { echo "[$(date -Is)] wrapper: $*" | tee -a "$LOG" ; }

probe_internet() {
  # Use --max-time so a black-holing captive portal at a coffee shop
  # doesn't hang the boot for minutes. -f = fail on HTTP 4xx/5xx so we
  # don't accept a guest-portal redirect as success.
  curl -fsS --max-time 5 -o /dev/null "$PROBE_URL"     && return 0
  curl -fsS --max-time 5 -o /dev/null "$PROBE_FALLBACK" && return 0
  return 1
}

cleanup_stuck_profiles() {
  # If a saved WiFi profile is in 'activating' state for >30s without
  # ever reaching 'connected', it's almost certainly a bad-password
  # leftover from a previous failed portal run. Delete it so NM doesn't
  # keep auto-activating it on every boot and starving the portal trigger.
  local stuck
  stuck=$(nmcli -t -f NAME,DEVICE,STATE c show --active 2>/dev/null \
            | awk -F: '$3=="activating" && $2=="wlan0" {print $1}')
  for name in $stuck; do
    log "deleting stuck WiFi profile: $name"
    nmcli connection delete "$name" 2>>"$LOG" || true
  done
}

log "waiting up to ${GRACE_SECS}s for working internet on wlan0"
for i in $(seq 1 "$GRACE_SECS"); do
  STATE=$(nmcli -t -f GENERAL.STATE d show wlan0 2>/dev/null \
            | grep -oE '100 \(connected\)' || true)
  if [ -n "$STATE" ] && probe_internet; then
    log "online after ${i}s — exiting without portal"
    exit 0
  fi
  sleep 1
done

# Reaching here means we went a full ${GRACE_SECS}s without a successful
# internet probe. ALWAYS fire the portal. The previous "if NM-connected
# but probe-fails for 30s, hand off to kiosk" branch was meant to handle
# gym guest-portals, but in practice it tripped on stale half-associations
# from a saved-but-unavailable home network, exiting without ever
# launching our own portal. Cleaner to just always show the portal —
# the user can pick a real WiFi from there.
log "no working internet after ${GRACE_SECS}s — cleaning stuck profiles + launching portal"
cleanup_stuck_profiles
exec /usr/bin/python3 "$PORTAL"
