#!/bin/sh
# cove-shell.sh -- the program every cove terminal runs. It wraps the login
# shell in an abduco session so the shell (and any agent running inside it)
# survives a kitty restart: reload-kitty.sh can rebuild + restart kitty and
# reattach each session, keeping the termlings and their live agents alive.
#
# The session name is minted once and is unique + stable (cove-<pid>), so it can
# be reattached later. `-A` is attach-or-create: it creates the session the first
# time and reattaches on later runs. (Do NOT add -c; `-A -c` means create-only
# and errors with "Address already in use" when reattaching.) abduco is a
# transparent passthrough (no status bar / screen model), so kitty renders the
# shell byte-for-byte as if abduco weren't there.
#
# Drop any Claude Code session env inherited from whoever launched kitty (the
# cove is often started by an agent's Bash tool): with CLAUDECODE /
# CLAUDE_CODE_CHILD_SESSION set, a fresh `claude` in a termling thinks it is a
# nested child of that session. The login shell re-sets anything user-defined.
for v in $(env | sed -n 's/^\(CLAUDE[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
sess="cove-$$"
# An agent spawning a child termling (cove_mcp's spawn) picks the name up front,
# so it knows the child's identity before the window even exists. It must still
# be cove-<digits>: that's how the Cove recognises abduco sessions.
case "${COVE_SPAWN_SESSION:-}" in
cove-[0-9]*) sess="$COVE_SPAWN_SESSION" ;;
esac
unset COVE_SPAWN_SESSION
# The stable identity of this termling: survives kitty restarts (unlike
# $KITTY_WINDOW_ID), and is what the cove MCP tools and board ownership key on.
export COVE_SESSION="$sess"
# Edit prompts (Claude Code's ctrl+g, git commit messages, ...) in the running
# Vibemacs rather than VS Code, which is what Claude Code picks when neither
# VISUAL nor EDITOR is set. emacsclient waits for the buffer to be finished
# (C-x #); ALTERNATE_EDITOR starts Vibemacs when no server is up.
VIBEMACS_CLIENT=/Applications/Vibemacs.app/Contents/MacOS/bin/emacsclient
if [ -x "$VIBEMACS_CLIENT" ]; then
	export EDITOR="$VIBEMACS_CLIENT" VISUAL="$VIBEMACS_CLIENT"
	export ALTERNATE_EDITOR=/Applications/Vibemacs.app/Contents/MacOS/Vibemacs
fi
# cove/bin/abduco (build-abduco.sh) stays on the main screen, so kitty keeps
# scrollback; stock abduco flips to the alt screen and the wheel does nothing.
ABDUCO="$(dirname "$0")/bin/abduco"
[ -x "$ABDUCO" ] || ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"
exec "$ABDUCO" -A "$sess" "${SHELL:-/bin/zsh}"
