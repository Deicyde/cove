#!/usr/bin/env bash
# Quit the Cove (both Godot and the detached kitty).
DIR="/tmp/cove"
pkill -f 'godot --path' 2>/dev/null || true
# Kill the cove-kitty via pid file + ps scan (macOS `pkill -f` can't see its args).
[ -f "$DIR/kitty.pid" ] && kill "$(cat "$DIR/kitty.pid" 2>/dev/null)" 2>/dev/null || true
for _p in $(ps -Ao pid=,command= | awk '/[l]auncher\/kitty --title cove/ {print $1}'); do
    kill "$_p" 2>/dev/null || true
done
echo "Cove stopped."
