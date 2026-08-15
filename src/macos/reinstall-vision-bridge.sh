#!/bin/sh
# Perform a Bridge-only macOS reinstall through the transactional installer.
# CC Switch routes and its database are intentionally outside this command.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for argument in "$@"; do
    case "$argument" in
        --configure-ccswitch-route|--force-close-ccswitch)
            printf '%s\n' "reinstall-vision-bridge.sh does not modify CC Switch routes; use the route command separately after health is confirmed." >&2
            exit 2
            ;;
    esac
done

exec sh "$SCRIPT_DIR/install-vision-bridge.sh" "$@"
