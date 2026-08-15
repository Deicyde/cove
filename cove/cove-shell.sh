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
sess="cove-$$"
ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"
exec "$ABDUCO" -A "$sess" "${SHELL:-/bin/zsh}"
