#!/usr/bin/env bash
# cove-remote-auto.sh — continuously mirror every sync peer's termlings into this
# Cove as remote shadows. For each peer in the wwid config it opens a shadow
# os-window per termling (titled "◈ <key> @ <peer>", which Cove.gd gives the red
# remote treatment) and reaps shadows whose remote termling has gone. Runs
# forever; start it once when the Cove comes up. Read-only (watch, not drive).
set -uo pipefail

DIR="${KITTY_COVE_DIR:-/tmp/cove}"
[ -f "$DIR/dev-env" ] && . "$DIR/dev-env"
KITTEN="${COVE_KITTEN:-$(command -v kitten || true)}"
SOCK="${COVE_KITTY_SOCKET:-unix:/tmp/cove-kitty}"
WWID="${WWID:-wwid}"
CFG="${WWID_HOME:-$HOME/.whatwasIdoing}/config.json"
INTERVAL="${COVE_REMOTE_INTERVAL:-3}"
MARK="◈"

[ -n "$KITTEN" ] || { echo "cove-remote-auto: no kitten (set COVE_KITTEN)" >&2; exit 1; }
command -v "$WWID" >/dev/null 2>&1 || { echo "cove-remote-auto: wwid not on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "cove-remote-auto: python3 required" >&2; exit 1; }

echo "cove-remote-auto: mirroring peers' termlings every ${INTERVAL}s" >&2

# Peer names from the wwid config's sync.peers.
peers() {
    python3 -c 'import json,sys
try: c=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for p in c.get("sync",{}).get("peers",[]): print(p.get("name",""))' "$CFG" 2>/dev/null
}

# Currently-open shadow windows as "<id>\t<title>" lines (only ◈-titled ones).
open_shadows() {
    "$KITTEN" @ --to "$SOCK" ls 2>/dev/null | python3 -c '
import sys, json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for o in d:
    for t in o.get("tabs",[]):
        for w in t.get("windows",[]):
            title=w.get("title") or ""
            if title.startswith("◈"):
                print(str(w.get("id"))+"\t"+title)'
}

while true; do
    # Desired shadow titles across all peers (newline-separated).
    desired="$(
        for peer in $(peers); do
            [ -n "$peer" ] || continue
            "$WWID" termling list --peer "$peer" 2>/dev/null | awk -v p="$peer" -v m="$MARK" \
                'NF{print m" "$1" @ "p}'
        done
    )"

    current="$(open_shadows)"

    # Open any desired shadow that isn't open yet.
    printf '%s\n' "$desired" | while IFS= read -r title; do
        [ -n "$title" ] || continue
        if ! printf '%s\n' "$current" | grep -Fq "	$title"; then
            body="${title#"$MARK" }"          # "<key> @ <peer>"
            key="${body%% @ *}"
            peer="${body##* @ }"
            "$KITTEN" @ --to "$SOCK" launch --type=os-window --title "$title" --keep-focus \
                "$WWID" termling watch --peer "$peer" "$key" >/dev/null 2>&1 || true
        fi
    done

    # Reap shadows whose remote termling is no longer advertised.
    printf '%s\n' "$current" | while IFS=$'\t' read -r id title; do
        [ -n "$id" ] || continue
        if ! printf '%s\n' "$desired" | grep -Fqx "$title"; then
            "$KITTEN" @ --to "$SOCK" close-window --match "id:$id" >/dev/null 2>&1 || true
        fi
    done

    sleep "$INTERVAL"
done
