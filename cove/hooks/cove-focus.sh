#!/bin/bash
# Clicked from a Cove stop-hook notification: bring the Cove (Godot) window to
# the front and make its camera focus + follow the agent's terminal. The kitty
# pane id is passed as $1; the Cove's `focus` command accepts a pane id.
PANE="${1:-}"
DIR="${KITTY_COVE_DIR:-/tmp/cove}"
[ -n "$PANE" ] || exit 0

# Raise the Cove. Godot runs as a bare binary named "godot" (not an .app), so
# activate it via System Events rather than `open -a`.
osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "godot") to true' 2>/dev/null

# Focus + camera-follow this terminal (no-op if the Cove isn't running).
[ -d "$DIR" ] && printf '{"cmd":"focus","id":%s}\n' "$PANE" >> "$DIR/commands.jsonl"
