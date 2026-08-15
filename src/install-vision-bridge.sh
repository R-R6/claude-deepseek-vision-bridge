#!/bin/sh
# Install the Vision Bridge, Vision Skill and macOS launchd entry point.
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' "This installer is for macOS only; use install-vision-bridge.ps1 on Windows." >&2
    exit 2
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_HOME=${HOME}
LAUNCH_AGENTS_DIR=${HOME}/Library/LaunchAgents
BRIDGE_HOST=${BRIDGE_HOST:-127.0.0.1}
BRIDGE_PORT=${BRIDGE_PORT:-15720}
BRIDGE_LABEL=com.claude.deepseek-vision-bridge
CCSWITCH_COORDINATOR_LABEL=com.claude.deepseek-vision-bridge.cc-switch
CCSWITCH_DIR=${CCSWITCH_DIR:-"${HOME}/.cc-switch"}
CCSWITCH_APP_PATH=${CCSWITCH_APP_PATH:-/Applications/CC Switch.app}
CCSWITCH_APP_TYPE=auto
NODE_PATH=$(node -p 'process.execPath' 2>/dev/null || true)
ENV_FILE_SOURCE=
SKIP_LAUNCHCTL=0
COORDINATE_CCSWITCH=0
CONFIGURE_ROUTE=0
FORCE_CLOSE_CCSWITCH=0
launch_domain=
bridge_agent_was_loaded=0
coordinator_agent_was_loaded=0
bridge_agent_changed=0
coordinator_agent_changed=0

usage() {
    cat <<'EOF'
Usage: install-vision-bridge.sh [options]

Options:
  --env-file PATH                 Copy a 600-mode environment file into the bridge bundle.
  --bridge-host HOST              Bridge listen host (default: 127.0.0.1).
  --bridge-port PORT              Bridge listen port (default: 15720).
  --ccswitch-directory PATH       CC Switch data directory (default: ~/.cc-switch).
  --ccswitch-app PATH             CC Switch app bundle (default: /Applications/CC Switch.app).
  --app-type TYPE                 auto, claude, or claude-desktop (default: auto).
  --configure-ccswitch-route      Health-check bridge, back up SQLite, update active route.
  --force-close-ccswitch          With route configuration, close/restart the verified CC Switch app.
  --coordinate-ccswitch-startup   Start CC Switch from a separate launchd coordinator.
  --skip-launchctl                Install files without loading launch agents (for testing).
  --help                          Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-file)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            ENV_FILE_SOURCE=$2
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
        --ccswitch-directory)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            CCSWITCH_DIR=$2
            shift
            ;;
        --ccswitch-app)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            CCSWITCH_APP_PATH=$2
            shift
            ;;
        --app-type)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            CCSWITCH_APP_TYPE=$2
            shift
            ;;
        --configure-ccswitch-route) CONFIGURE_ROUTE=1 ;;
        --force-close-ccswitch) FORCE_CLOSE_CCSWITCH=1 ;;
        --coordinate-ccswitch-startup) COORDINATE_CCSWITCH=1 ;;
        --skip-launchctl) SKIP_LAUNCHCTL=1 ;;
        --help) usage; exit 0 ;;
        *) printf '%s\n' "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

fail() {
    printf '%s\n' "Vision Bridge installation error: $*" >&2
    exit 1
}

require_node_18() {
    node_path=$1
    [ -n "$node_path" ] || fail "Node.js 18+ was not found in PATH."
    [ -x "$node_path" ] || fail "Configured Node.js executable is not executable: $node_path"
    node_major=$("$node_path" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
    case "$node_major" in
        ''|*[!0-9]*) fail "Could not determine the configured Node.js version." ;;
    esac
    [ "$node_major" -ge 18 ] || fail "Node.js 18+ is required; found Node.js $node_major."
}

require_node_18 "$NODE_PATH"
[ -f "$SCRIPT_DIR/vision-bridge.js" ] || fail "source files were not found beside the installer: $SCRIPT_DIR"
[ -f "$SCRIPT_DIR/bridge-health.js" ] || fail "source file was not found: $SCRIPT_DIR/bridge-health.js"

case "$BRIDGE_PORT" in
    ''|*[!0-9]*) fail "--bridge-port must be an integer between 1 and 65535." ;;
esac
if [ "$BRIDGE_PORT" -lt 1 ] || [ "$BRIDGE_PORT" -gt 65535 ]; then
    fail "--bridge-port must be an integer between 1 and 65535."
fi
case "$CCSWITCH_APP_TYPE" in
    auto|claude|claude-desktop) ;;
    *) fail "--app-type must be auto, claude, or claude-desktop." ;;
esac
if [ -n "$ENV_FILE_SOURCE" ]; then
    [ -f "$ENV_FILE_SOURCE" ] || fail "environment file was not found: $ENV_FILE_SOURCE"
    [ ! -L "$ENV_FILE_SOURCE" ] || fail "refusing to copy a symlink as the environment file: $ENV_FILE_SOURCE"
fi
if [ "$COORDINATE_CCSWITCH" -eq 1 ] && [ ! -d "$CCSWITCH_APP_PATH" ]; then
    fail "CC Switch app was not found: $CCSWITCH_APP_PATH"
fi
if [ "$CONFIGURE_ROUTE" -eq 1 ] && [ "$SKIP_LAUNCHCTL" -eq 1 ]; then
    fail "--configure-ccswitch-route requires launchd loading; remove --skip-launchctl"
fi
if [ "$FORCE_CLOSE_CCSWITCH" -eq 1 ] && [ "$CONFIGURE_ROUTE" -eq 0 ]; then
    fail "--force-close-ccswitch requires --configure-ccswitch-route"
fi

bridge_dir=${INSTALL_HOME}/.claude/bridge
skill_dir=${INSTALL_HOME}/.claude/skills/vision
plist_path=${LAUNCH_AGENTS_DIR}/${BRIDGE_LABEL}.plist
coordinator_plist_path=${LAUNCH_AGENTS_DIR}/${CCSWITCH_COORDINATOR_LABEL}.plist
if [ -L "$bridge_dir/bridge.env" ]; then
    fail "refusing to use a symlink as the bridge environment file: $bridge_dir/bridge.env"
fi
if [ -f "$bridge_dir/bridge.env" ] && [ "$(stat -f '%Lp' "$bridge_dir/bridge.env" 2>/dev/null || printf 'unknown')" != 600 ]; then
    fail "existing bridge environment file must have 600 permissions: $bridge_dir/bridge.env"
fi
if [ "$SKIP_LAUNCHCTL" -eq 0 ] && [ -z "$ENV_FILE_SOURCE" ] && [ ! -f "$bridge_dir/bridge.env" ]; then
    fail "--env-file is required before loading launchd when no existing bridge environment file is present."
fi
install_id=$(date +%Y%m%d-%H%M%S)-$$
backup_root=${bridge_dir}/backups/install-${install_id}
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/vision-bridge-install.XXXXXX")
records_path=${stage_root}/records.tsv
manifest_path=${backup_root}/manifest.tsv

cleanup() {
    rm -rf "$stage_root"
}
rollback_files() {
    if [ ! -f "$records_path" ]; then return; fi
    while IFS="$(printf '\t')" read -r destination backup existed; do
        [ -n "$destination" ] || continue
        if [ "$existed" = 1 ]; then
            cp -p "$backup" "$destination" 2>/dev/null || true
        else
            rm -f "$destination" 2>/dev/null || true
        fi
    done < "$records_path"
}
rollback_launch_agents() {
    [ -n "$launch_domain" ] || return
    if [ "$coordinator_agent_changed" -eq 1 ]; then
        launchctl bootout "$launch_domain/$CCSWITCH_COORDINATOR_LABEL" >/dev/null 2>&1 || true
    fi
    if [ "$bridge_agent_changed" -eq 1 ]; then
        launchctl bootout "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1 || true
    fi
}
restore_launch_agents() {
    [ -n "$launch_domain" ] || return
    if [ "$bridge_agent_changed" -eq 1 ] && [ "$bridge_agent_was_loaded" -eq 1 ] && [ -f "$plist_path" ]; then
        launchctl bootstrap "$launch_domain" "$plist_path" >/dev/null 2>&1 || true
        launchctl kickstart "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1 || true
    fi
    if [ "$coordinator_agent_changed" -eq 1 ] && [ "$coordinator_agent_was_loaded" -eq 1 ] && [ -f "$coordinator_plist_path" ]; then
        launchctl bootstrap "$launch_domain" "$coordinator_plist_path" >/dev/null 2>&1 || true
        launchctl kickstart "$launch_domain/$CCSWITCH_COORDINATOR_LABEL" >/dev/null 2>&1 || true
    fi
}
rollback_install() {
    rollback_launch_agents
    rollback_files
    restore_launch_agents
    cleanup
}
trap 'rollback_install' EXIT HUP INT TERM

generate_plist() {
    output=$1
    label=$2
    launcher=$3
    working_dir=$4
    node_path=$5
    env_file=$6
    host=$7
    port=$8
    stdout_path=$9
    stderr_path=${10}
    coordinator=${11:-0}
    app_path=${12:-}
    "$NODE_PATH" - "$output" "$label" "$launcher" "$working_dir" "$node_path" "$env_file" "$host" "$port" "$stdout_path" "$stderr_path" "$coordinator" "$app_path" <<'NODE'
const fs = require("node:fs");
const [output, label, launcher, workingDir, nodePath, envFile, host, port, stdoutPath, stderrPath, coordinator, appPath] = process.argv.slice(2);
const esc = (value) => String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
const item = (value) => `<string>${esc(value)}</string>`;
const env = [
  ["BRIDGE_DIR", workingDir],
  ["BRIDGE_ENV_FILE", envFile],
  ["BRIDGE_NODE", nodePath],
  ["BRIDGE_HOST", host],
  ["BRIDGE_PORT", port],
  ["PATH", `${nodePath.slice(0, nodePath.lastIndexOf("/"))}:/usr/bin:/bin:/usr/sbin:/sbin`],
];
const environment = env.flatMap(([key, value]) => [`<key>${esc(key)}</key>`, item(value)]).join("");
const isCoordinator = coordinator === "1";
const program = isCoordinator ? [item(launcher)] : [item(launcher), item("--foreground")];
const extraEnvironment = isCoordinator ? `<key>CCSWITCH_APP_PATH</key>${item(appPath)}` : "";
const keepAlive = isCoordinator
  ? "<key>KeepAlive</key><false/>"
  : "<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>";
const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key>${item(label)}
<key>ProgramArguments</key><array>${program.join("")}</array>
<key>WorkingDirectory</key>${item(workingDir)}
<key>RunAtLoad</key><true/>
${keepAlive}
<key>ThrottleInterval</key><integer>5</integer>
<key>ProcessType</key><string>Background</string>
<key>EnvironmentVariables</key><dict>${environment}${extraEnvironment}</dict>
<key>StandardOutPath</key>${item(stdoutPath)}
<key>StandardErrorPath</key>${item(stderrPath)}
</dict></plist>
`;
fs.writeFileSync(output, xml, { mode: 0o600 });
NODE
}

stage_file() {
    source=$1
    destination=$2
    label=$3
    mode=${4:-644}
    [ -f "$source" ] || fail "installer source file not found: $source"
    stage_path=${stage_root}/$(printf '%s' "$label" | tr '/ ' '__')-$(basename "$destination")
    cp -p "$source" "$stage_path"
    source_hash=$(shasum -a 256 "$source" | awk '{print $1}')
    stage_hash=$(shasum -a 256 "$stage_path" | awk '{print $1}')
    [ "$source_hash" = "$stage_hash" ] || fail "staged installer file failed verification: $source"
    printf '%s\t%s\t%s\t%s\n' "$stage_path" "$destination" "$label" "$mode" >> "${stage_root}/staged.tsv"
}

stage_generated_file() {
    source=$1
    destination=$2
    label=$3
    mode=${4:-644}
    stage_path=${stage_root}/generated-$(printf '%s' "$label" | tr '/ ' '__')-$(basename "$destination")
    cp -p "$source" "$stage_path"
    printf '%s\t%s\t%s\t%s\n' "$stage_path" "$destination" "$label" "$mode" >> "${stage_root}/staged.tsv"
}

mkdir -p "$stage_root" "$bridge_dir" "$skill_dir" "$LAUNCH_AGENTS_DIR"
generate_plist \
    "${stage_root}/vision-bridge.plist" "$BRIDGE_LABEL" \
    "$bridge_dir/start-vision-bridge.sh" "$bridge_dir" "$NODE_PATH" \
    "$bridge_dir/bridge.env" "$BRIDGE_HOST" "$BRIDGE_PORT" \
    "$bridge_dir/vision-bridge.log" "$bridge_dir/vision-bridge.err.log" 0 ""
stage_generated_file "${stage_root}/vision-bridge.plist" "$plist_path" launchd 600

if [ "$COORDINATE_CCSWITCH" -eq 1 ]; then
    generate_plist \
        "${stage_root}/cc-switch-coordinator.plist" "$CCSWITCH_COORDINATOR_LABEL" \
        "$bridge_dir/start-ccswitch-after-bridge.sh" "$bridge_dir" "$NODE_PATH" \
        "$bridge_dir/bridge.env" "$BRIDGE_HOST" "$BRIDGE_PORT" \
        "$bridge_dir/cc-switch-startup.log" "$bridge_dir/cc-switch-startup.err.log" 1 "$CCSWITCH_APP_PATH"
    stage_generated_file "${stage_root}/cc-switch-coordinator.plist" "$coordinator_plist_path" launchd 600
fi

stage_file "$SCRIPT_DIR/vision-bridge.js" "$bridge_dir/vision-bridge.js" bridge 755
stage_file "$SCRIPT_DIR/vision-client.js" "$bridge_dir/vision-client.js" bridge 644
stage_file "$SCRIPT_DIR/bridge-health.js" "$bridge_dir/bridge-health.js" bridge 755
stage_file "$SCRIPT_DIR/start-vision-bridge.sh" "$bridge_dir/start-vision-bridge.sh" bridge 755
stage_file "$SCRIPT_DIR/restart-vision-bridge.sh" "$bridge_dir/restart-vision-bridge.sh" bridge 755
stage_file "$SCRIPT_DIR/diagnose-vision-bridge.sh" "$bridge_dir/diagnose-vision-bridge.sh" bridge 755
stage_file "$SCRIPT_DIR/configure-ccswitch-route.js" "$bridge_dir/configure-ccswitch-route.js" bridge 755
stage_file "$SCRIPT_DIR/configure-ccswitch-route.sh" "$bridge_dir/configure-ccswitch-route.sh" bridge 755
stage_file "$SCRIPT_DIR/start-ccswitch-after-bridge.sh" "$bridge_dir/start-ccswitch-after-bridge.sh" bridge 755
stage_file "$SCRIPT_DIR/vision.js" "$skill_dir/vision.js" skill 755
stage_file "$SCRIPT_DIR/vision.sh" "$skill_dir/vision.sh" skill 755
stage_file "$SCRIPT_DIR/vision-client.js" "$skill_dir/vision-client.js" skill 644
stage_file "$SCRIPT_DIR/SKILL.md.template" "$skill_dir/SKILL.md" skill 644
stage_file "$SCRIPT_DIR/../.env.example" "$bridge_dir/bridge.env.example" bridge 600

if [ -n "$ENV_FILE_SOURCE" ]; then
    stage_file "$ENV_FILE_SOURCE" "$bridge_dir/bridge.env" config 600
fi

# Back up every existing managed destination before replacing any file.
mkdir -p "$backup_root"
: > "$records_path"
: > "$manifest_path"
while IFS="$(printf '\t')" read -r stage_path destination label mode; do
    [ -n "$destination" ] || continue
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        [ -f "$destination" ] && [ ! -L "$destination" ] || fail "refusing to overwrite a non-file or symlink: $destination"
        backup_dir=${backup_root}/${label}
        mkdir -p "$backup_dir"
        backup_path=${backup_dir}/$(basename "$destination")
        cp -p "$destination" "$backup_path"
        existed=1
    else
        backup_path=${backup_root}/${label}/$(basename "$destination")
        existed=0
    fi
    printf '%s\t%s\t%s\n' "$destination" "$backup_path" "$existed" >> "$records_path"
    printf '%s\t%s\t%s\n' "$destination" "$backup_path" "$existed" >> "$manifest_path"
done < "${stage_root}/staged.tsv"

while IFS="$(printf '\t')" read -r stage_path destination label mode; do
    [ -n "$destination" ] || continue
    mkdir -p "$(dirname "$destination")"
    cp -p "$stage_path" "$destination"
    chmod "$mode" "$destination"
done < "${stage_root}/staged.tsv"

while IFS="$(printf '\t')" read -r stage_path destination label mode; do
    [ -n "$destination" ] || continue
    staged_hash=$(shasum -a 256 "$stage_path" | awk '{print $1}')
    installed_hash=$(shasum -a 256 "$destination" | awk '{print $1}')
    [ "$staged_hash" = "$installed_hash" ] || fail "installed file failed verification: $destination"
done < "${stage_root}/staged.tsv"

if [ -n "$ENV_FILE_SOURCE" ]; then
    chmod 600 "$bridge_dir/bridge.env"
fi
chmod 700 "$bridge_dir" "$skill_dir"

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist_path" >/dev/null || fail "installed bridge launch agent plist is invalid"
    if [ "$COORDINATE_CCSWITCH" -eq 1 ]; then
        plutil -lint "$coordinator_plist_path" >/dev/null || fail "installed CC Switch coordinator plist is invalid"
    fi
fi

if [ "$SKIP_LAUNCHCTL" -eq 0 ]; then
    command -v launchctl >/dev/null 2>&1 || fail "launchctl is required unless --skip-launchctl is used"
    launch_domain="gui/$(id -u)"
    if launchctl print "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1; then
        bridge_agent_was_loaded=1
        launchctl bootout "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1 || fail "could not unload the existing $BRIDGE_LABEL agent"
        bridge_agent_changed=1
    fi
    launchctl bootstrap "$launch_domain" "$plist_path" || fail "could not load $plist_path"
    bridge_agent_changed=1
    launchctl kickstart "$launch_domain/$BRIDGE_LABEL" >/dev/null 2>&1 || fail "could not start $BRIDGE_LABEL"
    "$bridge_dir/restart-vision-bridge.sh" || fail "the installed Vision Bridge did not pass its health check"
    if [ "$CONFIGURE_ROUTE" -eq 1 ]; then
        if [ -f "$bridge_dir/bridge.env" ]; then
            set -a
            # shellcheck disable=SC1090
            . "$bridge_dir/bridge.env"
            set +a
        fi
        route_coordinator="$bridge_dir/configure-ccswitch-route.sh"
        configure_route() {
            set -- "$route_coordinator" \
                --ccswitch-directory "$CCSWITCH_DIR" \
                --ccswitch-app "$CCSWITCH_APP_PATH" \
                --app-type "$CCSWITCH_APP_TYPE" \
                --bridge-host "$BRIDGE_HOST" \
                --bridge-port "$BRIDGE_PORT" \
                --bridge-env-file "$bridge_dir/bridge.env"
            if [ "$FORCE_CLOSE_CCSWITCH" -eq 1 ]; then
                set -- "$@" --force-close-ccswitch
            fi
            "$@"
        }
        configure_route
    fi
    if [ "$COORDINATE_CCSWITCH" -eq 1 ]; then
        if launchctl print "$launch_domain/$CCSWITCH_COORDINATOR_LABEL" >/dev/null 2>&1; then
            coordinator_agent_was_loaded=1
            launchctl bootout "$launch_domain/$CCSWITCH_COORDINATOR_LABEL" >/dev/null 2>&1 || fail "could not unload the existing $CCSWITCH_COORDINATOR_LABEL agent"
            coordinator_agent_changed=1
        fi
        launchctl bootstrap "$launch_domain" "$coordinator_plist_path" || fail "could not load $coordinator_plist_path"
        coordinator_agent_changed=1
        launchctl kickstart "$launch_domain/$CCSWITCH_COORDINATOR_LABEL" >/dev/null 2>&1 || fail "could not start $CCSWITCH_COORDINATOR_LABEL"
    fi
fi

trap - EXIT HUP INT TERM
cleanup

printf '%s\n' "Vision Bridge runtime and Vision Skill installed for macOS."
printf '%s\n' "Launch agent: $plist_path"
printf '%s\n' "Bridge environment file: $bridge_dir/bridge.env (not created unless --env-file is supplied)"
printf '%s\n' "Backup manifest: $manifest_path"
if [ "$SKIP_LAUNCHCTL" -eq 1 ]; then
    printf '%s\n' "launchd loading was skipped by request."
fi
if [ "$COORDINATE_CCSWITCH" -eq 1 ]; then
    printf '%s\n' "CC Switch startup coordinator installed: $coordinator_plist_path"
else
    printf '%s\n' "CC Switch startup was not changed; enable it in CC Switch or pass --coordinate-ccswitch-startup explicitly."
fi
