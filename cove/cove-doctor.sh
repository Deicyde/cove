#!/usr/bin/env bash
# cove-doctor.sh — check this machine has everything the Cove needs, and flag
# multi-device drift (versions must match across laptops for remote termlings).
# Prints key=value lines (ok/missing/…); exits non-zero if any hard check fails.
#
#   cove/cove-doctor.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/cove"
GODOT="${GODOT:-godot}"
FAIL=0

say() { printf '%-16s %s\n' "$1" "$2"; }
need() { # label, condition-already-evaluated (0 ok), detail
    if [ "$2" -eq 0 ]; then say "$1" "ok${3:+ ($3)}"; else say "$1" "MISSING${3:+ ($3)}"; FAIL=1; fi
}

# Godot 4.6 — the Cove is version-sensitive; a mismatch across devices breaks the
# shared project.
if command -v "$GODOT" >/dev/null 2>&1; then
    ver="$("$GODOT" --version 2>/dev/null | head -1)"
    case "$ver" in
        4.6*) say godot "ok ($ver)" ;;
        *)    say godot "WRONG ($ver, want 4.6.x)"; FAIL=1 ;;
    esac
else
    say godot "MISSING (set GODOT=/path/to/godot)"; FAIL=1
fi

# The custom kitty build (deps + __main__ + shaders live under launcher/).
[ -x "$REPO/kitty/launcher/kitty" ]; need kitty $? "$REPO/kitty/launcher/kitty"

# The GDExtension dylib (fast input + IOSurface zero-copy).
[ -f "$APP/bin/libcove.macos.template_debug.universal.dylib" ]; need gdext_dylib $?

# abduco — warm reload / termlings surviving a kitty restart.
command -v abduco >/dev/null 2>&1; need abduco $?

# wwid — the multi-device backbone (sync + remote termlings).
if command -v wwid >/dev/null 2>&1; then
    role="$(wwid doctor 2>/dev/null | awk -F= '/^role=/{print $2}')"
    daemon="$(wwid doctor 2>/dev/null | awk -F= '/^daemon=/{print $2}')"
    say wwid "ok (daemon=${daemon:-?} role=${role:-?})"
else
    say wwid "MISSING (build what-was-I-doing)"; FAIL=1
fi

# Claude auth is per-machine Keychain — copying ~/.claude.json is not enough. We
# can only check the binary is here; run `claude login` once per device.
if command -v claude >/dev/null 2>&1; then
    say claude "present (run 'claude login' once per device if agents fail)"
else
    say claude "MISSING (install + 'claude login')"; FAIL=1
fi

[ "$FAIL" -eq 0 ] && echo "cove-doctor: all good" || echo "cove-doctor: issues above"
exit "$FAIL"
