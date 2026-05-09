#!/usr/bin/env python3
"""
bsa-kiosk-agent.py — Small long-running process on the Pi kiosk that polls
the BSA backend for commands (shutdown / reboot / reload) and executes them.

Reads the coach's referral_code from /home/pi/bsa-config (placed there by
the captive-portal onboarding flow) and uses it as the queue key.

Install:
    sudo cp bsa-kiosk-agent.py /usr/local/sbin/bsa-kiosk-agent.py
    sudo chmod +x /usr/local/sbin/bsa-kiosk-agent.py
    sudo cp bsa-kiosk-agent.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now bsa-kiosk-agent.service

Logs:
    journalctl -u bsa-kiosk-agent -f
"""

import json
import logging
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

API_BASE = os.environ.get("BSA_API_BASE", "https://app.bestrongagain.com/api/kiosk")
CONFIG_PATH = os.environ.get("BSA_CONFIG_PATH", "/home/pi/bsa-config")
POLL_INTERVAL = int(os.environ.get("BSA_POLL_INTERVAL", "10"))  # seconds
HTTP_TIMEOUT = 8

logging.basicConfig(
    format="[%(asctime)s] %(levelname)s %(message)s",
    level=logging.INFO,
    stream=sys.stdout,
)
log = logging.getLogger("bsa-kiosk-agent")


def read_coach_code():
    """bsa-config can be either:
      • JSON:        {"coach_code": "GLENM7NUS"}
      • KEY=VALUE:   COACH_CODE=GLENM7NUS
    The Pi's labwc-autostart writes JSON; older deployments wrote
    KEY=VALUE. Accept both so the agent works regardless of which
    onboarding flow created the file."""
    try:
        with open(CONFIG_PATH, "r") as f:
            text = f.read()
    except FileNotFoundError:
        log.error("Config file not found: %s", CONFIG_PATH)
        return None
    except Exception as e:
        log.exception("Failed to read %s: %s", CONFIG_PATH, e)
        return None

    # Try JSON first.
    try:
        import json
        data = json.loads(text)
        code = (data.get("coach_code") or data.get("COACH_CODE") or "").strip()
        if code:
            return code
    except Exception:
        pass

    # Fall back to KEY=VALUE.
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^\s*COACH_CODE\s*=\s*["\']?([^"\'\n]+)["\']?\s*$', line)
        if m:
            return m.group(1).strip()
    return None


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "bsa-kiosk-agent/1.0"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.load(resp)


def http_post(url, body=None):
    data = json.dumps(body or {}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "bsa-kiosk-agent/1.0"},
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.load(resp)


def poll(coach_code):
    url = f"{API_BASE}/commands?coach_code={urllib.request.quote(coach_code)}"
    return http_get(url).get("commands", [])


def ack(cmd_id):
    try:
        http_post(f"{API_BASE}/commands/{cmd_id}/ack")
    except Exception as e:
        log.warning("ack %s failed: %s", cmd_id, e)


def execute(cmd):
    """Run a command. Returns True if we should stop the agent afterwards
    (because the system is halting/rebooting)."""
    name = cmd.get("command")
    cmd_id = cmd.get("id")
    log.info("Executing command %s (id=%s)", name, cmd_id)

    if name == "shutdown":
        ack(cmd_id)
        # Give the ack time to flush, then halt.
        subprocess.Popen(["sudo", "shutdown", "-h", "+0"])
        return True
    if name == "reboot":
        ack(cmd_id)
        subprocess.Popen(["sudo", "reboot"])
        return True
    if name == "reload":
        # Reload just kicks Chromium so the TV page refreshes. This lets the
        # coach swap workouts without a full reboot.
        ack(cmd_id)
        subprocess.Popen(["pkill", "-HUP", "chromium"])
        return False
    log.warning("Unknown command: %s", name)
    ack(cmd_id)  # ack so we don't loop forever on a garbage row
    return False


def main():
    coach_code = read_coach_code()
    if not coach_code:
        log.error("No COACH_CODE in %s; exiting", CONFIG_PATH)
        sys.exit(1)
    log.info("Agent online — polling %s for coach=%s every %ds", API_BASE, coach_code, POLL_INTERVAL)
    backoff = POLL_INTERVAL
    while True:
        try:
            cmds = poll(coach_code)
            backoff = POLL_INTERVAL
            for cmd in cmds:
                if execute(cmd):
                    # System is going down — stop polling and let systemd kill us.
                    time.sleep(30)
                    return
        except urllib.error.URLError as e:
            log.warning("Poll failed (network): %s", e)
            backoff = min(backoff * 2, 120)
        except Exception as e:
            log.exception("Poll loop error: %s", e)
            backoff = min(backoff * 2, 120)
        time.sleep(backoff)


if __name__ == "__main__":
    main()
