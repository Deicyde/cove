#!/bin/sh
# Reattach a termling session in a fresh kitty window: cove-reattach.sh SESSION [SHELL]
# abduco keeps the processes but not kitty's screen, so reload-kitty.sh saves each
# termling's screen + scrollback (with colours) to $DIR/scroll/SESSION.ansi before
# it stops kitty. Print that first, so the window comes back showing what it had,
# then attach (the patched abduco client pulses the size, so the program repaints
# its live part at the bottom).
DIR="${KITTY_COVE_DIR:-/tmp/cove}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SAVED="$DIR/scroll/$1.ansi"
if [ -s "$SAVED" ]; then
    cat "$SAVED"
    rm -f "$SAVED"
fi
exec "$HERE/bin/abduco" -A "$1" "${2:-${SHELL:-/bin/zsh}}"
