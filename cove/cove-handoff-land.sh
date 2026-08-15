#!/bin/sh
# cove-handoff-land.sh — the program a landed termling runs on the receiving Mac.
#
# When a termling is dropped onto this Cove, Cove.gd launches a new cove-kitty
# os-window running this script with the dragged agent + session. Like
# cove-shell.sh it wraps everything in a fresh abduco session so the landed
# termling survives a kitty restart. For a Claude termling it resumes the dragged
# conversation (the repo is Syncthing-synced, so the transcript is already here),
# then drops to a login shell so the termling persists after Claude exits. For a
# plain shell it just opens a login shell in the handed-over cwd.
#
#   cove-handoff-land.sh <agent> [session-id]
#
# The launcher sets the cwd via `kitten @ launch --cwd`, so this runs in the
# right directory already.
AGENT="${1:-shell}"
SID="${2:-}"

sess="cove-$$"
ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"
SH="${SHELL:-/bin/zsh}"

if [ "$AGENT" = "claude" ] && [ -n "$SID" ] && command -v claude >/dev/null 2>&1; then
    # Resume the dragged conversation, then fall back to a login shell so the
    # termling stays alive once the session ends.
    exec "$ABDUCO" -A "$sess" "$SH" -lc "claude --resume '$SID'; exec '$SH' -l"
fi

exec "$ABDUCO" -A "$sess" "$SH"
