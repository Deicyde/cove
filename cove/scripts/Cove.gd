# Walking Terminals -- Godot host. See godot/DESIGN.md.
#
# A top-down 2.5D stage: each live terminal (published by hacked kitty) is hauled
# around by two little carriers (Sarah) on a ground panel, with soft shadows.
#   - the groups wander freely
#   - click a terminal to focus it, then type (keyboard -> focused shell)
#   - press-drag a terminal to LIFT it off the ground: it rises to the cursor,
#     its shadow shrinks, and the carriers panic; release to drop it (they recover)
#   - Cmd/Ctrl+N spawns another terminal
extends Node2D

const CarryGroup := preload("res://scripts/CarryGroup.gd")
const GroundGrid := preload("res://scripts/GroundGrid.gd")
const DIR := "/tmp/cove"

var kitten_exe := ""
var kitty_socket := ""

var _world: Node2D
var _bounds := Rect2(0, 0, 1280, 800)
var _groups := {}            # term_id:int -> CarryGroup
var _focused_id := -1
var _rescan_accum := 0.0

# Ctrl+` focus cycling. The order is frozen (by proximity to the focused
# terminal) on the *first* press of a run of chords, so repeated taps walk a
# stable ring of nearby termlings; any other input ends the run.
var _cycle_order: Array = []
var _cycle_idx := 0
var _cycle_active := false

# camera / interaction
var _cam: Camera2D
var _panning := false
var _gesture_accum := 0.0     # trackpad pan-gesture steps accumulated for resize
var _scroll_accum := 0.0      # trackpad pan-gesture steps accumulated for terminal scroll
var _tracking_id := -1       # term id the camera is following (double-click), or -1
var _press_group: Node2D = null
var _press_pos := Vector2.ZERO
var _lifting := false
const LIFT_THRESHOLD := 10.0
const MIN_ZOOM := 0.35
const MAX_ZOOM := 3.0

# input transport
var _sock: RefCounted = null
var _input_tries := 0

# agent state / control channel / notifications
var _ls_thread: Thread
var _ls_mutex: Mutex
var _ls_data := {}            # pane_id -> {agent, busy, attention, cwd}
var _ls_run := true
var _state_accum := 0.0
var _cmd_accum := 0.0
var _follows := {}           # follower term_id -> target term_id
var _notes := []             # [{project, event, term_id, ts}]
var _panel_vbox: VBoxContainer
var _agents := {}            # main-thread copy of _ls_data
var _attn_ids := {}          # term_id -> true (needs attention)
var _pan_once := -1          # term id to pan the camera to once (input required)
var _names := {}             # term_id -> custom name (persists across re-spawn)
var _saved := {}             # layout restored from the previous run's state.json

# rename dialog
var _rename_panel: PanelContainer
var _rename_edit: LineEdit
var _rename_id := -1

# proof mode
var _shot_path := ""
var _frames := 0


func _ready() -> void:
	_set_window_icon()   # cove pirate-map icon on the window + macOS dock
	kitten_exe = OS.get_environment("COVE_KITTEN")
	kitty_socket = OS.get_environment("COVE_KITTY_SOCKET")
	_shot_path = OS.get_environment("COVE_SHOT")
	if ClassDB.class_exists("CoveInput"):
		_sock = ClassDB.instantiate("CoveInput")
		_try_connect_sock()
		print("cove: fast input via CoveInput extension")
	else:
		push_warning("cove: CoveInput extension not loaded — input falls back to `kitten @ send` (slow). Check cove.gdextension / rebuild gdext.")
	_load_layout()   # restore positions/names/camera from the previous run
	_build_world()
	_build_ui()
	_reconcile()
	_restore_after_reconcile()
	_start_ls_poll()


func _set_window_icon() -> void:
	# The project.godot icon covers the launcher/export; this also swaps the
	# live window + dock icon at runtime (Godot's default otherwise wins there).
	var tex := load("res://branding/cove-icon-256.png") as Texture2D
	if tex:
		DisplayServer.set_icon(tex.get_image())


func _exit_tree() -> void:
	_ls_run = false
	if _ls_thread and _ls_thread.is_started():
		_ls_thread.wait_to_finish()


func _build_world() -> void:
	_bounds = Rect2(-1600, -1100, 3200, 2200)  # a big roamable ground

	# Camera we pan/zoom. (The checkerboard ground fills the whole view, so no
	# separate background is needed -- the view just shows more as you resize.)
	_cam = Camera2D.new()
	_cam.position = Vector2(_bounds.get_center().x, _bounds.get_center().y)
	_cam.zoom = Vector2(0.9, 0.9)
	if _saved.has("cam"):
		var c = _saved["cam"]
		_cam.position = Vector2(c[0], c[1])
		_cam.zoom = Vector2(c[2], c[2])
	add_child(_cam)
	_cam.make_current()

	# Infinite grid (world space, follows the camera).
	var ground := GroundGrid.new()
	ground.camera = _cam
	ground.z_index = -50
	add_child(ground)

	_world = Node2D.new()
	_world.y_sort_enabled = true
	add_child(_world)


func _process(delta: float) -> void:
	_rescan_accum += delta
	if _rescan_accum > 0.4:
		_rescan_accum = 0.0
		_reconcile()
	if _sock != null and not _sock.call("is_connected") and _input_tries < 100:
		_try_connect_sock()
	_apply_agent_state()
	_apply_follows()
	_pump_commands(delta)
	_pump_notify()
	_state_accum += delta
	if _state_accum > 0.2:
		_state_accum = 0.0
		_write_state()
	# Camera follows the tracked terminal (double-click to start). Track the
	# terminal's centre, not the group's ground point (which sits well below it).
	if _tracking_id != -1 and _groups.has(_tracking_id):
		_cam.position = _cam.position.lerp(_groups[_tracking_id].terminal.global_position, 6.0 * delta)
	_frames += 1
	if _shot_path != "" and _frames == 320:
		var img := get_viewport().get_texture().get_image()
		img.save_png(_shot_path)
		print("cove: saved proof screenshot to ", _shot_path)
		get_tree().quit()


# --- terminal discovery -----------------------------------------------------

func _reconcile() -> void:
	var present := {}
	var dir := DirAccess.open(DIR)
	if dir:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if fn.begins_with("term-") and fn.ends_with(".rgba"):
				var id := int(fn.substr(5, fn.length() - 10))
				present[id] = true
				if not _groups.has(id):
					_add_group(id)
			fn = dir.get_next()
		dir.list_dir_end()
	for id in _groups.keys():
		if not present.has(id):
			_remove_group(id)


func _add_group(id: int) -> void:
	var g := CarryGroup.new()
	if _saved.get("pos", {}).has(id):
		# Restore where it was on the previous run (hot-reload keeps positions).
		var p = _saved["pos"][id]
		g.position = Vector2(p[0], p[1])
	else:
		# Spawn near the camera so new terminals appear in view, then they wander off.
		var center := _cam.position if _cam else Vector2.ZERO
		var n := _groups.size()
		g.position = center + Vector2(cos(n * 2.4) * (150.0 + 55.0 * n), sin(n * 2.4) * (120.0 + 45.0 * n))
	_world.add_child(g)
	g.setup(id, "%s/term-%d.rgba" % [DIR, id], _bounds)
	if _names.has(id):
		g.terminal.set_custom_name(_names[id])
	_groups[id] = g
	if _focused_id == -1:
		_set_focus(id)


func _remove_group(id: int) -> void:
	if _groups.has(id):
		_groups[id].queue_free()
		_groups.erase(id)
	if _focused_id == id:
		_focused_id = -1
		for other in _groups:
			_set_focus(other)
			break


func _set_focus(id: int) -> void:
	_focused_id = id
	for oid in _groups:
		_groups[oid].terminal.set_focused(oid == id)
	# Attending to a terminal clears its "needs you" note.
	var kept := []
	var changed := false
	for n in _notes:
		if n.get("term_id", -2) == id:
			changed = true
		else:
			kept.append(n)
	if changed:
		_notes = kept
		_update_panel()


func _group_at(world_pos: Vector2) -> Node2D:
	var best: Node2D = null
	for id in _groups:
		var g: Node2D = _groups[id]
		if g.terminal.contains_point(world_pos):
			if best == null or g.position.y > best.position.y:
				best = g
	return best


func _is_modifier_key(kc: int) -> bool:
	return kc in [KEY_META, KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_CAPSLOCK]


# Cycle focus to the next nearby terminal. On the first press of a run the ring
# is frozen: terminals sorted by distance to the currently focused one (itself
# first), so taps march outward through the neighbours. Subsequent taps just
# advance the index; the run ends when any other input arrives.
func _cycle_focus() -> void:
	if _groups.size() <= 1:
		return
	if not _cycle_active or _cycle_order.size() != _groups.size():
		_cycle_order = _order_by_proximity(_focused_id)
		_cycle_idx = maxi(_cycle_order.find(_focused_id), 0)
		_cycle_active = true
	# Advance to the next still-present terminal in the frozen ring.
	for _i in _cycle_order.size():
		_cycle_idx = (_cycle_idx + 1) % _cycle_order.size()
		var target: int = _cycle_order[_cycle_idx]
		if _groups.has(target):
			_set_focus(target)
			if _tracking_id != -1:
				_tracking_id = target   # keep the camera glued if we were following
			else:
				_pan_once = target      # otherwise glide the view over to it
			return


func _order_by_proximity(from_id: int) -> Array:
	var origin := _cam.position if _cam else Vector2.ZERO
	if _groups.has(from_id):
		origin = _groups[from_id].get_ground_pos()
	var ids: Array = _groups.keys()
	ids.sort_custom(func(a, b):
		return _groups[a].get_ground_pos().distance_squared_to(origin) \
			< _groups[b].get_ground_pos().distance_squared_to(origin))
	return ids


# --- input ------------------------------------------------------------------

# Catch the spawn chord early (macOS can swallow Cmd-chords before they reach
# _unhandled_input). Accept Cmd+N or Ctrl+N.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# While the rename dialog is open, Esc cancels it and other keys go to it.
	if _rename_id != -1:
		if event.keycode == KEY_ESCAPE:
			_close_rename()
			get_viewport().set_input_as_handled()
		return
	# Ctrl+` (optionally with Shift) -> focus the next nearby terminal. We use
	# Ctrl, not Cmd: macOS reserves Cmd+` for its own "cycle windows of the app"
	# shortcut and swallows/mangles the event before Godot gets a usable one.
	var is_backtick: bool = (event.keycode == KEY_QUOTELEFT or event.physical_keycode == KEY_QUOTELEFT)
	if is_backtick and event.ctrl_pressed:
		_cycle_focus()
		get_viewport().set_input_as_handled()
		return
	# Any other real keypress (not a bare modifier) ends the cycle run, so the
	# next chord re-freezes a fresh proximity order.
	if not _is_modifier_key(event.keycode):
		_cycle_active = false
	if event.keycode == KEY_N and (event.meta_pressed or event.ctrl_pressed):
		_spawn_terminal()
		get_viewport().set_input_as_handled()


func _world_mouse() -> Vector2:
	return get_global_mouse_position()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed:
			_cycle_active = false   # any click ends a focus-cycle run
		var wpos := _world_mouse()
		# Wheel over a terminal: plain scroll goes *into* the terminal; Cmd/Ctrl+
		# scroll resizes it. Over empty ground: zoom the camera.
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var up: bool = event.button_index == MOUSE_BUTTON_WHEEL_UP
			var g := _group_at(wpos)
			if g == null:
				_zoom_at(event.position, 1 if up else -1)
			elif event.meta_pressed or event.ctrl_pressed:
				_resize_group(g, 1 if up else -1)
			else:
				_scroll_terminal(g, up, 3)
			return
		# Right button: rename the terminal under the cursor.
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			var g := _group_at(wpos)
			if g != null:
				_open_rename(g)
			return
		# Middle button: pan.
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
			if event.pressed:
				_tracking_id = -1  # manual pan cancels camera follow
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_group = _group_at(wpos)
				_press_pos = event.position
				_lifting = false
				_panning = _press_group == null  # empty-space left-drag pans
				if _panning:
					_tracking_id = -1  # manual pan cancels camera follow
				if event.double_click and _press_group != null:
					_set_focus(_press_group.term_id)
					_tracking_id = _press_group.term_id  # double-click: focus + follow
			else:
				if _press_group != null and _lifting:
					_press_group.drop()
				elif _press_group != null:
					_set_focus(_press_group.term_id)
				_press_group = null
				_lifting = false
				_panning = false
	elif event is InputEventMouseMotion:
		if _press_group != null:
			if not _lifting and event.position.distance_to(_press_pos) > LIFT_THRESHOLD:
				_lifting = true
				_press_group.lift()
				_set_focus(_press_group.term_id)
			if _lifting:
				_press_group.set_lift_target(_world_mouse())
		elif _panning:
			_cam.position -= event.relative / _cam.zoom
	elif event is InputEventPanGesture:
		# macOS trackpad two-finger scroll. Over a terminal: plain scroll goes
		# into the terminal, Cmd/Ctrl+scroll resizes it (in cell steps). Over
		# empty ground: zoom the camera. Wheel events don't fire for trackpads,
		# so this is the only scroll path on macOS.
		var g := _group_at(_world_mouse())
		if g == null:
			_zoom_by(pow(1.08, -event.delta.y))
		elif event.meta_pressed or event.ctrl_pressed:
			_gesture_accum += event.delta.y
			while _gesture_accum >= 1.5:
				_resize_group(g, -1); _gesture_accum -= 1.5
			while _gesture_accum <= -1.5:
				_resize_group(g, 1); _gesture_accum += 1.5
		else:
			# delta.y > 0 = swipe content up = scroll down (wheel-down / newer).
			_scroll_accum += event.delta.y
			var n := int(_scroll_accum)
			if n != 0:
				_scroll_terminal(g, n < 0, absi(n))
				_scroll_accum -= n
	elif event is InputEventMagnifyGesture:
		# trackpad pinch (event.factor > 1 = fingers spreading = zoom in)
		_zoom_by(event.factor)
	elif event is InputEventKey and event.pressed:
		# Accept echo (OS auto-repeat) here so holding a key repeats into the
		# shell -- only the chord handling in _input() filters echoes out.
		_on_key(event)


# Zoom the camera toward the cursor by a multiplicative factor (>1 zooms in).
func _zoom_by(factor: float) -> void:
	var before := _cam.get_global_mouse_position()
	var z := clampf(_cam.zoom.x * factor, MIN_ZOOM, MAX_ZOOM)
	_cam.zoom = Vector2(z, z)
	var after := _cam.get_global_mouse_position()
	_cam.position += before - after  # keep the point under the cursor stable


func _zoom_at(_screen_pos: Vector2, dir: int) -> void:
	_zoom_by(1.12 if dir > 0 else 1.0 / 1.12)


func _on_key(event: InputEventKey) -> void:
	# Cmd/Ctrl+N is handled early in _input(); here we only route typing.
	if _focused_id == -1 or not _groups.has(_focused_id):
		return
	var pane: int = _groups[_focused_id].terminal.pane_id
	if pane == 0:
		return
	var bytes := _encode_key(event)
	if not bytes.is_empty():
		_pty(pane, bytes)
		get_viewport().set_input_as_handled()


func _encode_key(event: InputEventKey) -> PackedByteArray:
	var kc := event.keycode
	match kc:
		KEY_ENTER, KEY_KP_ENTER: return PackedByteArray([13])
		KEY_BACKSPACE: return PackedByteArray([127])
		KEY_TAB: return PackedByteArray([9])
		KEY_ESCAPE: return PackedByteArray([27])
		KEY_UP: return PackedByteArray([27, 91, 65])
		KEY_DOWN: return PackedByteArray([27, 91, 66])
		KEY_RIGHT: return PackedByteArray([27, 91, 67])
		KEY_LEFT: return PackedByteArray([27, 91, 68])
		KEY_HOME: return PackedByteArray([27, 91, 72])
		KEY_END: return PackedByteArray([27, 91, 70])
		KEY_PAGEUP: return PackedByteArray([27, 91, 53, 126])
		KEY_PAGEDOWN: return PackedByteArray([27, 91, 54, 126])
		KEY_DELETE: return PackedByteArray([27, 91, 51, 126])
	if event.meta_pressed:
		return PackedByteArray()
	if event.ctrl_pressed:
		if kc >= KEY_A and kc <= KEY_Z:
			return PackedByteArray([kc - KEY_A + 1])
		if kc == KEY_SPACE:
			return PackedByteArray([0])
		return PackedByteArray()
	if event.unicode != 0:
		var s := String.chr(event.unicode).to_utf8_buffer()
		if event.alt_pressed:
			var out := PackedByteArray([27])
			out.append_array(s)
			return out
		return s
	return PackedByteArray()


# --- pty write channel: persistent socket, else kitten fallback -------------

func _try_connect_sock() -> void:
	_input_tries += 1
	_sock.call("connect_to", "%s/input.sock" % DIR)


func _pty(pane: int, data: PackedByteArray) -> void:
	if data.is_empty():
		return
	if _sock != null and _sock.call("is_connected"):
		_sock.call("send_bytes", pane, data)
	elif kitten_exe != "":
		OS.create_process(kitten_exe, ["@", "--to", kitty_socket, "send-text",
			"--match", "id:%d" % pane, data.get_string_from_utf8()], false)


func _spawn_terminal() -> void:
	# Prefer the persistent socket (no kitten process -> much snappier).
	if _sock != null and _sock.call("is_connected"):
		_sock.call("spawn")
		return
	if kitten_exe == "":
		return
	var shell := OS.get_environment("SHELL")
	if shell == "":
		shell = "/bin/zsh"
	OS.create_process(kitten_exe, ["@", "--to", kitty_socket, "launch", "--type=os-window", shell], false)


# Reflow the terminal by changing its cols/rows (scroll to resize).
func _resize_group(g: Node2D, dir: int) -> void:
	var t = g.terminal
	if t.cols <= 0:
		return
	var nc := clampi(t.cols + dir * 8, 24, 400)
	var nr := clampi(t.rows + dir * 3, 6, 200)
	if nc == t.cols and nr == t.rows:
		return
	if _sock != null and _sock.call("is_connected"):
		_sock.call("send_resize", g.term_id, nc, nr)
	elif kitten_exe != "":
		OS.create_process(kitten_exe, ["@", "--to", kitty_socket, "resize-os-window",
			"--match", "id:%d" % t.pane_id, "--unit", "cells",
			"--width", str(nc), "--height", str(nr)], false)


# Send `lines` of scroll to a terminal. If the app is grabbing the mouse (vim,
# less, htop, most agent TUIs) forward wheel events over the fast pty socket so
# it scrolls its own view. Otherwise scroll kitty's scrollback buffer via remote
# control (slower, but this is the only path that moves shell history).
func _scroll_terminal(g: Node2D, up: bool, lines: int) -> void:
	var t = g.terminal
	var pane: int = t.pane_id
	if pane == 0 or lines <= 0:
		return
	if t.mouse_mode != 0:
		var wheel := _wheel_bytes(t, up)
		var out := PackedByteArray()
		for _i in mini(lines, 10):   # cap the burst a fast flick can emit
			out.append_array(wheel)
		_pty(pane, out)
	elif kitten_exe != "":
		# `<n>l` scrolls down, `<n>l-` scrolls up (toward older lines).
		var amount := "%dl%s" % [mini(lines, 10), "-" if up else ""]
		OS.create_process(kitten_exe, ["@", "--to", kitty_socket, "scroll-window",
			"--match", "id:%d" % pane, amount], false)


# One SGR (or X10-fallback) mouse-wheel event for the cell under the cursor.
# Wheel-up = button 64, wheel-down = 65.
func _wheel_bytes(t, up: bool) -> PackedByteArray:
	var cell: Vector2i = t.cell_at(_world_mouse())
	var col := cell.x + 1   # SGR/X10 are 1-based
	var row := cell.y + 1
	var btn := 64 if up else 65
	var esc := char(27)
	if t.mouse_proto == 2 or t.mouse_proto == 4:   # SGR / SGR-pixel
		return ("%s[<%d;%d;%dM" % [esc, btn, col, row]).to_utf8_buffer()
	# X10: ESC [ M  <btn+32> <col+32> <row+32>  (clamped to the legacy range)
	return PackedByteArray([27, 91, 77,
		mini(btn + 32, 255), mini(col + 32, 255), mini(row + 32, 255)])


# ============================================================================
# Agent state (poll `kitten @ ls`), control channel (state.json / commands.jsonl),
# notifications (notify.jsonl) and the themed notification panel.
# ============================================================================

func _find(id: int) -> Node2D:
	if _groups.has(id):
		return _groups[id]
	for gid in _groups:  # allow addressing by kitty pane id too
		if _groups[gid].terminal.pane_id == id:
			return _groups[gid]
	return null


# --- layout persistence (hot-reload keeps positions/names/camera) -----------

func _load_layout() -> void:
	# The previous run's state.json is our restore source (kitty keeps running,
	# so the terminals + shells are still alive; we just re-place them).
	var path := DIR + "/state.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return
	var pos := {}
	var follows := {}
	for t in d.get("terminals", []):
		var id := int(t.get("id", -1))
		if id == -1:
			continue
		pos[id] = t.get("pos", [0, 0])
		if str(t.get("name", "")) != "":
			_names[id] = str(t["name"])
		if t.get("following", null) != null:
			follows[id] = int(t["following"])
	_saved = {"pos": pos, "cam": d.get("camera", null), "follows": follows, "focused": int(d.get("focused", -1))}
	if _saved["cam"] == null:
		_saved.erase("cam")


func _restore_after_reconcile() -> void:
	for fid in _saved.get("follows", {}):
		if _groups.has(fid):
			_follows[fid] = _saved["follows"][fid]
	var foc := int(_saved.get("focused", -1))
	if foc != -1 and _groups.has(foc):
		_set_focus(foc)


# --- kitty ls polling (background thread) -----------------------------------

func _start_ls_poll() -> void:
	if kitten_exe == "" or kitty_socket == "":
		return
	_ls_mutex = Mutex.new()
	_ls_thread = Thread.new()
	_ls_thread.start(_ls_loop)


func _ls_loop() -> void:
	while _ls_run:
		var out := []
		OS.execute(kitten_exe, ["@", "--to", kitty_socket, "ls"], out, false)
		var txt: String = out[0] if out.size() > 0 else ""
		var data := _parse_ls(txt)
		_ls_mutex.lock()
		_ls_data = data
		_ls_mutex.unlock()
		OS.delay_msec(1000)


func _detect_agent(procs) -> String:
	for p in procs:
		var cl := " ".join(p.get("cmdline", [])).to_lower()
		if cl.contains("opencode"): return "opencode"
		if cl.contains("codex"): return "codex"
		if cl.contains("claude"): return "claude"
	return "shell"


func _parse_ls(txt: String) -> Dictionary:
	var arr = JSON.parse_string(txt)
	var res := {}
	if typeof(arr) != TYPE_ARRAY:
		return res
	for osw in arr:
		for tab in osw.get("tabs", []):
			for w in tab.get("windows", []):
				var pane := int(w.get("id", 0))
				var agent := _detect_agent(w.get("foreground_processes", []))
				res[pane] = {
					"agent": agent,
					"busy": agent != "shell",
					"attention": bool(w.get("needs_attention", false)),
					"cwd": str(w.get("cwd", "")),
				}
	return res


# --- apply agent state + attention to groups --------------------------------

func _apply_agent_state() -> void:
	if _ls_mutex:
		_ls_mutex.lock()
		_agents = _ls_data.duplicate(true)
		_ls_mutex.unlock()
	# recompute attention set: kitty needs_attention OR a pending note
	_attn_ids.clear()
	for note in _notes:
		if note.get("term_id", -1) != -1:
			_attn_ids[note["term_id"]] = true
	for id in _groups:
		var g = _groups[id]
		var info = _agents.get(g.terminal.pane_id, {})
		g.set_agent(info.get("agent", "shell"), info.get("busy", false))
		if info.get("attention", false):
			_attn_ids[id] = true
		g.set_attention(_attn_ids.has(id))
	# one-shot camera pan to a terminal that needs input (only if not following)
	if _pan_once != -1 and _tracking_id == -1 and _groups.has(_pan_once):
		var tp: Vector2 = _groups[_pan_once].terminal.global_position
		_cam.position = _cam.position.lerp(tp, 5.0 * get_process_delta_time())
		if _cam.position.distance_to(tp) < 24.0:
			_pan_once = -1


func _apply_follows() -> void:
	for fid in _follows.keys():
		var target_id: int = _follows[fid]
		if not _groups.has(fid) or not _groups.has(target_id):
			_follows.erase(fid)
			if _groups.has(fid):
				_groups[fid].command_stop()
			continue
		var t = _groups[target_id]
		var offset := Vector2(t.terminal.onscreen_size().x * 0.6 + 170.0, 0)
		_groups[fid].command_move(t.get_ground_pos() + offset)


# --- control channel --------------------------------------------------------

func _pump_commands(delta: float) -> void:
	_cmd_accum += delta
	if _cmd_accum < 0.1:
		return
	_cmd_accum = 0.0
	var path := DIR + "/commands.jsonl"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var content := f.get_as_text()
	f.close()
	if content.strip_edges() == "":
		return
	var w := FileAccess.open(path, FileAccess.WRITE)  # consume
	if w:
		w.store_string("")
		w.close()
	for line in content.split("\n", false):
		var c = JSON.parse_string(line)
		if typeof(c) == TYPE_DICTIONARY:
			_exec_command(c)


func _exec_command(c: Dictionary) -> void:
	match str(c.get("cmd", "")):
		"move":
			var g := _find(int(c.get("id", -1)))
			if g and c.has("to"):
				g.command_move(Vector2(float(c["to"][0]), float(c["to"][1])))
				_follows.erase(g.term_id)
		"follow":
			var g := _find(int(c.get("id", -1)))
			var t := _find(int(c.get("target", -1)))
			if g and t:
				_follows[g.term_id] = t.term_id
		"stop":
			var g := _find(int(c.get("id", -1)))
			if g:
				g.command_stop()
				_follows.erase(g.term_id)
		"focus":
			var g := _find(int(c.get("id", -1)))
			if g:
				_set_focus(g.term_id)
				_tracking_id = g.term_id
		"rename":
			var g := _find(int(c.get("id", -1)))
			if g:
				var nm := str(c.get("name", ""))
				_names[g.term_id] = nm
				g.terminal.set_custom_name(nm)
		"gather":
			var i := 0
			for id in _groups:
				_groups[id].command_move(_cam.position + Vector2(cos(i * 2.4), sin(i * 2.4)) * (60 + 90 * i))
				i += 1
		"scatter", "release":
			for id in _groups:
				_groups[id].command_stop()
			_follows.clear()
		"dismiss":
			var tid := int(c.get("id", -1))
			var kept := []
			for n in _notes:
				if n.get("term_id", -2) != tid:
					kept.append(n)
			_notes = kept
			_update_panel()


# --- state.json (world -> agents) -------------------------------------------

func _write_state() -> void:
	var terms := []
	for id in _groups:
		var g = _groups[id]
		var info = _agents.get(g.terminal.pane_id, {})
		terms.append({
			"id": id,
			"pane_id": g.terminal.pane_id,
			"name": g.terminal.custom_name,
			"pos": [snappedf(g.position.x, 0.1), snappedf(g.position.y, 0.1)],
			"cols": g.terminal.cols,
			"rows": g.terminal.rows,
			"agent": info.get("agent", "shell"),
			"busy": info.get("busy", false),
			"attention": _attn_ids.has(id),
			"following": _follows.get(id, null),
			"cwd": info.get("cwd", ""),
		})
	var st := {
		"terminals": terms,
		"camera": [snappedf(_cam.position.x, 0.1), snappedf(_cam.position.y, 0.1), _cam.zoom.x],
		"focused": _focused_id,
	}
	var f := FileAccess.open(DIR + "/state.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(st))
		f.close()


# --- notifications (hooks -> notify.jsonl -> panel + camera) -----------------

func _find_by_cwd(cwd: String) -> Node2D:
	if cwd == "":
		return null
	for id in _groups:
		var info = _agents.get(_groups[id].terminal.pane_id, {})
		if str(info.get("cwd", "")) == cwd:
			return _groups[id]
	return null


func _pump_notify() -> void:
	var path := DIR + "/notify.jsonl"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var content := f.get_as_text()
	f.close()
	if content.strip_edges() == "":
		return
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w:
		w.store_string("")
		w.close()
	var got := false
	for line in content.split("\n", false):
		var n = JSON.parse_string(line)
		if typeof(n) != TYPE_DICTIONARY:
			continue
		# Map by kitty pane id (KITTY_WINDOW_ID) -> cove terminal. Skip events
		# from agents that aren't in a cove terminal.
		var g := _find(int(n.get("pane", -1)))
		if g == null:
			continue
		got = true
		# de-dupe: one live note per terminal
		var kept := []
		for existing in _notes:
			if existing.get("term_id", -2) != g.term_id:
				kept.append(existing)
		_notes = kept
		_notes.push_front({"project": str(n.get("project", "")), "event": str(n.get("event", "")), "term_id": g.term_id, "ts": int(n.get("ts", 0))})
		if _notes.size() > 8:
			_notes.resize(8)
		if _tracking_id == -1:
			_pan_once = g.term_id  # move the camera over to the terminal that wants input
	if got:
		_update_panel()


# --- themed notification / todo panel ---------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -320
	panel.offset_top = 16
	panel.offset_right = -16
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.10, 0.09, 0.92)
	sb.border_color = Color(0.45, 0.85, 1.0, 0.5)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)

	_panel_vbox = VBoxContainer.new()
	_panel_vbox.add_theme_constant_override("separation", 6)
	panel.add_child(_panel_vbox)

	var title := Label.new()
	title.text = "⚓ crew wants you"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(0.9, 0.8, 0.55))
	_panel_vbox.add_child(title)
	_update_panel()
	_build_rename_dialog()


func _themed_box(border := Color(0.45, 0.85, 1.0, 0.6)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.10, 0.09, 0.97)
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	return sb


func _build_rename_dialog() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	_rename_panel = PanelContainer.new()
	_rename_panel.add_theme_stylebox_override("panel", _themed_box())
	_rename_panel.visible = false
	center.add_child(_rename_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	_rename_panel.add_child(vb)

	var title := Label.new()
	title.text = "🐚 name this termling"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.9, 0.8, 0.55))
	vb.add_child(title)

	_rename_edit = LineEdit.new()
	_rename_edit.custom_minimum_size = Vector2(280, 0)
	_rename_edit.placeholder_text = "e.g. build · logs · notes"
	_rename_edit.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98))
	_rename_edit.text_submitted.connect(func(_t): _apply_rename())
	vb.add_child(_rename_edit)

	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END
	hb.add_theme_constant_override("separation", 8)
	vb.add_child(hb)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(_close_rename)
	hb.add_child(cancel)
	var ok := Button.new()
	ok.text = "Rename"
	ok.pressed.connect(_apply_rename)
	hb.add_child(ok)


func _open_rename(g: Node2D) -> void:
	if _rename_panel == null:
		return
	_rename_id = g.term_id
	_rename_edit.text = g.terminal.custom_name
	_rename_panel.visible = true
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func _apply_rename() -> void:
	if _rename_id != -1:
		var nm := _rename_edit.text.strip_edges()
		_names[_rename_id] = nm
		if _groups.has(_rename_id):
			_groups[_rename_id].terminal.set_custom_name(nm)
	_close_rename()


func _close_rename() -> void:
	if _rename_panel:
		_rename_panel.visible = false
	_rename_id = -1


func _update_panel() -> void:
	if _panel_vbox == null:
		return
	# clear rows (keep the title at index 0)
	while _panel_vbox.get_child_count() > 1:
		var c := _panel_vbox.get_child(1)
		_panel_vbox.remove_child(c)
		c.queue_free()
	if _notes.is_empty():
		var empty := Label.new()
		empty.text = "all quiet…"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.6, 0.62, 0.66))
		_panel_vbox.add_child(empty)
		return
	for n in _notes:
		var row := Label.new()
		var tid: int = n.get("term_id", -1)
		var who: String = str(n.get("project", ""))
		if tid != -1:
			who = "termling %d" % tid
			if _groups.has(tid) and _groups[tid].terminal.custom_name != "":
				who = _groups[tid].terminal.custom_name
		row.text = "• %s — needs you" % who
		row.add_theme_font_size_override("font_size", 13)
		row.add_theme_color_override("font_color", Color(0.92, 0.9, 0.85))
		_panel_vbox.add_child(row)
