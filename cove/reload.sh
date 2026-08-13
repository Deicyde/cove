#!/usr/bin/env bash
# Hot-reload the Cove: relaunch ONLY Godot against the still-running kitty.
# Terminals, shells and agents keep running; Godot restores positions/names/
# camera from state.json. Run after editing scripts. Requires dev.sh first.
set -euo pipefail

DIR="/tmp/cove"
[ -f "$DIR/dev-env" ] || { echo "Not in dev mode (no $DIR/dev-env). Start with cove/dev.sh." >&2; exit 1; }
# shellcheck disable=SC1090
source "$DIR/dev-env"

if ! pgrep -f 'launcher/kitty --title cove' >/dev/null; then
    echo "kitty (cove) isn't running — start fresh with cove/dev.sh." >&2
    exit 1
fi

pkill -f "godot --path $APP" 2>/dev/null || pkill -f 'godot --path' 2>/dev/null || true
sleep 0.4
COVE_KITTEN="$COVE_KITTEN" COVE_KITTY_SOCKET="$COVE_KITTY_SOCKET" \
    nohup "$GODOT" --path "$APP" >/tmp/cove-godot.log 2>&1 &
echo "reloaded Godot ($!) — terminals + positions preserved."
