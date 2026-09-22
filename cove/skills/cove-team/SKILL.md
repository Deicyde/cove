---
name: cove-team
description: Run a team of agents as termlings on the Cove board. Split work into tasks, give each task a frame and a fresh termling with a short prompt, wait for whichever finishes, follow up or close it, and track progress on a todo. Use in a Cove termling (COVE=1) when asked to "spawn N termlings", fan work out over files/items/ideas, run agents in parallel where the user can watch them, or get fresh eyes on something. iterate-pr is the PR-specific version.
---

# cove-team: a team of termlings

You're the lead, running in a Cove termling. You split the work, lay out the
board, spawn one termling per task, and steer them with short messages. The
user watches every termling and can step into any of them. The tools are the
`cove` MCP server's (see the `cove` skill).

## 1. Tasks

Turn the request into a list of tasks, each one line:

- "one per X" (files, PRs, modules, bugs, papers): one task per item. Get the
  list with a shell command (`ls`, `rg -l`, `gh issue list`) so none are
  missed.
- "N termlings on Y" (brainstorm, attempts, reviews): N copies of the same
  task. For variety, give each a different angle or constraint in one clause.
- Fresh eyes on something: one task.

Keep it to at most 8 at once. Queue the rest and spawn them as others finish.

Tasks that edit the same repo in parallel each get their own git worktree:
`git worktree add --detach ../<repo>-<slug>`. Read-only tasks share your cwd.

## 2. Board

1. `whoami`. A termling is about 330×185 world units, with its crew below.
   One task frame is 620×460.
2. A group frame for the team: `add_frame(title="<team name>", w=40+660·cols,
   h=80+500·rows, near="me")`, with cols = min(4, tasks).
3. One frame per task inside it: `add_frame(title="<task, a few words>", w=620,
   h=460, inside=<group id>)`.
4. `add_note(type="todo", text="<team name>", items=[<one per task>])` next to
   you.
5. `screenshot(target=<group id>)`. Fix any overlap with `update_note(id, x, y,
   w, h)` before spawning.

## 3. Spawn

For each task: `spawn(name="<short name>", frame=<its frame>, cwd=<its dir>,
command="claude", prompt=<prompt>)`.

Write the prompt the way the user types: one or two plain sentences with the
task and any link or path. Leave out any output format and anything about the
Cove. Examples: "Please review src/parser.rs", "Find why test_login flakes",
"Sketch three ways to cache the board renderer".

## 4. Steer

Loop on `wait(mode="any")`:

- **Turn ended**: `read(id, lines=200)` and judge it.
  - Done and good: tick its todo item, note the one-line outcome, and `kill`
    it. Spawn the next queued task into its frame.
  - Needs more: `send` one short follow-up ("Please also cover X", "Please fix
    that and commit").
  - Went wrong: `kill` it and respawn fresh with a sharper prompt. Once only.
    After that, leave it up and `status(blocked, "<task>: <why>")`.
- **Asking a question or a permission prompt**: answer it with `send` if the
  answer is in the task. Otherwise `status(needs_you, "<task> asks …")` and keep
  waiting on the others.
- **Timed out**: `wait` again.
- **`trust_prompt: true` from spawn**: the user accepts the folder.
  `status(needs_you, ...)`.

## 5. Finish

When the todo is all ticked:

- Combine the results in your own reply (a table or a short list, one line per
  task). For N-copies tasks, merge them: say where they agree and pick the
  strongest.
- `report(...)` to your parent if you have one, then `status(done, "<one
  line>")`.
- Leave the frames and the todo for the user to clear. Remove worktrees only
  when their work is merged or not needed.

## Rules

- Every termling goes in a frame, and every finished one is killed. No strays.
- Only drive your own children.
- A task that is itself a team can go to a child lead: spawn it with "Use
  cove-team: <task>" and it builds its own frames inside the one you gave it.
  Its arrows go to its own team.
