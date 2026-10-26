#!/usr/bin/env bash
# Tests for the configuration checks in preflight.sh. Run as a normal user (not root):
#   docker run --rm --user 1000 -v "$PWD:/mnt:ro" -w /mnt bash:5.2 bash scripts/test-preflight.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

log() { :; }  # preflight.sh logs through the entrypoint's log()
# shellcheck source=scripts/preflight.sh
source scripts/preflight.sh

failed=0
passed=0

# Runs a check and compares the number of errors it reports
expect_errors() {  # expected-errors description check arguments...
    local expected="$1" description="$2"; shift 2
    preflight_errors=0
    "$@"
    if (( preflight_errors == expected )); then
        passed=$((passed + 1))
    else
        echo "FAIL: $description – expected $expected error(s), got $preflight_errors"
        failed=$((failed + 1))
    fi
}

# Numbers ≥ 0
expect_errors 0 "0 is a number" check_uint BACKUP_HOURS 0
expect_errors 0 "24 is a number" check_uint BACKUP_HOURS 24
expect_errors 1 "text is not a number" check_uint BACKUP_HOURS abc
expect_errors 1 "negative numbers are refused" check_uint BACKUP_HOURS -1
expect_errors 1 "empty is not a number" check_uint BACKUP_HOURS ""

# Fixed choices
expect_errors 0 "true is allowed" check_choice AUTOSTART true true false
expect_errors 1 "yes is not true/false" check_choice AUTOSTART yes true false
expect_errors 1 "upper case is refused" check_choice AUTOSTART TRUE true false

# Web UI logins
WEBUI_USERS="" expect_errors 0 "no logins is allowed" check_webui_users
WEBUI_USERS="admin:secret" expect_errors 0 "one login" check_webui_users
WEBUI_USERS="admin:secret,anna:pw:with:colons" expect_errors 0 "colons in passwords are allowed" check_webui_users
WEBUI_USERS="admin:secret,,anna:pw" expect_errors 0 "empty entries are skipped" check_webui_users
WEBUI_USERS="admin" expect_errors 1 "a login needs a password" check_webui_users
WEBUI_USERS=":secret" expect_errors 1 "a login needs a name" check_webui_users
WEBUI_USERS="ad min:secret" expect_errors 1 "no spaces in the name" check_webui_users
WEBUI_USERS="admin:secret,anna" expect_errors 1 "every entry is checked" check_webui_users

# Writable volumes
scratch="$(mktemp -d)"
expect_errors 0 "a writable directory passes" check_writable "$scratch" "test"
expect_errors 1 "a missing directory is reported" check_writable "$scratch/missing" "test"
mkdir "$scratch/read-only" && chmod 500 "$scratch/read-only"
expect_errors 1 "a read-only directory is reported" check_writable "$scratch/read-only" "test"
chmod 700 "$scratch/read-only" && rm -rf "$scratch"

echo "preflight checks: $passed passed, $failed failed"
(( failed == 0 ))
