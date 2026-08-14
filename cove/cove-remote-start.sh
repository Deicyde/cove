#!/usr/bin/env bash
# Start (or restart) the remote-termling relay + auto-viewer, if wwid is
# installed. Idempotent — safe to call on every Cove launch. Both depend on
# cove-kitty (not Godot), so they keep running across Godot reloads. The relay
# publishes THIS machine's termlings; the auto-viewer mirrors every sync peer's
# termlings back as read-only shadows. No-op (not an error) when wwid is absent.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v wwid >/dev/null 2>&1; then
    echo "cove: wwid not installed — remote termlings off (build what-was-I-doing)" >&2
    exit 0
fi
WWID="$(command -v wwid)"

pkill -f cove-relay.sh 2>/dev/null || true
pkill -f cove-remote-auto.sh 2>/dev/null || true
sleep 0.3

WWID="$WWID" nohup "$APP/cove-relay.sh"       >/tmp/cove-relay.log 2>&1 &
WWID="$WWID" nohup "$APP/cove-remote-auto.sh"  >/tmp/cove-remote-auto.log 2>&1 &
echo "cove: remote termlings up — relay + auto-viewer (peers mirrored as shadows)"
