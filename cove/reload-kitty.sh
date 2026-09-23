#!/usr/bin/env bash
# Warm-reload the Cove: rebuild + RESTART kitty (to pick up cove.c / boss.py
# changes) WITHOUT losing termlings. Each terminal's shell runs inside an abduco
# session (see cove-shell.sh), so killing kitty only *detaches* the shells; we
# restart kitty, reattach every session as its own window, and relaunch Godot,
# which restores each termling's position/name by session from state.json.
#
# Use this when you changed kitty-side code (cove.c / boss.py). For Godot-only
# changes (Cove.gd, the gdext dylib), plain reload.sh is enough -- it leaves
# kitty running and only relaunches Godot.
set -euo pipefail

DIR="/tmp/cove"
[ -f "$DIR/dev-env" ] || { echo "Not in dev mode (no $DIR/dev-env). Start with cove/dev.sh." >&2; exit 1; }
# shellcheck disable=SC1090
source "$DIR/dev-env"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KITTY="$REPO/kitty/launcher/kitty"
KITTEN="${COVE_KITTEN:-$REPO/kitty/launcher/kitty.app/Contents/MacOS/kitten}"
WRAPPER="$REPO/cove/cove-shell.sh"
SOCK="${COVE_KITTY_SOCKET:-unix:/tmp/cove-kitty}"
ABDUCO="$REPO/cove/bin/abduco"   # patched: no alt screen (build-abduco.sh)
[ -x "$ABDUCO" ] || ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"

[ -e "$KITTY" ] || { echo "kitty not built ($KITTY). Run cove/dev.sh first." >&2; exit 1; }

# The termling sessions that will survive the kitty kill (abduco holds them).
SESSIONS=($("$ABDUCO" 2>/dev/null | awk 'NR>1{print $NF}' | grep '^cove-' || true))
echo "reattaching ${#SESSIONS[@]} termling session(s): ${SESSIONS[*]:-<none>}"

# Stop Godot + kitty. The abduco masters (and the shells/agents they hold) keep
# running, detached, so nothing inside the termlings is lost.
pkill -if "godot --path $APP" 2>/dev/null || pkill -if 'godot --path' 2>/dev/null || true
kpid="$(cat "$DIR/kitty.pid" 2>/dev/null || true)"
[ -n "$kpid" ] && kill "$kpid" 2>/dev/null || true
for _p in $(ps -Ao pid=,command= | awk '/[l]auncher\/kitty --title cove/ {print $1}'); do
    kill "$_p" 2>/dev/null || true
done
sleep 0.6
# Drop the stale frame files + socket, but KEEP state.json so Godot can restore
# positions/names by session.
# (kitty's only: panes below 1000000; Vibefox and Vibemacs critters
# belong to their apps, which keep publishing.)
for _f in "$DIR"/term-*.rgba; do
    _n=${_f##*/term-}; _n=${_n%.rgba}
    case "$_n" in *[!0-9]*|"") continue ;; esac
    [ "$_n" -lt 1000000 ] && rm -f "$_f"
done
rm -f /tmp/cove-kitty 2>/dev/null || true

export COVE=1 KITTY_COVE=1 KITTY_COVE_DIR="$DIR"
[ "${COVE_IOSURFACE:-}" = "1" ] && export KITTY_COVE_IOSURFACE=1

COMMON=(--title cove --listen-on "$SOCK"
    -o allow_remote_control=yes -o sync_to_monitor=no -o font_size=16
    -o remember_window_size=no -o initial_window_width=110c -o initial_window_height=32c
    -o "map cmd+n cove_new_os_window"
    -o shell="$WRAPPER")

# Restart kitty. First window reattaches session[0] (or a fresh shell via the
# wrapper if there are none); the rest are reattached below via remote control.
if [ "${#SESSIONS[@]}" -eq 0 ]; then
    nohup "$KITTY" "${COMMON[@]}" "$WRAPPER" >/tmp/cove-kitty.log 2>&1 &
else
    nohup "$KITTY" "${COMMON[@]}" "$ABDUCO" -A "${SESSIONS[0]}" "${SHELL:-/bin/zsh}" >/tmp/cove-kitty.log 2>&1 &
fi
COVE_KITTY_PID=$!

# Wait for kitty to publish its first frame.
for _ in $(seq 1 80); do ls "$DIR"/term-*.rgba >/dev/null 2>&1 && break; sleep 0.1; done
echo "$COVE_KITTY_PID" > "$DIR/kitty.pid"

# Reattach the remaining sessions, each as its own OS window.
for ((i=1; i<${#SESSIONS[@]}; i++)); do
    "$KITTEN" @ --to "$SOCK" launch --type=os-window \
        "$ABDUCO" -A "${SESSIONS[$i]}" "${SHELL:-/bin/zsh}" >/dev/null 2>&1 || true
done

# Refresh dev-env (new pid) and relaunch Godot.
cat > "$DIR/dev-env" <<EOF
COVE_KITTEN=$KITTEN
COVE_KITTY_SOCKET=$SOCK
APP=$APP
GODOT=$GODOT
COVE_KITTY_PID=$COVE_KITTY_PID
EOF
COVE_KITTEN="$KITTEN" COVE_KITTY_SOCKET="$SOCK" \
    nohup "$GODOT" --path "$APP" >/tmp/cove-godot.log 2>&1 &
echo "warm reload done: kitty restarted (new code), ${#SESSIONS[@]} termling(s) reattached."
