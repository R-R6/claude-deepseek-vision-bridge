#!/bin/sh
# Reload the macOS launch agent so it picks up bridge.env and verify health.
set -eu

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${BRIDGE_DIR}/bridge.env"}
BRIDGE_PLIST=${BRIDGE_PLIST:-"${HOME}/Library/LaunchAgents/com.claude.deepseek-vision-bridge.plist"}
BRIDGE_LABEL=${BRIDGE_LABEL:-com.claude.deepseek-vision-bridge}

fail() {
    printf '%s\n' "Vision Bridge restart error: $*" >&2
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

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${BRIDGE_DIR}/bridge.env"}
BRIDGE_PLIST=${BRIDGE_PLIST:-"${HOME}/Library/LaunchAgents/com.claude.deepseek-vision-bridge.plist"}
BRIDGE_HOST=${BRIDGE_HOST:-127.0.0.1}
BRIDGE_PORT=${BRIDGE_PORT:-15720}
BRIDGE_STARTUP_TIMEOUT_MS=${BRIDGE_STARTUP_TIMEOUT_MS:-30000}
BRIDGE_NODE=${BRIDGE_NODE:-"$(command -v node 2>/dev/null || true)"}

[ -f "$BRIDGE_PLIST" ] || fail "launch agent plist was not found: $BRIDGE_PLIST"
[ -f "$BRIDGE_DIR/bridge-health.js" ] || fail "bridge health helper was not found: $BRIDGE_DIR/bridge-health.js"
[ -n "$BRIDGE_NODE" ] || fail "Node.js was not found in PATH."
[ -x "$BRIDGE_NODE" ] || fail "Configured BRIDGE_NODE is not executable: $BRIDGE_NODE"
node_major=$("$BRIDGE_NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
case "$node_major" in
    ''|*[!0-9]*) fail "Could not determine the configured Node.js version." ;;
esac
[ "$node_major" -ge 18 ] || fail "Node.js 18+ is required; found Node.js $node_major."
[ -n "${UPSTREAM:-}" ] || fail "UPSTREAM is not configured. Put it in $BRIDGE_ENV_FILE or the launchd environment."
[ -n "${VISION_API_KEY:-}" ] || fail "VISION_API_KEY is not configured. Put it in $BRIDGE_ENV_FILE or the launchd environment."

case "$BRIDGE_PORT" in
    ''|*[!0-9]*) fail "BRIDGE_PORT must be an integer between 1 and 65535." ;;
esac
if [ "$BRIDGE_PORT" -lt 1 ] || [ "$BRIDGE_PORT" -gt 65535 ]; then
    fail "BRIDGE_PORT must be an integer between 1 and 65535."
fi

case "$BRIDGE_STARTUP_TIMEOUT_MS" in
    ''|*[!0-9]*) fail "BRIDGE_STARTUP_TIMEOUT_MS must be an integer between 1000 and 120000." ;;
esac
if [ "$BRIDGE_STARTUP_TIMEOUT_MS" -lt 1000 ] || [ "$BRIDGE_STARTUP_TIMEOUT_MS" -gt 120000 ]; then
    fail "BRIDGE_STARTUP_TIMEOUT_MS must be an integer between 1000 and 120000."
fi

health_url() {
    case "$BRIDGE_HOST" in
        0.0.0.0) printf 'http://127.0.0.1:%s/health\n' "$BRIDGE_PORT" ;;
        ::) printf 'http://[::1]:%s/health\n' "$BRIDGE_PORT" ;;
        *:*) printf 'http://[%s]:%s/health\n' "$BRIDGE_HOST" "$BRIDGE_PORT" ;;
        *) printf 'http://%s:%s/health\n' "$BRIDGE_HOST" "$BRIDGE_PORT" ;;
    esac
}

health_url_value=$(health_url)
health_timeout_seconds=$(( (BRIDGE_STARTUP_TIMEOUT_MS + 999) / 1000 ))
domain="gui/$(id -u)"

command -v launchctl >/dev/null 2>&1 || fail "launchctl is required on macOS."

# Only operate on the managed label and installed plist. Never kill a process by name.
launcher_from_plist=$(plutil -extract ProgramArguments.0 raw -o - "$BRIDGE_PLIST" 2>/dev/null || true)
if [ "$launcher_from_plist" != "$BRIDGE_DIR/start-vision-bridge.sh" ]; then
    fail "launch agent plist does not point to the installed Vision Bridge launcher."
fi

if launchctl print "$domain/$BRIDGE_LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "$domain/$BRIDGE_LABEL" || fail "launchctl could not restart $BRIDGE_LABEL"
else
    launchctl bootstrap "$domain" "$BRIDGE_PLIST" || fail "launchctl could not load $BRIDGE_PLIST"
    launchctl kickstart -k "$domain/$BRIDGE_LABEL" || fail "launchctl could not start $BRIDGE_LABEL"
fi

deadline=$(( $(date +%s) + health_timeout_seconds ))
while [ "$(date +%s)" -le "$deadline" ]; do
    if BRIDGE_EXPECTED_VERSION=0.2.1 BRIDGE_HEALTH_TIMEOUT_MS=2000 \
        "$BRIDGE_NODE" "$BRIDGE_DIR/bridge-health.js" "$health_url_value" >/dev/null 2>&1; then
        printf '%s\n' "Vision Bridge restarted and passed health check on port $BRIDGE_PORT."
        exit 0
    fi
    sleep 0.25
done

error_log="$BRIDGE_DIR/vision-bridge.err.log"
if [ -f "$error_log" ]; then
    printf '%s\n' "Vision Bridge did not pass health check within ${BRIDGE_STARTUP_TIMEOUT_MS} ms. See $error_log." >&2
else
    printf '%s\n' "Vision Bridge did not pass health check within ${BRIDGE_STARTUP_TIMEOUT_MS} ms." >&2
fi
exit 1
