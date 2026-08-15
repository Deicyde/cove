# Walking Terminals -- Godot host. See godot/DESIGN.md.
#
# A top-down 2.5D stage: each live terminal (published by hacked kitty) is hauled
# around by two little carriers (Sarah) on a ground panel, with soft shadows.
#   - the groups wander freely
#   - click a terminal to focus it, then type (keyboard -> focused shell)
#   - press-drag a terminal to slide it around the ground (double-click to
#     track+read one, and a drag then selects its text instead)
#   - drag a termling off the window edge to hand it to another Mac (Universal
#     Control carries it); hold Alt to relocate it freely, even off-screen,
#     without sending
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
var _occ_fading := false     # occluder fade is active (fading termlings in front of the tracked one)
var _press_group: Node2D = null
var _press_pos := Vector2.ZERO
var _press_world := Vector2.ZERO
var _lifting := false
var _moving := false           # this drag repositions the termling on the ground
var _move_can_send := false    # a plain (non-Alt) drag may fling to the edge; Alt-drag just relocates
var _move_grab := Vector2.ZERO # cursor->ground offset so the grabbed point stays under the mouse
# Drag-select on the focused terminal: text selection instead of lifting it.
var _selecting := false        # this press should select, not lift
var _sel_started := false      # the selection has actually begun (dragged past the deadzone)
const LIFT_THRESHOLD := 10.0
const SELECT_DEADZONE := 3.0
const MIN_ZOOM := 0.35
const MAX_ZOOM := 3.0
const TRACK_DIM := 0.18       # alpha for termlings occluding the tracked one

# input transport
var _sock: RefCounted = null
var _input_tries := 0

# cross-Mac termling handoff (native OS drag over Universal Control)
var _drag: RefCounted = null   # CoveDrag extension
var _inflight_id := -1         # term_id currently being dragged out (dimmed), or -1
var _ghost: Label = null       # landing ghost shown while an inbound drag hovers
const HANDOFF_EDGE_PX := 26.0  # drag a lifted termling this close to a window edge to fling it

# agent state / control channel / notifications
var _ls_thread: Thread
var _ls_mutex: Mutex
var _ls_data := {}            # pane_id -> {agent, busy, attention, cwd}
var _ls_run := true
var _state_accum := 0.0
var _cmd_accum := 0.0
var _follows := {}           # follower term_id -> target term_id
# Zones: named regions on the ground. Termlings auto-cluster by project (git-repo
# / cwd) so "who's working on what" reads as location. Drag one into a region to
# override; scatter clears everything.
var _zones := {}             # name -> {slot:int, color:[r,g,b]}
var _zone_of := {}           # term_id -> current zone name (derived)
var _zone_override := {}     # term_id -> zone name forced by a drag ("" = loose)
var _project_cache := {}     # cwd -> project key (git-root basename)
var _auto_zone := true       # cluster by project unless overridden
var _zone_layer: Node2D
const ZoneLayer := preload("res://scripts/ZoneLayer.gd")
var _notes := []             # [{project, event, term_id, ts}]
var _panel_vbox: VBoxContainer
var _agents := {}            # main-thread copy of _ls_data
var _attn_ids := {}          # term_id -> true (needs attention)
var _pan_once := -1          # term id to pan the camera to once (input required)
var _names := {}             # term_id -> custom name (persists across re-spawn)
var _saved := {}             # layout restored from the previous run's state.json
var _sessions := {}          # term_id -> abduco session name (once learned from ls)
var _pos_by_session := {}    # session -> [x,y], to restore across a kitty restart
var _name_by_session := {}   # session -> custom name, ditto
var _pos_restored := {}      # term_id -> true once its position has been restored
var _win_rect := {}          # last-known *windowed* os-window rect {pos,size} (not while maximized)

# rename dialog
var _rename_panel: PanelContainer
var _rename_edit: LineEdit
var _rename_id := -1

# search overlay (Cmd/Ctrl+K): fuzzy-as-you-type + semantic "jump" via cove-find
var _search_panel: PanelContainer
var _search_edit: LineEdit
var _search_list: VBoxContainer
var _search_hint: Label
var _search_open := false
var _search_rows := []        # [{id, why, source}] currently displayed, best-first
var _search_sel := 0          # highlighted row index
var _search_awaiting := ""    # query we're waiting on cove-find for ("" = idle)
var _search_poll := 0.0
var _search_preview_id := -1  # termling the camera is previewing while stepping
var _search_return_cam := Vector2.ZERO  # camera to restore if the search is escaped
var _cam_return := false       # true while swooping the camera back after an Esc
const SEARCH_HINT := "↵ jump  ·  ⇥ ✨ ask AI  ·  esc"
const SEARCH_DIM := 0.2       # alpha for termlings occluding the previewed one

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
	_setup_handoff()
	_load_layout()   # restore positions/names/camera from the previous run
	_restore_window()  # put the os-window back where (and how big / maximized) it was
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

	# Zone regions, painted above the ground but below the termlings.
	_zone_layer = ZoneLayer.new()
	_zone_layer.z_index = -40
	add_child(_zone_layer)

	_world = Node2D.new()
	_world.y_sort_enabled = true
	add_child(_world)


func _process(delta: float) -> void:
	_rescan_accum += delta
	if _rescan_accum > 0.4:
		_rescan_accum = 0.0
		_reconcile()
		_apply_zones()
	if _sock != null and not _sock.call("is_connected") and _input_tries < 100:
		_try_connect_sock()
	_apply_agent_state()
	_apply_follows()
	_poll_handoff()
	_pump_commands(delta)
	_pump_notify()
	_poll_search(delta)
	_state_accum += delta
	if _state_accum > 0.2:
		_state_accum = 0.0
		_write_state()
	# While previewing a search hit the camera swoops onto it; otherwise it follows
	# the tracked terminal (double-click / committed jump). Track the terminal's
	# centre, not the group's ground point (which sits well below it).
	if _search_open and _search_preview_id != -1 and _groups.has(_search_preview_id):
		_cam.position = _cam.position.lerp(_groups[_search_preview_id].terminal.global_position, 8.0 * delta)
	elif _tracking_id != -1 and _groups.has(_tracking_id):
		_cam.position = _cam.position.lerp(_groups[_tracking_id].terminal.global_position, 6.0 * delta)
	elif _cam_return:
		_cam.position = _cam.position.lerp(_search_return_cam, 8.0 * delta)
		if _cam.position.distance_to(_search_return_cam) < 2.0:
			_cam_return = false
	_update_occluder_fade(delta)
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
		_pos_restored[id] = true
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
	_zone_of.erase(id)
	_zone_override.erase(id)
	if _focused_id == id:
		_focused_id = -1
		for other in _groups:
			_set_focus(other)
			break


# --- cross-Mac termling handoff --------------------------------------------
# Fling a lifted termling at the window edge and Universal Control drags the real
# OS session to the other Mac's Cove, which resumes it there (see cove-handoff-*).

func _setup_handoff() -> void:
	if not ClassDB.class_exists("CoveDrag"):
		push_warning("cove: CoveDrag extension not loaded — termling handoff disabled.")
		return
	_drag = ClassDB.instantiate("CoveDrag")
	var view := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_VIEW, DisplayServer.MAIN_WINDOW_ID)
	if not _drag.call("attach", view):
		push_warning("cove: CoveDrag.attach failed — termling handoff disabled.")
		_drag = null
		return
	# The landing ghost: a chip that rides under the cursor while an inbound drag
	# hovers this Cove, so you can see where the termling will touch down.
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_ghost = Label.new()
	_ghost.add_theme_font_size_override("font_size", 16)
	_ghost.add_theme_color_override("font_color", Color(1, 1, 1))
	_ghost.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_ghost.add_theme_constant_override("outline_size", 6)
	_ghost.visible = false
	layer.add_child(_ghost)
	print("cove: termling handoff armed (fling a lifted termling at the window edge)")


func _near_window_edge(p: Vector2) -> bool:
	var s := get_viewport().get_visible_rect().size
	return p.x < HANDOFF_EDGE_PX or p.y < HANDOFF_EDGE_PX \
		or p.x > s.x - HANDOFF_EDGE_PX or p.y > s.y - HANDOFF_EDGE_PX


func _handoff_name(id: int) -> String:
	if _groups.has(id) and _groups[id].terminal.custom_name != "":
		return _groups[id].terminal.custom_name
	return _names.get(id, "")


# The self-describing string that rides the OS pasteboard to the other Mac. The
# agent/cwd and the wwid key are pane-id keyed (like the rest of Cove); term_id
# (the os-window id) only needs to travel so the origin knows what to close.
func _build_handoff_payload(g: Node2D) -> String:
	var id: int = g.term_id
	var pane: int = g.terminal.pane_id
	var info: Dictionary = _agents.get(pane, {})
	var agent := str(info.get("agent", "shell"))
	var cwd := str(info.get("cwd", ""))
	var sid := ""
	if agent == "claude" and cwd != "":
		# Ask Mac A's ~/.claude which conversation this termling is running, so the
		# other Mac can resume that exact session.
		var out := []
		var script := ProjectSettings.globalize_path("res://cove-handoff-capture.sh")
		OS.execute("/bin/sh", [script, cwd], out, false)
		if out.size() > 0:
			sid = str(out[0]).strip_edges()
	return JSON.stringify({
		"v": 1,
		"key": "w%d" % pane,
		"term_id": id,
		"agent": agent,
		"sid": sid,
		"cwd": cwd,
		"name": _handoff_name(id),
	})


func _try_begin_handoff() -> void:
	if _drag == null or _inflight_id != -1 or _drag.call("is_dragging"):
		return
	if _press_group == null:
		return
	var g := _press_group
	var id: int = g.term_id
	var label := _handoff_name(id)
	if label == "":
		label = str(_agents.get(g.terminal.pane_id, {}).get("agent", "termling"))
	# Snapshot the termling's live IOSurface as the drag image (falls back to a
	# chip inside the extension if the surface can't be read).
	var native: Vector2i = g.terminal.native_size()
	if not _drag.call("begin_drag", _build_handoff_payload(g), label,
			g.terminal.iosurface_id, native.x, native.y):
		return  # no usable mouse event yet; a later motion retries
	# The OS owns the mouse now. End the ground-drag and dim the termling so it
	# reads as "in flight"; it closes for real only if a destination accepts the
	# drop (else _cancel_inflight un-dims and it holds where it was).
	g.end_drag_move()
	_inflight_id = id
	if _groups.has(id):
		_groups[id].modulate = Color(1, 1, 1, 0.35)
	_moving = false
	_lifting = false
	_press_group = null
	_selecting = false
	_panning = false


func _poll_handoff() -> void:
	if _drag == null:
		return
	var drop: Dictionary = _drag.call("poll_drop")
	if not drop.is_empty():
		_land_handoff(drop)
	var ended: Dictionary = _drag.call("poll_drag_ended")
	if not ended.is_empty():
		if bool(ended.get("accepted", false)):
			_close_origin(_inflight_id)
		else:
			_cancel_inflight()
		_inflight_id = -1
	if _ghost != null:
		var hover: Dictionary = _drag.call("poll_hover")
		if bool(hover.get("active", false)):
			_ghost.text = "🐚 landing…"
			_ghost.position = Vector2(hover.get("x", 0.0) + 14.0, hover.get("y", 0.0) - 10.0)
			_ghost.visible = true
		else:
			_ghost.visible = false


# A termling was dropped onto this Cove: launch it here, resuming the dragged
# Claude conversation (or a shell) in the handed-over cwd.
func _land_handoff(drop: Dictionary) -> void:
	var data = JSON.parse_string(str(drop.get("payload", "")))
	if typeof(data) != TYPE_DICTIONARY:
		return
	var agent := str(data.get("agent", "shell"))
	var sid := str(data.get("sid", ""))
	var cwd := str(data.get("cwd", ""))
	var name := str(data.get("name", ""))
	if kitten_exe == "":
		push_warning("cove: landed a termling but no kitten to launch it")
		return
	var land := ProjectSettings.globalize_path("res://cove-handoff-land.sh")
	var args := ["@", "--to", kitty_socket, "launch", "--type=os-window", "--keep-focus"]
	if cwd != "":
		args.append_array(["--cwd", cwd])
	if name != "":
		args.append_array(["--title", name])
	args.append_array([land, agent, sid])
	OS.create_process(kitten_exe, args, false)
	print("cove: landed %s termling (sid=%s) in %s" % [agent, sid if sid != "" else "-", cwd])


func _cancel_inflight() -> void:
	# The drag was released over nothing; the termling stays put. Un-dim it.
	if _inflight_id != -1 and _groups.has(_inflight_id):
		_groups[_inflight_id].modulate = Color(1, 1, 1, 1)
		_groups[_inflight_id].drop()


# A destination accepted the drag, so the termling has moved: close the origin
# window AND kill its abduco session so the old process doesn't linger (which,
# for Claude, would double-open the now-synced transcript).
func _close_origin(id: int) -> void:
	if id == -1:
		return
	# close-window matches on the kitty window (pane) id, not the os-window id.
	if kitten_exe != "" and _groups.has(id):
		var pane: int = _groups[id].terminal.pane_id
		if pane != 0:
			OS.create_process(kitten_exe, ["@", "--to", kitty_socket, "close-window",
				"--match", "id:%d" % pane], false)
	var sess := str(_sessions.get(id, ""))
	if sess != "":
		OS.create_process("/usr/bin/pkill", ["-f", "abduco -A %s " % sess], false)
	_remove_group(id)


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
	# While the search overlay is open, drive it: Esc closes, Up/Down move the
	# highlight, Tab asks the AI, Enter commits. Every other key falls through to
	# the focused LineEdit so typing the query works normally.
	if _search_open:
		match event.keycode:
			KEY_ESCAPE:
				_close_search(true); get_viewport().set_input_as_handled()
			KEY_UP:
				_move_search_sel(-1); get_viewport().set_input_as_handled()
			KEY_DOWN:
				_move_search_sel(1); get_viewport().set_input_as_handled()
			KEY_TAB:
				_run_semantic_search(); get_viewport().set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				_commit_search(); get_viewport().set_input_as_handled()
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
	# Cmd+F opens the search overlay. Meta only (not Ctrl) so it never shadows the
	# emacs editing keys (C-f/C-k/C-n...) or Cmd+K, which the user drives elsewhere.
	if event.keycode == KEY_F and event.meta_pressed and not event.ctrl_pressed:
		_open_search()
		get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_N and (event.meta_pressed or event.ctrl_pressed):
		_spawn_terminal()
		get_viewport().set_input_as_handled()


func _world_mouse() -> Vector2:
	return get_global_mouse_position()


# Drive kitty's own text selection on the focused terminal. phase: 0 start,
# 1 drag-update, 2 end (kitty copies the selection to the clipboard on end).
# Only the fast socket carries this; there's no kitten fallback for selection.
func _send_select(g: Node2D, world: Vector2, phase: int) -> void:
	if g == null or _sock == null or not _sock.call("is_connected"):
		return
	var t = g.terminal
	var pane: int = t.pane_id
	if pane == 0:
		return
	var ch: Dictionary = t.cell_and_half(world)
	var cell: Vector2i = ch["cell"]
	_sock.call("send_mouse", pane, phase, cell.x, cell.y, ch["left"])


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
				_press_world = wpos
				_sel_started = false
				# Drag semantics on a termling: while the camera is *tracking* this
				# one you're reading it, so a drag selects its text; otherwise a drag
				# repositions it on the ground. Alt-drag always lifts (handoff gesture).
				_selecting = _press_group != null and _press_group.term_id == _tracking_id and not event.alt_pressed and not event.double_click
				_lifting = false
				_moving = false
				_panning = _press_group == null  # empty-space left-drag pans
				if _panning:
					_tracking_id = -1  # manual pan cancels camera follow
				if event.double_click and _press_group != null:
					_set_focus(_press_group.term_id)
					_tracking_id = _press_group.term_id  # double-click: focus + follow
			else:
				if _sel_started and _press_group != null:
					_send_select(_press_group, _world_mouse(), 2)  # end drag -> copy selection
				elif _press_group != null and _lifting:
					_press_group.drop()
				elif _press_group != null and _moving:
					_press_group.end_drag_move()
					_reassign_zone_on_drop(_press_group)
				elif _press_group != null:
					_set_focus(_press_group.term_id)
				_press_group = null
				_lifting = false
				_moving = false
				_selecting = false
				_sel_started = false
				_panning = false
	elif event is InputEventMouseMotion:
		if _selecting and _press_group != null:
			# Begin selecting once past the deadzone so a plain click still just
			# focuses; anchor at the press cell, then track the cursor as we drag.
			if not _sel_started and event.position.distance_to(_press_pos) > SELECT_DEADZONE:
				_sel_started = true
				_send_select(_press_group, _press_world, 0)  # start at the anchor cell
			if _sel_started:
				_send_select(_press_group, _world_mouse(), 1)  # drag update
		elif _press_group != null:
			# A drag slides the termling along the ground. A plain drag can fling
			# it off the window edge to the other Mac (Universal Control carries
			# it); holding Alt relocates freely — even off-screen — without sending.
			if not _moving and event.position.distance_to(_press_pos) > LIFT_THRESHOLD:
				_set_focus(_press_group.term_id)
				_moving = true
				_move_can_send = not event.alt_pressed
				_move_grab = _press_group.get_ground_pos() - _press_world
				_press_group.begin_drag_move()
			if _moving:
				_press_group.set_drag_pos(_world_mouse() + _move_grab)
				if _move_can_send and _near_window_edge(event.position):
					_try_begin_handoff()
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
	# Zones (slots + colours) so a hot-reload keeps the same regions in place.
	for z in d.get("zones", []):
		var zn := str(z.get("name", ""))
		if zn != "":
			var col = z.get("color", [0.6, 0.6, 0.6])
			_zones[zn] = {"slot": int(z.get("slot", _zones.size())), "color": col}
	if typeof(d.get("auto_zone", null)) == TYPE_BOOL:
		_auto_zone = d["auto_zone"]
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
		if t.get("zone_override", null) != null:
			_zone_override[id] = str(t["zone_override"])
		# Session-keyed restore survives a kitty restart: abduco keeps the shells
		# alive but kitty hands out fresh window ids, so id-keying alone misses.
		var sess := str(t.get("session", ""))
		if sess != "":
			_pos_by_session[sess] = t.get("pos", [0, 0])
			if str(t.get("name", "")) != "":
				_name_by_session[sess] = str(t["name"])
	_saved = {"pos": pos, "cam": d.get("camera", null), "follows": follows, "focused": int(d.get("focused", -1))}
	if _saved["cam"] == null:
		_saved.erase("cam")
	if typeof(d.get("window", null)) == TYPE_DICTIONARY:
		_saved["window"] = d["window"]


func _restore_after_reconcile() -> void:
	for fid in _saved.get("follows", {}):
		if _groups.has(fid):
			_follows[fid] = _saved["follows"][fid]
	var foc := int(_saved.get("focused", -1))
	if foc != -1 and _groups.has(foc):
		_set_focus(foc)


func _restore_window() -> void:
	# Put the os-window back on the same monitor, at the same size, and re-maximize
	# (or re-fullscreen) if that's how we were left. Restore the windowed rect first
	# so an un-maximize later lands somewhere sane rather than filling the screen.
	var w = _saved.get("window", null)
	if typeof(w) != TYPE_DICTIONARY:
		return
	_apply_window_rect(w)
	var mode := int(w.get("mode", DisplayServer.WINDOW_MODE_WINDOWED))
	if mode == DisplayServer.WINDOW_MODE_MAXIMIZED \
			or mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
			or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(mode)


func _apply_window_rect(w: Dictionary) -> void:
	var size = w.get("size", null)
	if size is Array and size.size() == 2:
		DisplayServer.window_set_size(Vector2i(int(size[0]), int(size[1])))
	var pos = w.get("pos", null)
	if pos is Array and pos.size() == 2:
		# Only reposition if the saved corner still lands on a connected monitor;
		# otherwise (display unplugged) leave Godot's default centred placement.
		var p := Vector2i(int(pos[0]), int(pos[1]))
		if _position_on_some_screen(p):
			DisplayServer.window_set_position(p)


func _position_on_some_screen(p: Vector2i) -> bool:
	for i in range(DisplayServer.get_screen_count()):
		var r := Rect2i(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i))
		if r.has_point(p):
			return true
	return false


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
		var pout := []
		OS.execute("/bin/ps", ["-Ao", "pid=,ppid=,command="], pout, false)
		var ptxt: String = pout[0] if pout.size() > 0 else ""
		var sess_info := _scan_sessions(ptxt)
		var data := _parse_ls(txt, sess_info)
		_ls_mutex.lock()
		_ls_data = data
		_ls_mutex.unlock()
		OS.delay_msec(1000)


# Each termling's shell runs inside an abduco session (see cove-shell.sh) so it
# survives a kitty restart. The shell/agent is then a child of the abduco master,
# not of the kitty window, so `kitten @ ls` can't see it -- we recover the agent
# and cwd by walking the process tree from each abduco master instead.
func _scan_sessions(ptxt: String) -> Dictionary:
	var cmd := {}    # pid -> command
	var kids := {}   # ppid -> [pid]
	for raw in ptxt.split("\n", false):
		var line := raw.strip_edges()
		if line == "":
			continue
		var sp := line.split(" ", false, 2)
		if sp.size() < 3:
			continue
		var pid := int(sp[0])
		var ppid := int(sp[1])
		cmd[pid] = sp[2]
		if not kids.has(ppid):
			kids[ppid] = []
		kids[ppid].append(pid)
	var res := {}
	for pid in cmd:
		var c: String = cmd[pid]
		# The abduco *master* holds the session: its argv carries the session name
		# and (unlike the attach client) it is the parent of the shell subtree.
		if not c.contains("abduco") or not kids.has(pid):
			continue
		var sess := _session_token(c)
		if sess == "":
			continue
		var agent := "shell"
		var agent_pid := -1
		var direct: Array = kids.get(pid, [])
		var shell_pid: int = direct[0] if direct.size() > 0 else -1
		var queue: Array = direct.duplicate()
		var guard := 0
		while not queue.is_empty() and guard < 256:
			guard += 1
			var cur: int = queue.pop_front()
			var lc: String = str(cmd.get(cur, "")).to_lower()
			if lc.contains("opencode"):
				agent = "opencode"; agent_pid = cur
			elif lc.contains("codex") and agent == "shell":
				agent = "codex"; agent_pid = cur
			elif lc.contains("claude") and agent == "shell":
				agent = "claude"; agent_pid = cur
			for k in kids.get(cur, []):
				queue.append(k)
		var src := agent_pid if agent_pid != -1 else shell_pid
		res[sess] = {"agent": agent, "busy": agent != "shell", "cwd": _cwd_of(src)}
	return res


# The session name is the argv token like `cove-12345` on an abduco command line.
# We extract `cove-<digits>` strictly so trailing junk in a ps line (quotes or
# newlines from a wrapped command) can't yield a bogus session key.
func _session_token(c: String) -> String:
	for tok in c.split(" ", false):
		if not tok.begins_with("cove-"):
			continue
		var digits := ""
		for i in range(5, tok.length()):
			var ch := tok[i]
			if ch >= "0" and ch <= "9":
				digits += ch
			else:
				break
		if digits != "":
			return "cove-" + digits
	return ""


func _cwd_of(pid: int) -> String:
	if pid <= 0:
		return ""
	var out := []
	OS.execute("/usr/sbin/lsof", ["-a", "-p", str(pid), "-d", "cwd", "-Fn"], out, false)
	var txt: String = out[0] if out.size() > 0 else ""
	for line in txt.split("\n", false):
		if line.begins_with("n"):
			return line.substr(1)
	return ""


func _session_from_procs(procs) -> String:
	for p in procs:
		var cl := " ".join(p.get("cmdline", []))
		if cl.contains("abduco"):
			var sess := _session_token(cl)
			if sess != "":
				return sess
	return ""


func _parse_ls(txt: String, sess_info: Dictionary) -> Dictionary:
	var arr = JSON.parse_string(txt)
	var res := {}
	if typeof(arr) != TYPE_ARRAY:
		return res
	for osw in arr:
		for tab in osw.get("tabs", []):
			for w in tab.get("windows", []):
				var pane := int(w.get("id", 0))
				var session := _session_from_procs(w.get("foreground_processes", []))
				var si: Dictionary = sess_info.get(session, {})
				res[pane] = {
					"session": session,
					"agent": str(si.get("agent", "shell")),
					"busy": bool(si.get("busy", false)),
					"attention": bool(w.get("needs_attention", false)),
					"cwd": str(si.get("cwd", w.get("cwd", ""))),
					"title": str(w.get("title", "")),
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
		_learn_session(id, g, str(info.get("session", "")))
		g.set_agent(info.get("agent", "shell"), info.get("busy", false))
		# A shadow pane opened by cove-remote-auto.sh titles itself "◈ <name> @ <peer>";
		# recognise it and give the termling the remote treatment.
		_apply_remote_marker(g, str(info.get("title", "")))
		if info.get("attention", false):
			_attn_ids[id] = true
		g.set_attention(_attn_ids.has(id))
	# one-shot camera pan to a terminal that needs input (only if not following)
	if _pan_once != -1 and _tracking_id == -1 and _groups.has(_pan_once):
		var tp: Vector2 = _groups[_pan_once].terminal.global_position
		_cam.position = _cam.position.lerp(tp, 5.0 * get_process_delta_time())
		if _cam.position.distance_to(tp) < 24.0:
			_pan_once = -1


# A remote shadow pane (from cove-remote-auto.sh) carries the title
# "◈ <name> @ <peer>". Parse that and toggle the termling's remote treatment;
# any other title clears it. Also seeds the nameplate name once.
func _apply_remote_marker(g: Node2D, title: String) -> void:
	if g.terminal == null:
		return
	if not title.begins_with("◈"):
		if g.terminal.remote:
			g.terminal.set_remote(false, "")
		return
	var body := title.substr(1).strip_edges()  # "<name> @ <peer>"
	var name := body
	var peer := ""
	var at := body.rfind(" @ ")
	if at != -1:
		name = body.substr(0, at).strip_edges()
		peer = body.substr(at + 3).strip_edges()
	g.terminal.set_remote(true, peer)
	if name != "" and g.terminal.custom_name == "":
		g.terminal.set_custom_name(name)


# Once we learn a termling's abduco session (from the ls poll) remember it for
# state.json, and if the id-keyed restore didn't fire (i.e. kitty was restarted
# and handed out fresh ids) snap it to its saved spot/name, just once.
func _learn_session(id: int, g: Node2D, session: String) -> void:
	if session == "":
		return
	_sessions[id] = session
	if _pos_restored.has(id):
		return
	_pos_restored[id] = true
	if _pos_by_session.has(session):
		var p = _pos_by_session[session]
		g.position = Vector2(p[0], p[1])
	if _name_by_session.has(session) and g.terminal.custom_name == "":
		g.terminal.set_custom_name(_name_by_session[session])


func _apply_follows() -> void:
	# Group followers by their target first, so several followers of one termling
	# arc around it (a fanned ring) instead of all aiming at the same slot and
	# piling up. A lone follower still stands directly beside its target.
	var by_target := {}
	for fid in _follows.keys():
		var target_id: int = _follows[fid]
		if not _groups.has(fid) or not _groups.has(target_id):
			_follows.erase(fid)
			if _groups.has(fid):
				_groups[fid].command_stop()
				_zone_of.erase(fid)   # re-confine to its zone on the next tick
			continue
		if not by_target.has(target_id):
			by_target[target_id] = []
		by_target[target_id].append(fid)
	for target_id in by_target:
		var t = _groups[target_id]
		var followers: Array = by_target[target_id]
		var radius: float = t.terminal.onscreen_size().x * 0.6 + 170.0
		var n := followers.size()
		for i in range(n):
			# Fan across the target's right side (-55°..+55°); single follower = 0°.
			var ang := 0.0 if n == 1 else deg_to_rad(lerpf(-55.0, 55.0, float(i) / float(n - 1)))
			var offset: Vector2 = Vector2(cos(ang), sin(ang)) * radius
			_groups[followers[i]].command_move(t.get_ground_pos() + offset)


# --- zones ------------------------------------------------------------------

# Layout: zones tile a fixed grid across the ground, so a zone keeps its slot as
# others come and go (no reshuffling). Bounds are 3200×2200, so 3 columns fit.
const ZONE_W := 900.0
const ZONE_H := 660.0
const ZONE_GAP := 130.0
const ZONE_COLS := 3

func _zone_slot_rect(slot: int) -> Rect2:
	var col := slot % ZONE_COLS
	var row := slot / ZONE_COLS
	var x := _bounds.position.x + 150.0 + col * (ZONE_W + ZONE_GAP)
	var y := _bounds.position.y + 150.0 + row * (ZONE_H + ZONE_GAP)
	return Rect2(x, y, ZONE_W, ZONE_H)


# A stable, pleasant colour per zone name (golden-angle hue off a name hash).
func _zone_color(name: String) -> Color:
	var h := float(hash(name) % 360) / 360.0
	return Color.from_hsv(h, 0.55, 0.95)


# The world rect of a named zone (creating a record + slot if new).
func _zone_rect(name: String) -> Rect2:
	if not _zones.has(name):
		var used := {}
		for z in _zones.values():
			used[int(z["slot"])] = true
		var slot := 0
		while used.has(slot):
			slot += 1
		var col := _zone_color(name)
		_zones[name] = {"slot": slot, "color": [col.r, col.g, col.b]}
	return _zone_slot_rect(int(_zones[name]["slot"]))


# Project key for a terminal: the basename of its enclosing git repo (walking up
# from cwd), else the cwd's own folder name. This is what colocates termlings.
func _project_key(cwd: String) -> String:
	if cwd == "":
		return ""
	if _project_cache.has(cwd):
		return _project_cache[cwd]
	var p := cwd
	while p != "" and p != "/":
		if DirAccess.dir_exists_absolute(p + "/.git"):
			break
		p = p.get_base_dir()
	var key := (p if (p != "" and p != "/") else cwd).get_file()
	_project_cache[cwd] = key
	return key


func _group_cwd(id: int) -> String:
	if not _groups.has(id):
		return ""
	return str(_agents.get(_groups[id].terminal.pane_id, {}).get("cwd", ""))


# Assign each termling to a zone and confine its wander there. A drag override
# wins over the project default; a following termling keeps its motion.
func _apply_zones() -> void:
	if not _auto_zone and _zone_override.is_empty():
		return
	for id in _groups:
		var want := ""
		if _zone_override.has(id):
			want = str(_zone_override[id])          # "" = pinned loose (no zone)
		elif _auto_zone:
			want = _project_key(_group_cwd(id))
		if _zone_of.get(id, "") == want:
			continue
		_zone_of[id] = want
		if want == "":
			_groups[id].clear_zone()
		elif not _follows.has(id):
			_groups[id].assign_zone(_zone_rect(want))
	_prune_zones()
	_rebuild_zone_layer()


# Drop empty auto-created zones so the stage doesn't accumulate ghost regions.
func _prune_zones() -> void:
	var live := {}
	for id in _zone_of:
		var z: String = _zone_of[id]
		if z != "":
			live[z] = true
	for name in _zones.keys():
		if not live.has(name):
			_zones.erase(name)


# Push the current zones (rect + colour + member count) to the draw layer.
func _rebuild_zone_layer() -> void:
	if _zone_layer == null:
		return
	var counts := {}
	for id in _zone_of:
		var z: String = _zone_of[id]
		if z != "":
			counts[z] = int(counts.get(z, 0)) + 1
	var items := []
	for name in _zones:
		var c = _zones[name]["color"]
		items.append({
			"rect": _zone_slot_rect(int(_zones[name]["slot"])),
			"color": Color(c[0], c[1], c[2]),
			"label": "%s  (%d)" % [name, int(counts.get(name, 0))],
		})
	_zone_layer.items = items


# On drop, membership follows the drop point: land inside a zone to join it,
# land on open ground to pin loose. Either way it's a sticky manual override.
func _reassign_zone_on_drop(g: Node2D) -> void:
	var p: Vector2 = g.get_ground_pos()
	var landed := ""
	for name in _zones:
		if _zone_slot_rect(int(_zones[name]["slot"])).has_point(p):
			landed = name
			break
	_zone_override[g.term_id] = landed
	# Re-run assignment now so the drop reads immediately.
	_zone_of.erase(g.term_id)
	_apply_zones()


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
				_zone_of.erase(g.term_id)   # re-confine to its zone on the next tick
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
				_groups[id].clear_zone()
			_follows.clear()
			_zones.clear()
			_zone_of.clear()
			_zone_override.clear()
			_rebuild_zone_layer()
		"assign":
			# Force a termling into a named zone (creating it), or "" to pin it loose.
			var g := _find(int(c.get("id", -1)))
			if g:
				var zn := str(c.get("zone", ""))
				_zone_override[g.term_id] = zn
				if zn != "":
					_zone_rect(zn)  # ensure the zone exists / has a slot
				_zone_of.erase(g.term_id)
				_apply_zones()
		"autozone":
			_auto_zone = bool(c.get("on", true))
			if not _auto_zone:
				# Keep only drag/assign overrides; drop project-derived memberships.
				for id in _groups:
					if not _zone_override.has(id):
						_zone_of.erase(id)
						_groups[id].clear_zone()
				_prune_zones()
				_rebuild_zone_layer()
			else:
				_apply_zones()
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
	# newest hook event per terminal, so state.json says what each is working on
	var note_by_id := {}
	for n in _notes:
		var nid: int = n.get("term_id", -1)
		if nid != -1 and not note_by_id.has(nid):
			note_by_id[nid] = n
	var terms := []
	for id in _groups:
		var g = _groups[id]
		var info = _agents.get(g.terminal.pane_id, {})
		var note = note_by_id.get(id, {})
		terms.append({
			"id": id,
			"pane_id": g.terminal.pane_id,
			"session": _sessions.get(id, ""),
			"name": g.terminal.custom_name,
			"pos": [snappedf(g.position.x, 0.1), snappedf(g.position.y, 0.1)],
			"cols": g.terminal.cols,
			"rows": g.terminal.rows,
			"agent": info.get("agent", "shell"),
			"busy": info.get("busy", false),
			"attention": _attn_ids.has(id),
			"following": _follows.get(id, null),
			"cwd": info.get("cwd", ""),
			"title": str(info.get("title", "")),
			"project": str(note.get("project", "")),
			"last_event": str(note.get("event", "")),
			"zone": str(_zone_of.get(id, "")),
			"zone_override": (str(_zone_override[id]) if _zone_override.has(id) else null),
		})
	# Remember the os-window geometry. Only refresh the windowed rect while actually
	# windowed, so a maximized/fullscreen session still records the rect to fall back
	# to when un-maximized (and across restarts).
	var win_mode := DisplayServer.window_get_mode()
	if win_mode == DisplayServer.WINDOW_MODE_WINDOWED:
		var wp := DisplayServer.window_get_position()
		var ws := DisplayServer.window_get_size()
		_win_rect = {"pos": [wp.x, wp.y], "size": [ws.x, ws.y]}
	var window := {"mode": int(win_mode)}
	if _win_rect.has("pos"):
		window["pos"] = _win_rect["pos"]
		window["size"] = _win_rect["size"]
	var zones := []
	for name in _zones:
		var r := _zone_slot_rect(int(_zones[name]["slot"]))
		zones.append({
			"name": name,
			"slot": int(_zones[name]["slot"]),
			"color": _zones[name]["color"],
			"rect": [snappedf(r.position.x, 0.1), snappedf(r.position.y, 0.1),
				snappedf(r.size.x, 0.1), snappedf(r.size.y, 0.1)],
		})
	var st := {
		"terminals": terms,
		"camera": [snappedf(_cam.position.x, 0.1), snappedf(_cam.position.y, 0.1), _cam.zoom.x],
		"focused": _focused_id,
		"window": window,
		"zones": zones,
		"auto_zone": _auto_zone,
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
	_build_search_dialog()


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


# --- search overlay ---------------------------------------------------------
# Cmd/Ctrl+K opens a search bar. As you type we fuzzy-match locally over every
# termling's name/title/project/last-event/cwd (instant). Enter jumps to the
# highlighted hit; Tab (or Enter on an empty list) asks cove-find to resolve the
# query semantically via the Anthropic API, then re-ranks. Choosing a result
# focuses that termling and sets the camera to track it.

func _build_search_dialog() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	_search_panel = PanelContainer.new()
	_search_panel.add_theme_stylebox_override("panel", _themed_box(Color(0.55, 0.95, 0.75, 0.7)))
	_search_panel.visible = false
	_search_panel.custom_minimum_size = Vector2(470, 0)
	center.add_child(_search_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	_search_panel.add_child(vb)

	var title := Label.new()
	title.text = "🔎 find a termling"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.9, 0.8, 0.55))
	vb.add_child(title)

	_search_edit = LineEdit.new()
	_search_edit.custom_minimum_size = Vector2(440, 0)
	_search_edit.placeholder_text = "who's running the tests? · the auth refactor · logs"
	_search_edit.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98))
	_search_edit.text_changed.connect(_on_search_text)
	vb.add_child(_search_edit)

	_search_list = VBoxContainer.new()
	_search_list.add_theme_constant_override("separation", 3)
	vb.add_child(_search_list)

	_search_hint = Label.new()
	_search_hint.text = SEARCH_HINT
	_search_hint.add_theme_font_size_override("font_size", 11)
	_search_hint.add_theme_color_override("font_color", Color(0.6, 0.62, 0.66))
	vb.add_child(_search_hint)


func _open_search() -> void:
	if _search_panel == null:
		return
	_search_open = true
	_search_awaiting = ""
	_search_sel = 0
	_search_preview_id = -1
	_search_return_cam = _cam.position   # so Esc can put the view back
	_search_hint.text = SEARCH_HINT
	_search_panel.visible = true
	_search_edit.text = ""
	_search_edit.grab_focus()
	_on_search_text("")   # seed with the full roster


# restore_view: on Esc we pan back to where we started and drop any preview; on a
# committed jump we keep the camera on the chosen termling instead.
func _close_search(restore_view := false) -> void:
	_clear_preview()
	# Swoop back to the pre-search view on Esc, but only if we weren't already
	# tracking a termling (in which case the tracker reclaims the camera).
	_cam_return = restore_view and _tracking_id == -1
	if _search_panel:
		_search_panel.visible = false
	_search_open = false
	_search_awaiting = ""
	_search_preview_id = -1


# One searchable record per termling -- the same fields cove-find reasons over.
func _search_cards() -> Array:
	var note_by_id := {}
	for n in _notes:
		var nid: int = n.get("term_id", -1)
		if nid != -1 and not note_by_id.has(nid):
			note_by_id[nid] = n
	var cards := []
	for id in _groups:
		var g = _groups[id]
		var info = _agents.get(g.terminal.pane_id, {})
		var note = note_by_id.get(id, {})
		cards.append({
			"id": id,
			"name": g.terminal.custom_name,
			"agent": str(info.get("agent", "shell")),
			"title": str(info.get("title", "")),
			"project": str(note.get("project", "")),
			"last_event": str(note.get("event", "")),
			"cwd": str(info.get("cwd", "")),
		})
	return cards


func _search_why(c: Dictionary) -> String:
	var bits := []
	if str(c.agent) != "shell":
		bits.append(str(c.agent))
	if str(c.project) != "":
		bits.append(str(c.project))
	elif str(c.title) != "":
		bits.append(str(c.title))
	elif str(c.cwd) != "":
		bits.append(str(c.cwd).get_file())
	return "  ·  ".join(bits)


func _on_search_text(text: String) -> void:
	_search_awaiting = ""   # typing supersedes any pending semantic reply
	_clear_preview()        # a fresh query stops previewing (camera stays put)
	_search_hint.text = SEARCH_HINT
	var q := text.strip_edges().to_lower()
	var words := q.split(" ", false)
	var scored := []
	for c in _search_cards():
		var hay := (str(c.name) + " " + str(c.agent) + " " + str(c.title) + " "
			+ str(c.project) + " " + str(c.last_event) + " " + str(c.cwd)).to_lower()
		var score := 0.0
		if q == "":
			score = 1.0   # no query -> show the whole roster
		else:
			if hay.contains(q):
				score += 5.0
			for w in words:
				if w != "" and hay.contains(w):
					score += 1.0
				if w != "" and str(c.name).to_lower().contains(w):
					score += 2.0
		if score > 0:
			scored.append({"id": c.id, "why": _search_why(c), "score": score})
	scored.sort_custom(func(a, b): return a.score > b.score)
	_search_sel = 0
	_render_search(scored)


func _render_search(rows: Array) -> void:
	_search_rows = rows
	if _search_sel >= rows.size():
		_search_sel = maxi(0, rows.size() - 1)
	while _search_list.get_child_count() > 0:
		var ch := _search_list.get_child(0)
		_search_list.remove_child(ch)
		ch.queue_free()
	if rows.is_empty():
		var empty := Label.new()
		empty.text = "no match — press ⇥ to ask AI"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.6, 0.62, 0.66))
		_search_list.add_child(empty)
		return
	var i := 0
	for r in rows:
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE   # keep keyboard focus in the LineEdit
		b.add_theme_font_size_override("font_size", 13)
		var why := str(r.get("why", ""))
		b.text = ("▸ " if i == _search_sel else "   ") + _term_label(int(r.id)) \
			+ ("   —   " + why if why != "" else "")
		var rid := int(r.id)
		b.pressed.connect(func(): _search_choose(rid))
		_search_list.add_child(b)
		i += 1


func _term_label(id: int) -> String:
	if _groups.has(id) and _groups[id].terminal.custom_name != "":
		return _groups[id].terminal.custom_name
	return "termling %d" % id


func _move_search_sel(d: int) -> void:
	if _search_rows.is_empty():
		return
	_search_sel = wrapi(_search_sel + d, 0, _search_rows.size())
	_render_search(_search_rows)
	_preview_selected()   # stepping the list previews that termling


func _commit_search() -> void:
	# Enter jumps to the highlighted hit; with nothing to jump to, ask the AI.
	if _search_rows.is_empty():
		_run_semantic_search()
		return
	_search_choose(int(_search_rows[_search_sel].id))


func _search_choose(id: int) -> void:
	if _groups.has(id):
		_set_focus(id)
		_tracking_id = id   # the camera keeps tracking the one we jumped to
	_close_search(false)


# --- search preview: camera + occluder fade while stepping the results -------

# Point the preview at the highlighted row: fade the termlings occluding it and
# let _process pan the camera onto it. Camera is restored on Esc, kept on Enter.
func _preview_selected() -> void:
	if _search_sel < 0 or _search_sel >= _search_rows.size():
		return
	var id := int(_search_rows[_search_sel].id)
	if not _groups.has(id):
		return
	_search_preview_id = id
	var target = _groups[id]
	for oid in _groups:
		var g = _groups[oid]
		g.terminal.set_dimmed(SEARCH_DIM if oid != id and _occludes(g, target) else 1.0)


func _clear_preview() -> void:
	_search_preview_id = -1
	for oid in _groups:
		_groups[oid].terminal.set_dimmed(1.0)


func _term_rect(g: Node2D) -> Rect2:
	var sz: Vector2 = g.terminal.onscreen_size()
	return Rect2(g.terminal.global_position - sz * 0.5, sz)


# a occludes target if it draws in front (greater y in the world's y-sort) and
# its on-screen quad overlaps the target's.
func _occludes(a: Node2D, target: Node2D) -> bool:
	if a.terminal.global_position.y <= target.terminal.global_position.y:
		return false
	return _term_rect(a).intersects(_term_rect(target))


# While the camera is tracking a termling, fade *only* the termlings drawing in
# front of it, so a wanderer crossing the foreground never hides what you're
# watching. The search overlay owns the dimming while it's open, so we defer to it.
func _update_occluder_fade(delta: float) -> void:
	if _search_open:
		return
	if _tracking_id != -1 and _groups.has(_tracking_id):
		var target: Node2D = _groups[_tracking_id]
		for oid in _groups:
			var g: Node2D = _groups[oid]
			var hide: bool = oid != _tracking_id and _occludes(g, target)
			g.terminal.ease_dim(TRACK_DIM if hide else 1.0, delta)
		_occ_fading = true
	elif _occ_fading:
		# Not tracking any more: ease everyone back to fully opaque, then settle.
		var still_fading := false
		for oid in _groups:
			var t = _groups[oid].terminal
			t.ease_dim(1.0, delta)
			if t.screen.modulate.a < 0.99:
				still_fading = true
		_occ_fading = still_fading


# Ask cove-find (Anthropic API) to resolve the query. Fire-and-forget: it writes
# find-result.json, which _poll_search picks up. Runs off the main thread so the
# ~1-2s round trip never stalls the app.
func _run_semantic_search() -> void:
	var q := _search_edit.text.strip_edges()
	if q == "":
		return
	var res_path := DIR + "/find-result.json"
	if FileAccess.file_exists(res_path):
		DirAccess.remove_absolute(res_path)  # drop any stale answer
	_search_awaiting = q
	_search_poll = 0.0
	_search_hint.text = "✨ finding…"
	var script := ProjectSettings.globalize_path("res://mcp/cove_find.py")
	OS.create_process("/usr/bin/python3", [script, "--json", q])


func _poll_search(delta: float) -> void:
	if not _search_open or _search_awaiting == "":
		return
	_search_poll += delta
	if _search_poll < 0.15:
		return
	_search_poll = 0.0
	var path := DIR + "/find-result.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var res = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(res) != TYPE_DICTIONARY or str(res.get("query", "")) != _search_awaiting:
		return   # stale, partial, or a different query
	_search_awaiting = ""
	_search_hint.text = SEARCH_HINT
	var rows := []
	for r in res.get("ranked", []):
		if typeof(r) == TYPE_DICTIONARY and _groups.has(int(r.get("id", -1))):
			rows.append({"id": int(r.get("id")), "why": str(r.get("why", ""))})
	if rows.is_empty() and res.get("id") != null and _groups.has(int(res.get("id"))):
		rows.append({"id": int(res.get("id")), "why": str(res.get("why", ""))})
	_search_sel = 0
	if rows.is_empty():
		_search_hint.text = "✨ no match: " + str(res.get("why", "")).left(40)
	_render_search(rows)


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
