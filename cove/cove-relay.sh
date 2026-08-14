#!/usr/bin/env bash
# cove-relay.sh — publish this device's live Cove termlings to the local wwid
# server so peers can watch them as remote termlings (read-only shadows).
#
# For each cove-kitty window it: registers a wwid session (device-tagged, project
# auto-linked by cwd) and, on an interval, snapshots the window's screen text
# (`kitten @ get-text`) and pushes it to wwid (`wwid termling publish`). wwid
# diffs the text and serves only the changed rows to subscribers over Tailscale —
# no rendered frames ever leave the machine. Windows that disappear are ended.
#
# Requires: a running wwid server (`wwid start`) with sync enabled + an api_key,
# and the cove-kitty instance (dev.sh/run.sh). Publishing is local-only; the
# api_key gate on wwid keeps the served stream to trusted peers.
set -euo pipefail

DIR="${KITTY_COVE_DIR:-/tmp/cove}"
# dev.sh writes the kitten path + socket here; fall back to sensible defaults.
[ -f "$DIR/dev-env" ] && . "$DIR/dev-env"
KITTEN="${COVE_KITTEN:-$(command -v kitten || true)}"
SOCK="${COVE_KITTY_SOCKET:-unix:/tmp/cove-kitty}"
WWID="${WWID:-wwid}"
INTERVAL="${COVE_RELAY_INTERVAL:-0.3}"

[ -n "$KITTEN" ] || { echo "cove-relay: no kitten found (set COVE_KITTEN)" >&2; exit 1; }
command -v "$WWID" >/dev/null 2>&1 || { echo "cove-relay: wwid not on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "cove-relay: python3 required" >&2; exit 1; }

echo "cove-relay: streaming cove-kitty ($SOCK) termlings to wwid every ${INTERVAL}s" >&2

# key -> 1 for every session we've registered this run, so we can end vanished ones.
declare -A KNOWN

# Emit one `id\tagent\tcwd\ttitle` line per live window (tabs skipped).
windows() {
    "$KITTEN" @ --to "$SOCK" ls 2>/dev/null | python3 - <<'PY'
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for osw in data:
    for tab in osw.get("tabs", []):
        for w in tab.get("windows", []):
            wid = w.get("id")
            if wid is None:
                continue
            cwd = w.get("cwd") or ""
            title = (w.get("title") or "").replace("\t", " ")
            # Crude agent sniff from the window's foreground process tree.
            blob = " ".join(
                " ".join(p.get("cmdline", []))
                for p in w.get("foreground_processes", [])
            ).lower()
            agent = "shell"
            for a in ("opencode", "codex", "claude"):
                if a in blob:
                    agent = a
                    break
            print("\t".join([str(wid), agent, cwd, title]))
PY
}

while true; do
    declare -A SEEN=()
    while IFS=$'\t' read -r wid agent cwd title; do
        [ -n "$wid" ] || continue
        key="w${wid}"
        SEEN[$key]=1
        if [ -z "${KNOWN[$key]:-}" ]; then
            "$WWID" session register "$key" --agent "$agent" \
                ${cwd:+--cwd "$cwd"} ${title:+--title "$title"} >/dev/null 2>&1 || true
            KNOWN[$key]=1
        fi
        # Snapshot the screen text and publish it (wwid diffs vs the last).
        "$KITTEN" @ --to "$SOCK" get-text --match "id:${wid}" 2>/dev/null \
            | "$WWID" termling publish "$key" 2>/dev/null || true
        # Replay any input a viewer forwarded to drive this termling. Gated at
        # wwid by sync.allow_remote_input, so this is empty unless you opted in.
        input="$("$WWID" termling input-drain "$key" 2>/dev/null || true)"
        if [ -n "$input" ]; then
            printf '%s' "$input" \
                | "$KITTEN" @ --to "$SOCK" send-text --match "id:${wid}" --stdin \
                  >/dev/null 2>&1 || true
        fi
    done < <(windows)

    # End any termling that has gone away since last tick.
    for key in "${!KNOWN[@]}"; do
        if [ -z "${SEEN[$key]:-}" ]; then
            "$WWID" session end "$key" >/dev/null 2>&1 || true
            "$WWID" termling end "$key" >/dev/null 2>&1 || true
            unset 'KNOWN[$key]'
        fi
    done

    sleep "$INTERVAL"
done
