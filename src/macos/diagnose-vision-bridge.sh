#!/bin/sh
# Read-only macOS bridge, launchd, Claude and CC Switch diagnostics.
set -u

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${BRIDGE_DIR}/bridge.env"}
BRIDGE_PLIST=${BRIDGE_PLIST:-"${HOME}/Library/LaunchAgents/com.claude.deepseek-vision-bridge.plist"}
BRIDGE_LABEL=${BRIDGE_LABEL:-com.claude.deepseek-vision-bridge}
CCSWITCH_DIR=${CCSWITCH_DIR:-"${HOME}/.cc-switch"}
CCSWITCH_PORT=${CCSWITCH_PORT:-15721}
ROUTE_APP_TYPE=auto
SKIP_CCSWITCH=0
SKIP_ROUTE_CHECK=0
env_file_insecure=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-ccswitch) SKIP_CCSWITCH=1 ;;
        --skip-route-check) SKIP_ROUTE_CHECK=1 ;;
        --ccswitch-port)
            [ "$#" -ge 2 ] || { printf '%s\n' "missing value for --ccswitch-port" >&2; exit 2; }
            CCSWITCH_PORT=$2
            shift
            ;;
        --app-type)
            [ "$#" -ge 2 ] || { printf '%s\n' "missing value for --app-type" >&2; exit 2; }
            ROUTE_APP_TYPE=$2
            shift
            ;;
        *) printf '%s\n' "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -f "$BRIDGE_ENV_FILE" ]; then
    if [ -L "$BRIDGE_ENV_FILE" ] || [ "$(stat -f '%Lp' "$BRIDGE_ENV_FILE" 2>/dev/null || printf 'unknown')" != 600 ]; then
        env_file_insecure=1
    else
        set -a
        # shellcheck disable=SC1090
        . "$BRIDGE_ENV_FILE"
        set +a
    fi
fi

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${BRIDGE_DIR}/bridge.env"}
BRIDGE_HOST=${BRIDGE_HOST:-127.0.0.1}
BRIDGE_PORT=${BRIDGE_PORT:-15720}
BRIDGE_NODE=${BRIDGE_NODE:-"$(command -v node 2>/dev/null || true)"}

case "$BRIDGE_PORT" in
    ''|*[!0-9]*) BRIDGE_PORT_VALID=no ;;
    *)
        if [ "$BRIDGE_PORT" -ge 1 ] && [ "$BRIDGE_PORT" -le 65535 ]; then
            BRIDGE_PORT_VALID=yes
        else
            BRIDGE_PORT_VALID=no
        fi
        ;;
esac

health_url() {
    case "$BRIDGE_HOST" in
        0.0.0.0) printf 'http://127.0.0.1:%s/health\n' "$BRIDGE_PORT" ;;
        ::) printf 'http://[::1]:%s/health\n' "$BRIDGE_PORT" ;;
        *:*) printf 'http://[%s]:%s/health\n' "$BRIDGE_HOST" "$BRIDGE_PORT" ;;
        *) printf 'http://%s:%s/health\n' "$BRIDGE_HOST" "$BRIDGE_PORT" ;;
    esac
}

print_check() {
    printf '%-32s %-5s %s\n' "$1" "$2" "$3"
}

bridge_health="FAIL"
if [ -n "$BRIDGE_NODE" ] && [ -f "$BRIDGE_DIR/bridge-health.js" ]; then
    if BRIDGE_EXPECTED_VERSION=0.2.1 BRIDGE_HEALTH_TIMEOUT_MS=2500 \
        "$BRIDGE_NODE" "$BRIDGE_DIR/bridge-health.js" "$(health_url)" >/dev/null 2>&1; then
        bridge_health="PASS"
    fi
fi

launch_agent="WARN"
if command -v launchctl >/dev/null 2>&1; then
    if launchctl print "gui/$(id -u)/$BRIDGE_LABEL" >/dev/null 2>&1; then
        launch_agent="PASS"
    else
        launch_agent="WARN"
    fi
fi

bridge_port_listener="no"
if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -a -iTCP:"$BRIDGE_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
        bridge_port_listener="yes"
    fi
fi

upstream_valid="no"
if [ "$BRIDGE_PORT_VALID" = yes ] && [ -n "${UPSTREAM:-}" ] && [ -n "$BRIDGE_NODE" ] && BRIDGE_PORT="$BRIDGE_PORT" "$BRIDGE_NODE" -e '
  const value = process.env.UPSTREAM || "";
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname) process.exit(1);
    if (url.hostname === "127.0.0.1" && url.port === process.env.BRIDGE_PORT) process.exit(1);
  } catch { process.exit(1); }
' >/dev/null 2>&1; then
    upstream_valid="yes"
fi

vision_base_url_valid="no"
if [ -n "${VISION_BASE_URL:-}" ] && [ -n "$BRIDGE_NODE" ] && VISION_BASE_URL="$VISION_BASE_URL" "$BRIDGE_NODE" -e '
  const value = process.env.VISION_BASE_URL || "";
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname) process.exit(1);
  } catch { process.exit(1); }
' >/dev/null 2>&1; then
    vision_base_url_valid="yes"
fi

required_config="FAIL"
if [ "$env_file_insecure" -eq 0 ] && [ "$upstream_valid" = "yes" ] &&
    [ "$vision_base_url_valid" = "yes" ] && [ -n "${VISION_API_KEY:-}" ] && [ -n "${VISION_MODEL:-}" ]; then
    required_config="PASS"
fi

printf '%s\n' "Vision Bridge macOS diagnostic (read-only)"
printf '%-32s %-5s %s\n' "Check" "State" "Detail"
printf '%s\n' "--------------------------------  ----- -----------------------------------------------"
print_check "Bridge health" "$bridge_health" "$(health_url); managed version 0.2.1"
print_check "Bridge port ownership" "$( [ "$bridge_port_listener" = yes ] && printf PASS || printf WARN )" "listening=$bridge_port_listener; port=$BRIDGE_PORT"
print_check "launchd agent" "$launch_agent" "$BRIDGE_LABEL"
required_detail="UPSTREAM and VISION_BASE_URL format plus VISION_API_KEY and VISION_MODEL presence checked; values hidden"
[ "$env_file_insecure" -eq 0 ] || required_detail="bridge.env must be a non-symlink file with 600 permissions; values hidden"
print_check "Required configuration" "$required_config" "$required_detail"

route_status="SKIP"
route_detail="route check skipped by request"
if [ "$SKIP_ROUTE_CHECK" -eq 0 ] && [ -x "$BRIDGE_NODE" ] && [ -f "$BRIDGE_DIR/configure-ccswitch-route.js" ]; then
    route_output=$("$BRIDGE_NODE" "$BRIDGE_DIR/configure-ccswitch-route.js" \
        --cc-switch-directory "$CCSWITCH_DIR" --app-type "$ROUTE_APP_TYPE" --status 2>&1 || true)
    route_check_output=$("$BRIDGE_NODE" "$BRIDGE_DIR/configure-ccswitch-route.js" \
        --cc-switch-directory "$CCSWITCH_DIR" --app-type "$ROUTE_APP_TYPE" \
        --bridge-host "$BRIDGE_HOST" --bridge-port "$BRIDGE_PORT" --check-target 2>&1)
    route_check_status=$?
    if [ "$route_check_status" -eq 0 ]; then
        route_status="PASS"
        route_detail=$(printf '%s\n%s' "$route_output" "$route_check_output" | tr '\n' ' ')
    else
        route_status="WARN"
        route_detail=$(printf '%s\n%s' "$route_output" "$route_check_output" | tr '\n' ' ')
    fi
fi
if [ "$SKIP_ROUTE_CHECK" -eq 1 ]; then
    route_status="SKIP"
fi
print_check "CC Switch provider route" "$route_status" "$route_detail"

ccswitch_status="SKIP"
ccswitch_detail="CC Switch checks skipped by request"
if [ "$SKIP_CCSWITCH" -eq 0 ]; then
    ccswitch_status="FAIL"
    ccswitch_detail="127.0.0.1:$CCSWITCH_PORT listening=no"
    if command -v lsof >/dev/null 2>&1 && lsof -nP -a -iTCP:"$CCSWITCH_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
        ccswitch_status="PASS"
        ccswitch_detail="127.0.0.1:$CCSWITCH_PORT listening=yes"
    fi
fi
print_check "CC Switch local proxy" "$ccswitch_status" "$ccswitch_detail"

startup_status="SKIP"
startup_detail="CC Switch checks skipped by request"
if [ "$SKIP_CCSWITCH" -eq 0 ] && [ -f "$CCSWITCH_DIR/settings.json" ]; then
    startup_value=$(CCSWITCH_SETTINGS="$CCSWITCH_DIR/settings.json" "$BRIDGE_NODE" -e '
      const fs = require("node:fs");
      try {
        const value = JSON.parse(fs.readFileSync(process.env.CCSWITCH_SETTINGS, "utf8")).launchOnStartup;
        process.stdout.write(value === true ? "enabled" : value === false ? "disabled" : "unknown");
      } catch { process.stdout.write("unreadable"); }
    ' 2>/dev/null || printf 'unreadable')
    startup_status="WARN"
    [ "$startup_value" = enabled ] && startup_status="PASS"
    startup_detail="$startup_value (CC Switch setting is not modified by this installer)"
fi
print_check "CC Switch login startup" "$startup_status" "$startup_detail"

printf '%s\n' "No API key, route credential, provider setting, or database value was printed."

if [ "$bridge_health" != PASS ] || [ "$required_config" != PASS ]; then
    exit 1
fi
if [ "$SKIP_CCSWITCH" -eq 0 ] && [ "$ccswitch_status" != PASS ]; then
    exit 1
fi
exit 0
