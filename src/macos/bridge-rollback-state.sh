#!/bin/sh
# Shared last-known-good state helpers for the macOS Bridge service.

bridge_rollback_files='vision-bridge.js vision-client.js bridge-health.js start-vision-bridge.sh'

bridge_rollback_root() {
    printf '%s/rollback\n' "$BRIDGE_DIR"
}

bridge_rollback_current_snapshot() {
    rollback_root=$(bridge_rollback_root)
    pointer_path=${rollback_root}/current
    [ -e "$pointer_path" ] || return 1
    [ -f "$pointer_path" ] && [ ! -L "$pointer_path" ] || return 2
    snapshot_id=$(cat "$pointer_path" 2>/dev/null || true)
    case "$snapshot_id" in
        snapshot-[0-9]*-[0-9]*) ;;
        *) return 2 ;;
    esac
    case "$snapshot_id" in
        ''|*[!A-Za-z0-9._-]*) return 2 ;;
    esac
    snapshot_path=${rollback_root}/${snapshot_id}
    [ -d "$snapshot_path" ] && [ ! -L "$snapshot_path" ] || return 2
    for rollback_file in $bridge_rollback_files bridge.env; do
        [ -f "$snapshot_path/$rollback_file" ] && [ ! -L "$snapshot_path/$rollback_file" ] || return 2
    done
    [ -f "$snapshot_path/launch-agent.plist" ] && [ ! -L "$snapshot_path/launch-agent.plist" ] || return 2
    printf '%s\n' "$snapshot_path"
}

bridge_rollback_snapshot_current() {
    rollback_root=$(bridge_rollback_root)
    [ ! -L "$rollback_root" ] || return 1
    mkdir -p "$rollback_root" || return 1
    chmod 700 "$rollback_root" || return 1

    previous_snapshot=$(bridge_rollback_current_snapshot 2>/dev/null || true)
    snapshot_id=snapshot-$(date +%Y%m%d-%H%M%S)-$$
    snapshot_path=${rollback_root}/${snapshot_id}
    snapshot_sequence=0
    while [ -e "$snapshot_path" ] || [ -L "$snapshot_path" ]; do
        snapshot_sequence=$((snapshot_sequence + 1))
        snapshot_id=snapshot-$(date +%Y%m%d-%H%M%S)-$$-$snapshot_sequence
        snapshot_path=${rollback_root}/${snapshot_id}
    done
    umask 077
    mkdir "$snapshot_path" || return 1
    for rollback_file in $bridge_rollback_files bridge.env; do
        [ -f "$BRIDGE_DIR/$rollback_file" ] && [ ! -L "$BRIDGE_DIR/$rollback_file" ] || {
            rm -rf "$snapshot_path"
            return 1
        }
        cp -p "$BRIDGE_DIR/$rollback_file" "$snapshot_path/$rollback_file" || {
            rm -rf "$snapshot_path"
            return 1
        }
    done
    [ -f "$BRIDGE_PLIST" ] && [ ! -L "$BRIDGE_PLIST" ] || {
        rm -rf "$snapshot_path"
        return 1
    }
    cp -p "$BRIDGE_PLIST" "$snapshot_path/launch-agent.plist" || {
        rm -rf "$snapshot_path"
        return 1
    }
    chmod 600 "$snapshot_path/bridge.env" "$snapshot_path/launch-agent.plist" || {
        rm -rf "$snapshot_path"
        return 1
    }

    pointer_path=${rollback_root}/current
    pointer_temp=${rollback_root}/.current.$$.tmp
    printf '%s\n' "$snapshot_id" > "$pointer_temp" || {
        rm -rf "$snapshot_path"
        return 1
    }
    chmod 600 "$pointer_temp" || {
        rm -f "$pointer_temp" "$snapshot_path"
        return 1
    }
    mv -f "$pointer_temp" "$pointer_path" || {
        rm -f "$pointer_temp"
        rm -rf "$snapshot_path"
        return 1
    }

    if [ -n "$previous_snapshot" ] && [ "$previous_snapshot" != "$snapshot_path" ] &&
        [ -d "$previous_snapshot" ] && [ ! -L "$previous_snapshot" ]; then
        rm -rf "$previous_snapshot"
    fi
}

bridge_rollback_restore_snapshot() {
    snapshot_path=$1
    for rollback_file in $bridge_rollback_files bridge.env; do
        [ -f "$snapshot_path/$rollback_file" ] && [ ! -L "$snapshot_path/$rollback_file" ] || return 1
        cp -p "$snapshot_path/$rollback_file" "$BRIDGE_DIR/$rollback_file" || return 1
    done
    [ -f "$snapshot_path/launch-agent.plist" ] && [ ! -L "$snapshot_path/launch-agent.plist" ] || return 1
    mkdir -p "$(dirname "$BRIDGE_PLIST")" || return 1
    cp -p "$snapshot_path/launch-agent.plist" "$BRIDGE_PLIST" || return 1
    chmod 600 "$BRIDGE_DIR/bridge.env" "$BRIDGE_PLIST" || return 1
}
