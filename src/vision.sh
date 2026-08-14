#!/bin/sh
# Run the manual Vision Skill with the protected macOS bridge configuration.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
vision_script=${SCRIPT_DIR}/vision.js
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${HOME}/.claude/bridge/bridge.env"}

fail() {
    printf '%s\n' "Vision Skill error: $*" >&2
    exit 1
}

[ -f "$vision_script" ] || fail "Vision Skill script was not found: $vision_script"
[ -f "$BRIDGE_ENV_FILE" ] || fail "bridge environment file was not found: $BRIDGE_ENV_FILE"
[ ! -L "$BRIDGE_ENV_FILE" ] || fail "refusing to source a symlink environment file: $BRIDGE_ENV_FILE"
env_mode=$(stat -f '%Lp' "$BRIDGE_ENV_FILE" 2>/dev/null || printf 'unknown')
[ "$env_mode" = 600 ] || fail "bridge environment file must have 600 permissions: $BRIDGE_ENV_FILE"

# This is the same user-owned configuration file used by the launch agent.
set -a
# shellcheck disable=SC1090
. "$BRIDGE_ENV_FILE"
set +a

BRIDGE_NODE=${BRIDGE_NODE:-"$(command -v node 2>/dev/null || true)"}
[ -n "$BRIDGE_NODE" ] || fail "Node.js was not found. Install Node.js 18+ and reinstall the Vision Skill."
[ -x "$BRIDGE_NODE" ] || fail "Configured BRIDGE_NODE is not executable: $BRIDGE_NODE"
node_major=$("$BRIDGE_NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
case "$node_major" in
    ''|*[!0-9]*) fail "Could not determine the configured Node.js version." ;;
esac
[ "$node_major" -ge 18 ] || fail "Node.js 18+ is required; found Node.js $node_major."
[ -n "${VISION_API_KEY:-}" ] || fail "VISION_API_KEY is not configured. Put it in $BRIDGE_ENV_FILE."

exec "$BRIDGE_NODE" "$vision_script" "$@"
