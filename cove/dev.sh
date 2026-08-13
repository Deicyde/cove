#!/usr/bin/env bash
# Cove dev launcher. Runs kitty DETACHED (its own lifetime) + the Godot app, so
# you can edit scripts and `reload.sh` to relaunch just Godot — kitty keeps
# running, so all terminals/shells/agents stay, and Godot restores their
# positions/names/camera from state.json. `stop.sh` quits everything.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/cove"
KITTY="$REPO/kitty/launcher/kitty"
KITTEN="$REPO/kitty/launcher/kitty.app/Contents/MacOS/kitten"
SOCK="unix:/tmp/cove-kitty"
DIR="/tmp/cove"
GODOT="${GODOT:-godot}"

[ -e "$KITTY" ] || { echo "kitty not built ($KITTY) — see cove/README.md" >&2; exit 1; }
command -v "$GODOT" >/dev/null 2>&1 || { echo "godot not found; set GODOT=/path/to/godot" >&2; exit 1; }

# The GDExtension (CoveInput/IOSurface) must be registered for fast input.
if [ ! -f "$APP/.godot/extension_list.cfg" ]; then
    "$GODOT" --path "$APP" --editor --headless --quit >/dev/null 2>&1 || true
fi

pkill -f 'godot --path' 2>/dev/null || true
pkill -f 'launcher/kitty --title cove' 2>/dev/null || true
sleep 0.5
rm -rf "$DIR"; rm -f /tmp/cove-kitty

export COVE=1
[ "${COVE_IOSURFACE:-}" = "1" ] && export KITTY_COVE_IOSURFACE=1
KITTY_COVE=1 KITTY_COVE_DIR="$DIR" nohup "$KITTY" --title cove \
    --listen-on "$SOCK" -o allow_remote_control=yes -o sync_to_monitor=no \
    -o font_size=16 -o remember_window_size=no \
    -o initial_window_width=60c -o initial_window_height=18c \
    "${SHELL:-/bin/zsh}" >/tmp/cove-kitty.log 2>&1 &

for _ in $(seq 1 60); do ls "$DIR"/term-*.rgba >/dev/null 2>&1 && break; sleep 0.1; done
cat > "$DIR/dev-env" <<EOF
COVE_KITTEN=$KITTEN
COVE_KITTY_SOCKET=$SOCK
APP=$APP
GODOT=$GODOT
EOF

COVE_KITTEN="$KITTEN" COVE_KITTY_SOCKET="$SOCK" \
    nohup "$GODOT" --path "$APP" >/tmp/cove-godot.log 2>&1 &
echo "Cove dev up (kitty + godot). Edit scripts, then: cove/reload.sh"
echo "Quit everything with: cove/stop.sh"
