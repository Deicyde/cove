#!/usr/bin/env bash
# Refuse to make kitty inherit an existing macOS Seatbelt profile. A fresh
# Claude/Codex termling needs to install its own workspace-scoped sandbox;
# macOS rejects that nested sandbox with sandbox_apply(3) EPERM.

cove_require_clean_launch_context() {
    local repo="$1" command="$2"
    [ "$(/usr/bin/uname -s)" = Darwin ] || return 0

    local probe="${COVE_SANDBOX_EXEC:-/usr/bin/sandbox-exec}"
    if [ ! -x "$probe" ]; then
        printf 'Cove: cannot verify a clean launch context; sandbox probe is not executable: %s\n' \
            "$probe" >&2
        printf 'Nothing was stopped. Start Cove from a normal Terminal/iTerm window.\n' >&2
        return 69
    fi
    local detail rc
    if detail=$("$probe" -p '(version 1)(allow default)' /usr/bin/true 2>&1 >/dev/null); then
        return 0
    else
        rc=$?
    fi

    cat >&2 <<EOF
Cove: refusing to launch kitty from inside an existing macOS sandbox.
That would make every new Claude/Codex termling fail with:
  sandbox-exec: sandbox_apply: Operation not permitted

Nothing was stopped. Run this once from a normal Terminal/iTerm window:
  cd "$repo"
  $command
EOF
    [ -z "$detail" ] || printf 'Sandbox probe: %s\n' "$detail" >&2
    return "$rc"
}
