#!/usr/bin/env bash
# cove-remote.sh — bring a peer's termlings into THIS Cove as remote shadows.
#
# Lists a peer's live termlings (over Tailscale, via wwid) and opens one local
# cove-kitty window per termling running `wwid termling watch`, which renders the
# reconstructed screen (read-only). Each shadow window is titled with the remote
# marker "◈ <name> @ <peer>", which Cove.gd recognises to give it the remote
# treatment (tinted screen + "◈" nameplate). Re-run to pick up new termlings;
# already-open shadows are left alone.
#
#   cove/cove-remote.sh <peer> [--drive]
#
# <peer> is a sync-peer name from your wwid config (sync.peers[].name).
# With --drive the shadow forwards lines you type back to the peer (take
# control) — needs the peer to have set sync.allow_remote_input. Read-only
# otherwise.
set -euo pipefail

PEER="${1:-}"
[ -n "$PEER" ] || { echo "usage: cove-remote.sh <peer> [--drive]" >&2; exit 1; }
MODE="watch"
[ "${2:-}" = "--drive" ] && MODE="drive"

DIR="${KITTY_COVE_DIR:-/tmp/cove}"
[ -f "$DIR/dev-env" ] && . "$DIR/dev-env"
KITTEN="${COVE_KITTEN:-$(command -v kitten || true)}"
SOCK="${COVE_KITTY_SOCKET:-unix:/tmp/cove-kitty}"
WWID="${WWID:-wwid}"
MARK="◈"

[ -n "$KITTEN" ] || { echo "cove-remote: no kitten found (set COVE_KITTEN)" >&2; exit 1; }
command -v "$WWID" >/dev/null 2>&1 || { echo "cove-remote: wwid not on PATH" >&2; exit 1; }

# Titles of already-open shadow windows, so we don't double-open one.
open_shadows() {
    "$KITTEN" @ --to "$SOCK" ls 2>/dev/null | python3 -c '
import sys, json
try: data = json.load(sys.stdin)
except Exception: sys.exit(0)
for o in data:
    for t in o.get("tabs", []):
        for w in t.get("windows", []):
            print(w.get("title") or "")
'
}

existing="$(open_shadows || true)"

# `wwid termling list` prints "<key>  seq <n>  <rows> rows"; take the key.
"$WWID" termling list --peer "$PEER" | awk '{print $1}' | while read -r key; do
    [ -n "$key" ] || continue
    title="$MARK $key @ $PEER"
    if printf '%s\n' "$existing" | grep -Fqx "$title"; then
        echo "cove-remote: $title already open" >&2
        continue
    fi
    echo "cove-remote: opening shadow $title ($MODE)" >&2
    "$KITTEN" @ --to "$SOCK" launch --type=window --title "$title" --keep-focus \
        "$WWID" termling "$MODE" --peer "$PEER" "$key" >/dev/null 2>&1 || true
done
