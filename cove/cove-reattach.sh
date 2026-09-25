#!/bin/sh
# Reattach a termling session in a fresh kitty window: cove-reattach.sh SESSION
# abduco keeps the processes but not kitty's screen, so reload-kitty.sh saves each
# termling's screen + scrollback (with colours) to $DIR/scroll/SESSION.ansi before
# it stops kitty. Print that first, so the window comes back showing what it had,
# then attach. The patched abduco client (abduco-attach-repaint.patch) pulses the
# size on attach, so the program repaints its live part at the bottom; the stock
# abduco fallback doesn't.
DIR="${KITTY_COVE_DIR:-/tmp/cove}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SAVED="$DIR/scroll/$1.ansi"
if [ -s "$SAVED" ]; then
    cat "$SAVED"
    rm -f "$SAVED"
fi
ABDUCO="$HERE/bin/abduco"   # patched (build-abduco.sh); same fallback as reload-kitty.sh
[ -x "$ABDUCO" ] || ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"
# -a, not -A: if the session died meanwhile, fail rather than start a blank
# shell under its name.
exec "$ABDUCO" -a "$1"
