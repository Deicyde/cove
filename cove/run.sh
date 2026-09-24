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
ABDUCO="$REPO/cove/bin/abduco"
[ -x "$ABDUCO" ] || ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"
LOCK_FILE="/tmp/cove-launch.lock"

exec 9>"$LOCK_FILE"
if ! /usr/bin/lockf -s -t 0 9; then
    echo "another Cove launch is already in progress" >&2
    exit 1
fi

if [ ! -e "$KITTY" ]; then
    echo "kitty is not built at $KITTY -- see cove/README.md (Building kitty)" >&2
    exit 1
fi
if [ ! -x "$KITTEN" ]; then
    echo "kitten is not built at $KITTEN" >&2
    exit 1
fi
if ! command -v "$GODOT" >/dev/null 2>&1; then
    echo "godot not found on PATH. Set GODOT=/path/to/godot" >&2
    exit 1
fi
if [ ! -x "$ABDUCO" ]; then
    echo "abduco not found at $ABDUCO" >&2
    exit 1
fi
if "$KITTEN" @ --to "$SOCK" ls >/dev/null 2>&1; then
    echo "Cove is already running at $SOCK" >&2
    exit 1
fi

# The abduco masters outlive a crashed Cove. Reattach detached sessions instead
# of deleting their saved layout and starting one empty replacement terminal.
if ! session_listing=$("$ABDUCO" 2>/dev/null); then
    echo "failed to list abduco sessions" >&2
    exit 1
fi
ALL_SESSIONS=($(printf '%s\n' "$session_listing" | awk 'NR>1 && $1 != "+"{print $NF}' | grep -E '^cove-[0-9]+$' || true))
SESSIONS=($(printf '%s\n' "$session_listing" | awk 'NR>1 && $1 != "*" && $1 != "+"{print $NF}' | grep -E '^cove-[0-9]+$' || true))
if [ "${#ALL_SESSIONS[@]}" -ne "${#SESSIONS[@]}" ]; then
    echo "some Cove sessions are still attached; refusing to start a competing Cove" >&2
    exit 1
fi
if [ "${#SESSIONS[@]}" -eq 0 ]; then
    rm -rf "$DIR"
else
    echo "reattaching ${#SESSIONS[@]} termling session(s): ${SESSIONS[*]}"
    mkdir -p "$DIR"
    for _f in "$DIR"/term-*.rgba; do
        _n=${_f##*/term-}; _n=${_n%.rgba}
        case "$_n" in *[!0-9]*|"") continue ;; esac
        [ "$_n" -lt 1000000 ] && rm -f "$_f"
    done
fi
rm -f /tmp/cove-kitty

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
CHILD=("$WRAPPER")
if [ "${#SESSIONS[@]}" -ne 0 ]; then
    CHILD=("$ABDUCO" -a "${SESSIONS[0]}")
fi
"$KITTY" --title cove \
    --listen-on "$SOCK" \
    -o allow_remote_control=yes \
    -o macos_quit_when_last_window_closed=yes \
    -o sync_to_monitor=no \
    -o font_size=16 \
    -o remember_window_size=no -o initial_window_width=110c -o initial_window_height=32c \
    -o "map cmd+n cove_new_os_window" \
    -o shell="$WRAPPER" \
    "${CHILD[@]}" 9>&- &
KITTY_PID=$!
cleanup() { kill "$KITTY_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for remote control before asking kitty to create recovered windows.
kitty_ready=false
for _ in $(seq 1 80); do
    if "$KITTEN" @ --to "$SOCK" ls >/dev/null 2>&1; then
        kitty_ready=true
        break
    fi
    sleep 0.1
done
if [ "$kitty_ready" != true ]; then
    echo "kitty did not become ready at $SOCK" >&2
    exit 1
fi

for ((i=1; i<${#SESSIONS[@]}; i++)); do
    "$KITTEN" @ --to "$SOCK" launch --type=os-window \
        "$ABDUCO" -a "${SESSIONS[$i]}" >/dev/null
done

# abduco preserves processes, not kitty's screen buffer. Resize and restore the
# windows so full-screen clients repaint instead of reopening as black panes.
if [ "${#SESSIONS[@]}" -ne 0 ]; then
    if "$KITTEN" @ --to "$SOCK" resize-os-window --match all \
        --unit cells --incremental --width 1 >/dev/null; then
        sleep 0.3
        "$KITTEN" @ --to "$SOCK" resize-os-window --match all \
            --unit cells --incremental --width=-1 >/dev/null || \
            echo "warning: failed to restore recovered window widths" >&2
    else
        echo "warning: failed to resize recovered windows for repaint" >&2
    fi
fi

export COVE_KITTEN="$KITTEN"
export COVE_KITTY_SOCKET="$SOCK"
exec 9>&-

# Auto-start remote termlings (relay + peer auto-viewer) before the Godot host.
"$REPO/cove/cove-remote-start.sh" || true

"$GODOT" --path "$REPO/cove"
