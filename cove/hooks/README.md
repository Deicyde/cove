# Cove hooks

Additive Claude Code hooks for the Cove (they never replace your existing
`notify-stop.sh`). Install by copying into `~/.claude/hooks/` and registering in
`~/.claude/settings.json`:

- `cove-hello.sh` (SessionStart) greets an agent that it's a Termling in the Cove.
- `cove-notify.sh` (Stop, Notification) mirrors "needs input / finished" into the
  Cove's `notify.jsonl` (on-stage panel + camera) and posts a clickable macOS
  notification via `terminal-notifier`.
- `cove-focus.sh` is the click target: it raises the Cove window and tells the
  camera to focus + follow that agent's terminal.

All are gated on `$COVE` so they only fire for shells running inside the Cove.
`cove-notify.sh`'s clickable alert needs `brew install terminal-notifier`.
