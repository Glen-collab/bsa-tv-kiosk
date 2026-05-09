#!/usr/bin/env python3
"""BSA Gym TV captive portal — stdlib-only.

Launched by /usr/local/sbin/wifi-connect-wrapper.sh when the Pi has no
working internet after the boot grace period. Brings up wlan0 as an open
AP "BSA-Kiosk-Setup" at 192.168.42.1, serves a branded form that captures
(gym SSID + password + coach code), connects to the chosen WiFi via nmcli,
saves the coach code to /home/pi/bsa-config, kicks Chromium so the kiosk
autostart respawn loop reloads with the new config, and exits 0.

Run as root from systemd. Requires:
  - /usr/share/bsa-setup/index.html  (the form UI)
  - /home/pi/.config/labwc/autostart (the Chromium respawn loop that
    reads /home/pi/bsa-config)
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import shlex
import subprocess
import sys
import threading
import time

PORT = 80
AP_SSID = "BSA-Kiosk-Setup"
AP_CON_NAME = "bsa-kiosk-setup"
HTML_PATH = "/usr/share/bsa-setup/index.html"
CONFIG_PATH = "/home/pi/bsa-config"
WIFI_IFACE = "wlan0"
LOG_PATH = "/var/log/wifi-connect-wrapper.log"
PI_UID = 1000
PI_GID = 1000


def log(msg):
    line = f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] portal: {msg}\n"
    sys.stderr.write(line)
    try:
        with open(LOG_PATH, "a") as f:
            f.write(line)
    except Exception:
        pass


def run(cmd, timeout=30):
    try:
        p = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def wipe_stale_ap():
    """Remove any leftover AP profile from a prior failed run.

    `nmcli device wifi hotspot` historically creates auto-named connections
    that linger; the previous portal also left half-configured profiles when
    the strip-security path errored. Wipe by name AND by SSID match."""
    run(f"nmcli connection delete {AP_CON_NAME}")
    rc, out, _ = run("nmcli -t -f NAME,TYPE,802-11-wireless.ssid c show")
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[2] == AP_SSID:
            run(f"nmcli connection delete {shlex.quote(parts[0])}")


def bring_up_ap():
    """Build an OPEN AP from scratch — no `wifi hotspot` (it injects WPA).

    The Apr 26 portal used `nmcli device wifi hotspot` then tried to strip
    the security after; that left the connection in a wep-key0-required
    state and AP activation failed forever. The clean path is to add a
    plain wifi connection and set mode=ap with no security from the start."""
    log(f"bringing up AP {AP_SSID}")
    wipe_stale_ap()

    rc, _, err = run(
        f"nmcli connection add type wifi ifname {WIFI_IFACE} "
        f"con-name {AP_CON_NAME} autoconnect no "
        f"ssid {shlex.quote(AP_SSID)}",
        timeout=15,
    )
    if rc != 0:
        log(f"connection add failed rc={rc}: {err}")
        return False

    # IMPORTANT: do NOT touch wifi-sec at all. Setting key-mgmt=none still
    # adds the security section and NM treats it as "WEP, key not provided"
    # → hotspot fails with `wep-key0 not given`. Validated 2026-05-09 across
    # three patterns; only "omit wifi-sec entirely" produces a true open AP.
    settings = [
        "802-11-wireless.mode ap",
        "802-11-wireless.band bg",
        "ipv4.method shared",
        "ipv4.addresses 192.168.42.1/24",
        "ipv6.method ignore",
    ]
    for s in settings:
        rc, _, err = run(f"nmcli connection modify {AP_CON_NAME} {s}")
        if rc != 0:
            log(f"modify '{s}' failed rc={rc}: {err}")

    rc, _, err = run(f"nmcli connection up {AP_CON_NAME}", timeout=20)
    if rc != 0:
        log(f"AP up failed rc={rc}: {err}")
        return False
    log(f"AP {AP_SSID} ready at 192.168.42.1")
    return True


def tear_down_ap():
    log("tearing down AP")
    run(f"nmcli connection down {AP_CON_NAME}")
    run(f"nmcli connection delete {AP_CON_NAME}")


def scan_networks():
    """Return [{ssid, signal, secured}, ...] for nearby WiFi (excl. our AP)."""
    run(f"nmcli device wifi rescan ifname {WIFI_IFACE}", timeout=15)
    time.sleep(2)
    rc, out, _ = run(
        f"nmcli -t -f SSID,SIGNAL,SECURITY device wifi list ifname {WIFI_IFACE}"
    )
    nets = []
    seen = set()
    for line in out.splitlines():
        # nmcli -t escapes ':' in fields as '\:'; parse with that in mind
        parts, cur, i = [], "", 0
        while i < len(line):
            if line[i] == "\\" and i + 1 < len(line):
                cur += line[i + 1]
                i += 2
            elif line[i] == ":":
                parts.append(cur)
                cur = ""
                i += 1
            else:
                cur += line[i]
                i += 1
        parts.append(cur)
        if len(parts) < 3:
            continue
        ssid, signal, security = parts[0], parts[1], parts[2]
        if not ssid or ssid == "--" or ssid == AP_SSID or ssid in seen:
            continue
        seen.add(ssid)
        try:
            sig = int(signal)
        except ValueError:
            sig = 0
        nets.append({
            "ssid": ssid,
            "signal": sig,
            "secured": bool(security and security != "--"),
        })
    nets.sort(key=lambda n: -n["signal"])
    return nets


def save_coach_code(code):
    try:
        with open(CONFIG_PATH, "w") as f:
            json.dump({"coach_code": code}, f)
        os.chown(CONFIG_PATH, PI_UID, PI_GID)
        log(f"coach code {code} saved")
        return True
    except Exception as e:
        log(f"save coach code failed: {e}")
        return False


def connect_wifi(ssid, password):
    """Try to join the chosen network. On failure, delete the half-saved
    connection so the next retry starts clean (otherwise NM keeps a profile
    with bad creds that auto-activates and blocks future portal runs)."""
    cmd = f"nmcli device wifi connect {shlex.quote(ssid)} ifname {WIFI_IFACE}"
    if password:
        cmd += f" password {shlex.quote(password)}"
    rc, out, err = run(cmd, timeout=45)
    if rc == 0:
        log(f"connected to {ssid}")
        return True
    log(f"connect to {ssid} failed rc={rc}: {err or out}")
    # Clean up the failed profile so the boot wrapper doesn't see a "known
    # network" forever and skip the portal.
    run(f"nmcli connection delete {shlex.quote(ssid)}")
    return False


# Coordination between request thread and main thread
_pending_lock = threading.Lock()
_pending_action = None


def schedule_connect(ssid, password):
    global _pending_action
    with _pending_lock:
        _pending_action = (ssid, password)


def take_pending():
    global _pending_action
    with _pending_lock:
        a = _pending_action
        _pending_action = None
        return a


class PortalHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log(f"http {self.address_string()} {fmt % args}")

    def _send(self, code, body, content_type="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if isinstance(body, str):
            body = body.encode()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/networks":
            try:
                self._send(200, json.dumps({"networks": scan_networks()}))
            except Exception as e:
                log(f"scan failed: {e}")
                self._send(500, json.dumps({"error": "scan failed"}))
            return
        # Captive-portal probes from iOS/Android land here too — answering
        # with a 200 to a non-known URL signals "logged in" on Android and
        # triggers the auto-popup on iOS. We just serve our form.
        try:
            with open(HTML_PATH, "rb") as f:
                body = f.read()
            self._send(200, body, "text/html; charset=utf-8")
        except FileNotFoundError:
            self._send(500, b"<h1>BSA setup HTML missing</h1>", "text/html")

    def do_POST(self):
        if self.path != "/api/connect":
            self._send(404, json.dumps({"error": "not found"}))
            return
        n = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(n) if n else b""
        try:
            data = json.loads(raw.decode() or "{}")
        except Exception:
            self._send(400, json.dumps({"error": "bad json"}))
            return
        ssid = (data.get("ssid") or "").strip()
        password = data.get("password") or ""
        coach = (data.get("coachCode") or "").strip().upper()
        if not ssid:
            self._send(400, json.dumps({"error": "Pick a WiFi network."}))
            return
        if not coach.isalnum() or not (4 <= len(coach) <= 20):
            self._send(400, json.dumps({"error": "Coach code must be 4-20 letters/digits."}))
            return
        # Save coach code immediately so the kiosk has it on next respawn
        # even if the WiFi connect fails on this attempt.
        save_coach_code(coach)
        self._send(200, json.dumps({"message": f"Connecting to {ssid}…"}))
        try:
            self.wfile.flush()
        except Exception:
            pass
        schedule_connect(ssid, password)


def serve_until_connect():
    """Loop: AP up → serve portal → on submit, try to join WiFi.

    Returns when nmcli reports success, so caller can exit 0 and the
    wrapper proceeds to launch the kiosk. If the user enters wrong WiFi
    creds, the AP comes back up automatically for a retry.
    """
    while True:
        if not bring_up_ap():
            log("AP failed to come up — sleeping 10s and retrying")
            time.sleep(10)
            continue
        ThreadingHTTPServer.allow_reuse_address = True
        httpd = ThreadingHTTPServer(("0.0.0.0", PORT), PortalHandler)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        log(f"portal listening on 0.0.0.0:{PORT}")
        try:
            while True:
                pending = take_pending()
                if pending:
                    ssid, password = pending
                    log(f"connect requested → {ssid}")
                    time.sleep(1)  # let the response flush before AP teardown
                    httpd.shutdown()
                    httpd.server_close()
                    tear_down_ap()
                    time.sleep(2)
                    if connect_wifi(ssid, password):
                        return
                    log("connect failed — restarting AP for retry")
                    break
                time.sleep(0.5)
        except Exception as e:
            log(f"server loop error: {e}")
            try:
                httpd.shutdown()
                httpd.server_close()
            except Exception:
                pass
            tear_down_ap()
            time.sleep(2)


def kick_chromium():
    """Force the kiosk autostart respawn loop to relaunch Chromium so it
    re-reads /home/pi/bsa-config and switches to the workout URL."""
    rc, _, _ = run("pkill -x chromium")
    log(f"kicked chromium (rc={rc}) — kiosk will reload with new config")


def main():
    if os.geteuid() != 0:
        log("must run as root")
        sys.exit(1)
    try:
        serve_until_connect()
        kick_chromium()
    except KeyboardInterrupt:
        log("interrupted — tearing down")
        tear_down_ap()
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
