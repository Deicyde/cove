---
name: cove-dev
description: Edit and hot-reload the Cove — the walking-terminals app where each live kitty terminal is a Termling carried around a 2.5D world by two little crew. Use when changing the Cove's code, launching it in dev mode, or hot-reloading its scripts while keeping the terminals and their positions.
---

# Developing the Cove

The Cove is a fork of kitty. kitty renders each terminal headless into a shared
frame, and a Godot app draws it as a Termling that gets carried around a 2.5D
world. The app is the `cove/` subdirectory of the kitty tree.

## Get the source

It's usually already cloned at `~/Documents/code/kitty` (app in `cove/`). If it
isn't, clone the fork and check out the `cove` branch:

```
git clone -b cove https://github.com/kiranandcode/cove ~/Documents/code/cove
```

kitty itself must be built once (`cove/README.md` has the steps); the app needs
`kitty/launcher/kitty` and Godot 4.6. Set `GODOT` if `godot` isn't on `PATH`.

## Edit and hot-reload

kitty runs as its own process, so Godot can restart without touching a single
terminal. Edit, reload, and every Termling keeps its shell, scrollback and
running agent.

```
cove/dev.sh        # kitty (detached) + Godot
# edit cove/scripts/*.gd or cove/scenes/*.tscn ...
cove/reload.sh     # relaunch Godot only; terminals + positions stay
cove/stop.sh       # quit both
```

Positions come back because Godot writes `/tmp/cove/state.json` continuously and
`Cove.gd::_load_layout()` reads it before the first frame, restoring each
Termling's position, name, camera, follows and focus. A reloaded Termling
resumes wandering from where it was, not from a reset. This is a Godot relaunch
(a ~2s blink), not in-place script swapping.

## When a rebuild is needed

GDScript and scene edits need only `reload.sh`. Native code needs a build first:

- kitty C (`kitty/cove.c`, `kitty/cove_macos.m`): `python3 setup.py` from the
  repo root, then `dev.sh` again.
- GDExtension (`cove/gdext/src`): `scons` in `cove/gdext` (needs godot-cpp at
  `/tmp/godot-cpp`; the build is pinned to a universal dylib), then re-import
  once with `godot --path cove --editor --headless --quit`.

On startup Godot prints `cove: fast input via CoveInput extension`. A
`push_warning` there instead means the extension didn't load and input fell back
to the slow `kitten @ send` path, usually a stale dylib path in
`cove.gdextension`.

## Notes

- Driving a Termling around (move, follow, focus) is the separate **cove** skill.
  This one is for changing the app.
- Logs: `/tmp/cove-kitty.log`, `/tmp/cove-godot.log`.
