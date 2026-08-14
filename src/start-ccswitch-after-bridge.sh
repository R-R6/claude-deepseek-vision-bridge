#!/bin/sh
# Optional launchd coordinator: start CC Switch only after the bridge is healthy.
set -eu

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${BRIDGE_DIR}/bridge.env"}
BRIDGE_NODE=${BRIDGE_NODE:-"$(command -v node 2>/dev/null || true)"}
BRIDGE_HOST=${BRIDGE_HOST:-127.0.0.1}
BRIDGE_PORT=${BRIDGE_PORT:-15720}
BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS=${BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS:-120000}
CCSWITCH_APP_PATH=${CCSWITCH_APP_PATH:-/Applications/CC Switch.app}

fail() {
    printf '%s\n' "CC Switch startup coordination error: $*" >&2
    exit 1
}

if [ -f "$BRIDGE_ENV_FILE" ]; then
    [ ! -L "$BRIDGE_ENV_FILE" ] || fail "refusing to source a symlink environment file: $BRIDGE_ENV_FILE"
    env_mode=$(stat -f '%Lp' "$BRIDGE_ENV_FILE" 2>/dev/null || printf 'unknown')
    [ "$env_mode" = 600 ] || fail "bridge environment file must have 600 permissions: $BRIDGE_ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    . "$BRIDGE_ENV_FILE"
    set +a
fi

BRIDGE_NODE=${BRIDGE_NODE:-"$(command -v node 2>/dev/null || true)"}
BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS=${BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS:-120000}

[ -n "$BRIDGE_NODE" ] || fail "Node.js was not found in PATH."
[ -x "$BRIDGE_NODE" ] || fail "Configured BRIDGE_NODE is not executable: $BRIDGE_NODE"
node_major=$("$BRIDGE_NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
case "$node_major" in
    ''|*[!0-9]*) fail "Could not determine the configured Node.js version." ;;
esac
[ "$node_major" -ge 18 ] || fail "Node.js 18+ is required; found Node.js $node_major."
[ -f "$BRIDGE_DIR/bridge-health.js" ] || fail "bridge health helper was not found: $BRIDGE_DIR/bridge-health.js"
[ -d "$CCSWITCH_APP_PATH" ] || fail "CC Switch app was not found: $CCSWITCH_APP_PATH"
[ -n "${UPSTREAM:-}" ] || fail "UPSTREAM is not configured. Put it in $BRIDGE_ENV_FILE or the launchd environment."
[ -n "${VISION_API_KEY:-}" ] || fail "VISION_API_KEY is not configured. Put it in $BRIDGE_ENV_FILE or the launchd environment."

case "$BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS" in
    ''|*[!0-9]*) fail "BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS must be an integer between 1000 and 300000." ;;
esac
if [ "$BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS" -lt 1000 ] || [ "$BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS" -gt 300000 ]; then
    fail "BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS must be an integer between 1000 and 300000."
fi

case "$BRIDGE_HOST" in
    0.0.0.0) health_url="http://127.0.0.1:${BRIDGE_PORT}/health" ;;
    ::) health_url="http://[::1]:${BRIDGE_PORT}/health" ;;
    *:*) health_url="http://[${BRIDGE_HOST}]:${BRIDGE_PORT}/health" ;;
    *) health_url="http://${BRIDGE_HOST}:${BRIDGE_PORT}/health" ;;
esac

deadline=$(( $(date +%s) + (BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS + 999) / 1000 ))
while [ "$(date +%s)" -le "$deadline" ]; do
    if BRIDGE_EXPECTED_VERSION=0.2.1 BRIDGE_HEALTH_TIMEOUT_MS=2000 \
        "$BRIDGE_NODE" "$BRIDGE_DIR/bridge-health.js" "$health_url" >/dev/null 2>&1; then
        printf '%s\n' "Vision Bridge is healthy; starting CC Switch."
        exec /usr/bin/open -a "$CCSWITCH_APP_PATH"
    fi
    sleep 0.25
done

printf '%s\n' "Vision Bridge was not healthy within ${BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS} ms; CC Switch was not started." >&2
exit 1
