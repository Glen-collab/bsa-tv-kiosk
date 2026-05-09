# Troubleshooting

When the kiosk misbehaves at a gym you can't SSH into.

---

## TV is stuck on the "Connect to BSA-Kiosk-Setup" page

The Pi is intentionally offline — it doesn't have a known WiFi yet, so
it's waiting for setup. This is the expected first-boot state.

**Fix:** the coach should follow the on-screen instructions: phone WiFi
→ `BSA-Kiosk-Setup` → form pops up → pick gym WiFi + coach code → submit.

If the BSA-Kiosk-Setup network doesn't show up on the phone:
- Power-cycle the Pi (unplug, plug back in, wait 60 seconds)
- Phone must be within ~20 ft, no metal walls
- The portal SSID only appears once the 60s grace period elapses with
  no internet — give it a full minute after boot

---

## TV shows the workout for ~10s, then flips back to setup page

`bsa-config` got cleared or coach code is malformed. SSH and check:
```
cat /home/pi/bsa-config
```
Should print: `{"coach_code": "GLENM7NUS"}`

If empty/missing, the captive portal didn't write it (or the user
abandoned the form). Re-run the captive portal manually:
```
sudo systemctl restart wifi-connect.service
```
Or just write the file yourself:
```
echo '{"coach_code":"YOURCODE"}' | sudo -u pi tee /home/pi/bsa-config
sudo pkill chromium
```
(Chromium's respawn loop will reload with the new config.)

---

## TV connected to WiFi but stuck on a blank/grey page

Either the `/tv/static` page failed to load, or the gym WiFi has a
captive guest-login portal Chromium is stuck behind.

**Captive guest portal:** the kiosk has no way to tap-through. Either
- Move the Pi onto a non-guest network at the gym (ask the gym to
  whitelist the Pi's MAC), or
- Use a phone hotspot for first-time setup, switch to gym WiFi later.

**Page failed to load:** `/tv/static` requires `app.bestrongagain.com`
to be reachable. SSH and probe:
```
curl -I https://app.bestrongagain.com/api/kiosk/health
```
If that fails: gym is firewalling outbound HTTPS to that host, or DNS
is broken. Some gym networks block unknown hostnames — talk to the gym
IT.

---

## I can't SSH because the Pi is on a foreign network

The "lost the IP" problem.

**Fastest recovery (no equipment):** the BSA dashboard reboot button
talks to the kiosk via the cloud, no SSH needed. Have the coach hit
**Reboot TV** in their dashboard — `bsa-kiosk-agent` polls every 10s and
executes the reboot.

**If the kiosk agent isn't running** (e.g. captive portal never wrote a
coach code, so the agent exits):
1. Plug an Ethernet cable from the Pi to the gym router (Pi 4 has
   gigabit ethernet). Pi gets a DHCP IP, you can scan from a laptop on
   the same LAN: `nmap -sn <gym-subnet>`.
2. **OR** pull the SD card, on Windows mount the boot partition and
   edit `etc/NetworkManager/system-connections/<name>.nmconnection`
   to add the gym WiFi credentials. Reinsert and boot.
3. **OR** reflash the SD with new credentials in Pi Imager OS
   Customization — last resort.

---

## Captive portal AP never appears (`BSA-Kiosk-Setup` not visible)

Almost always means the AP failed to come up. Tail the log:
```
sudo tail -50 /var/log/wifi-connect-wrapper.log
```

Old failure mode (pre-May 9): "AP up failed rc=4 ... wep-key0 not given".
Fixed in commit X — we now build the AP via `nmcli c add type wifi`
with explicit `key-mgmt none` instead of trying to strip security
after-the-fact via `wifi hotspot`.

If you see this error AND you're on a Pi with the old portal, redeploy:
```
cd ~/bsa-tv-kiosk && git pull && sudo bash install.sh
```

---

## Forcing the captive portal to fire (testing)

```
# Forget all known WiFi
sudo nmcli c show | awk '/wifi/{print $1}' \
  | xargs -I{} sudo nmcli c delete {}
# Reboot — wrapper sees no internet within 60s and launches portal
sudo reboot
```

---

## Logs to check

```
sudo tail -100 /var/log/wifi-connect-wrapper.log     # portal + wrapper
sudo journalctl -u wifi-connect.service -n 50        # service-level
sudo journalctl -u bsa-kiosk-agent.service -n 50     # command poll
tail -50 /tmp/kiosk-respawn.log                      # chromium relaunches
```
