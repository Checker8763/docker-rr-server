# shellcheck shell=bash
# Preflight checks at container start (sourced by entrypoint.sh).
# Errors abort with concrete instructions instead of ending in hard-to-read
# follow-up failures; warnings are only logged.
# Expects log() and the variables from entrypoint.sh.

preflight_errors=0

fail() { log "ERROR: $*"; preflight_errors=$((preflight_errors + 1)); }
warn() { log "WARNING: $*"; }

check_choice() {  # name value allowed-values...
    local name="$1" value="$2"; shift 2
    local allowed
    for allowed in "$@"; do
        [[ "$value" == "$allowed" ]] && return 0
    done
    fail "$name=\"$value\" is invalid (allowed: $*)"
}

check_uint() {  # name value
    [[ "$2" =~ ^[0-9]+$ ]] || fail "$1=\"$2\" is not a number ≥ 0"
}

# Is the volume writable? Most common mistake: the host directory belongs to root
# (created by Docker) or to another UID.
check_writable() {  # path description
    local dir="$1" what="$2" probe owner hint
    if [[ ! -d "$dir" ]]; then
        owner="$(stat -c '%u:%g' "$(dirname "$dir")" 2>/dev/null || echo "?")"
        fail "$what is missing and could not be created: $dir (parent directory owned by $owner) – on the host: chown -R $(id -u):$(id -g) <RR_DATA_DIR> (docs/CONFIGURATION.md#volumes)"
        return
    fi
    if probe="$(mktemp -p "$dir" .preflight.XXXXXX 2>/dev/null)"; then
        rm -f "$probe"
        return
    fi
    owner="$(stat -c '%u:%g' "$dir")"
    if [[ "$owner" != "$(id -u):$(id -g)" ]]; then
        hint="on the host: chown -R $(id -u):$(id -g) <RR_DATA_DIR>"
    else
        hint="check permissions or a read-only mount"
    fi
    fail "$what is not writable for UID $(id -u): $dir (owner $owner) – $hint (docs/CONFIGURATION.md#volumes)"
}

# WEBUI_USERS: user:pass[,user:pass]; the content is never logged
check_webui_users() {
    local entry i=0
    local -a entries
    if [[ -z "${WEBUI_USERS:-}" ]]; then
        return
    fi
    IFS=',' read -ra entries <<<"$WEBUI_USERS"
    for entry in "${entries[@]}"; do
        i=$((i + 1))
        if [[ -z "${entry// /}" ]]; then
            continue
        fi
        if [[ ! "$entry" =~ ^[^:[:space:]]+:.+$ ]]; then
            fail "WEBUI_USERS: entry $i is not in the format user:password (no spaces in the user name)"
        fi
    done
}

# Wine prefix: baked into the "full" image; the "public" image creates it in the
# /data/wine volume on the first start, which needs the license confirmation.
check_prefix() {
    if [[ -f "$WINEPREFIX/system.reg" ]]; then
        return
    fi
    if [[ "$ACCEPT_MICROSOFT_DOTNET_LICENSE" != "yes" ]]; then
        fail "This image does not contain the .NET Framework 4.8; it is installed into $(dirname "$WINEPREFIX") on the first start. Set ACCEPT_MICROSOFT_DOTNET_LICENSE=yes to accept the Microsoft .NET Framework license terms (README.md#licenses), or build the image yourself (docs/BUILD.md#image-variants)"
        return
    fi
    local dir free_mb
    dir="$(dirname "$WINEPREFIX")"
    check_writable "$dir" "Wine prefix volume (wine)"
    if [[ -d "$dir" ]]; then
        free_mb="$(df -Pm "$dir" | awk 'NR==2 {print $4}')"
        if (( free_mb < 4096 )); then
            warn "only ${free_mb} MB free in $dir (the Wine prefix with .NET needs about 2.5 GB)"
        fi
    fi
}

preflight() {
    log "Preflight checks"

    # Configuration values
    check_choice UPDATE_ON_START "$UPDATE_ON_START" true false
    check_choice AUTOSTART "$AUTOSTART" true false
    check_uint STEAMCMD_RETRIES "$STEAMCMD_RETRIES"
    check_uint STEAMCMD_RETRY_DELAY "$STEAMCMD_RETRY_DELAY"
    check_uint STOP_TIMEOUT "$STOP_TIMEOUT"
    check_uint WEBUI_WATCHDOG_MINUTES "$WEBUI_WATCHDOG_MINUTES"
    check_uint BACKUP_HOURS "$BACKUP_HOURS"
    check_uint BACKUP_KEEP "$BACKUP_KEEP"
    if [[ -n "$ACCEPT_MICROSOFT_DOTNET_LICENSE" ]]; then
        check_choice ACCEPT_MICROSOFT_DOTNET_LICENSE "$ACCEPT_MICROSOFT_DOTNET_LICENSE" yes
    fi
    check_webui_users

    # Runtime environment
    if [[ "$(id -u)" == 0 ]]; then
        warn "running as root – the image is meant to run as user rr (UID from the build)"
    fi
    if ! command -v script >/dev/null; then
        fail "\"script\" (util-linux) is missing – it provides the manager's console"
    fi
    check_prefix
    if [[ ! -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
        fail "SteamCMD is missing: $STEAMCMD_DIR/steamcmd.sh"
    fi

    # Volumes
    check_writable "$SERVER_DIR" "Installation directory (raceroom)"
    check_writable "$APPDATA_DIR" "Manager data (appdata)"
    check_writable "$USERDATA_DIR" "Results/logs (userdata)"

    if [[ -d "$SERVER_DIR" ]]; then
        local free_mb
        free_mb="$(df -Pm "$SERVER_DIR" | awk 'NR==2 {print $4}')"
        if (( free_mb < 1024 )); then
            warn "only ${free_mb} MB free in $SERVER_DIR (installation + game instance need about 300 MB, logs/replays grow)"
        fi
    fi

    # Combinations of settings
    if [[ "$AUTOSTART" == "true" && -z "${REGISTER_PHRASE:-}" ]]; then
        warn "AUTOSTART=true without REGISTER_PHRASE: after a restart the registration is missing and autostart waits in vain"
    fi

    if (( preflight_errors > 0 )); then
        log "Preflight: $preflight_errors error(s) – aborting"
        exit 1
    fi
}
