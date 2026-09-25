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
REATTACH="$REPO/cove/cove-reattach.sh"   # prints the saved screen, then abduco -A
SOCK="${COVE_KITTY_SOCKET:-unix:/tmp/cove-kitty}"
ABDUCO="$REPO/cove/bin/abduco"   # patched: no alt screen (build-abduco.sh)
[ -x "$ABDUCO" ] || ABDUCO="$(command -v abduco 2>/dev/null || echo /opt/homebrew/bin/abduco)"

[ -e "$KITTY" ] || { echo "kitty not built ($KITTY). Run cove/dev.sh first." >&2; exit 1; }

# The termling sessions that will survive the kitty kill (abduco holds them).
# (A leading "+" marks a session whose shell already exited: nothing to reattach.)
SESSIONS=($("$ABDUCO" 2>/dev/null | awk 'NR>1 && $1!="+"{print $NF}' | grep '^cove-' || true))
echo "reattaching ${#SESSIONS[@]} termling session(s): ${SESSIONS[*]:-<none>}"

# Save each termling's screen + scrollback (with colours) while this kitty still
# has it: abduco keeps the processes, not the screen, so without this every
# reattached window starts blank. cove-reattach.sh prints it back. Best-effort.
mkdir -p "$DIR/scroll"
"$KITTEN" @ --to "$SOCK" ls 2>/dev/null | /usr/bin/python3 -c '
import json, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
kitten, sock, out = sys.argv[1:4]
try:
    wins = [w for o in json.load(sys.stdin) for t in o["tabs"] for w in t["windows"]]
except Exception:
    sys.exit(0)
def save(w):
    for p in w.get("foreground_processes", []):
        m = re.search(r"abduco\S*\s+-A\s+(cove-\d+)", " ".join(p.get("cmdline", [])))
        if m:
            try:
                txt = subprocess.run([kitten, "@", "--to", sock, "get-text", "--match", "id:%d" % w["id"],
                                      "--ansi", "--extent", "all"], capture_output=True, timeout=20).stdout
            except Exception:
                return
            if txt.strip():
                with open("%s/%s.ansi" % (out, m.group(1)), "wb") as f:
                    f.write(txt)
            return
with ThreadPoolExecutor(8) as ex:
    list(ex.map(save, wins))
' "$KITTEN" "$SOCK" "$DIR/scroll" || true
echo "saved $(ls "$DIR/scroll" 2>/dev/null | wc -l | tr -d ' ') termling screen(s)"

# Stop Godot + kitty. The abduco masters (and the shells/agents they hold) keep
# running, detached, so nothing inside the termlings is lost.
pkill -if "godot --path $APP" 2>/dev/null || pkill -if 'godot --path' 2>/dev/null || true
# Wait for Godot to be gone before touching kitty: a Godot still running while
# the frame files vanish and reappear under new ids re-places those termlings
# and saves the wrong spots to state.json (seen 2026-09-25 under heavy load).
for _ in $(seq 1 50); do pgrep -if "godot --path $APP" >/dev/null || break; sleep 0.1; done
pkill -9 -if "godot --path $APP" 2>/dev/null || true
KPIDS="$(cat "$DIR/kitty.pid" 2>/dev/null || true) $(ps -Ao pid=,command= | awk '/[l]auncher\/kitty --title cove/ {print $1}')"
for _p in $KPIDS; do kill "$_p" 2>/dev/null || true; done
# A long-lived kitty can ignore SIGTERM, then unlink the NEW kitty's socket when
# it finally exits. Give it a moment, then make sure.
for _ in $(seq 1 30); do
    _alive=0; for _p in $KPIDS; do kill -0 "$_p" 2>/dev/null && _alive=1; done
    [ "$_alive" = 0 ] && break; sleep 0.1
done
for _p in $KPIDS; do kill -9 "$_p" 2>/dev/null || true; done
sleep 0.3
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
    nohup "$KITTY" "${COMMON[@]}" "$REATTACH" "${SESSIONS[0]}" "${SHELL:-/bin/zsh}" >/tmp/cove-kitty.log 2>&1 &
fi
COVE_KITTY_PID=$!

# Wait for kitty to publish its first frame.
for _ in $(seq 1 80); do ls "$DIR"/term-*.rgba >/dev/null 2>&1 && break; sleep 0.1; done
echo "$COVE_KITTY_PID" > "$DIR/kitty.pid"

# Reattach the remaining sessions, each as its own OS window.
# Retry: under load a launch can time out, and a session that misses its window
# silently vanishes from the board (26 of 70 did on 2026-09-25).
for ((i=1; i<${#SESSIONS[@]}; i++)); do
    for _try in 1 2 3; do
        "$KITTEN" @ --to "$SOCK" launch --type=os-window \
            "$REATTACH" "${SESSIONS[$i]}" "${SHELL:-/bin/zsh}" >/dev/null 2>&1 && break
        [ "$_try" = 3 ] && echo "WARNING: couldn't reattach ${SESSIONS[$i]} (still alive in abduco)" >&2
        sleep 2
    done
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
