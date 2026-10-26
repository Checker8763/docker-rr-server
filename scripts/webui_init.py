#!/usr/bin/env python3
"""Post-start tasks through the web UI's HTTP API.

1. REGISTER_PHRASE set: register the server with the RaceRoom backend
   (POST /dedi/register {"Secret": phrase}) – the manager forgets its
   registration on every restart.
2. AUTOSTART=true: start all configured servers
   (POST /dedi/start {"ProcessId": id}).

Started in the background by the entrypoint. Credentials and the phrase are
never printed. API reference: docs/API.md.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = "http://localhost:8088"
TIMEOUT = int(os.environ.get("WEBUI_INIT_TIMEOUT", "300"))
PHRASE = os.environ.get("REGISTER_PHRASE", "").strip()
AUTOSTART = os.environ.get("AUTOSTART", "false").lower() == "true"


def log(msg):
    print(f"[webui-init] {msg}", flush=True)


def headers():
    h = {"Content-Type": "application/json"}
    user = os.environ.get("WEBUI_USERS", "").split(",")[0].strip()
    if user:
        h["Authorization"] = "Basic " + base64.b64encode(user.encode()).decode()
    return h


def request(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers())
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or b"null")


def get_servers():
    """List of servers, "unregistered" on HTTP 403, None if the web UI is not reachable."""
    try:
        servers = request("GET", "/dedi")
        return servers if isinstance(servers, list) else None
    except urllib.error.HTTPError as e:
        with e:  # an error answer is also an open connection
            return "unregistered" if e.code == 403 else None
    except (urllib.error.URLError, OSError, ValueError):
        return None


def register():
    try:
        resp = request("POST", "/dedi/register", {"Secret": PHRASE}) or {}
    except (urllib.error.URLError, OSError, ValueError) as e:
        log(f"registration failed: {type(e).__name__}")
        return
    if resp.get("Ip"):
        log(f"registered for IP {resp['Ip']} (quota {resp.get('Quota')})")
    else:
        log(f"registration: {resp.get('Message', 'no response')}")


def wait_for_servers():
    deadline = time.time() + TIMEOUT
    register_tried = False
    while time.time() < deadline:
        servers = get_servers()
        if isinstance(servers, list):
            return servers
        if servers == "unregistered":
            if not PHRASE:
                log("not registered and REGISTER_PHRASE is empty – register in the web UI")
                return None
            if not register_tried:
                register()
                register_tried = True
        time.sleep(5)
    log(f"web UI not ready after {TIMEOUT}s")
    return None


def main():
    servers = wait_for_servers()
    if servers is None:
        return 1
    if not AUTOSTART:
        return 0
    if not servers:
        log("no servers configured")
        return 0
    for s in servers:
        setting = s.get("GameSetting") or {}
        state = s.get("ProcessState") or {}
        name, sid = setting.get("Name", "?"), setting.get("Id")
        if state.get("Running"):
            log(f"'{name}' is already running")
            continue
        try:
            request("POST", "/dedi/start", {"ProcessId": sid})
            log(f"'{name}' started")
        except (urllib.error.URLError, OSError, ValueError) as e:
            log(f"'{name}' could not be started: {e}")
        time.sleep(5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
