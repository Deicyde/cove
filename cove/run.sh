#!/usr/bin/env bash
# Walking Terminals -- Phase 0 launcher. Starts the hacked kitty in cove
# mode (publishing frames to a shared file, remote control on) and then launches
# the Godot host that displays it and forwards input. See cove/README.md.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KITTY="$REPO/kitty/launcher/kitty"
KITTEN="$REPO/kitty/launcher/kitty.app/Contents/MacOS/kitten"
SOCK="unix:/tmp/cove-kitty"
DIR="/tmp/cove"
GODOT="${GODOT:-godot}"

if [ ! -e "$KITTY" ]; then
    echo "kitty is not built at $KITTY -- see cove/README.md (Building kitty)" >&2
    exit 1
fi
if ! command -v "$GODOT" >/dev/null 2>&1; then
    echo "godot not found on PATH. Set GODOT=/path/to/godot" >&2
    exit 1
fi

rm -rf "$DIR"; rm -f /tmp/cove-kitty

export KITTY_COVE=1
export KITTY_COVE_DIR="$DIR"
# Child shells (and agents inside them) inherit these: COVE=1 marks a shell
# as living in the cove; its terminal id is kitty's own $KITTY_WINDOW_ID.
export COVE=1

# Opt into the zero-copy IOSurface transport with COVE_IOSURFACE=1. Needs
# the gdext/ extension built + registered (see cove/README.md). We make sure
# it's registered by running a one-time headless import if needed.
if [ "${COVE_IOSURFACE:-}" = "1" ]; then
    export KITTY_COVE_IOSURFACE=1
    if [ ! -f "$REPO/cove/.godot/extension_list.cfg" ]; then
        "$GODOT" --path "$REPO/cove" --editor --headless --quit >/dev/null 2>&1 || true
    fi
fi

# The kitty window is created hidden (cove mode); only Godot is visible.
# sync_to_monitor=no lets the hidden window keep rendering without a display link.
# cove-shell.sh wraps each shell in an abduco session (survives a kitty restart;
# see reload-kitty.sh). -o shell= makes Cmd+N windows use it too.
WRAPPER="$REPO/cove/cove-shell.sh"
"$KITTY" --title cove \
    --listen-on "$SOCK" \
    -o allow_remote_control=yes \
    -o macos_quit_when_last_window_closed=yes \
    -o sync_to_monitor=no \
    -o font_size=16 \
    -o remember_window_size=no -o initial_window_width=110c -o initial_window_height=32c \
    -o "map cmd+n cove_new_os_window" \
    -o shell="$WRAPPER" \
    "$WRAPPER" &
KITTY_PID=$!
cleanup() { kill "$KITTY_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for the first terminal's frame file so Godot has something to show.
for _ in $(seq 1 50); do ls "$DIR"/term-*.rgba >/dev/null 2>&1 && break; sleep 0.1; done

export COVE_KITTEN="$KITTEN"
export COVE_KITTY_SOCKET="$SOCK"

# Auto-start remote termlings (relay + peer auto-viewer) before the Godot host.
"$REPO/cove/cove-remote-start.sh" || true

"$GODOT" --path "$REPO/cove"
