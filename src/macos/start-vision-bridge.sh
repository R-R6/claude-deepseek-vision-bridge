#!/bin/sh
# Foreground macOS entry point used by launchd and manual diagnostics.
set -eu

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_SCRIPT=${BRIDGE_SCRIPT:-"${BRIDGE_DIR}/vision-bridge.js"}
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${BRIDGE_DIR}/bridge.env"}
BRIDGE_NODE=${BRIDGE_NODE:-""}
START_MODE=manual
if [ "${1:-}" = "--foreground" ]; then
    START_MODE=foreground
fi

fail() {
    printf '%s\n' "Vision Bridge startup error: $*" >&2
    exit 1
}

if [ -f "$BRIDGE_ENV_FILE" ]; then
    [ ! -L "$BRIDGE_ENV_FILE" ] || fail "refusing to source a symlink environment file: $BRIDGE_ENV_FILE"
    env_mode=$(stat -f '%Lp' "$BRIDGE_ENV_FILE" 2>/dev/null || printf 'unknown')
    [ "$env_mode" = 600 ] || fail "bridge environment file must have 600 permissions: $BRIDGE_ENV_FILE"
    # The environment file is user-owned configuration, not repository code.
    # launchd does not source shell startup files, so load it explicitly.
    set -a
    # shellcheck disable=SC1090
    . "$BRIDGE_ENV_FILE"
    set +a
fi

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_SCRIPT=${BRIDGE_SCRIPT:-"${BRIDGE_DIR}/vision-bridge.js"}
BRIDGE_NODE=${BRIDGE_NODE:-"$(command -v node 2>/dev/null || true)"}
BRIDGE_HOST=${BRIDGE_HOST:-127.0.0.1}
BRIDGE_PORT=${BRIDGE_PORT:-15720}

case "$BRIDGE_PORT" in
    ''|*[!0-9]*) fail "BRIDGE_PORT must be an integer between 1 and 65535." ;;
esac
if [ "$BRIDGE_PORT" -lt 1 ] || [ "$BRIDGE_PORT" -gt 65535 ]; then
    fail "BRIDGE_PORT must be an integer between 1 and 65535."
fi
[ -f "$BRIDGE_SCRIPT" ] || fail "Bridge script not found: $BRIDGE_SCRIPT"
[ -n "$BRIDGE_NODE" ] || fail "Node.js was not found. Install Node.js 18+ and reinstall the macOS launch agent."
[ -x "$BRIDGE_NODE" ] || fail "Configured BRIDGE_NODE is not executable: $BRIDGE_NODE"
node_major=$("$BRIDGE_NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
case "$node_major" in
    ''|*[!0-9]*) fail "Could not determine the configured Node.js version." ;;
esac
[ "$node_major" -ge 18 ] || fail "Node.js 18+ is required; found Node.js $node_major."
[ -n "${UPSTREAM:-}" ] || fail "UPSTREAM is not configured. Put it in $BRIDGE_ENV_FILE or the launchd environment."
[ -n "${VISION_API_KEY:-}" ] || fail "VISION_API_KEY is not configured. Put it in $BRIDGE_ENV_FILE or the launchd environment."
[ -n "${VISION_BASE_URL:-}" ] || fail "VISION_BASE_URL is not configured. Put it in $BRIDGE_ENV_FILE or the launchd environment."
[ -n "${VISION_MODEL:-}" ] || fail "VISION_MODEL is not configured. Put it in $BRIDGE_ENV_FILE or the launchd environment."

if ! command -v lsof >/dev/null 2>&1; then
    fail "lsof is required to verify bridge port ownership on macOS."
fi

health_url() {
    case "$BRIDGE_HOST" in
        0.0.0.0) printf 'http://127.0.0.1:%s/health\n' "$BRIDGE_PORT" ;;
        ::) printf 'http://[::1]:%s/health\n' "$BRIDGE_PORT" ;;
        *:*) printf 'http://[%s]:%s/health\n' "$BRIDGE_HOST" "$BRIDGE_PORT" ;;
        *) printf 'http://%s:%s/health\n' "$BRIDGE_HOST" "$BRIDGE_PORT" ;;
    esac
}

port_pids() {
    lsof -nP -a -iTCP:"$BRIDGE_PORT" -sTCP:LISTEN -t 2>/dev/null || true
}

managed_pid() {
    pid=$1
    process_user=$(ps -p "$pid" -o user= 2>/dev/null | tr -d ' ' || true)
    process_command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    current_user=$(id -un)
    [ "$process_user" = "$current_user" ] || return 1
    case "$process_command" in
        *"$BRIDGE_SCRIPT"*) return 0 ;;
        *) return 1 ;;
    esac
}

listener_pids=$(port_pids)
if [ -n "$listener_pids" ]; then
    unmanaged=""
    for pid in $listener_pids; do
        if ! managed_pid "$pid"; then
            unmanaged="$unmanaged $pid"
        fi
    done
    if [ -n "$unmanaged" ]; then
        fail "Port $BRIDGE_PORT is already in use by an unmanaged process (PID(s):$(printf '%s' "$unmanaged")). Refusing to stop or reuse it."
    fi
    if BRIDGE_EXPECTED_VERSION=0.2.1 BRIDGE_HEALTH_TIMEOUT_MS=2000 \
        "$BRIDGE_NODE" "$BRIDGE_DIR/bridge-health.js" "$(health_url)" >/dev/null 2>&1; then
        if [ "$START_MODE" = manual ]; then
            printf '%s\n' "Vision Bridge is already healthy on port $BRIDGE_PORT."
            exit 0
        fi
        # launchctl kickstart -k normally removes the previous process before
        # starting this entry point; wait briefly if the listener is still draining.
        drain_deadline=$(( $(date +%s) + 10 ))
        while [ -n "$(port_pids)" ] && [ "$(date +%s)" -le "$drain_deadline" ]; do
            sleep 0.1
        done
        [ -z "$(port_pids)" ] || fail "the previous managed Vision Bridge process did not release port $BRIDGE_PORT"
    else
        fail "A managed Vision Bridge process is listening on port $BRIDGE_PORT but did not pass the health check."
    fi
fi

mkdir -p "$BRIDGE_DIR"
exec "$BRIDGE_NODE" "$BRIDGE_SCRIPT"
