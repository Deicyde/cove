#!/bin/bash
# Clicked from a Cove stop-hook notification: bring the Cove (Godot) window to
# the front and make its camera focus + follow the agent's terminal. The kitty
# pane id is passed as $1; the Cove's `focus` command accepts a pane id.
PANE="${1:-}"
DIR="${KITTY_COVE_DIR:-/tmp/cove}"
[ -n "$PANE" ] || exit 0

# Raise the Cove. Godot runs as a bare binary named "godot" (not an .app), so
# activate it via System Events rather than `open -a`.
# By pid when state.json has it: the Godot *editor* is a process named Godot too.
COVE_PID=$(/usr/bin/python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("pid", 0)))' "$DIR/state.json" 2>/dev/null)
if [ -n "$COVE_PID" ] && [ "$COVE_PID" != 0 ] && kill -0 "$COVE_PID" 2>/dev/null; then
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $COVE_PID) to true" 2>/dev/null
else
  osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "godot") to true' 2>/dev/null
fi

# Focus + camera-follow this terminal (no-op if the Cove isn't running).
[ -d "$DIR" ] && printf '{"cmd":"focus","id":%s}\n' "$PANE" >> "$DIR/commands.jsonl"
