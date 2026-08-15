#!/bin/sh
# Safely update the macOS CC Switch route with an explicit app restart.
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' "This route coordinator is for macOS only." >&2
    exit 2
fi

BRIDGE_DIR=${BRIDGE_DIR:-"${HOME}/.claude/bridge"}
BRIDGE_NODE=${BRIDGE_NODE:-"$(command -v node 2>/dev/null || true)"}
ROUTE_SCRIPT=${ROUTE_SCRIPT:-"${BRIDGE_DIR}/configure-ccswitch-route.js"}
CCSWITCH_DIR=${CCSWITCH_DIR:-"${HOME}/.cc-switch"}
CCSWITCH_APP_PATH=${CCSWITCH_APP_PATH:-/Applications/CC Switch.app}
CCSWITCH_PORT=${CCSWITCH_PORT:-15721}
CCSWITCH_EXECUTABLE_NAME=cc-switch
CCSWITCH_EXECUTABLE_PATH=
APP_TYPE=auto
BRIDGE_HOST=127.0.0.1
BRIDGE_PORT=15720
BRIDGE_ENV_FILE=${BRIDGE_ENV_FILE:-"${HOME}/.claude/bridge/bridge.env"}
DATABASE_PATH=
SETTINGS_PATH=
BACKUP_DIRECTORY=
HEALTH_TIMEOUT_MS=3000
FORCE=0
FORCE_CLOSE=0
STATUS=0
WAIT_TIMEOUT_SECONDS=30
ORIGINAL_RUNNING=0
APP_CLOSED=0
ROUTE_UPDATED=0
BACKUP_PATH=
TEMP_OUTPUT=
CCSWITCH_PID=

usage() {
    cat <<'EOF'
Usage: configure-ccswitch-route.sh [options]

Options:
  --force-close-ccswitch        Explicitly allow closing/restarting CC Switch.
  --ccswitch-app PATH            CC Switch app bundle (default: /Applications/CC Switch.app).
  --ccswitch-directory PATH      CC Switch data directory (default: ~/.cc-switch).
  --ccswitch-port PORT           CC Switch local proxy port (default: 15721).
  --ccswitch-timeout-seconds N   Wait timeout for close/restart (default: 30).
  --app-type TYPE                auto, claude, or claude-desktop (default: auto).
  --bridge-host HOST             Bridge host (default: 127.0.0.1).
  --bridge-port PORT             Bridge port (default: 15720).
  --bridge-env-file PATH         Bridge environment file for health auth.
  --database PATH                Override the CC Switch database path.
  --settings PATH                Override the CC Switch settings path.
  --backup-directory PATH        Override the SQLite backup directory.
  --health-timeout-ms MS         Bridge health timeout.
  --force                       Force a route rewrite when it already matches.
  --status                      Read and print the current route only.
  --help                        Show this help.
EOF
}

fail() {
    printf '%s\n' "CC Switch route error: $*" >&2
    exit 1
}

positive_integer() {
    value=$1
    name=$2
    case "$value" in
        ''|*[!0-9]*) fail "$name must be a positive integer" ;;
    esac
    [ "$value" -ge 1 ] || fail "$name must be a positive integer"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force-close-ccswitch) FORCE_CLOSE=1 ;;
        --ccswitch-app)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            CCSWITCH_APP_PATH=$2
            shift
            ;;
        --ccswitch-directory)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            CCSWITCH_DIR=$2
            shift
            ;;
        --ccswitch-port)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            CCSWITCH_PORT=$2
            shift
            ;;
        --ccswitch-timeout-seconds)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            WAIT_TIMEOUT_SECONDS=$2
            shift
            ;;
        --app-type)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            APP_TYPE=$2
            shift
            ;;
        --bridge-host)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            BRIDGE_HOST=$2
            shift
            ;;
        --bridge-port)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            BRIDGE_PORT=$2
            shift
            ;;
        --bridge-env-file)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            BRIDGE_ENV_FILE=$2
            shift
            ;;
        --database)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            DATABASE_PATH=$2
            shift
            ;;
        --settings)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            SETTINGS_PATH=$2
            shift
            ;;
        --backup-directory)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            BACKUP_DIRECTORY=$2
            shift
            ;;
        --health-timeout-ms)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            HEALTH_TIMEOUT_MS=$2
            shift
            ;;
        --force) FORCE=1 ;;
        --status) STATUS=1 ;;
        --help) usage; exit 0 ;;
        *) printf '%s\n' "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

positive_integer "$CCSWITCH_PORT" --ccswitch-port
positive_integer "$WAIT_TIMEOUT_SECONDS" --ccswitch-timeout-seconds
positive_integer "$BRIDGE_PORT" --bridge-port
positive_integer "$HEALTH_TIMEOUT_MS" --health-timeout-ms

[ -n "$BRIDGE_NODE" ] || fail "Node.js was not found in PATH"
[ -x "$BRIDGE_NODE" ] || fail "configured Node.js executable is not executable: $BRIDGE_NODE"
[ -f "$ROUTE_SCRIPT" ] || fail "route updater was not found: $ROUTE_SCRIPT"

DATABASE_PATH=${DATABASE_PATH:-"${CCSWITCH_DIR}/cc-switch.db"}
SETTINGS_PATH=${SETTINGS_PATH:-"${CCSWITCH_DIR}/settings.json"}

cleanup() {
    [ -n "$TEMP_OUTPUT" ] && rm -f "$TEMP_OUTPUT"
}

restore_database() {
    [ -n "$BACKUP_PATH" ] || return 0
    [ -f "$BACKUP_PATH" ] || return 0
    restore_dir=$(dirname "$BACKUP_PATH")
    timestamp=$(date +%Y%m%d-%H%M%S)
    for sidecar in "$DATABASE_PATH-wal" "$DATABASE_PATH-shm"; do
        if [ -e "$sidecar" ]; then
            mv "$sidecar" "$restore_dir/failed-$(basename "$sidecar")-$timestamp" || return 1
        fi
    done
    cp -p "$BACKUP_PATH" "$DATABASE_PATH"
    chmod 600 "$DATABASE_PATH"
}

reopen_original_app() {
    [ "$ORIGINAL_RUNNING" -eq 1 ] || return 0
    if validate_ccswitch_process >/dev/null 2>&1; then
        return 0
    fi
    if get_ccswitch_pids | grep -q .; then
        /usr/bin/osascript -e 'tell application "CC Switch" to quit' >/dev/null 2>&1 || return 1
        wait_for_database_release || return 1
    fi
    /usr/bin/open -a "$CCSWITCH_APP_PATH" >/dev/null 2>&1 || return 1
    wait_for_ccswitch
}

finish() {
    exit_code=$?
    if [ "$exit_code" -ne 0 ] && [ "$APP_CLOSED" -eq 1 ] && [ "$ORIGINAL_RUNNING" -eq 1 ]; then
        if [ "$ROUTE_UPDATED" -eq 1 ]; then
            restore_database || printf '%s\n' "Warning: route database rollback failed; backup retained at $BACKUP_PATH" >&2
        fi
        reopen_original_app || printf '%s\n' "Warning: CC Switch could not be restored automatically" >&2
    fi
    cleanup
    exit "$exit_code"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM

get_ccswitch_pids() {
    /usr/bin/pgrep -x "$CCSWITCH_EXECUTABLE_NAME" 2>/dev/null || true
}

validate_ccswitch_process() {
    pids=$(get_ccswitch_pids)
    count=$(printf '%s\n' "$pids" | awk 'NF { count += 1 } END { print count + 0 }')
    [ "$count" -eq 1 ] || return 1
    CCSWITCH_PID=$(printf '%s\n' "$pids" | awk 'NF { print; exit }')
    process_user=$(/bin/ps -p "$CCSWITCH_PID" -o user= 2>/dev/null | awk '{ print $1 }')
    [ "$process_user" = "$(id -un)" ] || return 1
    /usr/sbin/lsof -n -p "$CCSWITCH_PID" -a -d txt -Fn 2>/dev/null \
        | sed -n 's/^n//p' | grep -F -x "$CCSWITCH_EXECUTABLE_PATH" >/dev/null 2>&1
}

database_in_use() {
    for file in "$DATABASE_PATH" "$DATABASE_PATH-wal" "$DATABASE_PATH-shm"; do
        [ -e "$file" ] || continue
        if /usr/sbin/lsof -n "$file" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

wait_for_database_release() {
    deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        if ! get_ccswitch_pids | grep -q . && ! database_in_use; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

wait_for_ccswitch() {
    deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        if validate_ccswitch_process; then
            listener_pid=$(/usr/sbin/lsof -nP -a -iTCP:"$CCSWITCH_PORT" -sTCP:LISTEN -t 2>/dev/null || true)
            if [ "$listener_pid" = "$CCSWITCH_PID" ]; then
                return 0
            fi
        fi
        sleep 0.25
    done
    return 1
}

run_route_updater() {
    set -- "$BRIDGE_NODE" "$ROUTE_SCRIPT" \
        --cc-switch-directory "$CCSWITCH_DIR" \
        --database "$DATABASE_PATH" \
        --settings "$SETTINGS_PATH" \
        --app-type "$APP_TYPE" \
        --bridge-host "$BRIDGE_HOST" \
        --bridge-port "$BRIDGE_PORT" \
        --bridge-env-file "$BRIDGE_ENV_FILE" \
        --health-timeout-ms "$HEALTH_TIMEOUT_MS"
    if [ -n "$BACKUP_DIRECTORY" ]; then
        set -- "$@" --backup-directory "$BACKUP_DIRECTORY"
    fi
    if [ "$FORCE" -eq 1 ]; then
        set -- "$@" --force
    fi
    "$@"
}

if [ "$STATUS" -eq 1 ]; then
    exec "$BRIDGE_NODE" "$ROUTE_SCRIPT" \
        --cc-switch-directory "$CCSWITCH_DIR" \
        --database "$DATABASE_PATH" \
        --settings "$SETTINGS_PATH" \
        --app-type "$APP_TYPE" \
        --status
fi

# A first attempt avoids closing CC Switch when the route is already correct,
# and also handles an initially stopped app without changing its state.
TEMP_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/vision-bridge-route.XXXXXX")
set +e
run_route_updater >"$TEMP_OUTPUT" 2>&1
route_status=$?
set -e
if [ "$route_status" -eq 0 ]; then
    cat "$TEMP_OUTPUT"
    exit 0
fi
if ! grep -F "CC Switch database is in use" "$TEMP_OUTPUT" >/dev/null 2>&1; then
    cat "$TEMP_OUTPUT" >&2
    exit "$route_status"
fi
if [ "$FORCE_CLOSE" -eq 0 ]; then
    cat "$TEMP_OUTPUT" >&2
    printf '%s\n' "CC Switch was not changed. If the route must be updated while CC Switch is running, use --force-close-ccswitch from an independent Terminal." >&2
    exit "$route_status"
fi

[ -d "$CCSWITCH_APP_PATH" ] || fail "CC Switch app was not found: $CCSWITCH_APP_PATH"
[ -f "$CCSWITCH_APP_PATH/Contents/Info.plist" ] || fail "CC Switch Info.plist was not found: $CCSWITCH_APP_PATH"
CCSWITCH_EXECUTABLE_NAME=$(plutil -extract CFBundleExecutable raw -o - "$CCSWITCH_APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[ "$CCSWITCH_EXECUTABLE_NAME" = cc-switch ] || fail "CC Switch executable identity could not be verified"
CCSWITCH_EXECUTABLE_PATH=$CCSWITCH_APP_PATH/Contents/MacOS/$CCSWITCH_EXECUTABLE_NAME
[ -x "$CCSWITCH_EXECUTABLE_PATH" ] || fail "CC Switch executable was not found: $CCSWITCH_EXECUTABLE_PATH"

if validate_ccswitch_process; then
    ORIGINAL_RUNNING=1
else
    if get_ccswitch_pids | grep -q .; then
        fail "CC Switch process identity could not be verified; refusing to close it"
    fi
    if database_in_use; then
        fail "CC Switch database is held by an unknown process; refusing to overwrite it"
    fi
fi

if [ "$ORIGINAL_RUNNING" -eq 1 ]; then
    /usr/bin/osascript -e 'tell application "CC Switch" to quit' >/dev/null 2>&1 \
        || fail "could not request CC Switch to quit"
    APP_CLOSED=1
    wait_for_database_release || fail "CC Switch database did not become free within ${WAIT_TIMEOUT_SECONDS}s"
fi

run_route_updater >"$TEMP_OUTPUT" 2>&1 || {
    cat "$TEMP_OUTPUT" >&2
    exit 1
}
cat "$TEMP_OUTPUT"
BACKUP_PATH=$(sed -n 's/.*Backup: //p' "$TEMP_OUTPUT" | tail -n 1)
if [ "$ORIGINAL_RUNNING" -eq 1 ]; then
    ROUTE_UPDATED=1
    /usr/bin/open -a "$CCSWITCH_APP_PATH" >/dev/null 2>&1 || fail "CC Switch could not be reopened"
    wait_for_ccswitch || fail "CC Switch did not restore its verified 15721 listener"
fi

exit 0
