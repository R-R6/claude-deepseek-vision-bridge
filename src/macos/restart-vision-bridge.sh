#!/bin/sh
# Reload the macOS launch agent, verify health, and restore the last-known-good
# service if the new process cannot start.
set -eu

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${BRIDGE_DIR}/bridge.env"}
BRIDGE_PLIST=${BRIDGE_PLIST:-"${HOME}/Library/LaunchAgents/com.claude.deepseek-vision-bridge.plist"}
BRIDGE_LABEL=${BRIDGE_LABEL:-com.claude.deepseek-vision-bridge}

fail() {
    printf '%s\n' "Vision Bridge restart error: $*" >&2
    exit 1
}

load_environment() {
    [ -f "$BRIDGE_ENV_FILE" ] || fail "bridge environment file was not found: $BRIDGE_ENV_FILE"
    [ ! -L "$BRIDGE_ENV_FILE" ] || fail "refusing to source a symlink environment file: $BRIDGE_ENV_FILE"
    env_mode=$(stat -f '%Lp' "$BRIDGE_ENV_FILE" 2>/dev/null || printf 'unknown')
    [ "$env_mode" = 600 ] || fail "bridge environment file must have 600 permissions: $BRIDGE_ENV_FILE"
    unset UPSTREAM VISION_API_KEY VISION_BASE_URL VISION_MODEL BRIDGE_AUTH_TOKEN
    unset BRIDGE_HOST BRIDGE_PORT BRIDGE_STARTUP_TIMEOUT_MS BRIDGE_NODE
    set -a
    # shellcheck disable=SC1090
    . "$BRIDGE_ENV_FILE"
    set +a
    BRIDGE_HOST=${BRIDGE_HOST:-127.0.0.1}
    BRIDGE_PORT=${BRIDGE_PORT:-15720}
    BRIDGE_STARTUP_TIMEOUT_MS=${BRIDGE_STARTUP_TIMEOUT_MS:-30000}
    BRIDGE_NODE=${BRIDGE_NODE:-"$(command -v node 2>/dev/null || true)"}
}

validate_environment() {
    [ -n "${UPSTREAM:-}" ] || fail "UPSTREAM is not configured. Put it in $BRIDGE_ENV_FILE."
    [ -n "${VISION_API_KEY:-}" ] || fail "VISION_API_KEY is not configured. Put it in $BRIDGE_ENV_FILE."
    [ -n "${VISION_BASE_URL:-}" ] || fail "VISION_BASE_URL is not configured. Put it in $BRIDGE_ENV_FILE."
    [ -n "${VISION_MODEL:-}" ] || fail "VISION_MODEL is not configured. Put it in $BRIDGE_ENV_FILE."
    [ -f "$BRIDGE_PLIST" ] || fail "launch agent plist was not found: $BRIDGE_PLIST"
    [ -f "$BRIDGE_DIR/bridge-health.js" ] || fail "bridge health helper was not found: $BRIDGE_DIR/bridge-health.js"
    [ -f "$BRIDGE_DIR/start-vision-bridge.sh" ] || fail "bridge launcher was not found: $BRIDGE_DIR/start-vision-bridge.sh"
    [ -n "$BRIDGE_NODE" ] || fail "Node.js was not found in PATH."
    [ -x "$BRIDGE_NODE" ] || fail "Configured BRIDGE_NODE is not executable: $BRIDGE_NODE"
    node_major=$($BRIDGE_NODE -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
    case "$node_major" in
        ''|*[!0-9]*) fail "Could not determine the configured Node.js version." ;;
    esac
    [ "$node_major" -ge 18 ] || fail "Node.js 18+ is required; found Node.js $node_major."
    case "$BRIDGE_PORT" in
        ''|*[!0-9]*) fail "BRIDGE_PORT must be an integer between 1 and 65535." ;;
    esac
    [ "$BRIDGE_PORT" -ge 1 ] && [ "$BRIDGE_PORT" -le 65535 ] || fail "BRIDGE_PORT must be an integer between 1 and 65535."
    case "$BRIDGE_STARTUP_TIMEOUT_MS" in
        ''|*[!0-9]*) fail "BRIDGE_STARTUP_TIMEOUT_MS must be an integer between 1000 and 120000." ;;
    esac
    [ "$BRIDGE_STARTUP_TIMEOUT_MS" -ge 1000 ] && [ "$BRIDGE_STARTUP_TIMEOUT_MS" -le 120000 ] ||
        fail "BRIDGE_STARTUP_TIMEOUT_MS must be an integer between 1000 and 120000."
}

health_url() {
    case "$BRIDGE_HOST" in
        0.0.0.0) printf 'http://127.0.0.1:%s/health\n' "$BRIDGE_PORT" ;;
        ::) printf 'http://[::1]:%s/health\n' "$BRIDGE_PORT" ;;
        *:*) printf 'http://[%s]:%s/health\n' "$BRIDGE_HOST" "$BRIDGE_PORT" ;;
        *) printf 'http://%s:%s/health\n' "$BRIDGE_HOST" "$BRIDGE_PORT" ;;
    esac
}

health_passes() {
    BRIDGE_EXPECTED_VERSION=0.2.1 BRIDGE_HEALTH_TIMEOUT_MS=2000 \
        "$BRIDGE_NODE" "$BRIDGE_DIR/bridge-health.js" "$(health_url)" >/dev/null 2>&1
}

wait_for_health() {
    deadline=$(( $(date +%s) + (BRIDGE_STARTUP_TIMEOUT_MS + 999) / 1000 ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        if health_passes; then return 0; fi
        sleep 0.25
    done
    return 1
}

launch_domain="gui/$(id -u)"
command -v launchctl >/dev/null 2>&1 || fail "launchctl is required on macOS."
launcher_from_plist=$(plutil -extract ProgramArguments.0 raw -o - "$BRIDGE_PLIST" 2>/dev/null || true)
[ "$launcher_from_plist" = "$BRIDGE_DIR/start-vision-bridge.sh" ] ||
    fail "launch agent plist does not point to the installed Vision Bridge launcher."

[ -f "$BRIDGE_DIR/bridge-rollback-state.sh" ] || fail "bridge rollback state helper was not found."
# shellcheck disable=SC1090
. "$BRIDGE_DIR/bridge-rollback-state.sh"

load_environment
validate_environment

restart_in_progress=0
previous_bridge_healthy=0
previous_snapshot=

restore_previous_bridge() {
    [ -n "$previous_snapshot" ] || return 1
    launchctl bootout "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1 || true
    bridge_rollback_restore_snapshot "$previous_snapshot" || return 1
    launchctl bootstrap "$launch_domain" "$BRIDGE_PLIST" >/dev/null 2>&1 || return 1
    launchctl kickstart "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1 || return 1
    load_environment
    validate_environment
    wait_for_health
}

finish_restart() {
    exit_code=$?
    trap - EXIT HUP INT TERM
    if [ "$exit_code" -ne 0 ] && [ "$restart_in_progress" -eq 1 ] && [ "$previous_bridge_healthy" -eq 1 ]; then
        set +e
        if restore_previous_bridge; then
            printf '%s\n' "Previous Vision Bridge configuration was restored and passed its health check." >&2
        else
            printf '%s\n' "Previous Vision Bridge configuration could not be restored; inspect the protected rollback state." >&2
        fi
    fi
    exit "$exit_code"
}
trap finish_restart EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

set +e
previous_snapshot=$(bridge_rollback_current_snapshot 2>/dev/null)
snapshot_status=$?
set -e
[ "$snapshot_status" -ne 2 ] || fail "the protected previous Vision Bridge snapshot is invalid"

if launchctl print "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1; then
    if ! health_passes; then
        [ "$snapshot_status" -eq 0 ] || fail "the existing managed Vision Bridge is not healthy and no protected previous state is available"
        previous_bridge_healthy=1
        restart_in_progress=1
        fail "the existing managed Vision Bridge is not healthy; restoring the protected previous state"
    fi
    previous_bridge_healthy=1
    if [ "$snapshot_status" -eq 1 ]; then
        bridge_rollback_snapshot_current || fail "could not save the protected previous Vision Bridge snapshot"
        previous_snapshot=$(bridge_rollback_current_snapshot) || fail "could not verify the protected previous Vision Bridge snapshot"
    fi
fi

restart_in_progress=1
if launchctl print "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "$launch_domain/$BRIDGE_LABEL" || fail "launchctl could not restart $BRIDGE_LABEL"
else
    launchctl bootstrap "$launch_domain" "$BRIDGE_PLIST" || fail "launchctl could not load $BRIDGE_PLIST"
    launchctl kickstart "$launch_domain/$BRIDGE_LABEL" || fail "launchctl could not start $BRIDGE_LABEL"
fi

wait_for_health || fail "Vision Bridge did not pass health check within ${BRIDGE_STARTUP_TIMEOUT_MS} ms."
if ! bridge_rollback_snapshot_current; then
    printf '%s\n' "Vision Bridge is healthy; the previous protected rollback snapshot was retained." >&2
else
    printf '%s\n' "Vision Bridge restarted and passed health check on port $BRIDGE_PORT."
fi
restart_in_progress=0
exit 0
