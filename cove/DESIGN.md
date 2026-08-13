# Walking Terminals — kitty × Godot design doc

Codename: **menagerie**. Goal: real, live kitty terminals rendered as sprites
that walk around a Godot 2D scene. Each critter is an actual shell you can type
into (vim, htop, ssh — the real thing), not a fake.

Status: design / architecture. Nothing built yet. This doc is the plan we agree
on before writing code.

---

## 1. The one hard constraint that shapes everything

We investigated kitty's internals to see how much we can reuse. Three findings,
in order of how much they hurt:

1. **Kitty's C core is a CPython extension, not a standalone library.** The C
   code (`kitty/fast_data_types.so`) is `PyObject*` all the way down, driven by
   the Python `Boss` via the `call_boss(...)` macro (`kitty/state.h:656`). There
   is no independent C main loop — Python drives everything. So the tempting
   idea "compile kitty's core into a `.a` and link it into a Godot GDExtension"
   is a multi-month rewrite. **We reject it.**

2. **But kitty already renders to offscreen textures.** It has per-OS-window
   FBOs (`indirect_output` in `kitty/state.h:514`), a full render-to-texture
   path for custom shaders (`start_os_window_rendering()` in
   `kitty/shaders.c:2242`), and a *single choke point* for where drawing goes:
   `bind_framebuffer_for_output()` (`kitty/gl.c:110`). Redirecting a terminal's
   pixels to a texture we control is a **small, surgical hack**, not a rewrite.

3. **PTY and input are already decoupled from GLFW.** Shells are spawned and
   poll()-multiplexed in `child-monitor.c` (`io_loop()` at line 1771),
   independent of any window. Input bottoms out at `write_to_child()` /
   `schedule_write_to_child()` (`child-monitor.c:386`) — GLFW is just one caller.
   We can inject input from Godot into the same path.

**Conclusion: don't turn kitty into a library. Keep kitty as its own process,
hacked lightly, and let it render each terminal into a shared GPU texture that
Godot composites.** Two processes, one shared surface per terminal, a thin
control channel between them.

This inverts the naive "embed real kitty windows" mental model (reparent OS
windows — only works on Linux/X11, hopeless on macOS). Instead we embed kitty's
*pixels and I/O*, which is both more portable and gives Godot full control over
transform, z-order, animation, and physics.

---

## 2. Architecture at a glance

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  kitty (hacked, headless-ish)│         │  Godot 4.5 (the game/host)   │
│                              │         │                              │
│  Boss (python)               │         │  Main scene (2D)             │
│   ├─ Terminal 0 ─ Screen ────┼──tex0──▶│   ├─ TermCritter0 (Node2D)   │
│   │    └─ PTY (real shell)   │         │   │    Sprite2D ⟵ tex0       │
│   ├─ Terminal 1 ─ Screen ────┼──tex1──▶│   ├─ TermCritter1  walks…    │
│   │    └─ PTY (real shell)   │         │   ├─ …                        │
│   └─ …                       │◀─input──┤   └─ InputRouter (focus)     │
│                              │◀─ctrl───┤                              │
│  render loop → per-term FBO  │──meta──▶│  spawns / kills / resizes    │
└─────────────────────────────┘         └──────────────────────────────┘
        GL renders into                       Metal samples the same
        an IOSurface-backed texture           IOSurface (zero copy)
```

Four channels between the processes:

| Channel   | Direction      | Carries                                        | Transport                          |
|-----------|----------------|------------------------------------------------|------------------------------------|
| **frame** | kitty → Godot  | rendered pixels of each terminal               | IOSurface (zero-copy) or shm copy  |
| **meta**  | kitty → Godot  | terminal list, sizes, cursor, title, dirty flag| unix socket, JSON/msgpack          |
| **input** | Godot → kitty  | key + mouse events for the focused terminal    | unix socket                        |
| **ctrl**  | Godot → kitty  | spawn / kill / resize (cols×rows) a terminal   | unix socket (reuse remote-control) |

meta + input + ctrl are all low-bandwidth and can share **one unix socket** with
a tiny framed protocol. Only **frame** needs to be fast/GPU.

---

## 3. Process model — why two processes

Could we run everything in one process (Godot loads a GDExtension that boots
CPython + kitty)? Technically possible, genuinely cursed: two GL/Metal contexts,
two event loops, CPython embedded in the engine, GIL vs. Godot threads. Not
worth it.

Two processes is cleaner and matches how kitty already thinks (it has a
remote-control protocol over a socket, `kitty/remote_control.py`). Godot is the
**parent/host**: it launches the hacked kitty as a child, hands it the socket
path and (later) receives IOSurface handles back. If kitty dies, Godot respawns
it; if Godot dies, kitty exits.

---

## 4. The frame channel — two phases, de-risk then optimize

This is the only genuinely hard part, so we stage it.

### Phase A (MVP): pixel readback + shared memory copy

- In kitty, after rendering a terminal into its own FBO, `glReadPixels` the RGBA
  into a shared-memory ring (one slab per terminal, POSIX `shm_open`).
- Godot reads the slab each frame and calls `ImageTexture.update()` (or
  `Image.set_data` → texture). **Pure GDScript on the Godot side, works on any
  renderer, any OS.**
- Cost: one GPU→CPU readback + one CPU→GPU upload per terminal per frame. Fine
  for a handful of terminals at reasonable sizes; this is how we prove the whole
  loop (spawn shell → see live pixels walking around → type into it) end-to-end
  before touching the scary GPU-sharing code.

### Phase B (optimization): IOSurface zero-copy (macOS)

- kitty allocates an `IOSurface` per terminal and binds it as the FBO color
  attachment via `CGLTexImageIOSurface2D` — a *live* binding, so kitty just
  renders and the pixels are immediately visible to any other process that holds
  the surface (confirmed: Apple's cross-process FBO pattern).
- kitty sends the `IOSurfaceID` (mach port) to Godot over the control socket.
- A small **Godot GDExtension** wraps the IOSurface as an `MTLTexture`
  (`MTLDevice.makeTexture(descriptor:iosurface:plane:)`), registers it with the
  RenderingDevice, and exposes it as a `Texture2DRD` (Godot 4.5) that a Sprite2D
  samples. No per-frame copy at all.
- Requires a cross-process fence/semaphore so Godot doesn't sample a
  half-drawn frame (IOSurface sharing needs manual sync — Apple docs are
  explicit). A double-buffered pair of surfaces per terminal + a "ready" flag in
  the meta channel is enough.

Linux equivalent for later: `dmabuf` + `EGL_EXT_image_dma_buf_import`, or Vulkan
external memory. We design the frame channel behind an interface so the transport
is swappable; macOS/IOSurface is the first concrete backend.

---

## 5. Concrete kitty hack points

All grounded in the code we read. Roughly in build order.

### 5.1 Per-terminal offscreen render target
- Give each `Window` (pane) its own FBO + backing texture (mirror the existing
  `indirect_output` struct in `state.h:514`, but per-`Window` not per-`OSWindow`).
- In `render_prepared_os_window()` (`child-monitor.c:993`), the loop at
  `child-monitor.c:1008-1022` already calls `draw_cells(&WD, …)` once per visible
  window. Before each call, `bind_framebuffer_for_output(window->term_fbo)` and
  set the viewport to the terminal's own size; after, unbind. That's the core
  redirect — kitty already isolates per-window draws here.
- Backing texture is either a plain GL texture (Phase A) or IOSurface-backed
  (Phase B). Same code path; only allocation differs.

### 5.2 Headless-ish OS window
- We still create one GLFW window to own the GL context (`glfwCreateWindow` at
  `glfw.c:2074`) but keep it hidden/offscreen (`GLFW_VISIBLE=false`). Its default
  framebuffer is never presented; we never call `swap_window_buffers()`
  (`glfw.c:2767`) for real display. All real pixels go to per-terminal FBOs.
- This sidesteps decoupling the render loop from GLFW entirely (finding #1 says
  that's expensive) while producing no visible kitty window.

### 5.3 Layout override
- Normally kitty's layouts tile windows inside the OS window. We want N
  independent terminals of arbitrary size, positioned by Godot. Add a trivial
  "detached" layout (or bypass layout) so each `Window` renders at its own
  cols×rows into its own FBO, ignoring tiling geometry.

### 5.4 Input injection
- Add socket commands that call the existing input path: encode a key like
  `on_key_input()` (`keys.c:252`) does, then `schedule_write_to_child()`
  (`child-monitor.c:386`); mouse via the `Window.on_mouse_event()` path
  (`window.py`). Godot sends `{term_id, key, mods, action}`; kitty routes it to
  that terminal's Screen. GLFW callbacks stay as-is but are unused (window
  hidden).

### 5.5 Control commands (spawn/kill/resize)
- Reuse the Boss + remote-control machinery (`remote_control.py`,
  `boss.add_os_window`/tab/window). "spawn a terminal" = create a Window +
  Child in the hidden OS window; "resize" = set cols×rows and reallocate its FBO;
  "kill" = close the Window. Emit a meta event so Godot learns the new term_id +
  surface handle.

### 5.6 Meta/dirty signalling
- Kitty already tracks damage per Screen. Push a compact per-frame meta message:
  `{term_id, cols, rows, px_w, px_h, cursor, title, frame_seq}` only when a
  terminal changed, so Godot re-samples only dirty critters.

None of these touch the VT parser, font rendering, or the graphics protocol —
those keep working unmodified, which is the whole point of hacking kitty rather
than reimplementing a terminal.

---

## 6. Godot side

- **`TermCritter` (Node2D)**: holds `term_id`, a `Sprite2D` whose texture is the
  terminal's surface (ImageTexture in Phase A, Texture2DRD in Phase B), plus
  whatever makes it "walk" — an `AnimationPlayer`/tween, or a
  `CharacterBody2D` with a wander behavior, or physics. Godot owns *all* motion;
  kitty knows nothing about position.
- **`Menagerie` (autoload)**: owns the unix socket to kitty, spawns the kitty
  child process, maintains the `term_id → TermCritter` map, handles spawn/kill/
  resize, routes meta updates.
- **`InputRouter`**: decides which critter is "focused" (click, proximity,
  whatever the game wants), forwards keyboard to that term_id over the socket,
  translates mouse-in-sprite coordinates to terminal cell coords for mouse
  reporting.
- **Resize policy**: a terminal's pixel size is `cols*cell_w × rows*cell_h`. If a
  critter scales in the scene, we either (a) just scale the sprite (cheap, blurry
  when big) or (b) tell kitty to re-cols/rows (crisp, triggers reflow). Start
  with (a); expose (b) via the resize control command.

---

## 7. Coordinate & focus model

- kitty renders each terminal at native cell resolution → crisp texture.
- Godot places/scales/rotates the sprite freely. Rotation & squash are free
  eye-candy since it's just a textured quad.
- Mouse: Godot hit-tests the sprite, converts local UV → (col,row), sends to
  kitty as a mouse event so programs using mouse mode (vim, tmux) work.
- Focus is a game concept Godot owns; only the focused terminal gets keys, but
  all terminals keep running and updating (they're real shells on real PTYs).

---

## 8. Phased delivery plan

- **Phase 0 — skateboard.** Hidden-window kitty + one terminal rendered to one
  FBO, `glReadPixels` → shm, a standalone Godot scene showing that texture on a
  Sprite2D that bounces around. Type into it via socket-forwarded keys. Proves
  the entire loop with the dumb transport. *This is the first milestone to
  build.*
- **Phase 1 — many critters.** N terminals, spawn/kill/resize over the socket,
  focus routing, mouse. Still shm copy.
- **Phase 2 — zero-copy.** IOSurface backend + Godot GDExtension + Texture2DRD +
  cross-process sync. Drop the readback. Measure.
- **Phase 3 — game feel.** Wander AI, collisions, titles as nameplates,
  spawn/despawn animations, "the shell exited" death animation, etc.
- **Phase 4 (optional) — Linux backend.** dmabuf transport behind the same
  frame-channel interface.

Each phase is independently demoable and doesn't block on the next.

---

## 9. Risks & open questions

- **Sync in Phase 2.** Sampling a half-rendered IOSurface = tearing/garbage.
  Mitigation: double-buffer per terminal + ready flag; only advance when kitty
  signals frame_seq complete. Known-solvable (browsers do exactly this).
- **kitty build churn.** We're editing kitty C; every change means a rebuild
  (`make`). Keep hacks isolated in as few files as possible and behind a compile
  flag / runtime `--menagerie` mode so upstream kitty still builds & runs normal.
- **Retina/scale.** macOS backing scale factor must match between the FBO size
  kitty renders and the surface Godot samples, or text is soft. Pin DPR
  explicitly in the meta message.
- **Perf ceiling Phase A.** Readback is the bottleneck; fine for a demo (say
  ≤8 terminals), not for a swarm. That's precisely why Phase 2 exists.
- **Godot renderer choice.** Phase A works on any renderer (Compatibility/Mobile/
  Forward+). Phase B ties us to the Metal RenderingDevice path on macOS. Decide
  before Phase 2; Phase 0/1 stay renderer-agnostic.
- **How "walking" should behave** — pure aesthetic wander, or gameplay (collide,
  get grabbed, stacked)? Doesn't affect the plumbing; deferred to Phase 3.

---

## 10. Repo layout (no submodule — lives in this repo)

```
godot/
  DESIGN.md            ← this file
  project.godot        ← the Godot project (Phase 0+)
  scenes/              ← TermCritter, Menagerie, demo scene
  scripts/             ← GDScript
  gdext/               ← GDExtension for IOSurface→Texture2DRD (Phase 2)
  README.md            ← how to build hacked kitty + run the Godot project
kitty/                 ← existing kitty C; menagerie hacks land here behind a flag
```

kitty hacks stay in the existing tree behind a `--menagerie` runtime mode +
minimal `#ifdef`/flag so normal kitty is unaffected and upstream stays mergeable.

---

## 11. What we're NOT doing (and why)

- **Not** extracting kitty's C core into a standalone lib (CPython-entangled —
  finding #1).
- **Not** reparenting real OS windows into Godot (Linux/X11-only, dead on macOS).
- **Not** reimplementing a terminal in Godot (the entire point is *real* kitty:
  its VT parser, fonts, ligatures, graphics protocol, all free).
```
