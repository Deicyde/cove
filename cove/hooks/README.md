# Cove hooks

Claude Code hooks for the Cove. Copy into `~/.claude/hooks/` and register in
`~/.claude/settings.json`. All are gated on `$COVE`, so they only fire for
shells running inside the Cove.

- `cove-hello.sh` (SessionStart) greets an agent that it's a Termling in the Cove.
- `cove-notify.sh` (Stop, Notification) mirrors "needs input / finished" into the
  Cove's `notify.jsonl` for the on-stage panel + camera.
- `cove-focus.sh` is the notification click target: it raises the Cove window and
  tells the camera to focus + follow that agent's terminal.

## The clickable banner

Clicking a stop notification should jump you to the Termling. Post it with
`terminal-notifier` (`brew install terminal-notifier`), whose `-execute` runs on
click:

```
terminal-notifier -title "🐚 Cove · $PROJECT" -subtitle "$BODY" \
  -message "tap to jump to it in the Cove" \
  -group "cove-$KITTY_WINDOW_ID" \
  -execute "$HOME/.claude/hooks/cove-focus.sh $KITTY_WINDOW_ID"
```

If you already have a stop hook that shows a macOS notification, put this branch
*there* (guarded by `[ -n "$COVE" ]`) and keep your normal notification in the
`else`, so a Cove agent gets one clickable banner rather than two. Leave the
`terminal-notifier` call out of `cove-notify.sh` in that case. With no such hook,
add the snippet to `cove-notify.sh` and it stands alone.
