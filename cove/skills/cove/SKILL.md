---
name: cove
description: Drive the Walking-Terminals Cove — see the little terminal-carriers on the 2.5D stage, move them, make one follow another, gather/scatter, or focus one. Use when the user asks to move/arrange/follow/gather terminals, wants an agent to control where its terminal goes, or to reason about terminal positions on the Cove stage.
---

# Cove control

The stage is **the Cove**: each live terminal is a **Termling**, hauled around a
cosy top-down world by two little crewmates. A Termling you follow to work
alongside becomes your **shellmate**. You drive them through the `cove` MCP
server (already registered). Motion planning — avoiding other Termlings, staying
nearby without clipping — is done by the engine; you just issue intents.

## Am I inside the Cove?

A shell inside the Cove has `COVE=1` and a `KITTY_WINDOW_ID`. From an
agent, call **`whoami`** — it returns your terminal record (id, position, agent,
cwd) or an error if you're not in one.

## Seeing the world

**`list_terminals`** returns every terminal: `id`, `pane_id`, `agent`
(`claude`/`codex`/`opencode`/`shell`), `busy`, `attention`, `pos [x,y]`,
`cols`/`rows`, `cwd`, and `following`. Plus the `camera`. World coordinates:
the ground spans roughly x∈[-1600,1600], y∈[-1100,1100]; +x is right, +y is down.
`id` is the Cove terminal id; `pane_id` is kitty's `$KITTY_WINDOW_ID`. Every
tool that takes an `id` accepts either.

## Commanding

- **`move(id, x, y)`** — send a terminal's carriers to a world point. Cancels any
  follow. The engine steers around other terminals.
- **`follow(id, target)`** — `id` shadows `target`, standing beside it and keeping
  up as it moves, without overlapping.
- **`stop(id)`** — end follow/move; it wanders again.
- **`focus(id)`** — focus it (typing goes there) and make the camera track it.
- **`rename(name, id?)`** — name a terminal (shown on its nameplate). From inside
  a terminal you can omit `id` to name your own (uses `$KITTY_WINDOW_ID`). Empty
  name resets to `terminal N`.
- **`gather()`** — cluster everyone around the current camera view.
- **`scatter()`** — release everyone to wander.

To name the terminal you're running in: `rename(name="build")`. Users can also
rename manually by right-clicking a terminal on the stage.

## Recipes

- *"bring my terminal next to the one running codex"*: `list_terminals` → find the
  codex terminal's id and your own via `whoami` → `follow(my_id, codex_id)`.
- *"line them up"*: `list_terminals`, then `move` each to a row of x positions at a
  shared y.
- *"send this one to the corner and leave it"*: `move(id, -1400, -900)` then it
  stays put until it finishes (it won't wander from a commanded point until you
  `stop` it).

## Notes

- Commands are fire-and-forget (appended to a queue Godot drains ~10×/s). Re-read
  `list_terminals` to see the result a moment later.
- Terminals that need your input flash a "!" and get added to the on-stage
  notification panel automatically (via the Stop/Notification hooks); you don't
  need to do anything for that.
- No-op if the Cove isn't running (`state.json` absent) — tools still return,
  just against an empty world.
