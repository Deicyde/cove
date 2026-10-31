# Cove board conventions

Every Claude and Codex termling reads this at startup (hooks/cove-hello.sh), so keep it short.

- Name your termling after its current task with the cove `rename` tool (20 characters or fewer), and rename it when the task changes.
- Refer to other agents by termling name (`list_terminals` → `name`), not by session ids or suffixes such as df, 47 or e9: those change on restart.
- autoform-bot: message the "Board Maintainer" termling before you open a PR or take an issue; it tracks claims.
- One heavy job at a time (Lean, lake, pytest, a browser). Check `uptime` and `sysctl vm.swapusage` first, and hold above load 40 or 8 GB of swap; `~/projects/cove/.swarm-worktrees/bin/resource-ok` checks both.
- Kill only processes you started; record their PIDs when you launch them.
- Reboots wipe /private/tmp: keep work under ~/projects/cove/.swarm-worktrees and push each commit.
