#!/usr/bin/env bash
# cove-handoff-capture.sh — print the Claude Code session id to resume for a cwd.
#
# When a Claude termling is dragged out, Mac A calls this to fill the handoff
# payload with the session to resume on Mac B. Claude Code writes one transcript
# per session at ~/.claude/projects/<mangled-cwd>/<session-uuid>.jsonl, where the
# cwd is mangled by replacing '/' and '.' with '-'. The most-recently-modified
# transcript in that dir is the live session. Prints the uuid, or nothing.
#
#   cove-handoff-capture.sh <cwd> [pid]
#
# If <pid> (the claude process) is given we prefer the exact transcript it has
# open (lsof), which is correct even when several sessions share a cwd; otherwise
# we fall back to newest-by-mtime.
set -euo pipefail

CWD="${1:-}"
PID="${2:-}"
[ -n "$CWD" ] || exit 0

mangled="${CWD//\//-}"
mangled="${mangled//./-}"
proj="$HOME/.claude/projects/$mangled"
[ -d "$proj" ] || exit 0

# Exact: the transcript the running claude has open.
if [ -n "$PID" ] && command -v lsof >/dev/null 2>&1; then
    sid="$(lsof -p "$PID" -Fn 2>/dev/null \
        | sed -n "s#^n${proj}/\([0-9a-fA-F-]*\)\.jsonl#\1#p" | head -1)"
    if [ -n "$sid" ]; then
        printf '%s' "$sid"
        exit 0
    fi
fi

# Fallback: newest transcript by mtime.
newest="$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1)"
[ -n "$newest" ] || exit 0
base="$(basename "$newest")"
printf '%s' "${base%.jsonl}"
