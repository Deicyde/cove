# Walking Terminals (kitty × Godot)

Real, live kitty terminals rendered as sprites that walk around a Godot 2D
scene. Type into them and you're driving an actual shell. Architecture and the
phased plan live in [DESIGN.md](DESIGN.md); this file is how to build and run.

Phase 1 is working today: **no visible kitty window** (each terminal renders
headless into an offscreen FBO), **multiple terminals** as separate draggable
sprites, **Cmd/Ctrl+N** to spawn, **click to focus**, and full keyboard input
(including Ctrl/Alt/Shift/Cmd) routed to the focused terminal.

## How it works

- `kitty/menagerie.c` (behind the `KITTY_MENAGERIE` env var): in this mode each
  kitty OS window is created **hidden** and rendered into its `indirect_output`
  FBO (an app-owned texture, readable even while hidden). Each frame is copied
  into a per-window memory-mapped file `/tmp/kitty-menagerie/term-<id>.rgba`
  (header carries width/height/seq and the pane id for input targeting). The
  file is removed when its terminal closes.
  - C touch points: the module itself, plus one `needs_layers` line + a publish
    call in `child-monitor.c`, a render-gate bypass + force-hidden in `glfw.c`,
    and a cleanup call in `state.c`. All guarded by menagerie mode; normal kitty
    is unaffected.
- `godot/` (Godot 4.6): `scripts/Menagerie.gd` discovers terminals by scanning
  that directory, shows each as a `TermCritter` (`scripts/TermCritter.gd`)
  sprite, and:
  - **drag** a terminal with the mouse, **click** to focus (focused is bright +
    raised; others dimmed),
  - **Cmd/Ctrl+N** spawns a new terminal (`kitten @ launch --type=os-window`),
  - keyboard goes to the focused terminal via `kitten @ send-text` / `send-key
    --match id:<pane>`, with modifiers preserved (Ctrl+C etc. reach the shell).

Zero-copy via IOSurface (replacing the CPU readback) is Phase 2. See DESIGN.md.

## Building kitty

kitty is a from-source build. On this machine the one-time setup was:

```sh
brew install xxhash simde go
brew install --cask font-symbols-only-nerd-font

# kitty 0.48+ compiles shaders with the Khronos Slang compiler (slangc).
# Grab the pinned release (version is in bypy/sources.json):
ver=2026.12.2
curl -fL "https://github.com/shader-slang/slang/releases/download/v${ver}/slang-${ver}-macos-aarch64.tar.gz" \
  | tar xz -C /tmp/slang    # gives /tmp/slang/bin/slangc
```

Then build from the repo root:

```sh
export PATH="/opt/homebrew/bin:$PATH"
export SLANGC=/tmp/slang/bin/slangc
python3 setup.py            # full build (C extension + glfw + go kitten binary)
```

Rebuild after editing the C hack with the same command; only changed files
recompile. `./kitty/launcher/kitty --version` should print `kitty 0.48.x`.

## Running the demo

```sh
godot/run.sh
```

That launches the hacked kitty in menagerie mode (hidden window, remote control
on), waits for the first terminal, then opens the Godot host. In the Godot
window: type to drive the focused terminal, click a terminal to focus it, drag
to move it, **Cmd/Ctrl+N** for a new terminal. Set `GODOT=/path/to/godot` if
godot isn't on your PATH.

## Poking at it by hand

```sh
# Terminal 1: hacked kitty, headless (no window) + remote control
KITTY_MENAGERIE=1 ./kitty/launcher/kitty \
  --listen-on unix:/tmp/menagerie-kitty -o allow_remote_control=yes -o sync_to_monitor=no zsh

# Terminal 2: spawn another terminal (what Cmd+N does), and type into one
K=./kitty/launcher/kitty.app/Contents/MacOS/kitten
$K @ --to unix:/tmp/menagerie-kitty launch --type=os-window zsh
$K @ --to unix:/tmp/menagerie-kitty send-text $'echo hello from outside\n'
ls /tmp/kitty-menagerie/   # one term-<id>.rgba per terminal

# Terminal 3: the Godot host on its own (reads the frame files)
godot --path godot
```

## Env vars

| Var                     | Meaning                                             |
|-------------------------|-----------------------------------------------------|
| `KITTY_MENAGERIE`       | set (any value) to turn on headless menagerie mode  |
| `KITTY_MENAGERIE_DIR`   | dir for per-terminal files (default `/tmp/kitty-menagerie`) |
| `MENAGERIE_KITTEN`      | path to the `kitten` binary (Godot spawn + input)   |
| `MENAGERIE_KITTY_SOCKET`| kitty remote-control socket, e.g. `unix:/tmp/menagerie-kitty` |
| `MENAGERIE_SHOT`        | if set, Godot saves a screenshot there after ~120 frames and quits (headless verification) |

## The scene (2.5D)

A top-down stage: each live terminal is hauled around by **two little carriers**
(Sarah, art reused from `../gates-of-poseidon`) on a ground panel with soft
shadows and a vignette for depth. The carry groups **wander freely**.

- **Focus / type**: click a terminal to focus it (cyan border), then type — keys
  go to that shell. **Cmd/Ctrl+N** spawns another terminal (new carry group).
- **Lift**: press-drag a terminal to lift it off the ground — it rises to the
  cursor, its shadow shrinks, and the two carriers **panic** (X-eyes + jitter).
  Release to drop it; they recover and pick it back up.

Scripts: `Carrier.gd` (walk/idle/panic), `CarryGroup.gd` (two carriers + wander +
lift), `GroundGrid.gd` (floor), `ShadowUtil.gd` (shadows). The live terminal is
still a `TermCritter` (readback or IOSurface), carried at a small `target_width`.

## Hacking in the Godot editor

Open `godot/project.godot` in Godot 4.6. `scenes/TermCritter.tscn` is one
terminal: a `Screen` sprite plus a `Border` and `Nameplate` you can restyle, and
you can add your own child nodes (glow, particles, an `AnimationPlayer`) — they
ride along with every terminal. `scenes/main.tscn` is the world. Press F5 to run;
if kitty is already running in menagerie mode the terminals appear, otherwise the
scene is empty until you launch one.

## Zero-copy IOSurface transport (optional, macOS)

By default frames travel via a CPU readback into the per-terminal file. Set
`KITTY_MENAGERIE_IOSURFACE=1` on the kitty side and each terminal is instead
blitted (GPU→GPU) into an `IOSurface`; its id is published in the file header and
Godot imports it as a Metal `Texture2DRD` — no CPU copy. This needs the
`gdext/` GDExtension built:

```sh
# one-time: godot-cpp matching your Godot (4.5 branch works for 4.6)
git clone --depth 1 --branch 4.5 --recurse-submodules \
  https://github.com/godotengine/godot-cpp /tmp/godot-cpp
# align to your exact Godot and build the extension
godot --headless --dump-gdextension-interface  # -> gdextension_interface.h
godot --headless --dump-extension-api          # -> extension_api.json
cp gdextension_interface.h /tmp/godot-cpp/gdextension/
cd godot/gdext && scons target=template_debug arch=arm64 custom_api_file=/path/to/extension_api.json
```

That builds `godot/bin/libmenagerie.macos.template_debug.arm64.dylib`, wired up by
`godot/menagerie.gdextension`. Godot registers a new `.gdextension` only during a
project import, so run it once (or open the project in the editor):

```sh
godot --path godot --editor --headless --quit   # registers the extension
```

Then launch with the transport on:

```sh
MENAGERIE_IOSURFACE=1 godot/run.sh   # run.sh does the import step for you
```

Without the extension, Godot silently falls back to the readback file, so the
demo always runs.

## Input transport

Keyboard, mouse, and resize go over a **persistent unix socket**
(`$KITTY_MENAGERIE_DIR/input.sock`, served by a listener thread in hacked kitty)
— no `kitten` process per event. Messages are `[kind][id]…`: kind 0 writes raw
terminal bytes to a pane; kind 1 resizes an OS window (queued for the main
thread, applied via `resize_os_window`). Keyboard/mouse are encoded to raw
terminal bytes in Godot. Needs the `gdext/` extension (class `MenagerieInput`);
without it Godot falls back to `kitten @ send-text` / `resize-os-window`. Only
spawning a terminal (`launch`) still uses kitty remote control.

The IOSurface transport is **double-buffered**: kitty ping-pongs between two
surfaces and publishes which one holds the latest complete frame, so Godot never
samples a half-blitted frame.

## Remote termlings (multi-device)

See another laptop's live termlings inside your own Cove, marked remote. The
transport is **differential text**, not rendered frames — cheap over Tailscale,
and the text stays selectable. It rides on wwid's multi-device sync (see
`what-was-I-doing/REMOTE_TERMLINGS_PLAN.md`).

- **Origin** (the machine being watched): run `cove/cove-relay.sh`. Per
  cove-kitty window it registers a wwid session (`wwid session register`) and,
  every ~0.3s, snapshots the window text (`kitten @ get-text`) and pushes it to
  the local wwid server (`wwid termling publish`). wwid diffs the text and serves
  only the changed rows at `GET /termlings/:key` (api_key + Tailscale, same gate
  as `/sync`). Needs `wwid start` with sync enabled and an `api_key` set.
- **Viewer**: run `cove/cove-remote.sh <peer>` (a sync-peer name from your wwid
  config). It lists the peer's termlings and opens one local cove-kitty window
  per termling running `wwid termling watch`, which reconstructs the screen from
  the deltas (read-only). Each shadow window is titled `◈ <name> @ <peer>`.
- **Remote indicator**: `Cove.gd` recognises the `◈` title marker and gives the
  termling a cool-blue tint and a `◈` nameplate (`TermCritter.set_remote`) so a
  remote shadow is never mistaken for a local termling.

- **Driving** (take control): watching is read-only by default. The origin opts
  in with `sync.allow_remote_input` in its wwid config; the viewer then runs
  `cove/cove-remote.sh <peer> --drive` (or `wwid termling drive`). Lines you type
  are forwarded to `POST /termlings/:key/input`, drained by `cove-relay.sh` on
  the origin and replayed into the real terminal via `kitten @ send-text`. Double
  gate: the sync+api_key surface AND the explicit opt-in.

## Known limitations

- Frames only advance when a terminal re-renders (i.e. when its content changes).
- The IOSurface transport + input socket are macOS-only; other platforms use the
  file-readback transport and `kitten` for input.
