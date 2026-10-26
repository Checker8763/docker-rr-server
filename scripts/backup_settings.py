#!/usr/bin/env python3
"""Saves the manager's backup (all servers and their settings) to BACKUP_DIR every BACKUP_HOURS.

The manager loses its settings when the host IP changes; restore a file with the import
in the web UI. Started in the background by the entrypoint. Docs: docs/CONFIGURATION.md
"""
import base64
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

MANAGER_URL = "http://localhost:8088"
BACKUP_DIR = Path(os.environ.get("BACKUP_DIR", "/data/backups"))
BACKUP_HOURS = int(os.environ.get("BACKUP_HOURS", "24"))
BACKUP_KEEP = int(os.environ.get("BACKUP_KEEP", "14"))
RETRY_SECONDS = 60


def log(message):
    print(f"[backup] {message}", flush=True)


def read_backup():
    """The manager's export as a dict, or None while it is not reachable or not registered."""
    login = os.environ.get("WEBUI_USERS", "").split(",")[0].strip()
    request = urllib.request.Request(MANAGER_URL + "/dedi?attachment=true", headers={
        "Authorization": "Basic " + base64.b64encode(login.encode()).decode()})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            backup = json.loads(response.read())
    except (urllib.error.URLError, OSError, ValueError):
        return None
    return backup if isinstance(backup, dict) else None


def without_time(backup):
    return {key: value for key, value in backup.items() if key != "BackupTime"}


def save(backup):
    """Writes a new file only if there are servers and something changed since the newest file."""
    if not backup.get("GameSettings"):
        log("manager reports no servers – nothing saved, older backups kept")
        return
    files = sorted(BACKUP_DIR.glob("servers-*.json"))
    if files:
        try:
            if without_time(json.loads(files[-1].read_text())) == without_time(backup):
                return
        except ValueError:
            pass  # damaged newest file: write a new one
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    target = BACKUP_DIR / time.strftime("servers-%Y-%m-%d-%H%M%S.json")
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(backup, indent=2) + "\n")
    temporary.chmod(0o600)  # contains the join passwords
    temporary.replace(target)  # never leaves a half-written file
    log(f"saved {target.name} ({len(backup['GameSettings'])} servers)")
    for old_file in files[:max(0, len(files) + 1 - BACKUP_KEEP)]:
        old_file.unlink()


def main():
    while True:
        backup = read_backup()
        if backup is None:
            time.sleep(RETRY_SECONDS)
            continue
        try:
            save(backup)
        except OSError as error:
            log(f"could not save: {error}")
        time.sleep(BACKUP_HOURS * 3600)


if __name__ == "__main__":
    if BACKUP_HOURS > 0:
        main()
