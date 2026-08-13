#!/usr/bin/env bash
# Quit the Cove (both Godot and the detached kitty).
pkill -f 'godot --path' 2>/dev/null || true
pkill -f 'launcher/kitty --title cove' 2>/dev/null || true
echo "Cove stopped."
