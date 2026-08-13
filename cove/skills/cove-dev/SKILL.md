---
name: cove-dev
description: Run and hot-reload the Cove — the walking-terminals Godot app at ~/Documents/code/kitty/cove where each live kitty terminal is a Termling carried around a 2.5D world. Use when launching the Cove, pushing code changes to a running Cove, or hot-reloading its scripts while keeping terminals and their positions.
---

# Developing the Cove

The app lives at `~/Documents/code/kitty/cove`. kitty runs as a **separate**
process from Godot, so Godot can be relaunched without disturbing any terminal.
That is what makes hot-reload safe: edit scripts, relaunch Godot, and every
Termling's shell, position, name, camera and follow come back.

Set `GODOT` to your Godot 4.6 binary if `godot` isn't on `PATH`.

## Launch, edit, reload

```
cove/dev.sh        # starts kitty (detached) + the Godot app
# edit cove/scripts/*.gd or cove/scenes/*.tscn ...
cove/reload.sh     # relaunches ONLY Godot; terminals + positions persist
cove/stop.sh       # quits both
```

`dev.sh` differs from `run.sh` in one way: it runs kitty detached so killing
Godot doesn't kill kitty. Use `run.sh` for a normal (non-dev) session where
closing the window tears everything down.

## What persists across a reload

Godot writes `/tmp/cove/state.json` continuously (positions, names, camera,
follows, focus). On the next launch `Cove.gd::_load_layout()` reads it before
anything is drawn and restores each Termling to where it was. kitty never
stopped, so the shells and running agents are untouched — a reloaded Termling
keeps its scrollback and its foreground process.

A Termling resumes wandering after it's restored; it's placed where it was, not
frozen. To pin one, `move` it via the `cove` MCP (a commanded Termling stays put
until `stop`).

## When a rebuild is needed

GDScript and scene edits need only `reload.sh`. Native changes need a build:

- kitty C (`kitty/cove.c`, `kitty/cove_macos.m`, frame export / input socket):
  `python3 setup.py` from the repo root, then `dev.sh` again.
- GDExtension (`cove/gdext/src`, IOSurface/Metal import + input): `scons` in
  `cove/gdext` (needs godot-cpp at `/tmp/godot-cpp`), then re-import once with
  `godot --path cove --editor --headless --quit`.

## Notes

- Requires kitty built at `kitty/launcher/kitty` (see `cove/README.md`).
- Logs: `/tmp/cove-kitty.log`, `/tmp/cove-godot.log`.
- The agent-facing control API (move/follow/focus a Termling) is the separate
  **cove** skill; this one is for changing the app itself.
