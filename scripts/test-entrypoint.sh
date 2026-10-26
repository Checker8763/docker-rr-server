#!/usr/bin/env bash
# Tests the entrypoint in the built image with a fake manager instead of Wine (no Steam download):
#   scripts/test-entrypoint.sh [image]   (default docker-rr-server:local; takes about 3 minutes)
# Docs: docs/BUILD.md#lint-and-tests
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

IMAGE="${1:-docker-rr-server:local}"
CONTAINER="rr-entrypoint-test"
failed=0
passed=0

check() {  # description command...
    local description="$1"; shift
    if "$@"; then
        passed=$((passed + 1))
    else
        echo "FAIL: $description"
        failed=$((failed + 1))
    fi
}

# Fake "wine": answers on port 8088 like the web UI and stops on Ctrl+C like the manager.
# With FAKE_HANG_AFTER=<seconds> the web UI stops answering after that time (the manager hangs).
# Python, because a script started in the background inherits "ignore Ctrl+C", which bash cannot undo.
fakes="$(mktemp -d)"
cat >"$fakes/wine" <<'EOF'
#!/usr/bin/env python3
import os, signal, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if sys.argv[1:] == ["--version"]:  # the entrypoint logs the version
    sys.exit(print("wine-fake"))

class WebUi(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def log_message(self, *args):
        pass

def stop(*_):  # the marker file shows that Ctrl+C arrived; the console may already be closed
    open("/tmp/ctrl-c-received", "w").close()
    os._exit(0)

signal.signal(signal.SIGINT, stop)
web_ui = ThreadingHTTPServer(("", 8088), WebUi)
threading.Thread(target=web_ui.serve_forever, daemon=True).start()
print("fake manager: Starting frontend on http://*:8088/", flush=True)
if os.environ.get("FAKE_HANG_AFTER"):
    time.sleep(int(os.environ["FAKE_HANG_AFTER"]))
    web_ui.shutdown()  # the port stays open but nobody answers, like the hanging manager
    print("fake manager: web UI hangs", flush=True)
while True:
    time.sleep(1)
EOF
printf '#!/bin/sh\nexit 0\n' >"$fakes/wineserver"
chmod 755 "$fakes" "$fakes"/*  # readable for the container user, whatever UID runs the test

# Starts the image in the background with fake server files and an empty Wine prefix, so neither
# SteamCMD nor .NET is needed (works with the "public" image too). FAKE_NO_SERVER_FILES=1 leaves out the server files.
start() {  # extra docker run arguments...
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    docker run -d --name "$CONTAINER" -v "$fakes:/fakes:ro" \
        -e PATH="/fakes:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        -e WINEPREFIX=/tmp/prefix -e UPDATE_ON_START=false -e STOP_TIMEOUT=10 "$@" "$IMAGE" bash -c '
            mkdir -p /tmp/prefix && touch /tmp/prefix/system.reg
            if [[ -n "${FAKE_OLD_XVFB_FILES:-}" ]]; then  # what a killed Xvfb leaves behind in a restarted container
                printf "%10d\n" 1 >/tmp/.X0-lock  # process 1 is alive, as old IDs often are after a restart
                mkdir -p /tmp/.X11-unix
                python3 -c "import socket; socket.socket(socket.AF_UNIX).bind(\"/tmp/.X11-unix/X0\")"
            fi
            if [[ -z "${FAKE_NO_SERVER_FILES:-}" ]]; then
                mkdir -p /data/raceroom/steamapps
                touch /data/raceroom/RRRE_Dedicated.exe
                printf "\"StateFlags\"\t\t\"4\"\n" >/data/raceroom/steamapps/appmanifest_354060.acf
            fi
            exec /opt/rr/entrypoint.sh' >/dev/null
}

wait_for_log() {  # text seconds
    local give_up=$((SECONDS + $2))
    until docker logs "$CONTAINER" 2>&1 | grep -qF -- "$1"; do
        (( SECONDS < give_up )) || return 1
        sleep 1
    done
}

# The fake manager leaves this file when it got Ctrl+C; docker cp also works on a stopped container
got_ctrl_c() {
    docker cp "$CONTAINER:/tmp/ctrl-c-received" - >/dev/null 2>&1
}

exit_code() {
    docker wait "$CONTAINER"
}

echo "1/5 start, access file and graceful stop"
start -e WEBUI_USERS="admin:top-secret,anna:pw2" -e WEBUI_WATCHDOG_MINUTES=0 -e BACKUP_HOURS=0
check "manager started" wait_for_log "fake manager: Starting frontend" 60
check "health check answers" docker exec "$CONTAINER" /opt/rr/healthcheck.sh
check "access file has mode 600" test "$(docker exec "$CONTAINER" stat -c %a /data/raceroom/access)" = 600
check "access file has one line per login" test "$(docker exec "$CONTAINER" sh -c 'wc -l < /data/raceroom/access')" = 2
docker stop -t 30 "$CONTAINER" >/dev/null
check "graceful stop ends with exit code 0" test "$(exit_code)" = 0
check "stop sends Ctrl+C to the manager" got_ctrl_c
check "passwords never appear in the log" bash -c "! docker logs $CONTAINER 2>&1 | grep -q -e top-secret -e pw2"

echo "2/5 watchdog (takes about 2 minutes)"
start -e WEBUI_USERS="admin:secret" -e WEBUI_WATCHDOG_MINUTES=1 -e BACKUP_HOURS=0 -e FAKE_HANG_AFTER=40
check "watchdog notices the hanging web UI" wait_for_log "web UI has not answered for 1 min" 180
check "watchdog ends the container with exit code 1" test "$(timeout 30 docker wait "$CONTAINER")" = 1
check "the manager is stopped first" got_ctrl_c

echo "3/5 wrong setting"
start -e BACKUP_HOURS=abc
check "a wrong setting stops the start with exit code 1" test "$(timeout 60 docker wait "$CONTAINER")" = 1
check "the log names the setting" wait_for_log 'BACKUP_HOURS="abc" is not a number' 5

echo "4/5 server files missing"
start -e FAKE_NO_SERVER_FILES=1
check "missing server files stop the start with exit code 1" test "$(timeout 60 docker wait "$CONTAINER")" = 1
check "the log names the missing file" wait_for_log "RRRE_Dedicated.exe is missing" 5

echo "5/5 Xvfb after a restart of the same container"
xvfb_running() {
    docker exec "$CONTAINER" pgrep -x Xvfb >/dev/null
}
start -e FAKE_OLD_XVFB_FILES=1 -e WEBUI_WATCHDOG_MINUTES=0 -e BACKUP_HOURS=0
check "manager started despite old Xvfb files" wait_for_log "fake manager: Starting frontend" 60
check "Xvfb runs despite its old lock file" xvfb_running
docker restart -t 30 "$CONTAINER" >/dev/null
check "manager started again after docker restart" wait_for_log "fake manager: Starting frontend" 60
check "Xvfb runs again after docker restart" xvfb_running
check "Xvfb never complained about a running server" bash -c "! docker logs $CONTAINER 2>&1 | grep -q 'already active'"

docker rm -f "$CONTAINER" >/dev/null 2>&1
rm -rf "$fakes"
echo "entrypoint: $passed passed, $failed failed"
(( failed == 0 ))
