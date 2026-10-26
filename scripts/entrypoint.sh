#!/usr/bin/env bash
# Starts the RaceRoom Dedicated Server under Wine.
# Flow: preflight -> Wine prefix (first start of the "public" image) -> data links
#       -> SteamCMD update -> access file -> Xvfb -> server.
# SIGTERM triggers a graceful shutdown. Details: docs/ARCHITECTURE.md
set -euo pipefail

# --- Configuration (see docs/CONFIGURATION.md) ----------------------------------
SERVER_DIR="${SERVER_DIR:-/data/raceroom}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
SERVER_EXE="${SERVER_EXE:-RRRE_Dedicated.exe}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
STEAM_USER="${STEAM_USER:-}"
STEAM_PASS="${STEAM_PASS:-}"
STEAMCMD_RETRIES="${STEAMCMD_RETRIES:-5}"
STEAMCMD_RETRY_DELAY="${STEAMCMD_RETRY_DELAY:-10}"
AUTOSTART="${AUTOSTART:-false}"
STOP_TIMEOUT="${STOP_TIMEOUT:-20}"
WEBUI_WATCHDOG_MINUTES="${WEBUI_WATCHDOG_MINUTES:-5}"
BACKUP_HOURS="${BACKUP_HOURS:-24}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"
ACCEPT_MICROSOFT_DOTNET_LICENSE="${ACCEPT_MICROSOFT_DOTNET_LICENSE:-}"
APPDATA_DIR="${APPDATA_DIR:-/data/appdata}"
USERDATA_DIR="${USERDATA_DIR:-/data/userdata}"

STEAM_APP_ID=354060

server_pid=""
xvfb_pid=""

# --- Helpers ---------------------------------------------------------------------
log() { echo "[entrypoint] $*"; }

# Remove terminal control sequences (window title, colours, cursor, CR) so that
# "docker logs" stays readable.
strip_console() {
    sed -u -e $'s/\e\][^\a]*\a//g' -e $'s/\e\[[0-9;?]*[A-Za-z]//g' -e $'s/\r//g' -e 's/^^C//' -e '/^[[:space:]]*$/d'
}

steamcmd() { "$STEAMCMD_DIR/steamcmd.sh" "$@"; }

# State of the installation from SteamCMD's app manifest. SteamCMD writes it only
# after a completed installation; "StateFlags" "4" means fully installed. Prints the
# flags (empty if the manifest is missing).
app_state_flags() {
    local manifest="$SERVER_DIR/steamapps/appmanifest_$STEAM_APP_ID.acf"
    [[ -f "$manifest" ]] || return 0
    awk -F'"' '$2 == "StateFlags" {print $4; exit}' "$manifest"
}

# One download run. Success only if SteamCMD prints "Success! App ...", the app
# manifest reports a complete installation AND the executable exists: the exit code
# is unreliable, right after a self-update SteamCMD sometimes reports success without
# having downloaded anything, and an aborted download can leave the executable
# without the rest of the files.
steamcmd_app_update() {
    local login=(+login anonymous) out flags rc=1
    if [[ -n "$STEAM_USER" ]]; then
        login=(+login "$STEAM_USER" "$STEAM_PASS")
    fi
    out="$(mktemp)"
    steamcmd +@sSteamCmdForcePlatformType windows \
        +force_install_dir "$SERVER_DIR" \
        "${login[@]}" \
        +app_update "$STEAM_APP_ID" validate \
        +quit | strip_console | tee "$out" || true
    if grep -q "Success! App '$STEAM_APP_ID'" "$out"; then
        flags="$(app_state_flags)"
        if [[ "$flags" != "4" ]]; then
            log "SteamCMD reports success, but the app manifest says StateFlags=\"${flags:-missing}\" (expected 4 = fully installed)"
        elif [[ ! -f "$SERVER_DIR/$SERVER_EXE" ]]; then
            log "SteamCMD reports success, but $SERVER_EXE is missing. Contents of $SERVER_DIR:"
            find "$SERVER_DIR" -mindepth 1 -maxdepth 1 -printf '[entrypoint]   %M %u:%g %10s %f\n'
        else
            rc=0
        fi
    fi
    rm -f "$out"
    return "$rc"
}

# Right after its self-update, SteamCMD often fails with "Failed to install app ...
# (Missing configuration)" – a known, transient SteamCMD issue. So: one warm-up run
# (self-update) first, then retries.
update_server() {
    local attempt
    log "SteamCMD self-update (warm-up run)"
    steamcmd +quit | strip_console || true
    log "SteamCMD update ($([[ -n "$STEAM_USER" ]] && echo "Steam account" || echo "anonymous"))"
    for attempt in $(seq "$STEAMCMD_RETRIES"); do
        if steamcmd_app_update; then
            return 0
        fi
        log "SteamCMD update failed (attempt $attempt/$STEAMCMD_RETRIES), waiting ${STEAMCMD_RETRY_DELAY}s"
        sleep "$STEAMCMD_RETRY_DELAY"
    done
    return 1
}

# Image target "public" ships without .NET: on the first start, create the prefix in
# the volume. It is built under a temporary name and only renamed when complete, so an
# interrupted installation is simply repeated on the next start.
install_prefix() {
    local partial="$WINEPREFIX.partial"
    log "Wine prefix missing – installing .NET Framework 4.8 into $WINEPREFIX (first start, takes 10–20 min)"
    rm -rf "$partial"
    WINEPREFIX="$partial" /opt/rr/install-prefix.sh
    mv "$partial" "$WINEPREFIX"
    log "Wine prefix ready"
}

# Where the manager and the game instance keep their data inside the prefix
# (%LOCALAPPDATA% and Documents) -> symlinks to the volumes. Directories there are left
# alone (volumes mounted directly into the prefix, as in older compose files).
link_data_dirs() {
    local users="$WINEPREFIX/drive_c/users/$USER" link target
    local -A links=(
        ["$users/AppData/Local/Sector3_Studios_AB"]="$APPDATA_DIR"
        ["$users/Documents/My Games/SimBin/RaceRoom Dedicated"]="$USERDATA_DIR"
    )
    for link in "${!links[@]}"; do
        target="${links[$link]}"
        if [[ -d "$link" && ! -L "$link" ]]; then
            log "WARNING: $link is a directory, not a link to $target – old compose file? See docs/CONFIGURATION.md#volumes"
            continue
        fi
        mkdir -p "$(dirname "$link")"
        ln -sfn "$target" "$link"
    done
}

# Write the access file from WEBUI_USERS ("user1:pass1,user2:pass2"); never log its content
write_access_file() {
    local access="$SERVER_DIR/access"
    if [[ -n "${WEBUI_USERS:-}" ]]; then
        (umask 077; tr ',' '\n' <<<"$WEBUI_USERS" | sed '/^[[:space:]]*$/d' >"$access")
        log "access file written ($(wc -l <"$access") user(s))"
    elif [[ -f "$access" ]]; then
        log "WEBUI_USERS is empty, keeping the existing access file"
    else
        log "WARNING: no access file – the web UI is only reachable inside the container"
    fi
}

start_xvfb() {
    local socket="/tmp/.X11-unix/X${DISPLAY#:}"
    # A restarted container keeps /tmp; a lock file left by the last Xvfb would stop the new one
    rm -f "/tmp/.X${DISPLAY#:}-lock" "$socket"
    Xvfb "$DISPLAY" -screen 0 1024x768x16 -nolisten tcp &
    xvfb_pid=$!
    for _ in $(seq 20); do
        [[ -S "$socket" ]] && break
        kill -0 "$xvfb_pid" 2>/dev/null || break
        sleep 0.5
    done
    if [[ ! -S "$socket" ]] || ! kill -0 "$xvfb_pid" 2>/dev/null; then
        log "ERROR: Xvfb on $DISPLAY is not running – the game instance would not start"
        exit 1
    fi
    log "Xvfb started on $DISPLAY"
}

# The manager needs a console (it calls Console.ReadKey). "script" gives it its own
# pseudo terminal whose input comes from a FIFO this script keeps open (fd 3); Ctrl+C
# is sent through it on shutdown. setsid: separate session, so signals sent to the
# container do not hit the manager directly. The output goes through a second FIFO
# into the filter, which must be a child of this script, not of "script" – otherwise
# "script" waits for it after the manager has exited.
start_manager() {
    local console_fifo output_fifo server_cmd
    console_fifo="$(mktemp -u /tmp/rr-console.XXXXXX)"
    output_fifo="$(mktemp -u /tmp/rr-output.XXXXXX)"
    mkfifo -m 600 "$console_fifo" "$output_fifo"
    exec 3<>"$console_fifo"
    strip_console <"$output_fifo" &
    printf -v server_cmd '%q ' wine "$SERVER_EXE" "$@"
    setsid script --quiet --flush --return --command "$server_cmd" /dev/null <&3 >"$output_fifo" &
    server_pid=$!
}

# Graceful shutdown: write Ctrl+C into the manager's console. Wine delivers it as
# CTRL_C_EVENT and the manager stops the web UI, workers and game instances.
# SIGINT/SIGTERM sent to the wine process would kill it hard instead.
shutdown() {  # [exit code]
    log "Signal received, stopping server"
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        printf '\003' >&3 || true
        for _ in $(seq "$STOP_TIMEOUT"); do
            kill -0 "$server_pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$server_pid" 2>/dev/null; then
            log "Server still running after ${STOP_TIMEOUT}s, killing it"
        fi
    fi
    wineserver -k 2>/dev/null || true
    if [[ -n "$xvfb_pid" ]]; then
        kill "$xvfb_pid" 2>/dev/null || true
        wait "$xvfb_pid" 2>/dev/null || true  # lets Xvfb remove its lock file before the container ends
    fi
    exit "${1:-0}"
}

# Stops the container (exit code 1, so Docker restarts it) when the web UI answered once
# and then stays silent for WEBUI_WATCHDOG_MINUTES – the manager hangs and needs a restart.
watch_web_ui() {
    local answered=false silent_since=0
    while true; do
        sleep 30
        if /opt/rr/healthcheck.sh 2>/dev/null; then
            answered=true
            silent_since=0
        elif [[ "$answered" == true ]]; then
            (( silent_since > 0 )) || silent_since=$SECONDS
            if (( SECONDS - silent_since >= WEBUI_WATCHDOG_MINUTES * 60 )); then
                log "web UI has not answered for $WEBUI_WATCHDOG_MINUTES min – stopping so Docker restarts the container"
                kill -USR1 $$
                return
            fi
        fi
    done
}

# Subdirectories of the data volume, so that a single mount of RR_DATA_DIR on /data
# is enough. Failures are reported by the preflight check (e.g. /data owned by root).
create_data_dirs() {
    local dirs=("$SERVER_DIR" "$APPDATA_DIR" "$USERDATA_DIR")
    if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
        dirs+=("$(dirname "$WINEPREFIX")")
    fi
    mkdir -p "${dirs[@]}" 2>/dev/null || true
}

# --- Main ------------------------------------------------------------------------
trap shutdown TERM INT
trap "shutdown 1" USR1

# shellcheck source=scripts/preflight.sh
source "$(dirname "$0")/preflight.sh"
create_data_dirs
preflight

if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
    install_prefix
fi
link_data_dirs

if [[ "$UPDATE_ON_START" == "true" ]] && ! update_server; then
    log "WARNING: update failed after $STEAMCMD_RETRIES attempts"
fi
if [[ ! -f "$SERVER_DIR/$SERVER_EXE" ]]; then
    log "ERROR: $SERVER_DIR/$SERVER_EXE is missing (download failed?)"
    exit 1
fi
if [[ "$(app_state_flags)" != "4" ]]; then
    log "WARNING: the installation may be incomplete (app manifest missing or StateFlags not 4) – starting anyway"
fi

write_access_file
start_xvfb

cd "$SERVER_DIR"
log "Starting $SERVER_EXE ($(wine --version))"
start_manager "$@"

if [[ "$AUTOSTART" == "true" || -n "${REGISTER_PHRASE:-}" ]]; then
    python3 /opt/rr/webui_init.py &
fi

if (( WEBUI_WATCHDOG_MINUTES > 0 )); then
    watch_web_ui &
fi

if (( BACKUP_HOURS > 0 )); then
    python3 /opt/rr/backup_settings.py &
fi

wait "$server_pid" || true
log "Server process exited"
wineserver -w 2>/dev/null || true
