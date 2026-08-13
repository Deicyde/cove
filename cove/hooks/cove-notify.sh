#!/bin/bash
# Cove integration hook. Mirrors Claude Code "needs input / finished"
# events into the cove's notification channel so the on-screen terminal
# that needs attention lights up. Additive -- does NOT replace notify-stop.sh.
# No-op unless the cove is running (its dir exists).

# Only fire for agents running INSIDE a cove terminal.
[ -n "$COVE" ] || exit 0
[ -n "$KITTY_WINDOW_ID" ] || exit 0
DIR="${KITTY_COVE_DIR:-/tmp/cove}"
[ -d "$DIR" ] || exit 0

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "Stop"')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
REASON=$(printf '%s' "$INPUT" | jq -r '.stop_reason // .tool_name // ""')
PROJECT=$(basename "$CWD" 2>/dev/null)
TS=$(date +%s)

# pane is kitty's window id -> maps directly to a cove terminal.
printf '{"ts":%s,"pane":%s,"event":%s,"cwd":%s,"project":%s,"reason":%s}\n' \
  "$TS" \
  "${KITTY_WINDOW_ID}" \
  "$(jq -cn --arg v "$EVENT" '$v')" \
  "$(jq -cn --arg v "$CWD" '$v')" \
  "$(jq -cn --arg v "$PROJECT" '$v')" \
  "$(jq -cn --arg v "$REASON" '$v')" \
  >> "$DIR/notify.jsonl" 2>/dev/null

# The clickable macOS banner is posted by notify-stop.sh (Cove-aware), so this
# hook only feeds the on-stage panel + camera to avoid a duplicate notification.

exit 0
