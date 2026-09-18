# Walking Terminals -- Godot host. See godot/DESIGN.md.
#
# A top-down 2.5D stage: each live terminal (published by hacked kitty) is hauled
# around by two little carriers (Sarah) on a ground panel, with soft shadows.
#   - the groups wander freely
#   - click a terminal to focus it, then type (keyboard -> focused shell)
#   - press-drag a terminal to slide it around the ground; on the focused one a
#     drag selects its text instead, and press-and-hold (HOLD_MS) lifts it to move
#   - Cmd+C copies the selection, Cmd+V pastes (an image-only clipboard is
#     forwarded as ^V so agents read the image off the system pasteboard)
#   - drag a termling off the window edge and release on the desktop: it leaves
#     the cove and becomes a normal kitty window (drag that window back onto
#     the Cove to re-adopt it). Release over another Mac's Cove instead and
#     Universal Control hands it over. Hold Alt to relocate freely, even
#     off-screen, without sending
#   - the ground is a tldraw-style board (see "the board" at the bottom): with
#     no termling focused, V/R/O/A/T/N/F/D/E... draw boxes, arrows, text, sticky
#     notes, frames and todo lists. Drop a termling in a frame/box to zone it
#   - Cmd/Ctrl+N spawns another terminal
#   - Cmd+' steps through the notifications (Enter focuses, any other key goes back)
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
var _hold_armed := false       # a select-press held still for HOLD_MS lifts the termling instead
var _press_ms := 0
const HOLD_MS := 250
const LIFT_THRESHOLD := 10.0
const SELECT_DEADZONE := 3.0
const MIN_ZOOM := 0.35
const MAX_ZOOM := 3.0
const TRACK_DIM := 0.18       # alpha for termlings occluding the tracked one

# Cmd+N: size the new termling to the view + follow it. Triple-click a termling
# to "present" it — zoom the camera so it fills the whole cove window.
var _spawn_follow := false     # next brand-new termling: fit it to the view + follow
var _fit_pending := {}         # term_id -> true: resize to fill the view once its cells are known
var _click_streak := 0         # consecutive quick clicks on the same termling
var _click_last_ms := 0
var _click_last_id := -1
var _present_id := -1          # term id currently presented full-window, or -1
var _present_zoom := 0.0       # camera zoom that fits the presented termling
var _present_prev_zoom := 0.0  # zoom to swoop back to when leaving present mode
var _present_leaving := false  # animating the zoom back after leaving present mode
var _present_lock := 0.0       # 0->1 ramp from swooping onto the presented termling to gluing to it
const PRESENT_MAX_ZOOM := 8.0  # present mode may zoom past MAX_ZOOM to fill the window
const VIEW_FILL := 0.92        # fraction of the window a fitted/presented termling spans
const USER_LAYOUT := "user://cove-layout.json"  # durable name/pos-by-session (survives a cold start)
var _durable_accum := 0.0

# input transport
var _sock: RefCounted = null
var _input_tries := 0

# cross-Mac termling handoff (native OS drag over Universal Control)
var _drag: RefCounted = null   # CoveDrag extension
var _inflight_id := -1         # term_id currently being dragged out (dimmed), or -1
var _self_drop := false        # the in-flight drag was dropped back onto this Cove
var _ghost: Label = null       # landing ghost shown while an inbound drag hovers
const HANDOFF_EDGE_PX := 26.0  # drag a lifted termling this close to a window edge to fling it

# drag-out / drag-in (detach a termling to the desktop, adopt it back)
var _evt_accum := 0.0          # pump cadence for kitty's events.jsonl
var _pending_place := {}       # term_id -> world pos for a termling adopted at the cursor
var _land_queue: Array = []    # world positions for the next landed handoff drops

# agent state / control channel / notifications
var _ls_thread: Thread
var _ls_mutex: Mutex
var _ls_data := {}            # pane_id -> {agent, busy, attention, cwd}
var _ls_run := true
var _child_mutex := Mutex.new()
var _child_pids: Array[int] = []
var _state_accum := 0.0
var _cmd_accum := 0.0
var _follows := {}           # follower term_id -> target term_id
# Zones: a termling lives in a frame or box on the board once you drop it there.
# It wanders inside and moves with the shape; drop it on open ground to set it
# loose. Placement is yours: an agent can at most put itself in a named frame
# (the assign command).
var _zone_of := {}           # term_id -> board shape id it lives in ("" = loose; absent = not restored yet)
var _zone_saved := {}        # term_id -> container ref from the last run (sessionless termlings only)
var _zone_by_session := {}   # abduco session -> container ref (shape id, or a legacy zone name)
var _legacy_zones := []      # pinned regions from an older state.json, turned into frames once
var _notes := []             # [{project, event, term_id, ts}]
# "Needs you" queue (Attention.gd): a ping focuses the termling only if nothing
# has focus and you're zoomed out (_ping); else it waits in the queue and the
# notifications panel, and Cmd+' steps through them.
const CoveAttentionScript := preload("res://scripts/Attention.gd")
var _attention = CoveAttentionScript.new()
var _kitty_attn := {}        # term_id -> true: kitty's needs_attention flag, to ping on its rising edge
var _attn_live := false      # the saved focus/queue is restored; kitty-flag pings may now fire
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
var _preview_id := -1  # termling the camera is previewing while stepping
var _preview_return_cam := Vector2.ZERO  # camera to restore if the search is escaped
var _cam_return := false       # true while swooping the camera back after an Esc
var _preview_return_zoom := 0.0 # camera zoom to restore if the search is escaped
var _zoom_goal := 0.0          # zoom to ease toward outside present mode (0 = none)
var _fly_id := -1              # termling the camera is flying onto (pan + zoom as one), or -1
var _fly_t := 0.0              # 0->1 progress of that flight
var _fly_z0 := 1.0             # zoom at take-off
var _fly_z1 := 1.0             # zoom on landing
var _fly_off := Vector2.ZERO   # target's on-screen offset from centre at take-off
const FLY_TIME := 0.45         # seconds per camera flight
var _track_lock := 0.0         # 0->1 ramp from easing onto the tracked termling to gluing to it
var _track_of := -1            # which termling that ramp belongs to
const SEARCH_HINT := "↵ jump  ·  ⇥ ✨ ask AI  ·  esc"
const SEARCH_DIM := 0.2       # alpha for termlings occluding the previewed one

# radial jump (Cmd+J): hop the preview between termlings by direction
var _radial_open := false
var _radial_layer: Control     # full-window holder for the waypoint markers
var _radial_title: Label
var _radial_hint: Label
var _radial_centre := -1       # termling the wheel is centred on (hjkl hop from here)
var _radial_markers := {}      # term id -> Button waypoint
var _radial_keys := {}         # "h"/"j"/"k"/"l" -> term id that key hops to
var _radial_ring: Array = []   # proximity order frozen at open, walked by Tab
var _radial_hover := -1        # marker under the mouse (layout holds still while hovered)
const RADIAL_MAX := 10         # nearest termlings shown as waypoints
const RADIAL_FILL := 0.45      # the previewed termling fits this much of the window, inside the ring
const RADIAL_FONT := 24        # marker label size (title and hint scale off it)
var _radial_axes := Vector2.ZERO  # on-screen semi-axes of the ring (0 = not laid out)
var _radial_dots: Array = []   # [screen point, keyed?] true-bearing ticks drawn on the ring
const RADIAL_HINT := "hjkl / arrows hop  ·  ⇥ next nearest  ·  ↵ or click jump  ·  esc back"
const RADIAL_DIRS := {"h": Vector2.LEFT, "j": Vector2.DOWN, "k": Vector2.UP, "l": Vector2.RIGHT}
const RADIAL_ARROWS := {"h": "◂", "j": "▾", "k": "▴", "l": "▸"}

# avy jump (Cmd+;): big letter labels on every visible termling; type one to jump
var _avy_open := false
var _avy_layer: Control
var _avy_hint: Label
var _avy_labels := {}          # label string -> term id
var _avy_nodes := {}           # term id -> Label drawn over it
var _avy_prefix := ""          # keys typed so far (two-letter labels only)
var _avy_cam := Vector2.ZERO   # camera goal while the labels are up
var _avy_zoom := 1.0           # zoom goal while the labels are up
const AVY_KEYS := "asdfghjklqwertyuiopzxcvbnm"   # home row first, like avy
const AVY_NEAR := 6            # zoom out (if needed) until this many nearby termlings fit

# stepping notifications (Cmd+'): preview each one in turn, Enter focuses
var _notif_open := false
var _notif_ids: Array = []     # termlings with a notification, panel order, frozen at open
var _notif_idx := 0            # the one being previewed

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
	_write_durable()   # capture the latest names/positions before we go
	if _bd_save_in >= 0.0:
		_bd_save_now()   # the board saves on a debounce; flush a pending save


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

	# The board: shapes painted above the ground, below the termlings.
	_bd_setup()

	_world = Node2D.new()
	_world.y_sort_enabled = true
	add_child(_world)


func _process(delta: float) -> void:
	# _restore_window()'s window_set_mode can pump a re-entrant _process from
	# inside _ready, before the world/camera exist. Wait until setup is done.
	if _world == null or _cam == null:
		return
	_rescan_accum += delta
	if _rescan_accum > 0.4:
		_rescan_accum = 0.0
		_reap_children()
		_reconcile()
		_apply_zones()
	if _sock != null and not _sock.call("is_connected") and _input_tries < 100:
		_try_connect_sock()
	_apply_agent_state()
	_apply_follows()
	_poll_handoff()
	_poll_hold()
	_pump_commands(delta)
	_pump_notify()
	_pump_events(delta)
	_poll_search(delta)
	_bd_tick(delta)
	_state_accum += delta
	if _state_accum > 0.2:
		_state_accum = 0.0
		_write_state()
	_durable_accum += delta
	if _durable_accum > 3.0:
		_durable_accum = 0.0
		_write_durable()   # session-keyed name/pos mirror that survives a cold restart
	_apply_fits(delta)
	# While previewing (search hit or radial jump) the camera swoops onto it;
	# otherwise it follows the tracked terminal (double-click / committed jump).
	# Track the terminal's centre, not the group's ground point (well below it).
	if _fly_id != -1:
		# Deferred (like present mode): after this frame's bob, so a termling we're
		# flying onto holds still instead of juddering against a camera a frame behind.
		_fly_step.call_deferred(delta)   # owns pan *and* zoom until it lands; then tracking (or the preview) takes over
	elif _previewing():
		_cam.position = _cam.position.lerp(_groups[_preview_id].terminal.global_position, 8.0 * delta)
	elif _avy_open:
		_cam.position = _cam.position.lerp(_avy_cam, 8.0 * delta)
	elif _present_id != -1 and _groups.has(_present_id):
		_present_lock = minf(_present_lock + 3.0 * delta, 1.0)
		_snap_present_cam.call_deferred(delta)   # after this frame's bob is applied
	elif _tracking_id != -1 and _groups.has(_tracking_id) \
			and not (_moving and _press_group != null and _press_group.term_id == _tracking_id):
		# (paused while dragging it: a chasing camera drags the cursor's world point along)
		if _track_of != _tracking_id:
			_track_of = _tracking_id   # a fresh target eases in rather than snapping
			_track_lock = 0.0
		_track_lock = minf(_track_lock + 3.0 * delta, 1.0)
		_snap_track_cam.call_deferred(delta)   # after this frame's bob is applied
	elif _cam_return:
		_cam.position = _cam.position.lerp(_preview_return_cam, 8.0 * delta)
		if _cam.position.distance_to(_preview_return_cam) < 2.0:
			_cam_return = false
	# Present ("fill the window") mode: zoom the camera so the presented termling
	# spans the whole window; leaving swoops the zoom back to where it was.
	# Previewing fits the previewed termling instead: exactly in present mode,
	# otherwise zooming out only as far as needed so a big termling isn't clipped.
	if _fly_id != -1:
		pass   # the flight owns the zoom
	elif _previewing():
		# The radial jump always fits smaller, so its ring has room around the termling.
		# Stepping notifications zooms onto each one (in or out) so it's readable.
		if _notif_open:
			_ease_zoom(_fit_zoom_for(_groups[_preview_id], ATTEND_FILL), delta)
		else:
			var fit := _fit_zoom_for(_groups[_preview_id], RADIAL_FILL if _radial_open else VIEW_FILL)
			_ease_zoom(fit if _present_id != -1 or _radial_open else minf(_preview_return_zoom, fit), delta)
	elif _avy_open:
		_ease_zoom(_avy_zoom, delta)
	elif _present_id != -1:
		if _groups.has(_present_id):
			_present_zoom = _fit_zoom_for(_groups[_present_id])
			var z := lerpf(_cam.zoom.x, _present_zoom, 8.0 * delta)
			_cam.zoom = Vector2(z, z)
		else:
			_leave_present()   # the presented termling went away
	elif _present_leaving:
		var z := lerpf(_cam.zoom.x, _present_prev_zoom, 8.0 * delta)
		_cam.zoom = Vector2(z, z)
		if absf(z - _present_prev_zoom) < 0.003:
			_cam.zoom = Vector2(_present_prev_zoom, _present_prev_zoom)
			_present_leaving = false
	elif _zoom_goal > 0.0:
		_ease_zoom(_zoom_goal, delta)
		if absf(_cam.zoom.x - _zoom_goal) < 0.003:
			_cam.zoom = Vector2(_zoom_goal, _zoom_goal)
			_zoom_goal = 0.0
	_update_occluder_fade(delta)
	if _radial_open:
		_radial_layout()   # markers ride the camera as the preview swoops
	if _avy_open:
		_avy_layout()      # labels ride the camera as it zooms out
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
	if _pending_place.has(id):
		# Adopted from the desktop: appear right where it was dropped.
		g.position = _pending_place[id]
		_pending_place.erase(id)
		_pos_restored[id] = true
	elif not _land_queue.is_empty():
		# A handed-off termling landed here: appear under the drop point.
		g.position = _land_queue.pop_front()
		_pos_restored[id] = true
	elif _saved.get("pos", {}).has(id):
		# Restore where it was on the previous run (hot-reload keeps positions).
		var p = _saved["pos"][id]
		g.position = Vector2(p[0], p[1])
		_pos_restored[id] = true
	else:
		# Spawn near the camera so new terminals appear in view, then they wander off.
		var center := _cam.position if _cam else Vector2.ZERO
		var n := _groups.size()
		g.position = center + Vector2(cos(n * 2.4) * (150.0 + 55.0 * n), sin(n * 2.4) * (120.0 + 45.0 * n))
		if _spawn_follow:
			# Cmd+N: this fresh termling gets framed by the camera and followed.
			_spawn_follow = false
			g.position = center
			_fit_pending[id] = true
	_world.add_child(g)
	g.setup(id, "%s/term-%d.rgba" % [DIR, id], _bounds)
	if _names.has(id):
		g.terminal.set_custom_name(_names[id])
	_groups[id] = g
	if _fit_pending.has(id):
		_set_focus(id)
		_tracking_id = id   # glue the camera to the new termling
	elif _focused_id == -1:
		_set_focus(id, false)


func _remove_group(id: int) -> void:
	if _groups.has(id):
		_groups[id].queue_free()
		_groups.erase(id)
	_zone_of.erase(id)
	_attention.remove(id)
	if _focused_id == id:
		_focused_id = -1
		for other in _groups:
			_set_focus(other, false)
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
	# Snapshot the termling as the drag image: the extension reads the live IOSurface
	# when it can, else this PNG of the current frame, else a text chip as last resort.
	var native: Vector2i = g.terminal.native_size()
	var snap: String = g.terminal.snapshot_png("%s/drag-%d.png" % [DIR, id])
	if not _drag.call("begin_drag", _build_handoff_payload(g), label,
			g.terminal.iosurface_id, native.x, native.y, snap):
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
		if _self_drop:
			_cancel_inflight()   # dropped back onto this Cove: it just stays
		elif bool(ended.get("accepted", false)):
			_close_origin(_inflight_id)
		elif not bool(ended.get("inside_self", false)) and ended.has("sx"):
			# Released on the desktop (no Cove took it): the termling leaves the
			# cove and becomes a normal kitty window right there.
			_detach_inflight(ended)
		else:
			_cancel_inflight()
		_inflight_id = -1
		_self_drop = false
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
	# Our own in-flight termling dropped back onto this same Cove: don't clone
	# it, just keep it here (_poll_handoff sees _self_drop and cancels).
	var tid := int(data.get("term_id", -1))
	if _inflight_id != -1 and tid == _inflight_id and _groups.has(tid):
		_self_drop = true
		return
	var agent := str(data.get("agent", "shell"))
	var sid := str(data.get("sid", ""))
	var cwd := str(data.get("cwd", ""))
	var name := str(data.get("name", ""))
	if kitten_exe == "":
		push_warning("cove: landed a termling but no kitten to launch it")
		return
	# Remember where it landed so the new termling appears under the drop point.
	var view := Vector2(float(drop.get("x", 0.0)), float(drop.get("y", 0.0)))
	_land_queue.append(get_viewport().get_canvas_transform().affine_inverse() * view)
	var land := ProjectSettings.globalize_path("res://cove-handoff-land.sh")
	var args := ["@", "--to", kitty_socket, "launch", "--type=os-window", "--keep-focus"]
	if cwd != "":
		args.append_array(["--cwd", cwd])
	if name != "":
		args.append_array(["--title", name])
	args.append_array([land, agent, sid])
	_create_process(kitten_exe, args, false)
	print("cove: landed %s termling (sid=%s) in %s" % [agent, sid if sid != "" else "-", cwd])


func _cancel_inflight() -> void:
	# The drag was released over nothing; the termling stays put. Un-dim it.
	if _inflight_id != -1 and _groups.has(_inflight_id):
		_groups[_inflight_id].modulate = Color(1, 1, 1, 1)
		_groups[_inflight_id].drop()


# Drag-out: the OS drag ended on the desktop, so the termling leaves the cove.
# Kitty un-hides its real window centred on the release point ((sx, sy), Cocoa
# screen coords straight from the drag session) and stops exporting its frame;
# _reconcile() removes the termling once the term file vanishes.
func _detach_inflight(ended: Dictionary) -> void:
	var id := _inflight_id
	if id == -1:
		return
	if _sock == null or not _sock.call("is_connected") \
			or not _sock.call("send_detach", id, int(ended.get("sx", 0.0)), int(ended.get("sy", 0.0))):
		push_warning("cove: detach of termling %d failed (no input socket?)" % id)
		_cancel_inflight()
		return
	# Carry the termling's name onto the desktop window's title bar (sticky, so the
	# shell/agent can't overwrite it). Drag it back in and the name returns with it,
	# since the term_id is preserved and _names[id] still holds it.
	var nm := _handoff_name(id)
	if nm != "" and kitten_exe != "" and _groups.has(id):
		var pane: int = _groups[id].terminal.pane_id
		if pane != 0:
			_create_process(kitten_exe, ["@", "--to", kitty_socket, "set-window-title",
				"--match", "id:%d" % pane, nm], false)
	print("cove: termling %d left the cove for the desktop" % id)


# Drag-in: kitty appends events to events.jsonl when a native kitty window is
# dropped back onto the Cove ("adopted"). The window keeps its os-window id, so
# the reborn termling is placed under the cursor (where the drop happened).
func _pump_events(delta: float) -> void:
	_evt_accum += delta
	if _evt_accum < 0.1:
		return
	_evt_accum = 0.0
	var path := DIR + "/events.jsonl"
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
		var e = JSON.parse_string(line)
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if str(e.get("event", "")) == "adopted":
			var id := int(e.get("term_id", -1))
			var pos := _world_mouse()   # the drop just happened under the cursor
			if _groups.has(id):
				_groups[id].position = pos
			else:
				_pending_place[id] = pos
			print("cove: adopted os-window %d back into the cove" % id)


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
			_create_process(kitten_exe, ["@", "--to", kitty_socket, "close-window",
				"--match", "id:%d" % pane], false)
	var sess := str(_sessions.get(id, ""))
	if sess != "":
		_create_process("/usr/bin/pkill", ["-f", "abduco -A %s " % sess], false)
	_remove_group(id)


# dismiss: this is you attending to it, so its notification goes. Focus that
# isn't you (a ping taking the camera, a drag, restoring after a reload) keeps it.
func _set_focus(id: int, dismiss := true) -> void:
	_focused_id = id
	for oid in _groups:
		_groups[oid].terminal.set_focused(oid == id)
	if id != -1:
		_bd_stop_edit()   # a termling took the keyboard: the board lets go
		_bd_sel = []
	_bd_update_hint()
	if dismiss:
		_dismiss_note(id)


# You attended to a terminal: clear its "needs you" note and queue entry.
func _dismiss_note(id: int) -> void:
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
	_attention.on_focus(id)


# Frontmost termling under world_pos. Ones faded out of the way (in front of the
# tracked termling) are see-through to clicks when something solid is behind.
func _group_at(world_pos: Vector2) -> Node2D:
	var best: Node2D = null
	var best_faded: Node2D = null
	for id in _groups:
		var g: Node2D = _groups[id]
		if g.terminal.contains_point(world_pos):
			if g.terminal.screen.modulate.a < 0.5:
				if best_faded == null or g.position.y > best_faded.position.y:
					best_faded = g
			elif best == null or g.position.y > best.position.y:
				best = g
	return best if best != null else best_faded


func _is_modifier_key(kc: int) -> bool:
	return kc in [KEY_META, KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_CAPSLOCK]


# Cycle focus to the next nearby terminal. On the first press of a run the ring
# is frozen: terminals sorted by distance to the currently focused one (itself
# first), so taps march outward through the neighbours. Subsequent taps just
# advance the index; the run ends when any other input arrives.
func _cycle_focus(dir := 1) -> void:
	if _groups.size() <= 1:
		return
	if not _cycle_active or _cycle_order.size() != _groups.size():
		_cycle_order = _attention.rank(_order_by_proximity(_focused_id))   # waiting termlings first
		_cycle_idx = maxi(_cycle_order.find(_focused_id), 0)
		_cycle_active = true
	# Step (dir = +1 outward, -1 back) to the next still-present terminal in the ring.
	for _i in _cycle_order.size():
		_cycle_idx = posmod(_cycle_idx + dir, _cycle_order.size())
		var target: int = _cycle_order[_cycle_idx]
		if _groups.has(target):
			# keep the camera glued if we were following, otherwise glide over to it
			_jump_focus(target, _tracking_id != -1)
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
	# The radial jump owns the keyboard while it's up (nothing types into a terminal),
	# but never steals keys from a board label being edited.
	if _radial_open and _bd_edit_id == "":
		_radial_key(event)
		get_viewport().set_input_as_handled()
		return
	# Likewise the avy jump: every key is a label letter (or Esc / Backspace).
	if _avy_open and _bd_edit_id == "":
		_avy_key(event)
		get_viewport().set_input_as_handled()
		return
	# Stepping notifications: Cmd+' / Tab / arrows step, Enter focuses, and any
	# other key is swallowed and swoops back to where you started.
	if _notif_open and _bd_edit_id == "":
		_notif_key(event)
		get_viewport().set_input_as_handled()
		return
	# While the rename dialog is open, Esc cancels it and other keys go to it.
	if _rename_id != -1:
		if event.keycode == KEY_ESCAPE:
			_close_rename()
			get_viewport().set_input_as_handled()
		return
	# While a board label is being edited every key is the editor's; Esc or
	# Cmd+Enter finishes it.
	if _bd_edit_id != "":
		if event.keycode == KEY_ESCAPE or (event.keycode in [KEY_ENTER, KEY_KP_ENTER] and event.meta_pressed):
			_bd_stop_edit()
			get_viewport().set_input_as_handled()
		return
	# Esc leaves "present" (full-window) mode, swooping the camera back.
	if event.keycode == KEY_ESCAPE and _present_id != -1:
		_leave_present()
		get_viewport().set_input_as_handled()
		return
	# With no termling focused, keys drive the board (tldraw's shortcuts). Cmd+N,
	# Cmd+F and Ctrl+` aren't board keys, so they fall through to the chords below.
	if (_focused_id == -1 or not _groups.has(_focused_id)) and _bd_key(event):
		get_viewport().set_input_as_handled()
		return
	# Cmd+C / Cmd+V: clipboard in and out of the focused termling. Copy grabs
	# kitty's current selection (drag-select while tracking, see _send_select);
	# paste routes through kitty so bracketed paste works, and an image-only
	# clipboard is forwarded as ^V so agents (Claude Code) read the image from
	# the system pasteboard themselves.
	if event.keycode == KEY_C and event.meta_pressed and not event.ctrl_pressed:
		_copy_focused()
		get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_V and event.meta_pressed and not event.ctrl_pressed:
		_paste_focused()
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
	# Ctrl+Tab / Ctrl+Shift+Tab -> quick flip to the next / previous nearby termling
	# (same ring as Ctrl+`). Terminals can't tell Ctrl+Tab from Tab, so none is lost.
	if event.keycode == KEY_TAB and event.ctrl_pressed and not event.meta_pressed:
		_cycle_focus(-1 if event.shift_pressed else 1)
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
	# Cmd+J opens the radial jump (hjkl between nearby termlings, Enter to go).
	if event.keycode == KEY_J and event.meta_pressed and not event.ctrl_pressed:
		_open_radial()
		get_viewport().set_input_as_handled()
		return
	# Cmd+; opens the avy jump (like avy's C-;): type a termling's label to go there.
	if event.keycode == KEY_SEMICOLON and event.meta_pressed and not event.ctrl_pressed:
		_open_avy()
		get_viewport().set_input_as_handled()
		return
	# Cmd+' steps through the notifications (camera only until you press Enter).
	if _is_apostrophe(event) and event.meta_pressed and not event.ctrl_pressed:
		_open_notif()
		get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_N and (event.meta_pressed or event.ctrl_pressed):
		_spawn_follow = true   # the next fresh termling is framed by the camera + followed
		_spawn_terminal()
		get_viewport().set_input_as_handled()


func _world_mouse() -> Vector2:
	return get_global_mouse_position()


# Start sliding the pressed termling along the ground. can_send: the drag may
# fling it off the window edge (plain drag); Alt-drag only relocates.
func _begin_move(can_send: bool) -> void:
	_set_focus(_press_group.term_id, false)   # moving it isn't attending to it
	_moving = true
	_move_can_send = can_send
	_move_grab = _press_group.get_ground_pos() - _press_world
	_press_group.begin_drag_move()


# A select-press held still for HOLD_MS lifts the termling: the drag that
# follows moves it instead of selecting. Motion never arrives while the mouse
# is still, so this runs from _process.
func _poll_hold() -> void:
	if not _hold_armed or _press_group == null or _sel_started:
		return
	if Time.get_ticks_msec() - _press_ms < HOLD_MS:
		return
	_hold_armed = false
	_selecting = false
	_begin_move(true)
	_press_group.pickup_hop()


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
		# A click out in the world (not on a marker) takes over from the radial jump.
		if _radial_open and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_close_radial(false)
		if _avy_open and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_close_avy(false)
		# While stepping notifications, a click on the one being shown focuses it
		# (like Enter); a click anywhere else takes over.
		if _notif_open and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var pid := _preview_id
			if _groups.has(pid) and _groups[pid].terminal.contains_point(_world_mouse()):
				_notif_commit(pid)
				get_viewport().set_input_as_handled()
				return
			_close_notif(false)
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
		# Right button: rename the terminal under the cursor; anywhere else, the
		# board's context menu.
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			var g := _group_at(wpos)
			if g != null:
				_open_rename(g)
			else:
				_bd_context_menu(wpos, event.position)
			return
		# Middle button: pan.
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
			if event.pressed:
				_tracking_id = -1  # manual pan cancels camera follow
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			# The board takes presses that aren't for a termling (see _bd_wants_press),
			# and the drag + release that follow go to it too.
			if event.pressed:
				_bd_stop_edit()   # a click outside the label editor finishes the edit
				var over := _group_at(wpos)
				if _bd_wants_press(wpos, over != null):
					_bd_gesture = true
					if over == null and _present_id != -1:
						_leave_present()
					_bd_pointer_down(wpos, event)
					return
			elif _bd_gesture:
				_bd_gesture = false
				_bd_pointer_up(wpos, event)
				return
			if event.pressed:
				_press_group = _group_at(wpos)
				_press_pos = event.position
				_press_world = wpos
				_sel_started = false
				# Drag semantics on a termling: on the focused (or tracked) one a drag
				# selects its text, but press-and-hold still for HOLD_MS lifts it so the
				# drag moves it instead. A drag on any other termling moves it straight
				# away, and Alt-drag always moves.
				_selecting = _press_group != null and not event.alt_pressed and not event.double_click \
					and (_press_group.term_id == _focused_id or _press_group.term_id == _tracking_id)
				_hold_armed = _selecting and _press_group.term_id != _present_id  # a presented one stays put
				_press_ms = Time.get_ticks_msec()
				_lifting = false
				_moving = false
				_panning = false   # empty ground belongs to the board now (space/hand/middle pan)
				if event.double_click and _press_group != null:
					_set_focus(_press_group.term_id)
					_tracking_id = _press_group.term_id  # double-click: focus + follow
				# Triple-click a termling -> present it full-window (click again or Esc
				# to leave). A click on empty ground also leaves present mode.
				var now_ms := Time.get_ticks_msec()
				var gid: int = _press_group.term_id if _press_group != null else -1
				if gid != -1 and gid == _click_last_id and now_ms - _click_last_ms < 450:
					_click_streak += 1
				else:
					_click_streak = 1
				_click_last_id = gid
				_click_last_ms = now_ms
				if gid != -1 and _click_streak >= 3:
					_toggle_present(_press_group)
					_click_streak = 0
					_hold_armed = false
				elif gid == -1 and _present_id != -1:
					_leave_present()
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
				_hold_armed = false
				_panning = false
	elif event is InputEventMouseMotion:
		if _bd_gesture:
			_bd_pointer_move(_world_mouse(), event)
		elif _selecting and _press_group != null:
			# Begin selecting once past the deadzone so a plain click still just
			# focuses; anchor at the press cell, then track the cursor as we drag.
			if not _sel_started and event.position.distance_to(_press_pos) > SELECT_DEADZONE:
				_sel_started = true
				_hold_armed = false
				_send_select(_press_group, _press_world, 0)  # start at the anchor cell
			if _sel_started:
				_send_select(_press_group, _world_mouse(), 1)  # drag update
		elif _press_group != null:
			# A drag slides the termling along the ground. A plain drag can fling
			# it off the window edge to the other Mac (Universal Control carries
			# it); holding Alt relocates freely — even off-screen — without sending.
			if not _moving and event.position.distance_to(_press_pos) > LIFT_THRESHOLD:
				_begin_move(not event.alt_pressed)
			if _moving:
				_press_group.set_drag_pos(_world_mouse() + _move_grab)
				if _move_can_send and _near_window_edge(event.position):
					_try_begin_handoff()
		elif _panning:
			_cam.position -= event.relative / _cam.zoom
	elif event is InputEventPanGesture:
		# macOS trackpad two-finger scroll. Over a terminal: plain scroll goes
		# into the terminal, Cmd/Ctrl+scroll resizes it (in cell steps). Over
		# empty ground, as in tldraw: pan, or zoom with Cmd/Ctrl (pinch zooms
		# too). Wheel events don't fire for trackpads, so this is the only
		# scroll path on macOS.
		var g := _group_at(_world_mouse())
		if g == null:
			if event.meta_pressed or event.ctrl_pressed:
				_zoom_by(pow(1.08, -event.delta.y))
			else:
				_cam.position += event.delta * 18.0 / _cam.zoom.x
				_bd_camera_changed()
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
	elif event is InputEventKey:
		if _bd_edit_id != "":
			return
		if not event.pressed:
			_bd_key_released(event)
		elif _focused_id == -1 or not _groups.has(_focused_id):
			# No termling has the keyboard: repeats (held arrows) nudge on the board.
			if _bd_key(event):
				get_viewport().set_input_as_handled()
		else:
			# Accept echo (OS auto-repeat) here so holding a key repeats into the
			# shell -- only the chord handling in _input() filters echoes out.
			_on_key(event)


# Zoom the camera toward the cursor by a multiplicative factor (>1 zooms in).
func _zoom_by(factor: float) -> void:
	# A manual zoom abandons present mode, keeping the zoom the user is dialling in.
	_present_id = -1
	_present_leaving = false
	_zoom_goal = 0.0
	_fly_id = -1   # a manual zoom cancels any camera flight
	var before := _cam.get_global_mouse_position()
	# (from past MAX_ZOOM, after a present or a notification jump, zoom out smoothly
	# rather than snapping back to MAX_ZOOM)
	var z := clampf(_cam.zoom.x * factor, MIN_ZOOM, maxf(MAX_ZOOM, _cam.zoom.x))
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


# ESC [ X, or ESC [ 1 ; mod X when modified (xterm-style).
func _csi_letter(final: String, mod: int) -> PackedByteArray:
	var s := "[" + final if mod == 1 else "[1;%d%s" % [mod, final]
	return (String.chr(27) + s).to_ascii_buffer()


# ESC [ n ~, or ESC [ n ; mod ~ when modified.
func _csi_tilde(n: int, mod: int) -> PackedByteArray:
	var s := "[%d~" % n if mod == 1 else "[%d;%d~" % [n, mod]
	return (String.chr(27) + s).to_ascii_buffer()


# Cove sends finished bytes straight to the pty (MSG_PTY), bypassing kitty's key
# encoder, so modifiers must be encoded here or they're silently lost.
func _encode_key(event: InputEventKey) -> PackedByteArray:
	var kc := event.keycode
	# xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl
	var mod := 1 + int(event.shift_pressed) + 2 * int(event.alt_pressed) + 4 * int(event.ctrl_pressed)
	match kc:
		KEY_ENTER, KEY_KP_ENTER:
			return PackedByteArray([27, 13]) if event.alt_pressed else PackedByteArray([13])
		KEY_BACKSPACE:
			return PackedByteArray([27, 127]) if event.alt_pressed else PackedByteArray([127])
		KEY_TAB:
			# Shift+Tab = back-tab (CSI Z); Claude Code cycles modes on it.
			return PackedByteArray([27, 91, 90]) if event.shift_pressed else PackedByteArray([9])
		KEY_ESCAPE: return PackedByteArray([27])
		KEY_UP: return _csi_letter("A", mod)
		KEY_DOWN: return _csi_letter("B", mod)
		KEY_RIGHT: return _csi_letter("C", mod)
		KEY_LEFT: return _csi_letter("D", mod)
		KEY_HOME: return _csi_letter("H", mod)
		KEY_END: return _csi_letter("F", mod)
		KEY_PAGEUP: return _csi_tilde(5, mod)
		KEY_PAGEDOWN: return _csi_tilde(6, mod)
		KEY_DELETE: return _csi_tilde(3, mod)
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
		_create_process(kitten_exe, ["@", "--to", kitty_socket, "send-text",
			"--match", "id:%d" % pane, data.get_string_from_utf8()], false)


func _focused_pane() -> int:
	if _focused_id == -1 or not _groups.has(_focused_id):
		return 0
	return _groups[_focused_id].terminal.pane_id


# Cmd+C: copy the focused terminal's current selection to the system clipboard.
# Runs through `kitten @ action` so kitty's own copy machinery does the work.
func _copy_focused() -> void:
	var pane := _focused_pane()
	if pane == 0 or kitten_exe == "":
		return
	_create_process(kitten_exe, ["@", "--to", kitty_socket, "action",
		"--match", "id:%d" % pane, "copy_to_clipboard"], false)


# Cmd+V: paste the system clipboard into the focused terminal. Text goes
# through kitty's paste_from_clipboard (bracketed-paste aware, so agents and
# editors see one paste, not keystrokes). An image-only clipboard becomes a ^V
# keypress: agents like Claude Code react to it by reading the image straight
# off the shared system pasteboard.
func _paste_focused() -> void:
	var pane := _focused_pane()
	if pane == 0:
		return
	if DisplayServer.clipboard_has():
		if kitten_exe != "":
			_create_process(kitten_exe, ["@", "--to", kitty_socket, "action",
				"--match", "id:%d" % pane, "paste_from_clipboard"], false)
	elif DisplayServer.clipboard_has_image():
		_pty(pane, PackedByteArray([22]))  # ^V


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
	_create_process(kitten_exe, ["@", "--to", kitty_socket, "launch", "--type=os-window", shell], false)


# A Cmd+N termling waits here until its first frame arrives, then we present it:
# the camera zooms to frame it (Esc swoops back). It keeps its default cols/rows.
# Reflowing it to fill the view made giant termlings (200x88 when zoomed in; 320x96
# when sized to the window's pixels), and every frame of a big terminal is copied
# through the rgba transport, so size is lag. Ids drop out once framed.
func _apply_fits(_delta: float) -> void:
	if _fit_pending.is_empty():
		return
	for id in _fit_pending.keys():
		if not _groups.has(id):
			_fit_pending.erase(id)
			continue
		var ns: Vector2i = _groups[id].terminal.native_size()
		if ns.x <= 0 or ns.y <= 0:
			continue   # no frame yet; try again next tick
		_fit_pending.erase(id)
		if _present_id != id:
			_toggle_present(_groups[id])


# Present a termling full-window (triple-click). Toggles off if it's already the
# presented one. The camera glue + zoom happen in _process.
func _toggle_present(g: Node2D) -> void:
	var id: int = g.term_id
	if _present_id == id:
		_leave_present()
		return
	if _present_id == -1:
		_present_prev_zoom = _cam.zoom.x   # remember where to swoop back to
	_present_id = id
	_present_leaving = false
	_present_lock = 0.0
	_zoom_goal = 0.0
	_set_focus(id)
	_tracking_id = id
	_present_zoom = _fit_zoom_for(g)


# Move focus to another termling from the keyboard (search jump, Ctrl+` cycle).
# In present mode the new one is presented instead, otherwise the present-mode
# camera glue would keep holding the old one. Outside it the camera tracks the
# new one and zooms out if it wouldn't fit the window.
func _jump_focus(id: int, track := true, zoom := 0.0, dismiss := true) -> void:
	if not _groups.has(id):
		return
	if _present_id != -1:
		if _present_id != id:
			_toggle_present(_groups[id])
		return
	_set_focus(id, dismiss)
	if track:
		_tracking_id = id
	# Fly there, zooming out if it wouldn't fit (or to the caller's zoom).
	_fly_to(id, zoom if zoom > 0.0 else minf(_cam.zoom.x, _fit_zoom_for(_groups[id])))


# Camera flights. A short hop glides straight onto the target while easing the
# zoom: its on-screen offset from centre shrinks steadily as the zoom changes, so
# it slides in rather than the view zooming about the old centre first. A long
# one (the target well off screen) zooms out, floats over and zooms back in, on
# van Wijk & Nuij's smooth pan-zoom path, taking a little longer the further it
# goes. Both chase a moving target: the path is laid out relative to where the
# target is now.
const FLY_POINT := -2          # _fly_id for a flight to a fixed point (_fly_pt)
const FLY_RHO := 1.4           # how far a long flight zooms out (van Wijk's rho, ~sqrt 2)
const FLY_FAR := 0.75          # "long": the target is more than this many view-widths away
var _fly_pt := Vector2.ZERO    # goal of a FLY_POINT flight
var _fly_dur := FLY_TIME       # seconds this flight takes
var _fly_S := 0.0              # a long flight's path length (0 = short glide)
var _fly_r0 := 0.0             # van Wijk's r0 for it
var _fly_w0 := 1.0             # visible world width at take-off
var _fly_u1 := 1.0             # distance to the target at take-off
var _fly_d0 := Vector2.ZERO    # take-off camera position minus the target's
var _fly_vpw := 1.0            # viewport width the world widths are measured against

func _fly_to(id: int, z: float) -> void:
	_fly_start(id, _groups[id].terminal.global_position, z)


func _fly_to_point(p: Vector2, z: float) -> void:
	_fly_pt = p
	_fly_start(FLY_POINT, p, z)


func _fly_start(id: int, goal: Vector2, z: float) -> void:
	_fly_id = id
	_fly_t = 0.0
	_fly_z0 = _cam.zoom.x
	_fly_z1 = z
	_fly_off = (goal - _cam.position) * _fly_z0
	_fly_d0 = _cam.position - goal
	_fly_vpw = get_viewport().get_visible_rect().size.x
	_fly_w0 = _fly_vpw / _fly_z0
	var w1 := _fly_vpw / z
	_fly_u1 = _fly_d0.length()
	_fly_S = 0.0
	_fly_dur = FLY_TIME
	if _fly_u1 > FLY_FAR * maxf(_fly_w0, w1):
		var p2 := FLY_RHO * FLY_RHO
		var b0 := (w1 * w1 - _fly_w0 * _fly_w0 + p2 * p2 * _fly_u1 * _fly_u1) / (2.0 * _fly_w0 * p2 * _fly_u1)
		var b1 := (w1 * w1 - _fly_w0 * _fly_w0 - p2 * p2 * _fly_u1 * _fly_u1) / (2.0 * w1 * p2 * _fly_u1)
		_fly_r0 = -_asinh(b0)
		_fly_S = (-_asinh(b1) - _fly_r0) / FLY_RHO
		_fly_dur = clampf(0.45 + 0.18 * _fly_S, 0.6, 1.6)
	_zoom_goal = 0.0
	_present_leaving = false
	_cam_return = false


# log(x + sqrt(x^2 + 1)), kept accurate for large negative x.
func _asinh(x: float) -> float:
	return log(x + sqrt(x * x + 1.0)) if x >= 0.0 else -log(-x + sqrt(x * x + 1.0))


func _fly_step(delta: float) -> void:
	if _panning or (_fly_id != FLY_POINT and not _groups.has(_fly_id)):
		_fly_id = -1   # target gone, or the user grabbed the camera
		return
	var goal: Vector2 = _fly_pt if _fly_id == FLY_POINT else _groups[_fly_id].terminal.global_position
	_fly_t = minf(_fly_t + delta / _fly_dur, 1.0)
	var e := _fly_t * _fly_t * (3.0 - 2.0 * _fly_t)   # smoothstep
	if _fly_t >= 1.0:
		_cam.zoom = Vector2(_fly_z1, _fly_z1)
		_cam.position = goal
		# Landed centred, so hand over to tracking already glued: easing in from here
		# would let the termling bob against the camera at close zoom.
		_track_of = _fly_id
		_track_lock = 1.0
		_fly_id = -1
	elif _fly_S > 0.0:
		# van Wijk & Nuij: visible width w(s) and distance travelled u(s) along the path
		var a := FLY_RHO * _fly_S * e + _fly_r0
		var w := _fly_w0 * cosh(_fly_r0) / cosh(a)
		var u := _fly_w0 / (FLY_RHO * FLY_RHO) * (cosh(_fly_r0) * tanh(a) - sinh(_fly_r0))
		var z := _fly_vpw / w
		_cam.zoom = Vector2(z, z)
		_cam.position = goal + _fly_d0 * (1.0 - u / _fly_u1)
	else:
		var z := _fly_z0 * pow(_fly_z1 / _fly_z0, e)      # geometric, so zoom speed feels even
		_cam.zoom = Vector2(z, z)
		_cam.position = goal - _fly_off * (1.0 - e) / z


# A "needs you" jump: focus it, pan over, and zoom in (or out) until it fills
# ATTEND_FILL of the window (as full as a triple-click present, and allowed past
# MAX_ZOOM like it), so it's readable the moment focus lands. dismiss: you asked
# for it (so its notification goes), rather than a ping taking the camera.
const ATTEND_FILL := VIEW_FILL
func _attend(id: int, dismiss := true) -> void:
	if not _groups.has(id):
		return
	# Follow it (like a search / radial commit): otherwise a previously tracked
	# termling pulls the camera back once the flight lands, and the ones in front
	# of this one stop fading, so your next click lands on them instead.
	_jump_focus(id, true, 0.0, dismiss)
	if _present_id == -1:
		_zoom_goal = _fit_zoom_for(_groups[id], ATTEND_FILL)


func _ease_zoom(goal: float, delta: float) -> void:
	var z := lerpf(_cam.zoom.x, goal, 8.0 * delta)
	_cam.zoom = Vector2(z, z)


func _leave_present() -> void:
	if _present_id == -1:
		return
	_present_id = -1
	_present_leaving = true   # _process eases the zoom back to _present_prev_zoom


# Present mode's camera follow. Runs deferred: after every _process (so after
# CarryGroup applies this frame's bob) and before Godot flushes the camera's
# transform, so the presented termling holds still on screen instead of bobbing
# against a camera that trails it by a frame. _present_lock ramps 0->1 so entering
# present mode still swoops in rather than jumping.
# Tracking's camera follow. Deferred for the same reason as present mode's, and
# _track_lock ramps 0->1 so it still eases onto a new target before gluing.
func _snap_track_cam(delta: float) -> void:
	if _tracking_id == -1 or not _groups.has(_tracking_id):
		return
	var target: Vector2 = _groups[_tracking_id].terminal.global_position
	_cam.position = _cam.position.lerp(target, maxf(_track_lock, 6.0 * delta))


func _snap_present_cam(delta: float) -> void:
	if _present_id == -1 or not _groups.has(_present_id):
		return
	var target: Vector2 = _groups[_present_id].terminal.global_position
	_cam.position = _cam.position.lerp(target, maxf(_present_lock, 6.0 * delta))


# Camera zoom at which g's terminal spans VIEW_FILL of the window. onscreen_size()
# is native*term.zoom (camera-independent world units); screen px = that * cam.zoom.
func _fit_zoom_for(g: Node2D, fill := VIEW_FILL) -> float:
	var on: Vector2 = g.terminal.onscreen_size()
	if on.x <= 0.0 or on.y <= 0.0:
		return _cam.zoom.x
	var vp := get_viewport().get_visible_rect().size
	return clampf(minf(vp.x / on.x, vp.y / on.y) * fill, MIN_ZOOM, PRESENT_MAX_ZOOM)


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
		_create_process(kitten_exe, ["@", "--to", kitty_socket, "resize-os-window",
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
		_create_process(kitten_exe, ["@", "--to", kitty_socket, "scroll-window",
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
	# Durable session-keyed names/positions first (this survives a cold start, which
	# wipes /tmp/cove); state.json below then overrides with the freshest values.
	_load_durable()
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
	# Hand-drawn regions from before the board: _bd_setup turns them into frames
	# (only when there's no board file yet). Auto zones aren't carried over.
	for z in d.get("zones", []):
		var zr = z.get("rect", null)
		if bool(z.get("pinned", false)) and zr is Array and zr.size() == 4 and str(z.get("name", "")) != "":
			_legacy_zones.append({"name": str(z["name"]), "rect": zr, "color": z.get("color", [0.6, 0.6, 0.6])})
	var pos := {}
	var follows := {}
	for t in d.get("terminals", []):
		var id := int(t.get("id", -1))
		if id == -1:
			continue
		pos[id] = t.get("pos", [0, 0])
		# Names with a session are restored by session (_learn_session), never by
		# id: ids are reissued when kitty restarts.
		if str(t.get("name", "")) != "" and str(t.get("session", "")) == "":
			_names[id] = str(t["name"])
		if t.get("following", null) != null:
			follows[id] = int(t["following"])
		# Zone membership: "container" (a board shape id, "" = loose), or an older
		# state's "zone_override" (a zone name, matched against frame titles).
		var zref = t.get("container", null)
		if zref == null:
			zref = t.get("zone_override", null)
		# Session-keyed restore survives a kitty restart: abduco keeps the shells
		# alive but kitty hands out fresh window ids, so id-keying alone misses.
		var sess := str(t.get("session", ""))
		if sess != "":
			_pos_by_session[sess] = t.get("pos", [0, 0])
			if str(t.get("name", "")) != "":
				_name_by_session[sess] = str(t["name"])
			if zref != null:
				_zone_by_session[sess] = str(zref)
		elif zref != null:
			_zone_saved[id] = str(zref)
	_saved = {"pos": pos, "cam": d.get("camera", null), "follows": follows, "focused": int(d.get("focused", -1)),
		"queue": d.get("attention_queue", [])}
	if _saved["cam"] == null:
		_saved.erase("cam")
	if typeof(d.get("window", null)) == TYPE_DICTIONARY:
		_saved["window"] = d["window"]


# Durable name/pos mirror, keyed by abduco session (the only id stable across a
# kitty restart). Lives in user:// so a cold start — which `rm -rf`s /tmp/cove and
# its state.json — still restores termling names once the ls poll relearns sessions.
func _load_durable() -> void:
	if not FileAccess.file_exists(USER_LAYOUT):
		return
	var f := FileAccess.open(USER_LAYOUT, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return
	for sess in d.get("by_session", {}):
		var rec = d["by_session"][sess]
		if typeof(rec) != TYPE_DICTIONARY:
			continue
		if str(rec.get("name", "")) != "":
			_name_by_session[sess] = str(rec["name"])
		if rec.get("pos", null) is Array:
			_pos_by_session[sess] = rec["pos"]
		if rec.get("zone", null) != null:
			_zone_by_session[sess] = str(rec["zone"])


func _write_durable() -> void:
	# Start from everything we already know (so sessions not present this run — e.g.
	# a detached termling — are never dropped), then refresh from the live groups.
	var by := {}
	for sess in _name_by_session:
		by[sess] = {"name": _name_by_session[sess]}
	for sess in _pos_by_session:
		var r: Dictionary = by.get(sess, {})
		r["pos"] = _pos_by_session[sess]
		by[sess] = r
	for sess in _zone_by_session:
		var r: Dictionary = by.get(sess, {})
		r["zone"] = _zone_by_session[sess]
		by[sess] = r
	for id in _groups:
		var sess := str(_sessions.get(id, ""))
		if sess == "":
			continue
		var g = _groups[id]
		var r: Dictionary = by.get(sess, {})
		if g.terminal.custom_name != "":
			r["name"] = g.terminal.custom_name
		r["pos"] = [snappedf(g.position.x, 0.1), snappedf(g.position.y, 0.1)]
		if _zone_of.has(id):
			r["zone"] = str(_zone_of[id])
			_zone_by_session[sess] = str(_zone_of[id])
		by[sess] = r
	var f := FileAccess.open(USER_LAYOUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"by_session": by}))
		f.close()


func _restore_after_reconcile() -> void:
	for fid in _saved.get("follows", {}):
		if _groups.has(fid):
			_follows[fid] = _saved["follows"][fid]
	var foc := int(_saved.get("focused", -1))
	if foc != -1 and _groups.has(foc):
		_set_focus(foc, false)
	# Re-queue whoever was waiting for you (by session first: kitty ids change on restart).
	for q in _saved.get("queue", []):
		if typeof(q) != TYPE_DICTIONARY:
			continue
		var g := _find_by_session(str(q.get("session", "")))
		var qid: int = g.term_id if g != null else int(q.get("id", -1))
		if _groups.has(qid) and qid != _focused_id and not _attention.is_queued(qid):
			_attention.queue.append(qid)
	_attn_live = true


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


# Keep every asynchronous child until it exits. On Unix, checking its status
# also waits for the exited child; discarding the PID leaves a zombie. The
# watchdog launches from the polling thread, so protect the shared PID list.
func _create_process(path: String, args: PackedStringArray, open_console: bool = false) -> int:
	_child_mutex.lock()
	var pid := OS.create_process(path, args, open_console)
	if pid > 0:
		_child_pids.append(pid)
	_child_mutex.unlock()
	return pid


func _reap_children() -> void:
	_child_mutex.lock()
	for i in range(_child_pids.size() - 1, -1, -1):
		if not OS.is_process_running(_child_pids[i]):
			_child_pids.remove_at(i)
	_child_mutex.unlock()


# --- kitty ls polling (background thread) -----------------------------------

func _start_ls_poll() -> void:
	if kitten_exe == "" or kitty_socket == "":
		return
	_ls_mutex = Mutex.new()
	_ls_thread = Thread.new()
	_ls_thread.start(_ls_loop)


func _ls_loop() -> void:
	var watchdog_tick := 0
	while _ls_run:
		# Every ~30s, run the session watchdog: it detects (and heals) abduco
		# attach clients spinning at 100% cpu and deadlocked session ptys, both
		# of which freeze a termling while every process in it stays alive.
		watchdog_tick += 1
		if watchdog_tick >= 30:
			watchdog_tick = 0
			var wd := ProjectSettings.globalize_path("res://cove-watchdog.py")
			_create_process("/usr/bin/python3", [wd])
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
			# kitty raising the flag (a bell, an agent waiting) is a ping too
			if _attn_live and not _kitty_attn.has(id):
				_kitty_attn[id] = true
				_ping(id, true)
		else:
			_kitty_attn.erase(id)
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
	# The session name beats whatever the id-keyed restore applied: after a kitty
	# restart the ids are fresh, so an id-keyed name belongs to some other termling.
	if _name_by_session.has(session):
		_names[id] = _name_by_session[session]
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
				_reconfine(fid)   # back to wandering inside its zone
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
# A termling's zone is a board shape (a frame or geo box) it was dropped into.
# The board section owns the shapes (_bd_container_*); this keeps memberships.


# Each tick: restore memberships from the last run, drop ones whose shape was
# deleted, and keep every member's wander rect in step with its shape (resized,
# or moved by an agent). Dragging a shape carries its members directly
# (_bd_carry_members); this only catches up.
func _apply_zones() -> void:
	if _bd_layer == null:
		return
	for id in _groups:
		var g = _groups[id]
		if not _zone_of.has(id):
			var sess := str(_sessions.get(id, ""))
			var ref := ""
			if _zone_saved.has(id):
				ref = str(_zone_saved[id])
			elif sess != "":
				ref = str(_zone_by_session.get(sess, ""))
			else:
				continue   # wait for the ls poll to learn its session
			var sid := _bd_resolve_container(ref)
			_zone_of[id] = sid
			_zone_saved.erase(id)
		var cur := str(_zone_of[id])
		if cur == "":
			if g.zone_rect() != null:
				g.clear_zone()
			continue
		if g.terminal.custom_name == "":
			_name_from_zone(id, cur)   # an unnamed termling takes its zone's name
		var r = _bd_container_rect(cur)
		if r == null:
			_zone_of[id] = ""   # its shape was deleted: loose again
			g.clear_zone()
		elif not _follows.has(id) and not _rect_near(g.zone_rect(), r):
			g.assign_zone(r)


func _rect_near(a, b: Rect2) -> bool:
	if a == null:
		return false
	var ra: Rect2 = a
	return ra.position.distance_to(b.position) < 1.0 and ra.size.distance_to(b.size) < 1.0


# Back to wandering inside its zone (after a follow/move ends).
func _reconfine(id: int) -> void:
	var sid := str(_zone_of.get(id, ""))
	if sid == "" or not _groups.has(id):
		return
	var r = _bd_container_rect(sid)
	if r != null:
		_groups[id].assign_zone(r)


# On drop, membership follows the drop point: land inside a frame or box on the
# board to live there (and take its name), on open ground to be loose.
func _reassign_zone_on_drop(g: Node2D) -> void:
	var sid := _bd_container_at(g.get_ground_pos())
	_zone_of[g.term_id] = sid
	if sid == "":
		g.clear_zone()
	else:
		g.assign_zone(_bd_container_rect(sid))
		_name_from_zone(g.term_id, sid)


# A termling in a named frame/box is called by that name: "Radial menu", then
# "Radial menu 2" for the next one in, and so on. No-op for an unnamed box.
func _name_from_zone(id: int, sid: String) -> void:
	var label := _bd_container_label(sid)
	if label == "" or not _groups.has(id):
		return
	var taken := {}
	for other in _zone_of:
		if other != id and str(_zone_of[other]) == sid and _groups.has(other):
			taken[_groups[other].terminal.custom_name] = true
	var nm := label
	var n := 2
	while taken.has(nm):
		nm = "%s %d" % [label, n]
		n += 1
	if _groups[id].terminal.custom_name != nm:
		_names[id] = nm
		_groups[id].terminal.set_custom_name(nm)


# --- control channel --------------------------------------------------------

func _pump_commands(delta: float) -> void:
	_cmd_accum += delta
	if _cmd_accum < 0.1:
		return
	_cmd_accum = 0.0
	# Take the file whole with a rename, so lines appended while we read land in
	# a fresh commands.jsonl instead of being truncated away. A leftover
	# processing file (we died mid-batch) is drained first.
	var path := DIR + "/commands.jsonl"
	var taken := DIR + "/commands.processing.jsonl"
	if not FileAccess.file_exists(taken):
		if not FileAccess.file_exists(path) or DirAccess.rename_absolute(path, taken) != OK:
			return
	var f := FileAccess.open(taken, FileAccess.READ)
	if f == null:
		return
	var content := f.get_as_text()
	f.close()
	DirAccess.remove_absolute(taken)
	# Commands carrying a "req" id get {"req", "ok", "error"} in replies.jsonl.
	var replies := []
	for line in content.split("\n", false):
		var c = JSON.parse_string(line)
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var err := _exec_command(c)
		if c.has("req"):
			replies.append({"req": c["req"], "ok": err == "", "error": err if err != "" else null})
	if replies.is_empty():
		return
	var rpath := DIR + "/replies.jsonl"
	var rf := FileAccess.open(rpath, FileAccess.READ_WRITE if FileAccess.file_exists(rpath) else FileAccess.WRITE)
	if rf:
		rf.seek_end()
		for r in replies:
			rf.store_line(JSON.stringify(r))
		rf.close()


# Run one control-channel command. Returns "" on success, else an error for the
# replies file.
func _exec_command(c: Dictionary) -> String:
	var cmd := str(c.get("cmd", ""))
	# Agents don't move termlings, drive the camera or take focus: the user
	# arranges the Cove. (Older MCP servers still send these; they get an error.)
	if cmd in ["move", "follow", "stop", "focus", "gather", "scatter", "release", "autozone"]:
		return "'%s' isn't allowed: the user arranges the Cove" % cmd
	match cmd:
		"rename":
			var g := _find(int(c.get("id", -1)))
			if g == null:
				return "no such terminal"
			var nm := str(c.get("name", ""))
			_names[g.term_id] = nm
			g.terminal.set_custom_name(nm)
		"assign":
			# Put a termling in a named frame/box on the board (a frame is drawn around
			# it if none has that name), or zone "" to set it loose. The MCP only lets
			# an agent do this to itself.
			var g := _find(int(c.get("id", -1)))
			if g == null:
				return "no such terminal"
			var zn := str(c.get("zone", ""))
			var sid := _bd_ensure_container(zn, g.get_ground_pos()) if zn != "" else ""
			_zone_of[g.term_id] = sid
			if sid == "":
				g.clear_zone()
			else:
				g.assign_zone(_bd_container_rect(sid))
		"board":
			# Drawing on the board. Terminal ids in from/to/near become termling refs.
			var bc: Dictionary = c.duplicate(true)
			for k in ["from", "to"]:
				var v = bc.get(k, null)
				if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
					var tg := _find(int(v))
					if tg == null:
						return "no such terminal: %s" % str(v)
					bc[k] = _bd_term_key(tg.term_id)
			if bc.get("near", null) != null:
				var ng := _find(int(bc["near"]))
				if ng != null:
					var tr = _bd_term_rect(_bd_term_key(ng.term_id))
					var nr: Rect2 = tr if tr != null else Rect2(ng.position, Vector2.ZERO)
					bc["near_pos"] = [nr.end.x + 60.0, nr.position.y]
			return _bd_command(bc)
		"dismiss":
			var tid := int(c.get("id", -1))
			var kept := []
			for n in _notes:
				if n.get("term_id", -2) != tid:
					kept.append(n)
			_notes = kept
			_update_panel()
		var other:
			return "unknown command: %s" % str(other)
	return ""


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
			"zone": _bd_container_name(str(_zone_of.get(id, ""))),
			"container": _zone_of.get(id, null),   # board shape id; "" loose, null not restored yet
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
	if _drag != null:
		# The Godot window's CGWindowID: kitty hit-tests native kitty-window drags
		# against it so a drag back onto the Cove re-adopts the terminal.
		window["wnum"] = int(_drag.call("window_number"))
	var st := {
		"terminals": terms,
		"camera": [snappedf(_cam.position.x, 0.1), snappedf(_cam.position.y, 0.1), _cam.zoom.x],
		"focused": _focused_id,
		# the "needs you" queue, oldest first; session-keyed so it survives a kitty restart
		"attention_queue": _attention.queue.map(func(q): return {"id": q, "session": _sessions.get(q, "")}),
		"window": window,
		"zones": _bd_containers(),   # the board's frames/boxes: [{id, name, type, rect}]
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


# Hooks (Stop/Notification) and the agents' status tool (needs_you / blocked /
# done / working) land here. Every event but "working" is a "needs you" ping.
func _pump_notify() -> void:
	# Same lossless take-the-file rename as _pump_commands.
	var path := DIR + "/notify.jsonl"
	var taken := DIR + "/notify.processing.jsonl"
	if not FileAccess.file_exists(taken):
		if not FileAccess.file_exists(path) or DirAccess.rename_absolute(path, taken) != OK:
			return
	var f := FileAccess.open(taken, FileAccess.READ)
	if f == null:
		return
	var content := f.get_as_text()
	f.close()
	DirAccess.remove_absolute(taken)
	var got := false
	for line in content.split("\n", false):
		var n = JSON.parse_string(line)
		if typeof(n) != TYPE_DICTIONARY:
			continue
		# Map to a cove terminal by abduco session (COVE_SESSION) when the line
		# has one, else by kitty pane id. Skip agents that aren't in the cove.
		var g := _find_by_session(str(n.get("session", "")))
		if g == null:
			g = _find(int(n.get("pane", -1)))
		if g == null:
			continue
		var ev := str(n.get("event", ""))
		if ev == "working":
			continue   # back at it; its notification stays until you focus it yourself
		got = true
		# de-dupe: one live note per terminal
		var kept := []
		for existing in _notes:
			if existing.get("term_id", -2) != g.term_id:
				kept.append(existing)
		_notes = kept
		_notes.push_front({"project": str(n.get("project", "")), "event": ev, "term_id": g.term_id, "ts": int(n.get("ts", 0))})
		if _notes.size() > 8:
			_notes.resize(8)
		_ping(g.term_id)
	if got:
		_update_panel()


# A termling needs you. It only takes the camera when nothing has focus and
# you're zoomed out over the board (it'd span under STEAL_FILL of the window
# where it is): then a jump is a glance, not a yank. Otherwise it waits in the
# queue and the notifications panel; Cmd+' steps through them.
const STEAL_FILL := 0.4
func _ping(id: int, deferred := false) -> void:
	if not _groups.has(id):
		return
	var steal: bool = _present_id == -1 and not _overlay_open() \
		and _cam.zoom.x < _fit_zoom_for(_groups[id], STEAL_FILL)
	var now: int = _attention.ping(id, _attention_focus(), steal)
	if now == -1:
		return
	# (the notification stays: the camera came to it, you didn't)
	if deferred:
		_attend.call_deferred(now, false)
	else:
		_attend(now, false)


# An overlay (search, radial, avy, notification stepping) owns the camera.
func _overlay_open() -> bool:
	return _search_open or _radial_open or _avy_open or _notif_open or _rename_id != -1


func _find_by_session(sess: String) -> Node2D:
	if sess == "":
		return null
	for id in _sessions:
		if str(_sessions[id]) == sess and _groups.has(id):
			return _groups[id]
	return null


# The focus a ping sees. While you're working the board (a tool armed, a label
# being edited, or board input in the last 10 s) it counts as taken, so pings
# queue instead of pulling the keyboard out from under you mid-drawing.
func _attention_focus() -> int:
	if _focused_id == -1 and _bd_owns_keyboard():
		return -2
	return _focused_id


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
	title.text = "🔔 notifications"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(0.9, 0.8, 0.55))
	_panel_vbox.add_child(title)
	_update_panel()
	_build_rename_dialog()
	_bd_build_ui()
	_build_search_dialog()
	_build_radial()
	_build_avy()
	_scale_ui_layers()


# Every UI layer (crew panel, rename, search, radial wheel, board chrome) hangs
# off a root Control scaled by _bd_ui_target_scale, so the whole UI keeps a
# comfortable size on Retina and on big displays. The drag ghost (layer 100)
# stays in raw screen pixels.
var _ui_roots: Array = []

func _scale_ui_layers() -> void:
	for layer in get_children():
		if not layer is CanvasLayer or layer.layer >= 100:
			continue
		if layer.get_child_count() == 1 and layer.get_child(0) == _bd_ui_root:
			continue   # the board built its own root
		var root := Control.new()
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for c in layer.get_children():
			c.reparent(root, false)
		layer.add_child(root)
		_ui_roots.append(root)
	_bd_apply_ui_scale()


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
		var sess := str(_sessions.get(_rename_id, ""))
		if sess != "":
			_name_by_session[sess] = nm   # capture now so a restart restores it
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
	_begin_preview()
	_search_hint.text = SEARCH_HINT
	_search_panel.visible = true
	_search_edit.text = ""
	_search_edit.grab_focus()
	_on_search_text("")   # seed with the full roster


# restore_view: on Esc we pan back to where we started and drop any preview; on a
# committed jump we keep the camera on the chosen termling instead.
func _close_search(restore_view := false) -> void:
	_end_preview(restore_view)
	if _search_panel:
		_search_panel.visible = false
	_search_open = false
	_search_awaiting = ""


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
	_close_search(false)
	_jump_focus(id)   # the camera keeps tracking (or presenting) the one we jumped to


# --- preview: camera + occluder fade while stepping search hits / radial jumps

func _previewing() -> bool:
	return (_search_open or _radial_open or _notif_open) and _preview_id != -1 and _groups.has(_preview_id)


# Remember the view a search / radial jump started from, so Esc can put it back.
func _begin_preview() -> void:
	_preview_id = -1
	_preview_return_cam = _cam.position
	_preview_return_zoom = _cam.zoom.x
	_zoom_goal = 0.0
	_fly_id = -1   # the preview takes the camera from any flight under way


# restore_view (Esc): swoop back to the starting view, unless a tracked or
# presented termling reclaims the camera. A committed jump keeps the view.
func _end_preview(restore_view: bool) -> void:
	_clear_preview()
	_cam_return = restore_view and _tracking_id == -1
	# Undo the preview's zoom too (present mode re-fits its own termling instead).
	if restore_view and _present_id == -1:
		_zoom_goal = _preview_return_zoom


func _preview_selected() -> void:
	if _search_sel < 0 or _search_sel >= _search_rows.size():
		return
	_preview(int(_search_rows[_search_sel].id))


# Point the preview at id: fade the termlings occluding it and let _process
# pan + fit the camera onto it.
func _preview(id: int) -> void:
	if not _groups.has(id):
		return
	_preview_id = id
	var target = _groups[id]
	for oid in _groups:
		var g = _groups[oid]
		g.terminal.set_dimmed(SEARCH_DIM if oid != id and _occludes(g, target) else 1.0)


func _clear_preview() -> void:
	_preview_id = -1
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
	if _search_open or _radial_open or _notif_open:
		return   # the preview does its own fading
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
	_create_process("/usr/bin/python3", [script, "--json", q])


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


# --- radial jump ------------------------------------------------------------
# Cmd+J pops a game-style waypoint wheel. The camera previews one termling (the
# focused one to start) and each nearby termling gets a marker at its spot on
# screen, or pinned to the window edge in its direction when it's off-screen.
# hjkl / arrows hop to the nearest termling that way (its marker wears the key),
# Tab walks outward by distance, hovering a marker previews it, Enter or a click
# jumps there, Esc (or Cmd+J again) swoops back.

func _build_radial() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)
	_radial_layer = Control.new()
	_radial_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_radial_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_radial_layer.visible = false
	_radial_layer.draw.connect(_radial_draw)
	layer.add_child(_radial_layer)
	_radial_title = _radial_label(RADIAL_FONT + 4, Color(0.9, 0.8, 0.55))
	_radial_hint = _radial_label(RADIAL_FONT - 8, Color(0.75, 0.77, 0.8))
	_radial_hint.text = RADIAL_HINT


func _radial_label(font_px: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_px)
	l.add_theme_color_override("font_color", col)
	l.add_theme_stylebox_override("normal", _radial_box(Color(0.55, 0.95, 0.75, 0.5)))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_radial_layer.add_child(l)
	return l


func _radial_box(border: Color) -> StyleBoxFlat:
	var sb := _themed_box(border)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	sb.set_corner_radius_all(12)
	return sb


func _open_radial() -> void:
	if _radial_layer == null or _groups.is_empty():
		return
	var start := _focused_id if _groups.has(_focused_id) else _nearest_to_camera()
	_radial_open = true
	_radial_hover = -1
	_begin_preview()
	_radial_ring = _attention.rank(_order_by_proximity(start))   # waiting termlings first
	_radial_layer.visible = true
	_radial_hop(start)


func _close_radial(restore_view: bool) -> void:
	if not _radial_open:
		return
	_end_preview(restore_view)
	_radial_open = false
	_radial_hover = -1
	_radial_centre = -1
	_radial_axes = Vector2.ZERO
	_radial_layer.visible = false
	for oid in _radial_markers:
		_radial_markers[oid].queue_free()
	_radial_markers = {}
	_radial_keys = {}


func _radial_key(ev: InputEventKey) -> void:
	var k := ev.keycode
	if k == KEY_ESCAPE or (k == KEY_J and ev.meta_pressed):
		_close_radial(true)
	elif k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		_radial_commit(_preview_id if _preview_id != -1 else _radial_centre)
	elif k == KEY_TAB:
		_radial_step_ring(-1 if ev.shift_pressed else 1)
	elif not ev.meta_pressed:
		var key := ""
		match k:
			KEY_H, KEY_LEFT: key = "h"
			KEY_J, KEY_DOWN: key = "j"
			KEY_K, KEY_UP: key = "k"
			KEY_L, KEY_RIGHT: key = "l"
		if _radial_keys.has(key):
			_radial_hop(_radial_keys[key])


func _radial_commit(id: int) -> void:
	_close_radial(false)
	_jump_focus(id)


func _radial_step_ring(d: int) -> void:
	var ring := _radial_ring.filter(func(x): return _groups.has(x))
	if ring.is_empty():
		return
	_radial_hop(ring[posmod(ring.find(_radial_centre) + d, ring.size())])


func _nearest_to_camera() -> int:
	var best := -1
	var best_d := INF
	for id in _groups:
		var d: float = _groups[id].terminal.global_position.distance_squared_to(_cam.position)
		if d < best_d:
			best_d = d
			best = id
	return best


# The termling nearest `from` in direction dir (terminal centres, so it matches
# what's on screen). It must sit within ~50° of that direction; hugging the axis
# beats being merely closer, so a straight-left neighbour wins over a near diagonal.
func _neighbor_toward(from: int, dir: Vector2) -> int:
	var o: Vector2 = _groups[from].terminal.global_position
	var best := -1
	var best_s := INF
	for id in _groups:
		if id == from:
			continue
		var d: Vector2 = _groups[id].terminal.global_position - o
		var along := d.dot(dir)
		var perp := absf(d.cross(dir))
		if along <= 1.0 or perp > along * 1.2:
			continue
		var s := along + 2.0 * perp
		if s < best_s:
			best_s = s
			best = id
	return best


# Re-centre the wheel on id: preview it, work out where each hjkl key goes from
# here, and show markers for the nearest few plus every key target.
func _radial_hop(id: int) -> void:
	if not _groups.has(id):
		return
	_radial_centre = id
	_radial_hover = -1
	_preview(id)
	_radial_keys = {}
	for key in RADIAL_DIRS:
		var t := _neighbor_toward(id, RADIAL_DIRS[key])
		if t != -1:
			_radial_keys[key] = t
	var shown := {}
	for oid in _order_by_proximity(id):
		if oid != id and shown.size() < RADIAL_MAX:
			shown[oid] = true
	for key in _radial_keys:
		shown[_radial_keys[key]] = true
	for oid in _radial_markers.keys():
		if not shown.has(oid):
			_radial_markers[oid].queue_free()
			_radial_markers.erase(oid)
	for oid in shown:
		if not _radial_markers.has(oid):
			_radial_markers[oid] = _radial_marker(oid)
		_style_marker(oid)
	var why := ""
	for c in _search_cards():
		if int(c.id) == id:
			why = _search_why(c)
	_radial_title.text = "◎  " + _term_label(id) + ("   ·   " + why if why != "" else "")
	_radial_title.reset_size()
	_radial_hint.reset_size()
	_radial_layout()


func _radial_marker(oid: int) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", RADIAL_FONT)
	b.mouse_entered.connect(func(): _radial_hover_on(oid))
	b.mouse_exited.connect(func(): _radial_hover_off(oid))
	b.pressed.connect(func(): _radial_commit(oid))
	_radial_layer.add_child(b)
	return b


# A key target wears its key(s) and a bright border; other neighbours sit quieter.
func _style_marker(oid: int) -> void:
	var b: Button = _radial_markers[oid]
	var keys := []
	for key in _radial_keys:
		if _radial_keys[key] == oid:
			keys.append(key + RADIAL_ARROWS[key])
	var lit := not keys.is_empty()
	b.text = ("  ".join(keys) + "   " if lit else "") + _term_label(oid)
	var border := Color(0.55, 0.95, 0.75, 0.9) if lit else Color(0.6, 0.62, 0.66, 0.45)
	b.add_theme_stylebox_override("normal", _radial_box(border))
	b.add_theme_stylebox_override("hover", _radial_box(Color(0.9, 0.8, 0.55, 1.0)))
	b.add_theme_stylebox_override("pressed", _radial_box(Color(0.9, 0.8, 0.55, 1.0)))
	b.modulate.a = 1.0 if lit else 0.75
	b.reset_size()


func _radial_hover_on(oid: int) -> void:
	_radial_hover = oid
	_preview(oid)


func _radial_hover_off(oid: int) -> void:
	if _radial_hover != oid:
		return
	_radial_hover = -1
	_preview(_radial_centre)


# The wheel is a ring in the middle of the window, around the previewed termling
# (the camera fits it into the hole). Each marker sits on the ring at the true
# bearing of its termling from the wheel's centre, fanned round the ring when
# two collide. Key targets are placed first so they keep their true bearing.
func _radial_layout() -> void:
	var vp := _radial_layer.size   # the UI root's scaled units (see _scale_ui_layers)
	_radial_title.position = Vector2((vp.x - _radial_title.size.x) * 0.5, 18)
	_radial_hint.position = Vector2((vp.x - _radial_hint.size.x) * 0.5, vp.y - _radial_hint.size.y - 18)
	if _radial_hover != -1 or not _groups.has(_radial_centre):
		return   # hold still: the preview swooping would slide the marker out from under the mouse
	var centre := vp * 0.5
	var from: Vector2 = _groups[_radial_centre].terminal.global_position
	# The ring circumscribes the centre termling as drawn (so it breathes with the
	# zoom), kept on screen with room for the labels hanging off it.
	var px: Vector2 = _groups[_radial_centre].terminal.onscreen_size() \
		* get_viewport().get_canvas_transform().get_scale() / maxf(_bd_ui_scale, 1.0)
	# Room for the biggest label to hang off the ring without leaving the window.
	var pad := Vector2(110, 40)
	for oid in _radial_markers:
		pad = pad.max(_radial_markers[oid].size * 0.5 + Vector2(12, 12))
	var lo := Vector2(220, 150)
	var hi := (vp * 0.5 - pad).max(lo)
	var half := (px * 0.5 * sqrt(2.0) + Vector2.ONE * pad.y).clamp(lo, hi)
	_radial_axes = half
	_radial_dots = []
	var keyed := _radial_keys.values()
	var order: Array = _radial_markers.keys()
	order.sort_custom(func(a, b): return int(a in keyed) > int(b in keyed))
	var placed: Array = []
	for oid in order:
		if not _groups.has(oid):
			continue
		var b: Button = _radial_markers[oid]
		var d: Vector2 = _groups[oid].terminal.global_position - from
		var ang := d.angle() if d.length() > 1.0 else -PI * 0.5
		var r := Rect2()
		for i in 25:
			# the true bearing first, then fan out either side of it
			var a := ang + 0.12 * ceili(i / 2.0) * (1.0 if i % 2 == 1 else -1.0)
			var p := centre + _on_ellipse(a, half)
			r = Rect2(p - b.size * 0.5, b.size)
			var free := true
			for q in placed:
				if r.grow(3.0).intersects(q):
					free = false
					break
			if free:
				break
		r.position = r.position.clamp(Vector2(8, 8), vp - r.size - Vector2(8, 8))
		placed.append(r)
		b.position = r.position
		_radial_dots.append([centre + _on_ellipse(ang, half), oid in keyed])
	_radial_layer.queue_redraw()


# Point on the ellipse with semi-axes `half` at polar angle a (from its centre).
func _on_ellipse(a: float, half: Vector2) -> Vector2:
	var c := cos(a)
	var s := sin(a)
	return Vector2(c, s) * (half.x * half.y / sqrt(pow(half.y * c, 2.0) + pow(half.x * s, 2.0)))


# The ring itself: a translucent band with a thin rim, and a tick at each
# neighbour's true bearing (bright for the hjkl targets).
func _radial_draw() -> void:
	if _radial_axes == Vector2.ZERO:
		return
	var centre := _radial_layer.size * 0.5
	var pts := PackedVector2Array()
	for i in 97:
		pts.append(centre + _on_ellipse(TAU * i / 96.0, _radial_axes))
	_radial_layer.draw_polyline(pts, Color(0.12, 0.10, 0.09, 0.6), RADIAL_FONT * 2.6, true)
	_radial_layer.draw_polyline(pts, Color(0.55, 0.95, 0.75, 0.35), 3.0, true)
	for dot in _radial_dots:
		var lit: bool = dot[1]
		_radial_layer.draw_circle(dot[0], 8.0 if lit else 5.0,
			Color(0.55, 0.95, 0.75, 0.95) if lit else Color(0.8, 0.8, 0.85, 0.6))


# --- avy jump ---------------------------------------------------------------
# Cmd+; zooms out (never in) just far enough to take in the termlings nearest
# the view, then drops a big letter label on every visible termling, nearest
# first on the home row. Type a label to jump there (focus + track, easing back
# to the zoom you started at); past 26 termlings labels are two letters and the
# first one narrows. Backspace un-types, Esc swoops back, a click abandons it.

func _build_avy() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)
	_avy_layer = Control.new()
	_avy_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_avy_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avy_layer.visible = false
	layer.add_child(_avy_layer)
	_avy_hint = Label.new()
	_avy_hint.text = "type a label to jump  ·  ⌫ back  ·  esc"
	_avy_hint.add_theme_font_size_override("font_size", RADIAL_FONT - 8)
	_avy_hint.add_theme_color_override("font_color", Color(0.75, 0.77, 0.8))
	_avy_hint.add_theme_stylebox_override("normal", _radial_box(Color(0.98, 0.84, 0.35, 0.6)))
	_avy_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avy_layer.add_child(_avy_hint)


func _open_avy() -> void:
	if _avy_layer == null or _groups.is_empty():
		return
	_begin_preview()   # so Esc can put the view back
	var vp := get_viewport().get_visible_rect().size
	var ids: Array = _groups.keys()
	var here := _cam.position
	ids.sort_custom(func(a, b):
		return _groups[a].terminal.global_position.distance_squared_to(here) \
			< _groups[b].terminal.global_position.distance_squared_to(here))
	# Zoom out only if the few nearest termlings don't already fit, then frame them.
	var box := _term_rect(_groups[ids[0]])
	for i in mini(AVY_NEAR, ids.size()):
		box = box.merge(_term_rect(_groups[ids[i]]))
	box = box.grow(60.0)
	var fit := clampf(minf(vp.x / box.size.x, vp.y / box.size.y), MIN_ZOOM, MAX_ZOOM)
	_fly_id = -1   # the labels take the camera from any flight under way
	_avy_zoom = _cam.zoom.x
	_avy_cam = _cam.position
	if fit < _cam.zoom.x:
		_avy_zoom = fit
		_avy_cam = box.get_center()
	# Label everything that will be on screen once the camera settles, nearest first.
	var view := Rect2(_avy_cam - vp * 0.5 / _avy_zoom, vp / _avy_zoom)
	var vis := []
	for id in ids:
		if view.intersects(_term_rect(_groups[id])):
			vis.append(id)
	if vis.is_empty():
		_end_preview(false)
		return
	var labels := _avy_make_labels(vis.size())
	_avy_labels = {}
	_avy_nodes = {}
	for i in vis.size():
		_avy_labels[labels[i]] = vis[i]
		_avy_nodes[vis[i]] = _avy_label_node(labels[i])
	_avy_prefix = ""
	_avy_open = true
	_avy_layer.visible = true
	_avy_hint.reset_size()
	_avy_layout()


# n prefix-free labels: single keys while they last, else all two-key pairs.
func _avy_make_labels(n: int) -> Array:
	var out := []
	if n <= AVY_KEYS.length():
		for i in n:
			out.append(AVY_KEYS[i])
		return out
	for a in AVY_KEYS:
		for b in AVY_KEYS:
			if out.size() == n:
				return out
			out.append(a + b)
	return out


# A label sized off the window height, so it reads at any resolution or zoom.
func _avy_label_node(text: String) -> Label:
	var px := int(clampf(_avy_layer.size.y * 0.07, 32.0, 140.0))   # overlay units, not raw pixels
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", Color(0.12, 0.10, 0.09))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.98, 0.84, 0.35, 0.95)
	sb.border_color = Color(0.12, 0.10, 0.09, 0.9)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(int(px * 0.2))
	sb.content_margin_left = px * 0.3
	sb.content_margin_right = px * 0.3
	sb.content_margin_top = px * 0.04
	sb.content_margin_bottom = px * 0.08
	l.add_theme_stylebox_override("normal", sb)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avy_layer.add_child(l)
	l.reset_size()
	return l


# The overlay lives under a UI root scaled for Retina (_scale_ui_layers), so map
# world -> window pixels (camera) -> the overlay's own units (its inverse transform).
func _avy_layout() -> void:
	var vp := _avy_layer.size
	_avy_hint.position = Vector2((vp.x - _avy_hint.size.x) * 0.5, vp.y - _avy_hint.size.y - 18)
	var xf := _avy_layer.get_global_transform_with_canvas().affine_inverse() \
		* get_viewport().get_canvas_transform()
	for id in _avy_nodes:
		if not _groups.has(id):
			continue
		var l: Label = _avy_nodes[id]
		var p: Vector2 = xf * _groups[id].terminal.global_position
		l.position = (p - l.size * 0.5).clamp(Vector2(8, 8), vp - l.size - Vector2(8, 8))


func _avy_key(ev: InputEventKey) -> void:
	var k := ev.keycode
	if k == KEY_ESCAPE or (k == KEY_SEMICOLON and ev.meta_pressed):
		_close_avy(true)
		return
	if k == KEY_BACKSPACE:
		_avy_prefix = _avy_prefix.left(-1)
		_avy_refresh()
		return
	if ev.meta_pressed or ev.ctrl_pressed or ev.unicode == 0:
		return
	var typed := _avy_prefix + String.chr(ev.unicode).to_lower()
	if _avy_labels.has(typed):
		_avy_commit(_avy_labels[typed])
		return
	for lab in _avy_labels:
		if lab.begins_with(typed):
			_avy_prefix = typed
			_avy_refresh()
			return
	# no label starts that way: ignore the key


# Show only the labels still reachable from what's been typed, minus that prefix.
func _avy_refresh() -> void:
	for lab in _avy_labels:
		var id: int = _avy_labels[lab]
		if not _avy_nodes.has(id):
			continue
		var l: Label = _avy_nodes[id]
		l.visible = lab.begins_with(_avy_prefix)
		l.text = lab.substr(_avy_prefix.length())
		l.reset_size()


func _avy_commit(id: int) -> void:
	_close_avy(false)
	if not _groups.has(id):
		return
	# Land zoomed to fit the chosen termling, in or out, whatever zoom you started at.
	_jump_focus(id, true, _fit_zoom_for(_groups[id]))


func _close_avy(restore_view: bool) -> void:
	if not _avy_open:
		return
	_end_preview(restore_view)
	_avy_open = false
	_avy_layer.visible = false
	for id in _avy_nodes:
		_avy_nodes[id].queue_free()
	_avy_nodes = {}
	_avy_labels = {}
	_avy_prefix = ""


# --- stepping notifications (Cmd+') ------------------------------------------
# Cmd+' previews the newest notification's termling: the camera flies over and
# zooms onto it, and its row lights up in the panel. Cmd+' again (or Tab / Down)
# steps to the next, Shift (or Up) steps back. Enter focuses the one you're on;
# any other key swoops back to where you started. A click takes over.

func _is_apostrophe(ev: InputEventKey) -> bool:
	return ev.keycode == KEY_APOSTROPHE or ev.physical_keycode == KEY_APOSTROPHE


# Termlings with a notification, in panel order (newest first).
func _notif_targets() -> Array:
	var ids := []
	for n in _notes:
		var tid: int = n.get("term_id", -1)
		if tid != -1 and _groups.has(tid) and not ids.has(tid):
			ids.append(tid)
	return ids


func _open_notif() -> void:
	var ids := _notif_targets()
	if ids.is_empty():
		return
	_notif_ids = ids
	_notif_idx = 0
	_notif_open = true
	_begin_preview()
	_notif_go(_notif_ids[0])
	_update_panel()


# Preview id and fly the camera onto it, zoomed to read (a long hop zooms out,
# floats over and back in).
func _notif_go(id: int) -> void:
	_preview(id)
	_fly_to(id, _fit_zoom_for(_groups[id], ATTEND_FILL))


# Enter, or a click on the one being shown: focus it for real.
func _notif_commit(id: int) -> void:
	var flying := _fly_id == id
	_close_notif(false)
	if not _groups.has(id):
		return
	if flying and _present_id == -1:
		# the flight under way already lands on it at the right zoom; don't restart it
		_set_focus(id)
		_tracking_id = id
	else:
		_attend(id)


func _notif_step(d: int) -> void:
	var cur: int = _notif_ids[_notif_idx] if _notif_idx < _notif_ids.size() else -1
	_notif_ids = _notif_ids.filter(func(x): return _groups.has(x))
	for t in _notif_targets():   # ones that arrived since you started go on the end
		if not _notif_ids.has(t):
			_notif_ids.append(t)
	if _notif_ids.is_empty():
		_close_notif(true)
		return
	var at := _notif_ids.find(cur)
	_notif_idx = posmod(at + d, _notif_ids.size()) if at != -1 else clampi(_notif_idx, 0, _notif_ids.size() - 1)
	_notif_go(_notif_ids[_notif_idx])
	_update_panel()


func _notif_key(ev: InputEventKey) -> void:
	var k := ev.keycode
	if _is_modifier_key(k):
		return   # the Shift of Shift+Cmd+' isn't a keypress of its own
	if (_is_apostrophe(ev) and ev.meta_pressed) or k == KEY_TAB or k == KEY_DOWN:
		_notif_step(-1 if ev.shift_pressed else 1)
	elif k == KEY_UP:
		_notif_step(-1)
	elif k == KEY_ENTER or k == KEY_KP_ENTER:
		_notif_commit(_notif_ids[_notif_idx] if _notif_idx < _notif_ids.size() else -1)
	else:
		_close_notif(true)


func _close_notif(restore_view: bool) -> void:
	if not _notif_open:
		return
	_notif_open = false
	_notif_ids = []
	# Going back flies home the same way (a long hop zooms out and back in);
	# present mode re-fits its own termling instead.
	if restore_view and _present_id == -1:
		_end_preview(false)
		if _tracking_id != -1 and _groups.has(_tracking_id):
			_fly_to(_tracking_id, _preview_return_zoom)
		else:
			_fly_to_point(_preview_return_cam, _preview_return_zoom)
	else:
		_end_preview(restore_view)
	_update_panel()


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
		empty.text = "no notifications"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.6, 0.62, 0.66))
		_panel_vbox.add_child(empty)
		return
	var cur: int = _notif_ids[_notif_idx] if _notif_open and _notif_idx < _notif_ids.size() else -1
	for n in _notes:
		var row := Label.new()
		var tid: int = n.get("term_id", -1)
		var who: String = str(n.get("project", ""))
		if tid != -1:
			who = "termling %d" % tid
			if _groups.has(tid) and _groups[tid].terminal.custom_name != "":
				who = _groups[tid].terminal.custom_name
		var on := tid != -1 and tid == cur
		row.text = ("▸ %s" if on else "• %s") % who
		row.add_theme_font_size_override("font_size", 13)
		row.add_theme_color_override("font_color", Color(1, 1, 1) if on else Color(0.92, 0.9, 0.85))
		if on:   # the one Cmd+' is showing
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.45, 0.85, 1.0, 0.25)
			sb.set_corner_radius_all(4)
			sb.content_margin_left = 4
			sb.content_margin_right = 4
			row.add_theme_stylebox_override("normal", sb)
		_panel_vbox.add_child(row)
	var hint := Label.new()
	hint.text = "↵ focus  ·  ⌘' next  ·  ⇧⌘' back  ·  other keys: return" if _notif_open else "⌘' step through"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.6, 0.62, 0.66))
	_panel_vbox.add_child(hint)


# =============================================================================
# --- the board: tldraw on the ground -----------------------------------------
# =============================================================================
#
# Shapes live on the ground between the checkerboard and the termlings: boxes,
# ellipses, diamonds, triangles, arrows (bendable; their ends stick to shapes and
# to termlings), lines, freehand + highlighter, text, sticky notes, frames and
# todo lists. The keys are tldraw's, and they only fire while no termling has
# focus (every keystroke otherwise belongs to its shell): click empty ground to
# unfocus, click a termling to type into it again. Frames and geo boxes are also
# the termlings' zones (see _apply_zones). The document persists in
# user://cove-board.json, mirrored to /tmp/cove/board.json for other tools.

const BOARD_SAVE := "user://cove-board.json"
const BOARD_MIRROR := DIR + "/board.json"
const BD_PALETTE := {
	"black": Color(0.91, 0.91, 0.92),   # tldraw's "black" is the ink: near-white on this dark ground
	"grey": Color(0.60, 0.63, 0.67),
	"light-violet": Color(0.90, 0.60, 0.97),
	"violet": Color(0.75, 0.40, 0.88),
	"blue": Color(0.38, 0.52, 0.98),
	"light-blue": Color(0.40, 0.70, 0.98),
	"yellow": Color(1.00, 0.76, 0.28),
	"orange": Color(0.96, 0.50, 0.18),
	"green": Color(0.15, 0.66, 0.48),
	"light-green": Color(0.40, 0.78, 0.44),
	"light-red": Color(1.00, 0.55, 0.55),
	"red": Color(0.94, 0.30, 0.30),
	"white": Color(1.0, 1.0, 1.0),
}
const BD_COLORS := ["black", "grey", "light-violet", "violet", "blue", "light-blue", "yellow",
	"orange", "green", "light-green", "light-red", "red", "white"]
const BD_STROKE := {"s": 2.0, "m": 3.5, "l": 5.0, "xl": 10.0}
const BD_FONT_PX := {"s": 18, "m": 24, "l": 36, "xl": 44}
const BD_FONT_NAMES := {
	"draw": ["Chalkboard SE", "Marker Felt", "Comic Sans MS"],
	"sans": ["Helvetica Neue", "Arial"],
	"serif": ["Georgia", "Times New Roman"],
	"mono": ["Menlo", "Monaco", "Courier New"],
}
const BD_PAD := 12.0
const BD_GEO := ["rectangle", "ellipse", "diamond", "triangle"]
const BD_STICKY_TOOLS := ["hand", "draw", "highlight", "eraser", "laser"]  # stay armed after use
const BD_ASSETS := "user://board-assets"   # images are copied in, so the board keeps them
const BD_IMAGE_EXTS := ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tga"]
# Link bookmarks: tldraw's BookmarkShapeUtil sizes and its dark theme colours.
const BD_BM_W := 300.0
const BD_BM_H := 320.0              # with a preview image (or still loading)
const BD_BM_SHORT := 101.0          # title, no image
const BD_BM_JUST_URL := 46.0        # nothing but the address
const BD_BM_FIELDS := ["title", "description", "image", "favicon", "site", "github", "fetched"]
const BD_BM_REFRESH_MS := 300000    # GitHub PR/issue cards re-check their state this often
const BD_BM_PANEL := Color(0.126, 0.127, 0.144)     # --color-panel
const BD_BM_EDGE := Color(0.203, 0.198, 0.262)      # --color-panel-contrast
const BD_BM_DIVIDER := Color(0.200, 0.200, 0.240)   # --color-divider
const BD_BM_MUTED0 := Color(1, 1, 1, 0.02)          # --color-muted-0
const BD_BM_MUTED2 := Color(1, 1, 1, 0.05)          # --color-muted-2
const BD_BM_TEXT := Color(0.85, 0.85, 0.85)         # --color-text-1
const BD_BM_TEXT2 := Color(0.74, 0.752, 0.76)       # --color-text-3
const BD_GH_STATES := {   # GitHub's own dark-mode state colours
	"open": ["Open", Color(0.137, 0.525, 0.212)], "draft": ["Draft", Color(0.431, 0.463, 0.506)],
	"merged": ["Merged", Color(0.537, 0.341, 0.898)], "closed": ["Closed", Color(0.855, 0.212, 0.2)],
	"not_planned": ["Not planned", Color(0.431, 0.463, 0.506)],
}
const BD_SNAP_COL := Color(1.0, 0.32, 0.45)
const BD_ARRANGE := [   # [glyph, menu label, mode]
	["⇤", "Align left   ⌥A", "left"], ["⇔", "Align centre   ⌥H", "center-h"], ["⇥", "Align right   ⌥D", "right"],
	["⤒", "Align top   ⌥W", "top"], ["⇕", "Align middle   ⌥V", "center-v"], ["⤓", "Align bottom   ⌥S", "bottom"],
	["⋯", "Distribute horizontally   ⇧⌥H", "dist-h"], ["⋮", "Distribute vertically   ⇧⌥V", "dist-v"],
	["↔", "Stretch horizontally", "stretch-h"], ["↕", "Stretch vertically", "stretch-v"], ["▦", "Pack", "pack"],
]
const BD_TOOL_KEYS := {
	KEY_V: "select", KEY_H: "hand", KEY_D: "draw", KEY_P: "draw", KEY_E: "eraser",
	KEY_K: "laser", KEY_A: "arrow", KEY_L: "line", KEY_T: "text", KEY_N: "note",
	KEY_F: "frame", KEY_C: "todo", KEY_R: "rectangle", KEY_O: "ellipse", KEY_G: "rectangle",
}
const BD_TOOLS := [   # [tool, glyph, name, key] for the tool bar
	["select", "↖", "Select", "V"], ["hand", "✋", "Hand", "H"], ["draw", "✎", "Draw", "D"],
	["eraser", "⌫", "Eraser", "E"], ["arrow", "↗", "Arrow", "A"], ["text", "T", "Text", "T"],
	["note", "▤", "Sticky note", "N"], ["rectangle", "▭", "Rectangle", "R"],
	["ellipse", "◯", "Ellipse", "O"], ["diamond", "◇", "Diamond", ""], ["triangle", "△", "Triangle", ""],
	["line", "╱", "Line", "L"], ["frame", "⌗", "Frame", "F"], ["todo", "☑", "Todo list", "C"],
	["highlight", "▰", "Highlighter", "⇧D"], ["laser", "✦", "Laser pointer", "K"],
]
const BD_HISTORY := 200
const BD_SEL := Color(0.36, 0.62, 1.0)
const BD_HELP := """Board keys work while no termling has focus: click empty ground to unfocus.

  V select     H hand       D draw        ⇧D highlighter   E eraser    K laser
  R rectangle  O ellipse    A arrow       L line           T text      N sticky note
  F frame      C todo list  Q tool lock   space+drag pan   esc back to select

  ⌘Z undo   ⇧⌘Z redo   ⌘A select all   ⌘D duplicate   ⌘C ⌘X ⌘V copy/cut/paste
  ⌘G group   ⇧⌘G ungroup   ⌫ delete   arrows nudge (⇧ ×10)   ↵ edit text
  ] to front   [ to back   ⌥] forward   ⌥[ backward   ⇧H ⇧V flip   ⇧L lock
  ⇧1 zoom to fit   ⇧2 zoom to selection   ⇧0 zoom to 100%   ⌘= ⌘- zoom
  ⇧. ⇧, rotate 15° (⇧⌥ for 1°)   ⌘⌥G frame the selection   ⌘U insert image
  ⌥A ⌥H ⌥D align left/centre/right   ⌥W ⌥V ⌥S align top/middle/bottom
  ⇧⌥H ⇧⌥V distribute   ⌥F solid fill   ⇧⌥F pattern fill   ⌥T white
  ⌘⌥= ⌘⌥- make this chrome bigger / smaller

Dragging: ⇧ keeps the aspect or snaps the angle, ⌥ scales from the centre, ⌥-drag duplicates,
⌘ snaps to other shapes and termlings (the 🧲 button makes snapping the default).
Double-click empty ground to type; double-click a shape to edit its label.
Paste or drop images onto the ground; drop files onto a termling to type their paths.
Paste a link for a bookmark card (GitHub PRs show their state); click its address to open it.
Drop a termling inside a frame or box and it lives there, moving when the frame moves."""

var _bd_layer: Node2D           # paints the shapes (above the ground, below termlings)
var _bd_overlay: Node2D         # selection, handles, marquee, laser, editor (above termlings)
var _bd_shapes: Array = []      # back-to-front
var _bd_by_id := {}
var _bd_next := 1
var _bd_sel: Array = []
var _bd_tool := "select"
var _bd_lock := false           # tool lock (Q): stay in the tool after creating
var _bd_style := {"color": "black", "fill": "none", "dash": "draw", "size": "m", "font": "draw"}
var _bd_fonts := {}
var _bd_alpha := 1.0            # eraser preview fades the shapes it would take
# the gesture in flight
var _bd_g := ""                 # "" | none | pan | pending | move | marquee | handle | box | draw | erase | laser | click
var _bd_gesture := false        # a left press went to the board: its drag + release follow it there
var _bd_down := Vector2.ZERO
var _bd_down_screen := Vector2.ZERO
var _bd_moved := false
var _bd_press_id := ""
var _bd_shift := false
var _bd_orig := {}              # id -> shape copy at gesture start
var _bd_orig_box := Rect2()
var _bd_move_ids: Array = []
var _bd_last_d := Vector2.ZERO
var _bd_handle := {}
var _bd_new_id := ""
var _bd_marquee := Rect2()
var _bd_marquee_base: Array = []
var _bd_erase := {}
var _bd_laser: Array = []
var _bd_space := false
var _bd_bind_hint := ""
var _bd_cam_goal = null         # {pos, zoom} while easing to a zoom-to-fit
# history + persistence
var _bd_undo_stack: Array = []
var _bd_redo_stack: Array = []
var _bd_pre := ""               # snapshot taken when a change began
var _bd_save_in := -1.0
var _bd_cmd_queue: Array = []   # agent commands held until the user's gesture/edit ends
# text editing
var _bd_edit_id := ""
var _bd_edit_part := -1         # todo lists: -2 title, >= 0 item index
var _bd_editor: Control = null
# chrome
var _bd_tool_btns := {}
var _bd_style_btns := {}
var _bd_lock_btn: Button
var _bd_hint: Label
var _bd_hint_accum := 0.0
var _bd_help: PanelContainer
var _bd_menu: PopupMenu
var _bd_menu_pos := Vector2.ZERO
var _bd_ui_root: Control        # all the board chrome, scaled for Retina
var _bd_ui_scale := 0.0
var _bd_ui_user := 1.0          # ⌘⌥= / ⌘⌥- on top of the automatic scale (saved with the board)
var _bd_arrange_row: Control
var _bd_snap_btn: Button
var _bd_snap_mode := false      # always snap (⌘ while dragging inverts it)
var _bd_snap_cache: Array = []  # Rect2s of what a drag may snap to, taken when it starts
var _bd_guides: Array = []      # [[from, to]] snap guide lines for the overlay
var _bd_rot_center := Vector2.ZERO
var _bd_rot_start := 0.0
var _bd_tex := {}               # image src -> Texture2D (null if it failed to load)
var _bd_last_input_ms := 0      # last board click/key, for _bd_owns_keyboard
# Redraw on change, not every frame (see _bd_tick).
var _bd_live_layer: Node2D      # arrows tied to termlings, which move on their own
var _bd_dirty := true
var _bd_drawn_zoom := 0.0
var _bd_member_sig := 0
var _bd_overlay_was_live := true
# Link bookmarks (see "board: link bookmarks").
var _bd_unfurl := {}            # url -> metadata from cove_unfurl.py (title, image, favicon, github...)
var _bd_unfurl_pending := {}    # url -> {out, t} while the helper runs
var _bd_bm_next_refresh := 0    # ticks msec of the next GitHub state re-check
var _bd_bm_styles := {}         # StyleBoxFlats for the card


func _bd_setup() -> void:
	_bd_layer = Node2D.new()
	_bd_layer.z_index = -40
	_bd_layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS   # images stay smooth zoomed out
	_bd_layer.draw.connect(_bd_draw)
	get_window().files_dropped.connect(_bd_files_dropped)
	add_child(_bd_layer)
	_bd_live_layer = Node2D.new()
	_bd_live_layer.z_index = -39
	_bd_live_layer.draw.connect(_bd_draw_live)
	add_child(_bd_live_layer)
	_bd_overlay = Node2D.new()
	_bd_overlay.z_index = 100
	_bd_overlay.draw.connect(_bd_draw_overlay)
	add_child(_bd_overlay)
	if not _bd_load():
		_bd_migrate(_legacy_zones)


func _bd_tick(delta: float) -> void:
	if _bd_save_in >= 0.0:
		_bd_save_in -= delta
		if _bd_save_in < 0.0:
			_bd_save_now()
	var now := Time.get_ticks_msec()
	while not _bd_laser.is_empty() and now - int(_bd_laser[0]["t"]) > 900:
		_bd_laser.pop_front()
	if _bd_cam_goal != null:
		var k := minf(1.0, 10.0 * delta)
		var goal_pos: Vector2 = _bd_cam_goal["pos"]
		var goal_z: float = _bd_cam_goal["zoom"]
		_cam.position = _cam.position.lerp(goal_pos, k)
		var z := lerpf(_cam.zoom.x, goal_z, k)
		_cam.zoom = Vector2(z, z)
		if _cam.position.distance_to(goal_pos) < 0.5 and absf(z - goal_z) < 0.002:
			_cam.position = goal_pos
			_cam.zoom = Vector2(goal_z, goal_z)
			_bd_cam_goal = null
	if _bd_g == "" and _bd_edit_id == "" and not _bd_cmd_queue.is_empty():
		var q := _bd_cmd_queue
		_bd_cmd_queue = []
		for c in q:
			_bd_exec(c)
	if _bd_editor != null:
		_bd_place_editor()
	_bd_hint_accum += delta
	if _bd_hint_accum > 0.3:
		_bd_hint_accum = 0.0
		_bd_update_hint()
		_bd_unfurl_poll()
		if absf(_bd_ui_target_scale() - _bd_ui_scale) > 0.01:
			_bd_apply_ui_scale()   # the window moved to another screen
	# Redraw only what changed. Redrawing every shape every frame (at up to 144
	# fps) was the Cove's biggest main-thread cost. The shapes redraw when they
	# change, while a drag/edit is shaping them, or when the zoom (frame titles)
	# or zone memberships (frame counts) change. Arrows tied to termlings follow
	# them every frame on their own layer. The overlay redraws while it has
	# anything on it.
	var sig := hash(_zone_of)
	if _bd_dirty or _bd_g in ["move", "handle", "box", "draw", "erase"] or _bd_edit_id != "" \
			or _cam.zoom.x != _bd_drawn_zoom or sig != _bd_member_sig:
		_bd_dirty = false
		_bd_drawn_zoom = _cam.zoom.x
		_bd_member_sig = sig
		_bd_layer.queue_redraw()
		_bd_live_layer.queue_redraw()
	else:
		for s in _bd_shapes:
			if _bd_is_live(s):
				_bd_live_layer.queue_redraw()
				break
	var overlay_live := not _bd_sel.is_empty() or _bd_g != "" or not _bd_laser.is_empty() \
		or _bd_bind_hint != "" or not _bd_guides.is_empty()
	if overlay_live or _bd_overlay_was_live:
		_bd_overlay.queue_redraw()   # one more pass after it empties, to clear it
	_bd_overlay_was_live = overlay_live


# --- board: model -------------------------------------------------------------

func _bd_v(a) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


func _bd_a(v: Vector2) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01)]


func _bd_rect(s: Dictionary) -> Rect2:
	return Rect2(float(s["x"]), float(s["y"]), float(s["w"]), float(s["h"]))


func _bd_set_rect(s: Dictionary, r: Rect2) -> void:
	r = r.abs()
	s["x"] = snappedf(r.position.x, 0.01)
	s["y"] = snappedf(r.position.y, 0.01)
	s["w"] = snappedf(r.size.x, 0.01)
	s["h"] = snappedf(r.size.y, 0.01)


func _bd_pts(s: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in s.get("points", []):
		out.append(_bd_v(p))
	return out


func _bd_pts_bounds(pts: PackedVector2Array) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r


func _bd_bounds(s: Dictionary) -> Rect2:
	match str(s["type"]):
		"arrow":
			return _bd_pts_bounds(_bd_arrow_curve(s))
		"line", "draw":
			return _bd_pts_bounds(_bd_pts(s))
	if _bd_rot(s) != 0.0:
		var r := _bd_rect(s)
		var xf := _bd_xform(s)
		return _bd_pts_bounds(PackedVector2Array([xf * r.position, xf * Vector2(r.end.x, r.position.y),
			xf * r.end, xf * Vector2(r.position.x, r.end.y)]))
	return _bd_rect(s)


func _bd_is_box(s: Dictionary) -> bool:
	return str(s["type"]) in ["geo", "text", "note", "frame", "todo", "image", "bookmark"]


func _bd_reindex() -> void:
	_bd_dirty = true
	_bd_by_id.clear()
	for s in _bd_shapes:
		_bd_by_id[str(s["id"])] = s
		if str(s["type"]) == "bookmark":
			_bd_bm_apply(s)   # undo and reloads pick up what's been unfurled since
	_bd_sel = _bd_sel.filter(func(i): return _bd_by_id.has(i))


func _bd_fresh_id() -> String:
	var id := "s%d" % _bd_next
	while _bd_by_id.has(id):
		_bd_next += 1
		id = "s%d" % _bd_next
	_bd_next += 1
	return id


func _bd_new(type: String) -> Dictionary:
	return {"id": _bd_fresh_id(), "type": type, "color": _bd_style["color"], "fill": _bd_style["fill"],
		"dash": _bd_style["dash"], "size": _bd_style["size"], "font": _bd_style["font"], "text": ""}


func _bd_add(s: Dictionary) -> void:
	_bd_dirty = true
	_bd_shapes.append(s)
	_bd_by_id[str(s["id"])] = s
	if str(s["type"]) == "bookmark":
		_bd_bm_apply(s)


func _bd_remove(ids: Array) -> void:
	# Arrows pointing at a doomed shape keep their end where it was.
	for s in _bd_shapes:
		if str(s["type"]) == "arrow" and not ids.has(str(s["id"])):
			var e := _bd_arrow_ends(s)
			if ids.has(str(s.get("bind_a", ""))):
				s["a"] = _bd_a(e[0])
				s["bind_a"] = ""
			if ids.has(str(s.get("bind_b", ""))):
				s["b"] = _bd_a(e[1])
				s["bind_b"] = ""
	_bd_shapes = _bd_shapes.filter(func(s): return not ids.has(str(s["id"])))
	_bd_reindex()


func _bd_col(s: Dictionary) -> Color:
	var c: Color = BD_PALETTE.get(str(s.get("color", "black")), BD_PALETTE["black"])
	return Color(c.r, c.g, c.b, c.a * _bd_alpha)


func _bd_text_color(s: Dictionary) -> Color:
	if str(s["type"]) == "note":
		return Color(0.10, 0.10, 0.12, _bd_alpha)
	return _bd_col(s)


func _bd_fill(s: Dictionary) -> Color:
	var c := _bd_col(s)
	match str(s.get("fill", "none")):
		"semi":
			return Color(c.r, c.g, c.b, 0.16 * _bd_alpha)
		"solid":
			var d := c.darkened(0.45)
			return Color(d.r, d.g, d.b, 0.95 * _bd_alpha)
		"pattern":
			return Color(c.r, c.g, c.b, 0.07 * _bd_alpha)   # a wash under the hatching
	return Color(0, 0, 0, 0)


func _bd_sw(s: Dictionary) -> float:
	return float(BD_STROKE.get(str(s.get("size", "m")), 3.5))


func _bd_draw_w(s: Dictionary) -> float:
	return _bd_sw(s) * (5.0 if bool(s.get("highlight", false)) else 1.0)


func _bd_fs(s: Dictionary) -> int:
	return int(BD_FONT_PX.get(str(s.get("size", "m")), 24))


func _bd_font(name: String) -> Font:
	if not _bd_fonts.has(name):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(BD_FONT_NAMES.get(name, BD_FONT_NAMES["sans"]))
		f.multichannel_signed_distance_field = true   # crisp at every camera zoom
		_bd_fonts[name] = f
	return _bd_fonts[name]


func _bd_font_of(s: Dictionary) -> Font:
	return _bd_font(str(s.get("font", "draw")))


func _bd_text_size(s: Dictionary, text: String, width: float, fs: int) -> Vector2:
	var t := text if text != "" else " "
	return _bd_font_of(s).get_multiline_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, width, fs)


# Shapes that size themselves to their text: text boxes, notes that grow, geo
# labels that outgrow their box, and todo lists.
func _bd_relayout(s: Dictionary) -> void:
	var fs := _bd_fs(s)
	match str(s["type"]):
		"text":
			if bool(s.get("autosize", true)):
				var sz := _bd_text_size(s, str(s["text"]), -1.0, fs)
				s["w"] = maxf(sz.x + 8.0, fs * 0.8)
				s["h"] = sz.y + 4.0
			else:
				s["h"] = _bd_text_size(s, str(s["text"]), float(s["w"]) - 8.0, fs).y + 4.0
		"note":
			var sz := _bd_text_size(s, str(s["text"]), float(s["w"]) - BD_PAD * 2.0, fs)
			s["h"] = maxf(float(s["w"]), sz.y + BD_PAD * 2.0)
		"geo":
			if str(s["text"]) != "":
				var sz := _bd_text_size(s, str(s["text"]), float(s["w"]) - BD_PAD * 2.0, fs)
				s["h"] = maxf(float(s["h"]), sz.y + BD_PAD * 2.0)
		"todo":
			s["h"] = float(_bd_todo_rows(s)["h"])


func _bd_geo_poly(s: Dictionary) -> PackedVector2Array:
	var r := _bd_rect(s)
	var c := r.get_center()
	match str(s.get("geo", "rectangle")):
		"ellipse":
			var out := PackedVector2Array()
			var h := r.size * 0.5
			for i in 64:
				var ang := TAU * float(i) / 64.0
				out.append(c + Vector2(cos(ang) * h.x, sin(ang) * h.y))
			return out
		"diamond":
			return PackedVector2Array([Vector2(c.x, r.position.y), Vector2(r.end.x, c.y),
				Vector2(c.x, r.end.y), Vector2(r.position.x, c.y)])
		"triangle":
			if bool(s.get("flip_y", false)):
				return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), Vector2(c.x, r.end.y)])
			return PackedVector2Array([Vector2(c.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


# --- board: arrows ------------------------------------------------------------

func _bd_perp(d: Vector2) -> Vector2:
	if d.length() < 0.0001:
		return Vector2.ZERO
	var n := d.normalized()
	return Vector2(-n.y, n.x)


# The rect an arrow end is bound to: a shape's box or a termling's screen.
func _bd_bind_rect(key: String):
	if key == "":
		return null
	if key.begins_with("term"):
		return _bd_term_rect(key)
	var t = _bd_by_id.get(key, null)
	if t == null or not _bd_is_box(t):
		return null
	return _bd_rect(t)


# Where the line from the target's centre toward `toward` leaves its outline
# (a geo shape's real outline, in the shape's own rotated frame), plus a small
# gap so the head doesn't touch it.
func _bd_clip_out(key: String, r: Rect2, toward: Vector2) -> Vector2:
	var c := r.get_center()
	var tgt = _bd_by_id.get(key, null)
	var rot := _bd_rot(tgt) if tgt != null else 0.0
	var d := (toward - c).rotated(-rot)
	if d.length() < 0.001:
		return c
	var dir := d.normalized()
	var edge := Vector2.INF
	if tgt != null and str(tgt["type"]) == "geo":
		var poly := _bd_geo_poly(tgt)
		var far := c + dir * (r.size.length() + 10.0)
		for i in poly.size():
			var hit = Geometry2D.segment_intersects_segment(c, far, poly[i], poly[(i + 1) % poly.size()])
			if hit != null and (edge == Vector2.INF or c.distance_to(hit) < c.distance_to(edge)):
				edge = hit
	if edge == Vector2.INF:
		var half := r.size * 0.5
		edge = c + d * minf(half.x / maxf(absf(d.x), 0.0001), half.y / maxf(absf(d.y), 0.0001))
	if d.length() <= c.distance_to(edge):
		return c   # the other end sits inside the target
	return c + (edge - c + dir * 10.0).rotated(rot)


# [start, end, mid]. A bound end aims at its target's centre and stops at its
# edge; `bend` pushes the midpoint off the straight line (a curved arrow).
func _bd_arrow_ends(s: Dictionary) -> Array:
	var a := _bd_v(s["a"])
	var b := _bd_v(s["b"])
	var ka := str(s.get("bind_a", ""))
	var kb := str(s.get("bind_b", ""))
	var ra = _bd_bind_rect(ka)
	var rb = _bd_bind_rect(kb)
	var ca: Vector2 = ra.get_center() if ra != null else a
	var cb: Vector2 = rb.get_center() if rb != null else b
	var bend := float(s.get("bend", 0.0))
	var mid0 := (ca + cb) * 0.5 + _bd_perp(cb - ca) * bend
	if ra != null:
		a = _bd_clip_out(ka, ra, mid0 if bend != 0.0 else cb)
	if rb != null:
		b = _bd_clip_out(kb, rb, mid0 if bend != 0.0 else ca)
	return [a, b, (a + b) * 0.5 + _bd_perp(b - a) * bend]


func _bd_arrow_curve(s: Dictionary) -> PackedVector2Array:
	var e := _bd_arrow_ends(s)
	var a: Vector2 = e[0]
	var b: Vector2 = e[1]
	if absf(float(s.get("bend", 0.0))) < 0.5:
		return PackedVector2Array([a, b])
	var ctl: Vector2 = e[2] * 2.0 - (a + b) * 0.5   # quadratic control point that puts the curve through mid
	var out := PackedVector2Array()
	for i in 25:
		var t := float(i) / 24.0
		out.append(a.lerp(ctl, t).lerp(ctl.lerp(b, t), t))
	return out


func _bd_arrow_label_rect(s: Dictionary) -> Rect2:
	var t := str(s.get("text", ""))
	if t == "":
		return Rect2()
	var sz := _bd_text_size(s, t, -1.0, _bd_fs(s))
	var m: Vector2 = _bd_arrow_ends(s)[2]
	return Rect2(m - sz * 0.5 - Vector2(6, 2), sz + Vector2(12, 4))


# Termlings as arrow targets: keyed by abduco session (stable across a kitty
# restart), or by term id until the ls poll has learned the session.
func _bd_term_key(id: int) -> String:
	var sess := str(_sessions.get(id, ""))
	return "term:" + sess if sess != "" else "term#%d" % id


func _bd_term_id(key: String) -> int:
	if key.begins_with("term#"):
		return int(key.substr(5))
	if key.begins_with("term:"):
		var sess := key.substr(5)
		for id in _sessions:
			if str(_sessions[id]) == sess and _groups.has(id):
				return id
	return -1


func _bd_term_rect(key: String):
	var id := _bd_term_id(key)
	if id == -1 or not _groups.has(id):
		return null
	var t = _groups[id].terminal
	var sz: Vector2 = t.onscreen_size()
	if sz.x <= 0.0:
		return null
	return Rect2(t.global_position - sz * 0.5, sz)


# The thing an arrow end dropped at p should stick to: a termling (they're
# drawn on top), else the topmost box, preferring anything over a frame.
func _bd_bind_at(p: Vector2, exclude: String) -> String:
	var g := _group_at(p)
	if g != null:
		return _bd_term_key(g.term_id)
	for want_frame in [false, true]:
		for i in range(_bd_shapes.size() - 1, -1, -1):
			var s: Dictionary = _bd_shapes[i]
			if str(s["id"]) == exclude or not _bd_is_box(s) or (str(s["type"]) == "frame") != want_frame:
				continue
			if _bd_rect(s).has_point(_bd_local(s, p)):
				return str(s["id"])
	return ""


# --- board: hit testing + selection ---------------------------------------------

func _bd_tol() -> float:
	return 8.0 / _cam.zoom.x


func _bd_dist_poly(p: Vector2, pts: PackedVector2Array, closed := false) -> float:
	if pts.size() == 1:
		return p.distance_to(pts[0])
	var best := INF
	for i in range(pts.size() - 1):
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])))
	if closed and pts.size() > 2:
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[pts.size() - 1], pts[0])))
	return best


func _bd_frame_px() -> int:
	return int(maxf(20.0, 14.0 / _cam.zoom.x))   # frame titles stay legible when zoomed out


func _bd_frame_name(s: Dictionary) -> String:
	return str(s["text"]) if str(s.get("text", "")) != "" else "Frame"


func _bd_frame_label_rect(s: Dictionary) -> Rect2:
	var px := _bd_frame_px()
	var w := _bd_font("sans").get_string_size(_bd_frame_name(s), HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	return Rect2(float(s["x"]), float(s["y"]) - px * 1.5, w + 8.0, px * 1.4)


func _bd_hit_solid(s: Dictionary, p: Vector2, tol: float) -> bool:
	p = _bd_local(s, p)   # a rotated box is tested in its own frame
	match str(s["type"]):
		"geo":
			var poly := _bd_geo_poly(s)
			if (str(s.get("fill", "none")) != "none" or str(s.get("text", "")) != "") \
					and Geometry2D.is_point_in_polygon(p, poly):
				return true
			return _bd_dist_poly(p, poly, true) <= tol + _bd_sw(s) * 0.5
		"note", "text", "todo", "image", "bookmark":
			return _bd_rect(s).grow(tol * 0.5).has_point(p)
		"frame":
			if _bd_frame_label_rect(s).has_point(p):
				return true
			var r := _bd_rect(s)
			return r.grow(tol).has_point(p) and not r.grow(-tol).has_point(p)
		"arrow":
			if _bd_arrow_label_rect(s).has_point(p):
				return true
			return _bd_dist_poly(p, _bd_arrow_curve(s)) <= tol + _bd_sw(s) * 0.5
		"line":
			return _bd_dist_poly(p, _bd_pts(s)) <= tol + _bd_sw(s) * 0.5
		"draw":
			return _bd_dist_poly(p, _bd_pts(s)) <= tol + _bd_draw_w(s) * 0.5
	return false


# Topmost shape under p. Strokes, filled bodies and labels win; the inside of a
# hollow box counts only when nothing else is there (smallest box first). A
# frame is grabbed by its title or edge, so you can still marquee inside it.
func _bd_hit(p: Vector2, include_locked := false) -> String:
	var tol := _bd_tol()
	for i in range(_bd_shapes.size() - 1, -1, -1):
		var s: Dictionary = _bd_shapes[i]
		if bool(s.get("locked", false)) and not include_locked:
			continue
		if _bd_hit_solid(s, p, tol):
			return str(s["id"])
	var best := ""
	var best_area := INF
	for s in _bd_shapes:
		if bool(s.get("locked", false)) and not include_locked:
			continue
		if str(s["type"]) == "geo" and Geometry2D.is_point_in_polygon(_bd_local(s, p), _bd_geo_poly(s)):
			var area := float(s["w"]) * float(s["h"])
			if area < best_area:
				best = str(s["id"])
				best_area = area
	return best


func _bd_with_groups(ids: Array) -> Array:
	var out := ids.duplicate()
	var groups := {}
	for i in ids:
		var s = _bd_by_id.get(i, null)
		if s != null and str(s.get("group", "")) != "":
			groups[str(s["group"])] = true
	if groups.is_empty():
		return out
	for s in _bd_shapes:
		if groups.has(str(s.get("group", ""))) and not out.has(str(s["id"])):
			out.append(str(s["id"]))
	return out


func _bd_sel_box() -> Rect2:
	var r := Rect2()
	var first := true
	for i in _bd_sel:
		var b := _bd_bounds(_bd_by_id[i])
		r = b if first else r.merge(b)
		first = false
	return r


# Drag handles for the selection: arrow ends + bend, line points, or the eight
# resize handles of the selection box.
func _bd_handles() -> Array:
	var out := []
	if _bd_sel.is_empty() or _bd_edit_id != "":
		return out
	for i in _bd_sel:
		if bool(_bd_by_id[i].get("locked", false)):
			return out
	if _bd_sel.size() == 1:
		var s: Dictionary = _bd_by_id[_bd_sel[0]]
		match str(s["type"]):
			"arrow":
				var e := _bd_arrow_ends(s)
				return [{"kind": "a", "pos": e[0]}, {"kind": "b", "pos": e[1]}, {"kind": "bend", "pos": e[2]}]
			"line":
				var pts := _bd_pts(s)
				for j in pts.size():
					out.append({"kind": "pt", "i": j, "pos": pts[j]})
				return out
	# A single box gets handles on its own (possibly rotated) outline, a group on
	# the selection's bounding box; both get the rotate handle above the top.
	var r := _bd_sel_box()
	var xf := Transform2D.IDENTITY
	if _bd_sel.size() == 1 and _bd_is_box(_bd_by_id[_bd_sel[0]]):
		r = _bd_rect(_bd_by_id[_bd_sel[0]])
		xf = _bd_xform(_bd_by_id[_bd_sel[0]])
	var c := r.get_center()
	if _bd_sel.size() == 1 and str(_bd_by_id[_bd_sel[0]]["type"]) == "bookmark":   # tldraw: bookmarks don't resize
		return [{"kind": "rotate", "pos": xf * Vector2(c.x, r.position.y - 28.0 / _cam.zoom.x)}]
	for n in ["tl", "t", "tr", "r", "br", "b", "bl", "l"]:
		var x: float = r.position.x if n in ["tl", "l", "bl"] else (r.end.x if n in ["tr", "r", "br"] else c.x)
		var y: float = r.position.y if n in ["tl", "t", "tr"] else (r.end.y if n in ["bl", "b", "br"] else c.y)
		out.append({"kind": "resize", "name": n, "pos": xf * Vector2(x, y)})
	out.append({"kind": "rotate", "pos": xf * Vector2(c.x, r.position.y - 28.0 / _cam.zoom.x)})
	return out


func _bd_handle_at(p: Vector2) -> Dictionary:
	var rad := 10.0 / _cam.zoom.x
	for h in _bd_handles():
		if p.distance_to(h["pos"]) <= rad:
			return h
	return {}


# Cove asks before routing a left press: the board takes everything while a
# drawing tool (or space-pan) is armed, and under the select tool it takes the
# selection's handles and anything that isn't a termling.
func _bd_wants_press(p: Vector2, over_termling: bool) -> bool:
	if _bd_tool != "select" or _bd_space:
		return true
	if not _bd_handle_at(p).is_empty():
		return true
	return not over_termling


# --- board: pointer gestures ----------------------------------------------------

func _bd_pointer_down(p: Vector2, ev: InputEventMouseButton) -> void:
	_bd_cam_goal = null
	_bd_last_input_ms = Time.get_ticks_msec()
	_bd_unfocus_termling()   # the keyboard now drives the board
	_bd_down = p
	_bd_down_screen = ev.position
	_bd_moved = false
	_bd_shift = ev.shift_pressed
	if _bd_space or _bd_tool == "hand":
		_bd_g = "pan"
		return
	match _bd_tool:
		"select":
			_bd_select_down(p, ev)
		"eraser":
			_bd_g = "erase"
			_bd_erase = {}
			_bd_erase_at(p)
		"laser":
			_bd_g = "laser"
			_bd_laser.append({"p": p, "t": Time.get_ticks_msec(), "new": true})
		"draw", "highlight":
			_bd_begin()
			var s := _bd_new("draw")
			s["points"] = [_bd_a(p)]
			if _bd_tool == "highlight":
				s["highlight"] = true
				if str(s["color"]) == "black":
					s["color"] = "yellow"
			_bd_add(s)
			_bd_new_id = str(s["id"])
			_bd_g = "draw"
		"arrow":
			_bd_begin()
			var s := _bd_new("arrow")
			s["a"] = _bd_a(p)
			s["b"] = _bd_a(p)
			s["bind_a"] = _bd_bind_at(p, "")
			s["bind_b"] = ""
			s["bend"] = 0.0
			s["head_a"] = false
			s["head_b"] = true
			_bd_add(s)
			_bd_new_id = str(s["id"])
			_bd_sel = [_bd_new_id]
			_bd_handle = {"kind": "b"}
			_bd_g = "handle"
		"line":
			_bd_begin()
			var s := _bd_new("line")
			s["points"] = [_bd_a(p), _bd_a(p)]
			_bd_add(s)
			_bd_new_id = str(s["id"])
			_bd_sel = [_bd_new_id]
			_bd_handle = {"kind": "pt", "i": 1}
			_bd_g = "handle"
		"text", "note", "todo":
			_bd_g = "click"
		_:   # rectangle / ellipse / diamond / triangle / frame: drag out a box
			_bd_begin()
			var s := _bd_new("frame" if _bd_tool == "frame" else "geo")
			if _bd_tool != "frame":
				s["geo"] = _bd_tool
			_bd_set_rect(s, Rect2(p, Vector2(1, 1)))
			_bd_add(s)
			_bd_new_id = str(s["id"])
			_bd_snap_cache = _bd_snap_targets([_bd_new_id])
			_bd_g = "box"
	_bd_ui_refresh()


func _bd_select_down(p: Vector2, ev: InputEventMouseButton) -> void:
	var h := _bd_handle_at(p)
	if not h.is_empty():
		_bd_begin()
		_bd_handle = h
		_bd_snap_orig()
		_bd_rot_center = _bd_orig_box.get_center()
		_bd_rot_start = (p - _bd_rot_center).angle()
		_bd_snap_cache = _bd_snap_targets(_bd_sel)
		_bd_g = "handle"
		return
	var id := _bd_hit(p)
	# A bookmark opens from its address row (as tldraw's link does) or a double-click.
	if id != "" and str(_bd_by_id[id]["type"]) == "bookmark" and not ev.shift_pressed:
		var bm: Dictionary = _bd_by_id[id]
		if ev.double_click or _bd_bm_link_rect(bm).has_point(_bd_local(bm, p)):
			_bd_bm_open(bm)
			_bd_g = "none"
			return
	# A todo list's checkboxes and "+ add item" row work on a single click.
	if id != "" and str(_bd_by_id[id]["type"]) == "todo" and not ev.double_click:
		var part := _bd_todo_part_at(_bd_by_id[id], p)
		if part["kind"] == "check":
			_bd_begin()
			var it: Dictionary = _bd_by_id[id]["items"][int(part["i"])]
			it["done"] = not bool(it.get("done", false))
			_bd_commit()
			_bd_g = "none"
			return
		if part["kind"] == "add":
			_bd_todo_insert(id, _bd_by_id[id]["items"].size())
			_bd_g = "none"
			return
	if ev.double_click:
		_bd_g = "none"
		if id != "":
			_bd_edit_at(id, p)
		else:
			_bd_create_at("text", p)   # tldraw: double-click empty canvas to type
		return
	if id != "":
		_bd_press_id = id
		if ev.shift_pressed:
			if not _bd_sel.has(id):
				_bd_sel = _bd_with_groups(_bd_sel + [id])
				_bd_press_id = ""   # just added: don't toggle it back off on release
		elif not _bd_sel.has(id):
			_bd_sel = _bd_with_groups([id])
		_bd_g = "pending"
	else:
		_bd_g = "marquee"
		_bd_marquee = Rect2(p, Vector2.ZERO)
		_bd_marquee_base = _bd_sel.duplicate() if ev.shift_pressed else []
		if not ev.shift_pressed:
			_bd_sel = []


func _bd_pointer_move(p: Vector2, ev: InputEventMouseMotion) -> void:
	if not _bd_moved and ev.position.distance_to(_bd_down_screen) > 3.0:
		_bd_moved = true
	match _bd_g:
		"pan":
			_cam.position -= ev.relative / _cam.zoom
			_bd_camera_changed()
		"pending":
			if _bd_moved:
				_bd_start_move(ev.alt_pressed)
				_bd_do_move(p, ev)
		"move":
			_bd_do_move(p, ev)
		"marquee":
			_bd_marquee = Rect2(_bd_down, Vector2.ZERO).expand(p)
			var ids := _bd_marquee_base.duplicate()
			for s in _bd_shapes:
				var sid := str(s["id"])
				if bool(s.get("locked", false)) or ids.has(sid):
					continue
				var b := _bd_bounds(s).grow(0.5)
				var inside: bool = _bd_marquee.encloses(b) if str(s["type"]) == "frame" else _bd_marquee.intersects(b)
				if inside:
					ids.append(sid)
			_bd_sel = _bd_with_groups(ids)
		"handle":
			_bd_do_handle(p, ev)
		"box":
			_bd_do_box(p, ev)
		"draw":
			var s = _bd_by_id.get(_bd_new_id, null)
			if s != null:
				var pts: Array = s["points"]
				if p.distance_to(_bd_v(pts[pts.size() - 1])) > 1.5 / _cam.zoom.x:
					pts.append(_bd_a(p))
		"erase":
			_bd_erase_at(p)
		"laser":
			_bd_laser.append({"p": p, "t": Time.get_ticks_msec(), "new": false})


func _bd_pointer_up(p: Vector2, _ev: InputEventMouseButton) -> void:
	var g := _bd_g
	_bd_g = ""
	_bd_bind_hint = ""
	_bd_guides = []
	match g:
		"pending":   # a click on a shape without dragging
			if _bd_shift and _bd_press_id != "" and _bd_sel.has(_bd_press_id):
				var drop := _bd_with_groups([_bd_press_id])
				_bd_sel = _bd_sel.filter(func(i): return not drop.has(i))
			elif not _bd_shift and _bd_press_id != "":
				_bd_sel = _bd_with_groups([_bd_press_id])
		"move":
			_bd_move_ids = []
			_bd_commit()
		"handle":
			if _bd_new_id != "" and not _bd_moved:
				# A click with the arrow/line tool makes nothing.
				_bd_remove([_bd_new_id])
				_bd_pre = ""
				_bd_new_id = ""
				_bd_sel = []
			else:
				_bd_finish_create()
				_bd_commit()
		"box":
			var s = _bd_by_id.get(_bd_new_id, null)
			if s != null and not _bd_moved:
				var sz := Vector2(320, 200) if str(s["type"]) == "frame" else Vector2(100, 100)
				_bd_set_rect(s, Rect2(_bd_down - sz * 0.5, sz))
			_bd_finish_create()
			_bd_commit()
		"draw":
			var s = _bd_by_id.get(_bd_new_id, null)
			if s != null and s["points"].size() == 1:
				s["points"].append(s["points"][0])
			_bd_new_id = ""
			_bd_commit()
		"erase":
			if not _bd_erase.is_empty():
				_bd_begin()
				_bd_remove(_bd_erase.keys())
				_bd_commit()
			_bd_erase = {}
		"click":
			_bd_create_at(_bd_tool, p)
		"marquee":
			_bd_marquee = Rect2()
	_bd_press_id = ""
	_bd_ui_refresh()


func _bd_finish_create() -> void:
	var id := _bd_new_id
	_bd_new_id = ""
	if id == "" or not _bd_by_id.has(id):
		return
	_bd_sel = [id]
	if str(_bd_by_id[id]["type"]) == "frame":
		_bd_adopt_into(id)
	if not _bd_lock and not BD_STICKY_TOOLS.has(_bd_tool):
		_bd_set_tool("select")


func _bd_create_at(kind: String, p: Vector2) -> void:
	_bd_begin()
	var s := _bd_new(kind)
	var fs := _bd_fs(s)
	match kind:
		"text":
			s["autosize"] = true
			_bd_set_rect(s, Rect2(p - Vector2(4.0, fs * 0.7), Vector2(20.0, fs * 1.4)))
		"note":
			if str(s["color"]) in ["black", "white", "grey"]:
				s["color"] = "yellow"
			_bd_set_rect(s, Rect2(p - Vector2(100, 100), Vector2(200, 200)))
		"todo":
			s["text"] = "To do"
			s["items"] = [{"text": "", "done": false}]
			_bd_set_rect(s, Rect2(p, Vector2(300, 100)))
	_bd_add(s)
	_bd_relayout(s)
	if not _bd_lock:
		_bd_set_tool("select")
	_bd_start_edit(str(s["id"]), 0 if kind == "todo" else -1)


func _bd_erase_at(p: Vector2) -> void:
	var id := _bd_hit(p)
	if id != "":
		for i in _bd_with_groups([id]):
			_bd_erase[i] = true


func _bd_cancel_gesture() -> void:
	_bd_dirty = true
	if _bd_pre != "":
		_bd_restore(_bd_pre)
	_bd_pre = ""
	_bd_g = ""
	_bd_new_id = ""
	_bd_move_ids = []
	_bd_bind_hint = ""
	_bd_erase = {}


# --- board: move / resize / handles ---------------------------------------------

func _bd_snap_orig() -> void:
	_bd_orig = {}
	for i in _bd_sel:
		_bd_orig[i] = _bd_by_id[i].duplicate(true)
	_bd_orig_box = _bd_sel_box()


func _bd_start_move(duplicate: bool) -> void:
	_bd_begin()
	if duplicate:
		_bd_sel = _bd_clone(_bd_sel, Vector2.ZERO)   # ⌥-drag leaves the originals behind
	var ids: Array = _bd_sel.duplicate()
	# A frame carries the shapes inside it.
	for i in _bd_sel:
		var f: Dictionary = _bd_by_id[i]
		if str(f["type"]) != "frame":
			continue
		var fr := _bd_rect(f)
		for s in _bd_shapes:
			var sid := str(s["id"])
			if not ids.has(sid) and fr.encloses(_bd_bounds(s)):
				ids.append(sid)
	# An arrow dragged away from what it points at lets go of it.
	for i in ids:
		var s: Dictionary = _bd_by_id[i]
		if str(s["type"]) != "arrow":
			continue
		var e := _bd_arrow_ends(s)
		if str(s.get("bind_a", "")) != "" and not ids.has(str(s["bind_a"])):
			s["a"] = _bd_a(e[0])
			s["bind_a"] = ""
		if str(s.get("bind_b", "")) != "" and not ids.has(str(s["bind_b"])):
			s["b"] = _bd_a(e[1])
			s["bind_b"] = ""
	_bd_orig = {}
	for i in ids:
		_bd_orig[i] = _bd_by_id[i].duplicate(true)
	_bd_move_ids = ids
	_bd_last_d = Vector2.ZERO
	_bd_orig_box = _bd_sel_box()
	_bd_snap_cache = _bd_snap_targets(ids)
	_bd_g = "move"


func _bd_do_move(p: Vector2, ev: InputEventWithModifiers) -> void:
	var d := p - _bd_down
	if ev.shift_pressed:   # axis lock
		if absf(d.x) > absf(d.y):
			d.y = 0.0
		else:
			d.x = 0.0
	if _bd_snapping(ev):
		d += _bd_snap_offset(Rect2(_bd_orig_box.position + d, _bd_orig_box.size))
	else:
		_bd_guides = []
	for i in _bd_move_ids:
		if _bd_by_id.has(i):
			_bd_translate(_bd_by_id[i], _bd_orig[i], d)
	var step := d - _bd_last_d
	_bd_last_d = d
	_bd_carry_members(_bd_move_ids, step)


func _bd_translate(s: Dictionary, o: Dictionary, d: Vector2) -> void:
	match str(s["type"]):
		"arrow":
			s["a"] = _bd_a(_bd_v(o["a"]) + d)
			s["b"] = _bd_a(_bd_v(o["b"]) + d)
		"line", "draw":
			var pts := []
			for q in o["points"]:
				pts.append(_bd_a(_bd_v(q) + d))
			s["points"] = pts
		_:
			s["x"] = float(o["x"]) + d.x
			s["y"] = float(o["y"]) + d.y


# Termlings living in a moved frame/box walk along with it.
func _bd_carry_members(ids: Array, step: Vector2) -> void:
	if step == Vector2.ZERO:
		return
	for tid in _zone_of:
		if ids.has(_zone_of[tid]) and _groups.has(tid):
			_groups[tid].translate_by(step)


func _bd_snap_angle(origin: Vector2, p: Vector2) -> Vector2:
	var d := p - origin
	return origin + Vector2.from_angle(snappedf(d.angle(), PI / 12.0)) * d.length()


func _bd_do_handle(p: Vector2, ev: InputEventWithModifiers) -> void:
	var kind := str(_bd_handle.get("kind", ""))
	if kind == "resize":
		_bd_do_resize(p, ev)
		return
	if kind == "rotate":
		var turn := (p - _bd_rot_center).angle() - _bd_rot_start
		if ev.shift_pressed:
			turn = snappedf(turn, PI / 12.0)
		for i in _bd_orig:
			if _bd_by_id.has(i):
				_bd_rotate_shape(_bd_by_id[i], _bd_orig[i], _bd_rot_center, turn)
		return
	if _bd_sel.size() != 1 or not _bd_by_id.has(_bd_sel[0]):
		return
	var s: Dictionary = _bd_by_id[_bd_sel[0]]
	match kind:
		"a", "b":
			var q := p
			if ev.shift_pressed:
				q = _bd_snap_angle(_bd_arrow_ends(s)[1 if kind == "a" else 0], p)
			s[kind] = _bd_a(q)
			var key := _bd_bind_at(p, str(s["id"]))
			s["bind_" + kind] = key
			_bd_bind_hint = key
		"bend":
			var e := _bd_arrow_ends(s)
			var a: Vector2 = e[0]
			var b: Vector2 = e[1]
			var bend := (p - (a + b) * 0.5).dot(_bd_perp(b - a))
			s["bend"] = 0.0 if absf(bend) < 6.0 / _cam.zoom.x else snappedf(bend, 0.01)
		"pt":
			var i := int(_bd_handle["i"])
			var pts: Array = s["points"]
			var q := p
			if ev.shift_pressed and pts.size() > 1:
				q = _bd_snap_angle(_bd_v(pts[i - 1 if i > 0 else 1]), p)
			pts[i] = _bd_a(q)


# Scale the selection about the handle's opposite side (or its centre with ⌥).
# Signed factors let a drag past the anchor flip the shapes, as in tldraw.
#
# A single box resizes in its own frame, so a rotated shape keeps its angle and
# stretches along its own sides. Images keep their aspect on the corners.
func _bd_do_resize(p: Vector2, ev: InputEventWithModifiers) -> void:
	var single := _bd_orig.size() == 1 and _bd_is_box(_bd_orig.values()[0])
	var o: Dictionary = _bd_orig.values()[0] if single else {}
	var r := _bd_rect(o) if single else _bd_orig_box
	var n := str(_bd_handle["name"])
	var hx: int = -1 if n in ["tl", "l", "bl"] else (1 if n in ["tr", "r", "br"] else 0)
	var hy: int = -1 if n in ["tl", "t", "tr"] else (1 if n in ["bl", "b", "br"] else 0)
	if _bd_snapping(ev) and (not single or _bd_rot(o) == 0.0):
		p = _bd_snap_point(p, hx != 0, hy != 0)
	else:
		_bd_guides = []
	var q := _bd_local(o, p) if single else p
	var c := r.get_center()
	var half := r.size * 0.5
	var corner := c + Vector2(hx * half.x, hy * half.y)
	var anchor := c if ev.alt_pressed else c - Vector2(hx * half.x, hy * half.y)
	var sx := 1.0
	var sy := 1.0
	if hx != 0 and absf(corner.x - anchor.x) > 0.0001:
		sx = (q.x - anchor.x) / (corner.x - anchor.x)
	if hy != 0 and absf(corner.y - anchor.y) > 0.0001:
		sy = (q.y - anchor.y) / (corner.y - anchor.y)
	var keep := ev.shift_pressed or (single and str(o["type"]) == "image")
	if keep and hx != 0 and hy != 0:
		var k := maxf(absf(sx), absf(sy))
		sx = k if sx >= 0.0 else -k
		sy = k if sy >= 0.0 else -k
	if single:
		var id: String = _bd_orig.keys()[0]
		var s: Dictionary = _bd_by_id[id]
		_bd_scale(s, o, anchor, Vector2(sx, sy), false)
		var rot := _bd_rot(o)
		if rot != 0.0:   # resized in the shape's frame: put its centre back in the world
			var nr := _bd_rect(s)
			var nc := c + (nr.get_center() - c).rotated(rot)
			_bd_set_rect(s, Rect2(nc - nr.size * 0.5, nr.size))
		return
	for i in _bd_orig:
		if _bd_by_id.has(i):
			_bd_scale(_bd_by_id[i], _bd_orig[i], anchor, Vector2(sx, sy))


# `world` scaling (a group, a flip) mirrors a rotated box's angle when it flips;
# scaling in the box's own frame (see _bd_do_resize) keeps it.
func _bd_scale(s: Dictionary, o: Dictionary, anchor: Vector2, k: Vector2, world := true) -> void:
	var f := func(q: Vector2) -> Vector2: return anchor + (q - anchor) * k
	match str(s["type"]):
		"arrow":
			s["a"] = _bd_a(f.call(_bd_v(o["a"])))
			s["b"] = _bd_a(f.call(_bd_v(o["b"])))
			s["bend"] = float(o.get("bend", 0.0)) * (1.0 if k.x * k.y >= 0.0 else -1.0)
		"line", "draw":
			var pts := []
			for q in o["points"]:
				pts.append(_bd_a(f.call(_bd_v(q))))
			s["points"] = pts
		_:
			var r := _bd_rect(o)
			var p0: Vector2 = f.call(r.position)
			var p1: Vector2 = f.call(r.end)
			var nr := Rect2(p0, p1 - p0).abs()
			if str(s["type"]) == "text":
				s["autosize"] = false
				nr.size.x = maxf(nr.size.x, 20.0)
			_bd_set_rect(s, nr)
			if str(s.get("geo", "")) == "triangle":
				s["flip_y"] = bool(o.get("flip_y", false)) != (k.y < 0.0)
			if world and k.x * k.y < 0.0 and _bd_rot(o) != 0.0:
				s["rot"] = -_bd_rot(o)
			_bd_relayout(s)


func _bd_do_box(p: Vector2, ev: InputEventWithModifiers) -> void:
	var s = _bd_by_id.get(_bd_new_id, null)
	if s == null:
		return
	if _bd_snapping(ev):
		p = _bd_snap_point(p, true, true)
	else:
		_bd_guides = []
	var d := p - _bd_down
	if ev.shift_pressed:
		var m := maxf(absf(d.x), absf(d.y))
		d = Vector2(m if d.x >= 0.0 else -m, m if d.y >= 0.0 else -m)
	var r := Rect2(_bd_down - d, d * 2.0) if ev.alt_pressed else Rect2(_bd_down, d)
	_bd_set_rect(s, r.abs())


# --- board: text editing ---------------------------------------------------------
# An in-place LineEdit/TextEdit sits over the shape in world space (a child of
# the overlay, so it zooms with the camera). The shape updates as you type.

func _bd_edit_at(id: String, p: Vector2) -> void:
	var s: Dictionary = _bd_by_id[id]
	if str(s["type"]) != "todo":
		_bd_start_edit(id)
		return
	var part := _bd_todo_part_at(s, p)
	match str(part["kind"]):
		"item", "check":
			_bd_start_edit(id, int(part["i"]))
		"add":
			_bd_todo_insert(id, s["items"].size())
		_:
			_bd_start_edit(id, -2)


func _bd_edit_text(s: Dictionary, part: int) -> String:
	if str(s["type"]) == "todo":
		if part == -2:
			return str(s["text"])
		var items: Array = s["items"]
		if part >= 0 and part < items.size():
			return str(items[part]["text"])
		return ""
	return str(s.get("text", ""))


func _bd_start_edit(id: String, part := -1) -> void:
	_bd_stop_edit()
	var s = _bd_by_id.get(id, null)
	if s == null or bool(s.get("locked", false)) or str(s["type"]) == "bookmark":
		return
	var type := str(s["type"])
	if type in ["line", "draw"]:
		return
	if type == "todo" and part == -1:
		part = -2
	_bd_begin()
	_bd_unfocus_termling()
	_bd_edit_id = id
	_bd_edit_part = part
	_bd_dirty = true
	_bd_sel = [id]
	var font := _bd_font("sans") if type == "frame" else _bd_font_of(s)
	var fs := _bd_frame_px() if type == "frame" else (_bd_fs(s) + 4 if type == "todo" and part == -2 else _bd_fs(s))
	var ed: Control
	if type == "frame" or type == "todo":
		var le := LineEdit.new()
		le.text = _bd_edit_text(s, part)
		le.flat = true
		le.text_changed.connect(_bd_on_edit_text)
		le.text_submitted.connect(func(_t): _bd_edit_submit())
		le.gui_input.connect(_bd_edit_key)
		ed = le
	else:
		var te := TextEdit.new()
		te.text = _bd_edit_text(s, part)
		var grows := type == "text" and bool(s.get("autosize", true))
		te.wrap_mode = TextEdit.LINE_WRAPPING_NONE if grows else TextEdit.LINE_WRAPPING_BOUNDARY
		te.scroll_fit_content_height = true
		te.text_changed.connect(func(): _bd_on_edit_text(te.text))
		ed = te
	ed.add_theme_font_override("font", font)
	ed.add_theme_font_size_override("font_size", fs)
	ed.add_theme_color_override("font_color", _bd_text_color(s))
	ed.add_theme_color_override("caret_color", BD_SEL)
	for sb in ["normal", "focus", "read_only"]:
		ed.add_theme_stylebox_override(sb, StyleBoxEmpty.new())
	_bd_overlay.add_child(ed)
	_bd_editor = ed
	_bd_place_editor()
	ed.grab_focus()
	if ed is LineEdit:
		(ed as LineEdit).select_all()
	else:
		(ed as TextEdit).select_all()


func _bd_on_edit_text(t: String) -> void:
	_bd_dirty = true
	var s = _bd_by_id.get(_bd_edit_id, null)
	if s == null:
		return
	if str(s["type"]) == "todo" and _bd_edit_part >= 0:
		var items: Array = s["items"]
		if _bd_edit_part < items.size():
			items[_bd_edit_part]["text"] = t
	else:
		s["text"] = t
	_bd_relayout(s)


func _bd_place_editor() -> void:
	var s = _bd_by_id.get(_bd_edit_id, null)
	if s == null or _bd_editor == null:
		return
	var fs := _bd_fs(s)
	var pos := Vector2.ZERO
	var size := Vector2.ZERO
	match str(s["type"]):
		"text":
			var r := _bd_rect(s)
			pos = r.position + Vector2(4, 2)
			size = Vector2(r.size.x + fs, r.size.y)
		"note", "geo":
			var r := _bd_rect(s)
			var th := _bd_text_size(s, str(s["text"]), r.size.x - BD_PAD * 2.0, fs).y
			pos = Vector2(r.position.x + BD_PAD, r.get_center().y - th * 0.5)
			size = Vector2(r.size.x - BD_PAD * 2.0, th)
		"frame":
			var lr := _bd_frame_label_rect(s)
			pos = lr.position + Vector2(4, 0)
			size = Vector2(maxf(lr.size.x, 160.0), lr.size.y)
		"arrow":
			var m: Vector2 = _bd_arrow_ends(s)[2]
			var sz := _bd_text_size(s, str(s["text"]), -1.0, fs)
			size = Vector2(maxf(sz.x, 120.0) + fs, sz.y)
			pos = m - size * 0.5
		"todo":
			var rows := _bd_todo_rows(s)
			if _bd_edit_part == -2:
				var tr: Rect2 = rows["title"]
				pos = tr.position
				size = tr.size
			elif _bd_edit_part >= 0 and _bd_edit_part < rows["items"].size():
				var ir: Rect2 = rows["items"][_bd_edit_part]
				var box: float = rows["box"]
				pos = ir.position + Vector2(box + 10.0, 0)
				size = Vector2(ir.size.x - box - 10.0, ir.size.y)
	_bd_editor.position = pos
	_bd_editor.size = size
	if _bd_is_box(s):   # turn with a rotated shape, about its centre
		_bd_editor.pivot_offset = _bd_rect(s).get_center() - pos
		_bd_editor.rotation = _bd_rot(s)


func _bd_stop_edit() -> void:
	if _bd_edit_id == "":
		return
	var id := _bd_edit_id
	var part := _bd_edit_part
	_bd_edit_id = ""
	_bd_edit_part = -1
	if _bd_editor != null:
		_bd_editor.queue_free()
		_bd_editor = null
	var s = _bd_by_id.get(id, null)
	if s != null:
		if str(s["type"]) == "text" and str(s["text"]).strip_edges() == "":
			_bd_remove([id])   # an emptied text box goes away, as in tldraw
		else:
			if str(s["type"]) == "todo" and part >= 0:
				var items: Array = s["items"]
				if part < items.size() and items.size() > 1 and str(items[part]["text"]).strip_edges() == "":
					items.remove_at(part)
			_bd_relayout(s)
	_bd_commit()


# Enter on a todo item starts the next one (Enter on an empty item ends the list).
func _bd_edit_submit() -> void:
	var id := _bd_edit_id
	var part := _bd_edit_part
	var s = _bd_by_id.get(id, null)
	if s != null and str(s["type"]) == "todo" and part >= 0 \
			and part < s["items"].size() and str(s["items"][part]["text"]).strip_edges() != "":
		_bd_todo_insert(id, part + 1)
	else:
		_bd_stop_edit()


# Todo item editor keys: backspace on an empty item removes it, up/down step.
func _bd_edit_key(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed) or _bd_editor == null:
		return
	var id := _bd_edit_id
	var part := _bd_edit_part
	var s = _bd_by_id.get(id, null)
	if s == null or str(s["type"]) != "todo" or part < 0:
		return
	var items: Array = s["items"]
	var le := _bd_editor as LineEdit
	var k := (ev as InputEventKey).keycode
	var to := -1
	if k == KEY_BACKSPACE and le.text == "" and items.size() > 1:
		items.remove_at(part)
		to = maxi(part - 1, 0)
	elif k == KEY_UP and part > 0:
		to = part - 1
	elif k == KEY_DOWN and part < items.size() - 1:
		to = part + 1
	if to == -1:
		return
	le.accept_event()
	_bd_edit_part = -3   # we moved deliberately: stop_edit mustn't prune this item
	_bd_stop_edit()
	_bd_start_edit(id, to)


func _bd_todo_insert(id: String, at: int) -> void:
	_bd_stop_edit()
	var s = _bd_by_id.get(id, null)
	if s == null:
		return
	_bd_begin()
	var items: Array = s["items"]
	var i := clampi(at, 0, items.size())
	items.insert(i, {"text": "", "done": false})
	_bd_relayout(s)
	_bd_start_edit(id, i)


func _bd_todo_rows(s: Dictionary) -> Dictionary:
	var fs := _bd_fs(s)
	var x := float(s["x"])
	var w := float(s["w"])
	var y := float(s["y"]) + BD_PAD
	var box := float(fs) * 0.85
	var inner := w - BD_PAD * 2.0
	var title_h := _bd_text_size(s, str(s["text"]), inner - 60.0, fs + 4).y
	var title := Rect2(x + BD_PAD, y, inner - 60.0, title_h)
	y += title_h + BD_PAD * 0.6
	var items := []
	for it in s.get("items", []):
		var th := maxf(_bd_text_size(s, str(it.get("text", "")), inner - box - 10.0, fs).y, box)
		items.append(Rect2(x + BD_PAD, y, inner, th))
		y += th + 6.0
	var add := Rect2(x + BD_PAD, y, inner, float(fs) * 1.2)
	y += float(fs) * 1.2 + BD_PAD
	return {"title": title, "items": items, "add": add, "box": box, "h": y - float(s["y"])}


func _bd_todo_part_at(s: Dictionary, p: Vector2) -> Dictionary:
	p = _bd_local(s, p)
	var rows := _bd_todo_rows(s)
	var items: Array = rows["items"]
	var box: float = rows["box"]
	for i in items.size():
		var r: Rect2 = items[i]
		if r.grow(3.0).has_point(p):
			return {"kind": "check" if p.x < r.position.x + box + 6.0 else "item", "i": i}
	var add: Rect2 = rows["add"]
	if add.has_point(p):
		return {"kind": "add"}
	var title: Rect2 = rows["title"]
	if title.has_point(p):
		return {"kind": "title"}
	return {"kind": "body"}


# --- board: drawing ----------------------------------------------------------------

func _bd_draw() -> void:
	if _cam == null:
		return
	for s in _bd_shapes:   # frames first: they're backdrops for what's in them
		if str(s["type"]) == "frame":
			_bd_draw_shape(_bd_layer, s)
	for s in _bd_shapes:
		if str(s["type"]) != "frame" and not _bd_is_live(s):
			_bd_draw_shape(_bd_layer, s)


# An arrow with an end on a termling: it moves whenever the termling wanders.
func _bd_is_live(s: Dictionary) -> bool:
	return str(s["type"]) == "arrow" and (str(s.get("bind_a", "")).begins_with("term") \
		or str(s.get("bind_b", "")).begins_with("term"))


func _bd_draw_live() -> void:
	if _cam == null:
		return
	for s in _bd_shapes:
		if _bd_is_live(s):
			_bd_draw_shape(_bd_live_layer, s)


func _bd_draw_shape(ci: CanvasItem, s: Dictionary) -> void:
	_bd_alpha = 0.3 if _bd_erase.has(str(s["id"])) else 1.0
	var rot := _bd_rot(s)
	if rot != 0.0:
		ci.draw_set_transform_matrix(_bd_xform(s))
	match str(s["type"]):
		"geo":
			_bd_draw_geo(ci, s)
		"image":
			_bd_draw_image(ci, s)
		"bookmark":
			_bd_draw_bookmark(ci, s)
		"text":
			if str(s["id"]) != _bd_edit_id:
				var fs := _bd_fs(s)
				var f := _bd_font_of(s)
				var width := -1.0 if bool(s.get("autosize", true)) else float(s["w"]) - 8.0
				ci.draw_multiline_string(f, Vector2(float(s["x"]) + 4.0, float(s["y"]) + 2.0 + f.get_ascent(fs)),
					str(s["text"]), HORIZONTAL_ALIGNMENT_LEFT, width, fs, -1, _bd_col(s))
		"note":
			var r := _bd_rect(s)
			ci.draw_rect(Rect2(r.position + Vector2(3, 5), r.size), Color(0, 0, 0, 0.28 * _bd_alpha))
			ci.draw_rect(r, _bd_col(s))
			if str(s["id"]) != _bd_edit_id and str(s["text"]) != "":
				_bd_label(ci, s, str(s["text"]), r, _bd_text_color(s))
		"frame":
			_bd_draw_frame(ci, s)
		"todo":
			_bd_draw_todo(ci, s)
		"arrow":
			_bd_draw_arrow(ci, s)
		"line":
			_bd_stroke(ci, _bd_pts(s), false, _bd_col(s), _bd_sw(s), str(s.get("dash", "solid")), _bd_seed(s))
		"draw":
			_bd_draw_free(ci, s)
	if rot != 0.0:
		ci.draw_set_transform_matrix(Transform2D.IDENTITY)
	_bd_alpha = 1.0


# A polyline in the shape's dash style: solid, dashed or dotted.
func _bd_stroke(ci: CanvasItem, pts: PackedVector2Array, closed: bool, col: Color, w: float, dash: String, seed := 0) -> void:
	if pts.size() < 2:
		if pts.size() == 1:
			ci.draw_circle(pts[0], w * 0.5, col)
		return
	var path := pts.duplicate()
	if closed:
		path.append(pts[0])
	if dash == "solid":
		ci.draw_polyline(path, col, w, true)
		return
	if dash == "draw":
		_bd_sketch(ci, path, col, w, seed)
		return
	var dotted := dash == "dotted"
	var on: float = 0.01 if dotted else w * 4.0 + 4.0
	var off: float = w * 2.5 + 3.0 if dotted else w * 3.0 + 4.0
	var drawing := true
	var remain := on
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var seg := a.distance_to(b)
		var t := 0.0
		while t < seg:
			var step := minf(remain, seg - t)
			if drawing:
				var p0 := a.lerp(b, t / seg)
				if dotted:
					ci.draw_circle(p0, w * 0.6, col)
				else:
					ci.draw_line(p0, a.lerp(b, (t + step) / seg), col, w, true)
			t += step
			remain -= step
			if remain <= 0.0001:
				drawing = not drawing
				remain = on if drawing else off


# A wrapped label centred in r (geo boxes, sticky notes).
func _bd_label(ci: CanvasItem, s: Dictionary, t: String, r: Rect2, col: Color) -> void:
	var fs := _bd_fs(s)
	var f := _bd_font_of(s)
	var width := maxf(r.size.x - BD_PAD * 2.0, 10.0)
	var th := f.get_multiline_string_size(t, HORIZONTAL_ALIGNMENT_CENTER, width, fs).y
	var pos := Vector2(r.position.x + BD_PAD, r.get_center().y - th * 0.5 + f.get_ascent(fs))
	ci.draw_multiline_string(f, pos, t, HORIZONTAL_ALIGNMENT_CENTER, width, fs, -1, col)


func _bd_draw_geo(ci: CanvasItem, s: Dictionary) -> void:
	var poly := _bd_geo_poly(s)
	var fill := _bd_fill(s)
	var big := float(s["w"]) > 2.0 and float(s["h"]) > 2.0
	if fill.a > 0.0 and big:
		ci.draw_colored_polygon(poly, fill)
	if str(s.get("fill", "none")) == "pattern" and big:
		_bd_hatch(ci, poly, _bd_rect(s), _bd_col(s), _bd_sw(s))
	_bd_stroke(ci, poly, true, _bd_col(s), _bd_sw(s), str(s.get("dash", "solid")), _bd_seed(s))
	var t := str(s.get("text", ""))
	if t != "" and str(s["id"]) != _bd_edit_id:
		_bd_label(ci, s, t, _bd_rect(s), _bd_col(s))


func _bd_draw_frame(ci: CanvasItem, s: Dictionary) -> void:
	var r := _bd_rect(s)
	var c := _bd_col(s)
	ci.draw_rect(r, Color(c.r, c.g, c.b, 0.06 * _bd_alpha))
	var edge := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	var fdash := str(s.get("dash", "solid"))
	_bd_stroke(ci, edge, true, Color(c.r, c.g, c.b, 0.45 * _bd_alpha), 3.0, "solid" if fdash == "draw" else fdash)
	if str(s["id"]) == _bd_edit_id:
		return
	var px := _bd_frame_px()
	var label := _bd_frame_name(s)
	var n := _bd_member_count(str(s["id"]))
	if n > 0:
		label += "  · %d" % n
	ci.draw_string(_bd_font("sans"), Vector2(r.position.x + 4.0, r.position.y - px * 0.45), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(c.r, c.g, c.b, 0.9 * _bd_alpha))


func _bd_draw_todo(ci: CanvasItem, s: Dictionary) -> void:
	var r := _bd_rect(s)
	var c := _bd_col(s)
	ci.draw_rect(Rect2(r.position + Vector2(3, 5), r.size), Color(0, 0, 0, 0.25 * _bd_alpha))
	ci.draw_rect(r, Color(0.13, 0.12, 0.11, 0.95 * _bd_alpha))
	ci.draw_rect(r, c, false, 2.0)
	var rows := _bd_todo_rows(s)
	var fs := _bd_fs(s)
	var f := _bd_font_of(s)
	var items: Array = s.get("items", [])
	var editing := str(s["id"]) == _bd_edit_id
	var done := 0
	for it in items:
		if bool(it.get("done", false)):
			done += 1
	var tr: Rect2 = rows["title"]
	if not (editing and _bd_edit_part == -2):
		ci.draw_multiline_string(f, tr.position + Vector2(0, f.get_ascent(fs + 4)), str(s["text"]),
			HORIZONTAL_ALIGNMENT_LEFT, tr.size.x, fs + 4, -1, c)
	ci.draw_string(f, Vector2(r.end.x - BD_PAD - 60.0, tr.position.y + f.get_ascent(fs)), "%d/%d" % [done, items.size()],
		HORIZONTAL_ALIGNMENT_RIGHT, 60.0, fs - 4, Color(c.r, c.g, c.b, 0.6 * _bd_alpha))
	var box: float = rows["box"]
	var line_h := f.get_height(fs)
	var item_rows: Array = rows["items"]
	for i in item_rows.size():
		var ir: Rect2 = item_rows[i]
		var it: Dictionary = items[i]
		var is_done := bool(it.get("done", false))
		var br := Rect2(ir.position + Vector2(0, (line_h - box) * 0.5), Vector2(box, box))
		ci.draw_rect(br, c, false, 2.0)
		if is_done:
			ci.draw_rect(br.grow(-3.0), Color(c.r, c.g, c.b, 0.25 * _bd_alpha))
			ci.draw_polyline(PackedVector2Array([br.position + br.size * Vector2(0.2, 0.55),
				br.position + br.size * Vector2(0.42, 0.78), br.position + br.size * Vector2(0.82, 0.25)]), c, 2.5, true)
		if editing and _bd_edit_part == i:
			continue
		var tc := Color(0.55, 0.55, 0.58, _bd_alpha) if is_done else Color(0.92, 0.92, 0.94, _bd_alpha)
		var tx := ir.position.x + box + 10.0
		var tw := ir.size.x - box - 10.0
		var text := str(it.get("text", ""))
		ci.draw_multiline_string(f, Vector2(tx, ir.position.y + f.get_ascent(fs)), text,
			HORIZONTAL_ALIGNMENT_LEFT, tw, fs, -1, tc)
		if is_done and text != "":
			var sw := minf(f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x, tw)
			var sy := ir.position.y + line_h * 0.55
			ci.draw_line(Vector2(tx, sy), Vector2(tx + sw, sy), tc, 1.5)
	var ar: Rect2 = rows["add"]
	ci.draw_string(f, Vector2(ar.position.x, ar.position.y + f.get_ascent(fs)), "+ add item",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, Color(c.r, c.g, c.b, 0.4 * _bd_alpha))


func _bd_draw_arrow(ci: CanvasItem, s: Dictionary) -> void:
	var pts := _bd_arrow_curve(s)
	var c := _bd_col(s)
	var w := _bd_sw(s)
	_bd_stroke(ci, pts, false, c, w, str(s.get("dash", "solid")), _bd_seed(s))
	if pts.size() >= 2:
		if bool(s.get("head_b", true)):
			_bd_head(ci, pts[pts.size() - 1], pts[pts.size() - 2], c, w)
		if bool(s.get("head_a", false)):
			_bd_head(ci, pts[0], pts[1], c, w)
	var t := str(s.get("text", ""))
	if t != "" and str(s["id"]) != _bd_edit_id:
		var lr := _bd_arrow_label_rect(s)
		ci.draw_rect(lr, Color(0.155, 0.14, 0.13, 0.92 * _bd_alpha))   # ground colour: the label cuts the shaft
		var f := _bd_font_of(s)
		var fs := _bd_fs(s)
		ci.draw_multiline_string(f, lr.position + Vector2(6, 2 + f.get_ascent(fs)), t,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, -1, c)


func _bd_head(ci: CanvasItem, tip: Vector2, from: Vector2, c: Color, w: float) -> void:
	var d := tip - from
	if d.length() < 0.001:
		return
	d = d.normalized()
	var L := maxf(14.0, w * 4.0)
	ci.draw_polyline(PackedVector2Array([tip - d.rotated(0.5) * L, tip, tip - d.rotated(-0.5) * L]), c, w, true)


func _bd_draw_overlay() -> void:
	if _cam == null:
		return
	var o := _bd_overlay
	var z := _cam.zoom.x
	var lw := 1.5 / z
	if _bd_bind_hint != "":
		var hint = _bd_bind_rect(_bd_bind_hint)
		if hint != null:
			var hr: Rect2 = hint
			o.draw_rect(hr.grow(6.0 / z), BD_SEL, false, 2.5 / z)
	if not _bd_sel.is_empty() and _bd_edit_id != "":
		o.draw_rect(_bd_sel_box().grow(4.0 / z), Color(BD_SEL, 0.5), false, lw)
	elif not _bd_sel.is_empty():
		var only_line := _bd_sel.size() == 1 and str(_bd_by_id[_bd_sel[0]]["type"]) in ["arrow", "line"]
		if not only_line:
			if _bd_sel.size() > 1:
				for i in _bd_sel:
					o.draw_rect(_bd_bounds(_bd_by_id[i]), Color(BD_SEL, 0.45), false, lw)
				o.draw_rect(_bd_sel_box(), BD_SEL, false, lw)
			else:   # one shape: outline it along its own (possibly rotated) sides
				var one: Dictionary = _bd_by_id[_bd_sel[0]]
				var r1 := _bd_rect(one) if _bd_is_box(one) else _bd_bounds(one)
				var xf := _bd_xform(one) if _bd_is_box(one) else Transform2D.IDENTITY
				o.draw_polyline(PackedVector2Array([xf * r1.position, xf * Vector2(r1.end.x, r1.position.y),
					xf * r1.end, xf * Vector2(r1.position.x, r1.end.y), xf * r1.position]), BD_SEL, lw, true)
		for h in _bd_handles():
			var hrad := (3.5 if h["kind"] == "bend" else 5.0) / z
			o.draw_circle(h["pos"], hrad, Color(1, 1, 1))
			o.draw_arc(h["pos"], hrad, 0.0, TAU, 20, BD_SEL, lw, true)
	if _bd_g == "marquee" and _bd_moved:
		o.draw_rect(_bd_marquee, Color(BD_SEL, 0.08))
		o.draw_rect(_bd_marquee, BD_SEL, false, lw)
	for gl in _bd_guides:
		o.draw_line(gl[0], gl[1], BD_SNAP_COL, lw)
	var now := Time.get_ticks_msec()
	for i in range(1, _bd_laser.size()):
		var q: Dictionary = _bd_laser[i]
		if bool(q["new"]):
			continue
		var a := clampf(1.0 - float(now - int(q["t"])) / 900.0, 0.0, 1.0)
		o.draw_line(_bd_laser[i - 1]["p"], q["p"], Color(1.0, 0.25, 0.3, a), 5.0 / z, true)


# --- board: keys -------------------------------------------------------------------
# Only called while no termling has focus (see _input / _unhandled_input).

func _bd_key(ev: InputEventKey) -> bool:
	if _bd_edit_id != "":
		return false
	_bd_last_input_ms = Time.get_ticks_msec()
	var k := ev.keycode
	var cmd := ev.meta_pressed or ev.ctrl_pressed
	var arrows := [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]
	if ev.echo:
		if k in arrows and not cmd:
			_bd_nudge(k, ev.shift_pressed)
			return true
		return false
	if cmd:
		match k:
			KEY_Z:
				if ev.shift_pressed:
					_bd_redo()
				else:
					_bd_undo()
			KEY_Y:
				_bd_redo()
			KEY_A:
				_bd_select_all()
			KEY_D:
				_bd_duplicate()
			KEY_C:
				_bd_copy()
			KEY_X:
				_bd_cut()
			KEY_V:
				_bd_paste(get_global_mouse_position())
			KEY_G:
				if ev.alt_pressed:
					_bd_frame_selection()
				elif ev.shift_pressed:
					_bd_ungroup()
				else:
					_bd_group()
			KEY_U:
				_bd_insert_media()
			KEY_EQUAL, KEY_PLUS:
				if ev.alt_pressed:
					_bd_ui_bump(1.15)   # ⌘⌥=: bigger chrome
				else:
					_bd_zoom_to(_cam.position, _cam.zoom.x * 1.25)
			KEY_MINUS:
				if ev.alt_pressed:
					_bd_ui_bump(1.0 / 1.15)
				else:
					_bd_zoom_to(_cam.position, _cam.zoom.x * 0.8)
			KEY_SLASH:
				_bd_toggle_help()
			_:
				return false
		_bd_ui_refresh()
		return true
	if ev.alt_pressed and ev.shift_pressed:
		match k:
			KEY_H:
				_bd_distribute(true)
			KEY_V:
				_bd_distribute(false)
			KEY_F:
				_bd_set_style("fill", "pattern")
			KEY_PERIOD:
				_bd_rotate_sel(PI / 192.0)   # tldraw's fine rotate: HALF_PI / 96
			KEY_COMMA:
				_bd_rotate_sel(-PI / 192.0)
			_:
				return false
		_bd_ui_refresh()
		return true
	if ev.alt_pressed:
		match k:
			KEY_BRACKETRIGHT:
				_bd_reorder("forward")
			KEY_BRACKETLEFT:
				_bd_reorder("backward")
			KEY_A:
				_bd_align("left")
			KEY_H:
				_bd_align("center-h")
			KEY_D:
				_bd_align("right")
			KEY_W:
				_bd_align("top")
			KEY_V:
				_bd_align("center-v")
			KEY_S:
				_bd_align("bottom")
			KEY_T:
				_bd_set_style("color", "white")
			KEY_F:
				_bd_set_style("fill", "solid")
			_:
				return false
		_bd_ui_refresh()
		return true
	if ev.shift_pressed:
		match k:
			KEY_1:
				_bd_zoom_to_fit(false)
			KEY_2:
				_bd_zoom_to_fit(true)
			KEY_0:
				_bd_zoom_to(_cam.position, 1.0)
			KEY_H:
				_bd_flip(true)
			KEY_V:
				_bd_flip(false)
			KEY_L:
				_bd_toggle_lock()
			KEY_D:
				_bd_set_tool("highlight")
			KEY_SLASH:
				_bd_toggle_help()
			KEY_PERIOD:
				_bd_rotate_sel(PI / 12.0)    # tldraw: HALF_PI / 6
			KEY_COMMA:
				_bd_rotate_sel(-PI / 12.0)
			_:
				if k in arrows:
					_bd_nudge(k, true)
				else:
					return false
		_bd_ui_refresh()
		return true
	match k:
		KEY_ESCAPE:
			if _bd_g != "":
				_bd_cancel_gesture()
			elif _bd_help != null and _bd_help.visible:
				_bd_help.visible = false
			elif not _bd_sel.is_empty():
				_bd_sel = []
			elif _bd_tool != "select":
				_bd_set_tool("select")
		KEY_DELETE, KEY_BACKSPACE:
			_bd_delete_selected()
		KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN:
			_bd_nudge(k, false)
		KEY_ENTER, KEY_KP_ENTER:
			if _bd_sel.size() == 1:
				_bd_start_edit(_bd_sel[0])
		KEY_SPACE:
			_bd_space = true
			_bd_update_cursor()
		KEY_BRACKETRIGHT:
			_bd_reorder("front")
		KEY_BRACKETLEFT:
			_bd_reorder("back")
		KEY_Q:
			_bd_toggle_tool_lock()
		KEY_EQUAL, KEY_PLUS:
			_bd_zoom_to(_cam.position, _cam.zoom.x * 1.25)
		KEY_MINUS:
			_bd_zoom_to(_cam.position, _cam.zoom.x * 0.8)
		_:
			if BD_TOOL_KEYS.has(k):
				_bd_set_tool(BD_TOOL_KEYS[k])
			else:
				return false
	_bd_ui_refresh()
	return true


func _bd_key_released(ev: InputEventKey) -> void:
	if ev.keycode == KEY_SPACE and _bd_space:
		_bd_space = false
		_bd_update_cursor()


func _bd_set_tool(t: String) -> void:
	_bd_stop_edit()
	_bd_tool = t
	_bd_unfocus_termling()   # picking a tool means drawing, not typing
	_bd_update_cursor()
	_bd_ui_refresh()


func _bd_toggle_tool_lock() -> void:
	_bd_lock = not _bd_lock
	_bd_ui_refresh()


func _bd_update_cursor() -> void:
	var shape := Input.CURSOR_ARROW
	if _bd_space or _bd_tool == "hand":
		shape = Input.CURSOR_DRAG
	elif _bd_tool == "text":
		shape = Input.CURSOR_IBEAM
	elif _bd_tool != "select":
		shape = Input.CURSOR_CROSS
	Input.set_default_cursor_shape(shape)


# Hand the keyboard from the focused termling to the board. (Not _set_focus(-1):
# that also clears notes keyed to term -1.)
func _bd_unfocus_termling() -> void:
	if _focused_id == -1:
		return
	_focused_id = -1
	for oid in _groups:
		_groups[oid].terminal.set_focused(false)
	_bd_update_hint()


func _bd_owns_keyboard() -> bool:
	# (_bd_g only counts while the button is held, so a gesture whose release
	# never arrived can't block the attention queue forever)
	return _bd_edit_id != "" or _bd_tool != "select" \
		or (_bd_g != "" and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) \
		or Time.get_ticks_msec() - _bd_last_input_ms < 4000


func _bd_camera_changed() -> void:
	_tracking_id = -1
	_cam_return = false
	_present_id = -1
	_present_leaving = false
	_zoom_goal = 0.0


# --- board: edit operations ------------------------------------------------------

func _bd_snapshot() -> String:
	return JSON.stringify(_bd_shapes)


func _bd_begin() -> void:
	if _bd_pre == "":
		_bd_pre = _bd_snapshot()


func _bd_commit() -> void:
	_bd_dirty = true
	if _bd_pre == "":
		return
	var now := _bd_snapshot()
	if now != _bd_pre:
		_bd_undo_stack.append(_bd_pre)
		if _bd_undo_stack.size() > BD_HISTORY:
			_bd_undo_stack.pop_front()
		_bd_redo_stack.clear()
		_bd_save_in = 0.4
	_bd_pre = ""


func _bd_restore(snap: String) -> void:
	var d = JSON.parse_string(snap)
	if typeof(d) != TYPE_ARRAY:
		return
	_bd_shapes = d
	_bd_reindex()
	_bd_save_in = 0.4


func _bd_undo() -> void:
	_bd_stop_edit()
	if _bd_undo_stack.is_empty():
		return
	_bd_redo_stack.append(_bd_snapshot())
	_bd_restore(_bd_undo_stack.pop_back())
	_bd_ui_refresh()


func _bd_redo() -> void:
	_bd_stop_edit()
	if _bd_redo_stack.is_empty():
		return
	_bd_undo_stack.append(_bd_snapshot())
	_bd_restore(_bd_redo_stack.pop_back())
	_bd_ui_refresh()


func _bd_select_all() -> void:
	_bd_sel = []
	for s in _bd_shapes:
		if not bool(s.get("locked", false)):
			_bd_sel.append(str(s["id"]))


func _bd_delete_selected() -> void:
	var ids := _bd_sel.filter(func(i): return not bool(_bd_by_id[i].get("locked", false)))
	if ids.is_empty():
		return
	_bd_begin()
	_bd_remove(ids)
	_bd_sel = []
	_bd_commit()


func _bd_nudge(k: int, big: bool) -> void:
	if _bd_sel.is_empty():
		return
	var step := 10.0 if big else 1.0
	var d := Vector2.ZERO
	match k:
		KEY_LEFT:
			d.x = -step
		KEY_RIGHT:
			d.x = step
		KEY_UP:
			d.y = -step
		KEY_DOWN:
			d.y = step
	_bd_begin()
	for i in _bd_sel:
		var s: Dictionary = _bd_by_id[i]
		_bd_translate(s, s.duplicate(true), d)
	_bd_carry_members(_bd_sel, d)
	_bd_commit()


func _bd_clone(ids: Array, offset: Vector2) -> Array:
	var copies := []
	for i in ids:
		var c: Dictionary = _bd_by_id[i].duplicate(true)
		if str(c["type"]) == "arrow":   # copies start where the original is drawn
			var e := _bd_arrow_ends(_bd_by_id[i])
			c["a"] = _bd_a(e[0])
			c["b"] = _bd_a(e[1])
		copies.append(c)
	return _bd_insert(copies, offset)


# Add copies of shapes under fresh ids. Bindings and groups among the copies are
# remapped to each other; arrows bound outside the set keep their ends.
func _bd_insert(copies: Array, offset: Vector2) -> Array:
	var idmap := {}
	for c in copies:
		idmap[str(c["id"])] = _bd_fresh_id()
	var gmap := {}
	var out := []
	for c in copies:
		var s: Dictionary = c.duplicate(true)
		s["id"] = idmap[str(c["id"])]
		var grp := str(s.get("group", ""))
		if grp != "":
			if not gmap.has(grp):
				gmap[grp] = "g" + _bd_fresh_id()
			s["group"] = gmap[grp]
		if str(s["type"]) == "arrow":
			for e in ["a", "b"]:
				var key := str(s.get("bind_" + e, ""))
				if idmap.has(key):
					s["bind_" + e] = idmap[key]
				elif key != "" and not key.begins_with("term"):
					s["bind_" + e] = ""
		_bd_translate(s, s.duplicate(true), offset)
		_bd_add(s)
		out.append(s["id"])
	return out


func _bd_duplicate() -> void:
	if _bd_sel.is_empty():
		return
	_bd_begin()
	_bd_sel = _bd_clone(_bd_sel, Vector2(24, 24))
	_bd_commit()


func _bd_copy() -> void:
	if _bd_sel.is_empty():
		return
	var copies := []
	for i in _bd_sel:
		var c: Dictionary = _bd_by_id[i].duplicate(true)
		if str(c["type"]) == "arrow":
			var e := _bd_arrow_ends(_bd_by_id[i])
			c["a"] = _bd_a(e[0])
			c["b"] = _bd_a(e[1])
		copies.append(c)
	DisplayServer.clipboard_set(JSON.stringify({"cove-board": copies}))


func _bd_cut() -> void:
	_bd_copy()
	_bd_delete_selected()


# Paste board shapes (centred on `at`), or plain text as a text shape.
func _bd_paste(at: Vector2) -> void:
	var txt := DisplayServer.clipboard_get()
	var d = JSON.parse_string(txt) if txt.begins_with("{\"cove-board\"") else null
	_bd_begin()
	if typeof(d) == TYPE_DICTIONARY and typeof(d.get("cove-board")) == TYPE_ARRAY and not d["cove-board"].is_empty():
		var ids := _bd_insert(d["cove-board"], Vector2.ZERO)
		_bd_sel = ids
		var shift := at - _bd_sel_box().get_center()
		for i in ids:
			var s: Dictionary = _bd_by_id[i]
			_bd_translate(s, s.duplicate(true), shift)
	elif DisplayServer.clipboard_has_image():
		var id := _bd_add_image(DisplayServer.clipboard_get_image(), at)
		if id != "":
			_bd_sel = [id]
	elif _bd_is_url(txt.strip_edges()):
		_bd_sel = [_bd_add_bookmark(txt.strip_edges(), at)]
	elif txt.strip_edges() != "":
		var s := _bd_new("text")
		s["text"] = txt.strip_edges()
		s["autosize"] = true
		_bd_set_rect(s, Rect2(at, Vector2(20, 20)))
		_bd_add(s)
		_bd_relayout(s)
		_bd_sel = [str(s["id"])]
	_bd_commit()


func _bd_group() -> void:
	if _bd_sel.size() < 2:
		return
	_bd_begin()
	var gid := "g" + _bd_fresh_id()
	for i in _bd_sel:
		_bd_by_id[i]["group"] = gid
	_bd_commit()


func _bd_ungroup() -> void:
	_bd_begin()
	for i in _bd_sel:
		_bd_by_id[i].erase("group")
	_bd_commit()


func _bd_reorder(mode: String) -> void:
	if _bd_sel.is_empty():
		return
	_bd_begin()
	var picked := _bd_shapes.filter(func(s): return _bd_sel.has(str(s["id"])))
	var rest := _bd_shapes.filter(func(s): return not _bd_sel.has(str(s["id"])))
	match mode:
		"front":
			_bd_shapes = rest + picked
		"back":
			_bd_shapes = picked + rest
		"forward":
			for i in range(_bd_shapes.size() - 2, -1, -1):
				if _bd_sel.has(str(_bd_shapes[i]["id"])) and not _bd_sel.has(str(_bd_shapes[i + 1]["id"])):
					var t = _bd_shapes[i]
					_bd_shapes[i] = _bd_shapes[i + 1]
					_bd_shapes[i + 1] = t
		"backward":
			for i in range(1, _bd_shapes.size()):
				if _bd_sel.has(str(_bd_shapes[i]["id"])) and not _bd_sel.has(str(_bd_shapes[i - 1]["id"])):
					var t = _bd_shapes[i]
					_bd_shapes[i] = _bd_shapes[i - 1]
					_bd_shapes[i - 1] = t
	_bd_commit()


func _bd_flip(horizontal: bool) -> void:
	if _bd_sel.is_empty():
		return
	_bd_begin()
	var c := _bd_sel_box().get_center()
	var k := Vector2(-1, 1) if horizontal else Vector2(1, -1)
	for i in _bd_sel:
		var s: Dictionary = _bd_by_id[i]
		_bd_scale(s, s.duplicate(true), c, k)
	_bd_commit()


func _bd_toggle_lock() -> void:
	if _bd_sel.is_empty():
		return
	var lock := false
	for i in _bd_sel:
		if not bool(_bd_by_id[i].get("locked", false)):
			lock = true
	_bd_begin()
	for i in _bd_sel:
		_bd_by_id[i]["locked"] = lock
	_bd_commit()


func _bd_zoom_to(center: Vector2, z: float) -> void:
	_bd_camera_changed()
	_bd_cam_goal = {"pos": center, "zoom": clampf(z, MIN_ZOOM, MAX_ZOOM)}


# ⇧1 frames every shape and termling; ⇧2 just the selection.
func _bd_zoom_to_fit(selection_only: bool) -> void:
	var r := Rect2()
	var first := true
	var ids: Array = _bd_sel if selection_only else _bd_by_id.keys()
	for i in ids:
		var b := _bd_bounds(_bd_by_id[i])
		r = b if first else r.merge(b)
		first = false
	if not selection_only:
		for id in _groups:
			var tr = _bd_term_rect(_bd_term_key(id))
			if tr != null:
				r = tr if first else r.merge(tr)
				first = false
	if first:
		return
	var vp := get_viewport_rect().size
	_bd_zoom_to(r.get_center(), minf(vp.x / (r.size.x + 160.0), vp.y / (r.size.y + 160.0)))


func _bd_current_style() -> Dictionary:
	if not _bd_sel.is_empty() and _bd_by_id.has(_bd_sel[0]):
		var s: Dictionary = _bd_by_id[_bd_sel[0]]
		var st := _bd_style.duplicate()
		for k in st.keys():
			if s.has(k):
				st[k] = s[k]
		return st
	return _bd_style


# A style pick sets the style for new shapes and restyles the selection.
func _bd_set_style(key: String, value: String) -> void:
	_bd_style[key] = value
	if not _bd_sel.is_empty():
		_bd_begin()
		for i in _bd_sel:
			var s: Dictionary = _bd_by_id[i]
			s[key] = value
			_bd_relayout(s)
		_bd_commit()
	_bd_ui_refresh()


# --- board: frames and boxes as the termlings' zones -----------------------------

func _bd_is_container(s: Dictionary) -> bool:
	return str(s["type"]) == "frame" or str(s["type"]) == "geo"


# The smallest frame or geo shape around p: where a termling dropped at p lives.
func _bd_container_at(p: Vector2) -> String:
	var best := ""
	var best_area := INF
	for s in _bd_shapes:
		if not _bd_is_container(s):
			continue
		var lp := _bd_local(s, p)
		var inside: bool = Geometry2D.is_point_in_polygon(lp, _bd_geo_poly(s)) if str(s["type"]) == "geo" \
			else _bd_rect(s).has_point(lp)
		if inside:
			var area := float(s["w"]) * float(s["h"])
			if area < best_area:
				best = str(s["id"])
				best_area = area
	return best


# Where a member may wander: the shape's box, pulled in for round or pointy
# outlines so it stays inside them. null if the shape is gone.
func _bd_container_rect(id: String):
	var s = _bd_by_id.get(id, null)
	if s == null or not _bd_is_container(s):
		return null
	var r := _bd_rect(s)
	if _bd_rot(s) != 0.0:   # a turned shape: a square that fits inside it whatever the angle
		var m := minf(r.size.x, r.size.y) * 0.6
		return Rect2(r.get_center() - Vector2(m, m) * 0.5, Vector2(m, m))
	match str(s.get("geo", "")):
		"ellipse", "diamond":
			return r.grow_individual(-r.size.x * 0.15, -r.size.y * 0.15, -r.size.x * 0.15, -r.size.y * 0.15)
		"triangle":
			return Rect2(r.position.x + r.size.x * 0.25, r.position.y + r.size.y * 0.5, r.size.x * 0.5, r.size.y * 0.45)
	return r


func _bd_container_name(id: String) -> String:
	var s = _bd_by_id.get(id, null)
	if s == null:
		return ""
	var label := _bd_container_label(id)
	if label != "":
		return label
	return "frame" if str(s["type"]) == "frame" else str(s.get("geo", "box"))


# What a frame/box is called: its own title or label; else the text that goes
# with it, which is a text/note grouped with it, else a heading (a text sitting
# just above it or along its top edge). First line only. "" if it has none.
func _bd_container_label(id: String) -> String:
	var s = _bd_by_id.get(id, null)
	if s == null:
		return ""
	var own := str(s.get("text", "")).strip_edges()
	if own != "":
		return own.get_slice("\n", 0)
	var grp := str(s.get("group", ""))
	var r := _bd_bounds(s)
	var heading := ""
	var best_d := INF
	for t in _bd_shapes:
		if str(t["id"]) == id or not str(t["type"]) in ["text", "note"]:
			continue
		var txt := str(t.get("text", "")).strip_edges().get_slice("\n", 0)
		if txt == "":
			continue
		if grp != "" and str(t.get("group", "")) == grp:
			return txt
		var b := _bd_bounds(t)
		if b.position.x < r.end.x and b.end.x > r.position.x \
				and b.end.y >= r.position.y - 80.0 and b.position.y <= r.position.y + 80.0:
			var d := absf(b.end.y - r.position.y)
			if d < best_d:
				best_d = d
				heading = txt
	return heading


# A container by shape id or by name (see _bd_container_label).
func _bd_resolve_container(ref: String) -> String:
	if ref == "":
		return ""
	var s = _bd_by_id.get(ref, null)
	if s != null and _bd_is_container(s):
		return ref
	for t in _bd_shapes:
		if _bd_is_container(t) and _bd_container_label(str(t["id"])) == ref:
			return str(t["id"])
	return ""


# A named frame (for the assign/autozone commands), made around `near` if new.
func _bd_ensure_container(name: String, near: Vector2) -> String:
	var id := _bd_resolve_container(name)
	if id != "":
		return id
	var own := _bd_pre == ""   # don't commit the user's half-done gesture along with it
	if own:
		_bd_begin()
	var s := _bd_new("frame")
	s["text"] = name
	s["color"] = BD_COLORS[1 + absi(hash(name)) % (BD_COLORS.size() - 2)]
	_bd_set_rect(s, Rect2(near - Vector2(450, 380), Vector2(900, 660)))
	_bd_add(s)
	if own:
		_bd_commit()
	return str(s["id"])


func _bd_containers() -> Array:
	var out := []
	for s in _bd_shapes:
		if _bd_is_container(s):
			var r := _bd_rect(s)
			out.append({
				"id": s["id"],
				"name": _bd_container_name(str(s["id"])),
				"type": "frame" if str(s["type"]) == "frame" else str(s.get("geo", "rectangle")),
				"rect": [snappedf(r.position.x, 0.1), snappedf(r.position.y, 0.1),
					snappedf(r.size.x, 0.1), snappedf(r.size.y, 0.1)],
			})
	return out


# A freshly drawn frame takes in the termlings standing inside it.
func _bd_adopt_into(sid: String) -> void:
	var r = _bd_container_rect(sid)
	if r == null:
		return
	for id in _groups:
		if _bd_container_at(_groups[id].get_ground_pos()) == sid:
			_zone_of[id] = sid
			if not _follows.has(id):
				_groups[id].assign_zone(r)


func _bd_member_count(sid: String) -> int:
	var n := 0
	for id in _zone_of:
		if str(_zone_of[id]) == sid and _groups.has(id):
			n += 1
	return n


# --- board: persistence ------------------------------------------------------------

func _bd_save_now() -> void:
	_bd_save_in = -1.0
	# Termling bindings made before the ls poll learned a session get keyed by it now.
	for s in _bd_shapes:
		if str(s["type"]) != "arrow":
			continue
		for e in ["a", "b"]:
			var key := str(s.get("bind_" + e, ""))
			if key.begins_with("term#"):
				var id := _bd_term_id(key)
				if id != -1:
					s["bind_" + e] = _bd_term_key(id)
	var txt := JSON.stringify({"version": 1, "next": _bd_next, "ui_scale": _bd_ui_user, "shapes": _bd_shapes})
	for path in [BOARD_SAVE, BOARD_MIRROR]:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(txt)
			f.close()


func _bd_load() -> bool:
	if not FileAccess.file_exists(BOARD_SAVE):
		return false
	var f := FileAccess.open(BOARD_SAVE, FileAccess.READ)
	if f == null:
		return false
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY or typeof(d.get("shapes", null)) != TYPE_ARRAY:
		push_warning("cove: %s is unreadable; starting an empty board" % BOARD_SAVE)
		return false
	_bd_shapes = d["shapes"]
	_bd_next = int(d.get("next", 1))
	_bd_ui_user = clampf(float(d.get("ui_scale", 1.0)), 0.6, 2.5)
	_bd_reindex()
	return true


# Hand-drawn regions from before the board become frames, once.
func _bd_migrate(zones: Array) -> void:
	for z in zones:
		var s := _bd_new("frame")
		s["text"] = str(z["name"])
		var zc = z.get("color", [0.6, 0.6, 0.6])
		var col := Color(float(zc[0]), float(zc[1]), float(zc[2]))
		var best := "grey"
		var best_d := INF
		for n in BD_COLORS:
			if n == "black" or n == "white":
				continue
			var p: Color = BD_PALETTE[n]
			var dist := Vector3(p.r - col.r, p.g - col.g, p.b - col.b).length_squared()
			if dist < best_d:
				best_d = dist
				best = n
		s["color"] = best
		var r: Array = z["rect"]
		_bd_set_rect(s, Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])))
		_bd_add(s)
	if not zones.is_empty():
		_bd_save_in = 0.1
		print("cove: moved %d hand-drawn region(s) onto the board as frames" % zones.size())


# --- board: commands from other tools (commands.jsonl {"cmd": "board", ...}) ------
# op add: type (note|text|todo|frame|rectangle|ellipse|diamond|triangle|arrow),
#   id (caller-chosen), text, items, color, x/y/w/h or near_pos, from/to (shape
#   id or termling key), owner (kept as-is). op update: id or name, then text,
#   color/fill/dash/size/font, x/y/w/h, items, add_items, check/uncheck/remove
#   (item index or text). op delete: ids.

func _bd_command(c: Dictionary) -> String:
	var op := str(c.get("op", ""))
	match op:
		"add":
			var kind := str(c.get("type", "note"))
			if not (kind in BD_GEO or kind in ["note", "text", "todo", "frame", "arrow", "image", "bookmark"]):
				return "unknown shape type: " + kind
			if kind == "bookmark" and not _bd_is_url(str(c.get("url", ""))):
				return "a bookmark needs an http(s) url"
		"update":
			if _bd_lookup(str(c.get("id", c.get("name", "")))) == "":
				return "no such shape"
		"delete":
			var found := false
			for ref in c.get("ids", []):
				if _bd_lookup(str(ref)) != "":
					found = true
			if not found:
				return "no such shape"
		_:
			return "unknown board op: " + op
	if _bd_g != "" or _bd_edit_id != "":
		_bd_cmd_queue.append(c)   # don't fold it into the user's in-flight undo step
		return ""
	_bd_exec(c)
	return ""


func _bd_exec(c: Dictionary) -> void:
	_bd_begin()
	match str(c.get("op", "")):
		"add":
			_bd_exec_add(c)
		"update":
			_bd_exec_update(c)
		"delete":
			var ids := []
			for ref in c.get("ids", []):
				var id := _bd_lookup(str(ref))
				if id != "":
					ids.append(id)
			_bd_remove(ids)
	_bd_commit()


func _bd_lookup(ref: String) -> String:
	if _bd_by_id.has(ref):
		return ref
	for s in _bd_shapes:
		if str(s.get("text", "")) == ref:
			return str(s["id"])
	return ""


func _bd_norm_items(v) -> Array:
	var out := []
	if typeof(v) != TYPE_ARRAY:
		return out
	for it in v:
		if typeof(it) == TYPE_DICTIONARY:
			out.append({"text": str(it.get("text", "")), "done": bool(it.get("done", false))})
		else:
			out.append({"text": str(it), "done": false})
	return out


func _bd_exec_add(c: Dictionary) -> void:
	var kind := str(c.get("type", "note"))
	var type := "geo" if kind in BD_GEO else kind
	if not type in ["geo", "note", "text", "todo", "frame", "arrow", "image", "bookmark"]:
		return
	var s := _bd_new(type)
	if type == "geo":
		s["geo"] = kind
	var want := str(c.get("id", ""))
	if want != "" and not _bd_by_id.has(want):
		s["id"] = want
	var col := str(c.get("color", "yellow" if type == "note" else "black"))
	s["color"] = col if BD_PALETTE.has(col) else "black"
	for k in ["fill", "dash", "size", "font", "owner"]:
		if c.has(k):
			s[k] = str(c[k])
	s["text"] = str(c.get("text", c.get("name", "")))
	var at := _cam.position
	if c.get("x", null) != null and c.get("y", null) != null:
		at = Vector2(float(c["x"]), float(c["y"]))
	elif c.get("near_pos", null) != null:
		at = _bd_v(c["near_pos"])
	var defaults := {"note": Vector2(200, 200), "todo": Vector2(300, 100), "frame": Vector2(900, 660), "geo": Vector2(200, 140)}
	var dsz: Vector2 = defaults.get(type, Vector2(200, 200))
	var sz := Vector2(float(c.get("w", dsz.x)), float(c.get("h", dsz.y)))
	match type:
		"arrow":
			var ka := _bd_ref_key(c.get("from", null))
			var kb := _bd_ref_key(c.get("to", null))
			var ra = _bd_bind_rect(ka)
			var rb = _bd_bind_rect(kb)
			var a0: Vector2 = ra.get_center() if ra != null else at
			var b0: Vector2 = rb.get_center() if rb != null else at + Vector2(200, 0)
			s["a"] = _bd_a(a0)
			s["b"] = _bd_a(b0)
			s["bind_a"] = ka
			s["bind_b"] = kb
			s["bend"] = float(c.get("bend", 0.0))
			s["head_a"] = false
			s["head_b"] = true
		"todo":
			s["items"] = _bd_norm_items(c.get("items", []))
			if str(s["text"]) == "":
				s["text"] = "To do"
			_bd_set_rect(s, Rect2(at, sz))
		"text":
			s["autosize"] = not c.has("w")
			_bd_set_rect(s, Rect2(at, Vector2(sz.x if c.has("w") else 20.0, 30.0)))
		"image":
			var path := str(c.get("path", ""))
			var img: Image = Image.load_from_file(path) if FileAccess.file_exists(path) else null
			var src := _bd_import_image(img)
			if src == "":
				return
			s["src"] = src
			var iw := float(c.get("w", minf(480.0, float(img.get_width()))))
			_bd_set_rect(s, Rect2(at, Vector2(iw, iw * float(img.get_height()) / maxf(float(img.get_width()), 1.0))))
		"bookmark":
			s["url"] = str(c.get("url", ""))
			_bd_set_rect(s, Rect2(at, Vector2(BD_BM_W, BD_BM_H)))   # _bd_add fits the height to what's known
		_:
			_bd_set_rect(s, Rect2(at, sz))
	if c.has("rotation") and type != "arrow":
		s["rot"] = deg_to_rad(float(c["rotation"]))
	_bd_add(s)
	_bd_relayout(s)


func _bd_ref_key(v) -> String:
	if v == null:
		return ""
	var r := str(v)
	return r if r.begins_with("term") else _bd_lookup(r)


func _bd_todo_find(items: Array, ref) -> int:
	if typeof(ref) == TYPE_FLOAT or typeof(ref) == TYPE_INT:
		var i := int(ref)
		return i if i >= 0 and i < items.size() else -1
	var needle := str(ref).to_lower()
	for i in items.size():
		if str(items[i]["text"]).to_lower() == needle:
			return i
	for i in items.size():
		if str(items[i]["text"]).to_lower().contains(needle):
			return i
	return -1


func _bd_exec_update(c: Dictionary) -> void:
	var id := _bd_lookup(str(c.get("id", c.get("name", ""))))
	if id == "":
		return
	var s: Dictionary = _bd_by_id[id]
	if c.has("text"):
		s["text"] = str(c["text"])
	for k in ["color", "fill", "dash", "size", "font"]:
		if c.has(k):
			s[k] = str(c[k])
	if _bd_is_box(s):
		for k in ["x", "y", "w", "h"]:
			if c.has(k):
				s[k] = float(c[k])
		if c.has("rotation"):
			s["rot"] = deg_to_rad(float(c["rotation"]))
	if str(s["type"]) == "todo":
		if c.has("items"):
			s["items"] = _bd_norm_items(c["items"])
		var items: Array = s["items"]
		for t in c.get("add_items", []):
			items.append({"text": str(t), "done": false})
		for field in ["check", "uncheck"]:
			var refs = c.get(field, [])
			if typeof(refs) != TYPE_ARRAY:
				refs = [refs]
			for ref in refs:
				var i := _bd_todo_find(items, ref)
				if i != -1:
					items[i]["done"] = field == "check"
		var drop := []
		var refs = c.get("remove", [])
		if typeof(refs) != TYPE_ARRAY:
			refs = [refs]
		for ref in refs:
			var i := _bd_todo_find(items, ref)
			if i != -1 and not drop.has(i):
				drop.append(i)
		drop.sort()
		drop.reverse()
		for i in drop:
			items.remove_at(i)
	_bd_relayout(s)


# --- board: chrome (tool bar, style panel, shortcut sheet, context menu) ----------

func _bd_build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 4
	add_child(layer)
	# Everything hangs off one full-window root, scaled by the screen's backing
	# scale (_bd_apply_ui_scale), so the chrome keeps its size on Retina.
	_bd_ui_root = Control.new()
	_bd_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_bd_ui_root)
	var ui := _bd_ui_root

	# Tool bar along the bottom, as in tldraw.
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _bd_panel_box())
	bar.anchor_left = 0.5
	bar.anchor_right = 0.5
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_top = -14
	bar.offset_bottom = -14
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ui.add_child(bar)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 2)
	bar.add_child(hb)
	hb.add_child(_bd_button("↶", "Undo (⌘Z)", _bd_undo, false))
	hb.add_child(_bd_button("↷", "Redo (⇧⌘Z)", _bd_redo, false))
	hb.add_child(VSeparator.new())
	for t in BD_TOOLS:
		var tip: String = t[2] if str(t[3]) == "" else "%s (%s)" % [t[2], t[3]]
		var b := _bd_button(t[1], tip, func(): _bd_set_tool(t[0]))
		_bd_tool_btns[t[0]] = b
		hb.add_child(b)
	hb.add_child(VSeparator.new())
	_bd_lock_btn = _bd_button("🔒", "Tool lock: stay in the tool after drawing (Q)", _bd_toggle_tool_lock)
	hb.add_child(_bd_lock_btn)
	_bd_snap_btn = _bd_button("🧲", "Always snap to shapes and termlings (or hold ⌘ while dragging)", _bd_toggle_snap)
	hb.add_child(_bd_snap_btn)
	hb.add_child(_bd_button("?", "Keyboard shortcuts (?)", _bd_toggle_help, false))

	# Who has the keyboard: a termling's shell, or the board.
	_bd_hint = Label.new()
	_bd_hint.anchor_left = 0.5
	_bd_hint.anchor_right = 0.5
	_bd_hint.anchor_top = 1.0
	_bd_hint.anchor_bottom = 1.0
	_bd_hint.offset_top = -80
	_bd_hint.offset_bottom = -80
	_bd_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bd_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bd_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bd_hint.add_theme_font_size_override("font_size", 12)
	_bd_hint.add_theme_color_override("font_color", Color(0.78, 0.8, 0.85, 0.85))
	_bd_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_bd_hint.add_theme_constant_override("outline_size", 4)
	ui.add_child(_bd_hint)

	# Style panel down the left: colour, fill, dash, size, font.
	var sp := PanelContainer.new()
	sp.add_theme_stylebox_override("panel", _bd_panel_box())
	sp.anchor_top = 0.5
	sp.anchor_bottom = 0.5
	sp.offset_left = 14
	sp.offset_right = 14
	sp.grow_vertical = Control.GROW_DIRECTION_BOTH
	ui.add_child(sp)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	sp.add_child(vb)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	vb.add_child(grid)
	for n in BD_COLORS:
		var b := _bd_button("", n, func(): _bd_set_style("color", n))
		b.custom_minimum_size = Vector2(26, 26)
		var c: Color = BD_PALETTE[n]
		b.add_theme_stylebox_override("normal", _bd_swatch_box(c, false))
		b.add_theme_stylebox_override("hover", _bd_swatch_box(c.lightened(0.15), false))
		b.add_theme_stylebox_override("pressed", _bd_swatch_box(c, true))
		b.add_theme_stylebox_override("hover_pressed", _bd_swatch_box(c, true))
		_bd_style_btns["color:" + n] = b
		grid.add_child(b)
	var rows := [
		["fill", [["none", "○", "No fill"], ["semi", "◐", "Semi-transparent fill"],
			["solid", "●", "Solid fill (⌥F)"], ["pattern", "▨", "Pattern fill (⇧⌥F)"]]],
		["dash", [["draw", "~", "Draw (hand-drawn)"], ["dashed", "╍", "Dashed"], ["dotted", "┉", "Dotted"], ["solid", "━", "Solid"]]],
		["size", [["s", "S", "Small"], ["m", "M", "Medium"], ["l", "L", "Large"], ["xl", "XL", "Extra large"]]],
		["font", [["draw", "Aa", "Draw"], ["sans", "Aa", "Sans"], ["serif", "Aa", "Serif"], ["mono", "Aa", "Mono"]]],
	]
	for row in rows:
		var rb := HBoxContainer.new()
		rb.add_theme_constant_override("separation", 2)
		vb.add_child(rb)
		for opt in row[1]:
			var b := _bd_button(opt[1], opt[2], func(): _bd_set_style(row[0], opt[0]))
			b.custom_minimum_size = Vector2(28, 28)
			b.add_theme_font_size_override("font_size", 14)
			if row[0] == "font":
				b.add_theme_font_override("font", _bd_font(opt[0]))
			_bd_style_btns[row[0] + ":" + opt[0]] = b
			rb.add_child(b)

	# Arrange (align / distribute / stretch / pack), shown for two or more shapes.
	_bd_arrange_row = GridContainer.new()
	_bd_arrange_row.columns = 4
	_bd_arrange_row.add_theme_constant_override("h_separation", 2)
	_bd_arrange_row.add_theme_constant_override("v_separation", 2)
	vb.add_child(_bd_arrange_row)
	for a in BD_ARRANGE:
		var b := _bd_button(a[0], a[1].replace("   ", " "), func(): _bd_arrange(a[2]), false)
		b.custom_minimum_size = Vector2(28, 28)
		b.add_theme_font_size_override("font_size", 14)
		_bd_arrange_row.add_child(b)

	# The shortcut sheet (?).
	_bd_help = PanelContainer.new()
	_bd_help.add_theme_stylebox_override("panel", _themed_box())
	_bd_help.anchor_left = 0.5
	_bd_help.anchor_right = 0.5
	_bd_help.anchor_top = 0.5
	_bd_help.anchor_bottom = 0.5
	_bd_help.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bd_help.grow_vertical = Control.GROW_DIRECTION_BOTH
	_bd_help.visible = false
	_bd_help.gui_input.connect(_bd_help_input)
	var help := Label.new()
	help.text = BD_HELP
	help.add_theme_font_override("font", _bd_font("mono"))
	help.add_theme_font_size_override("font_size", 13)
	help.add_theme_color_override("font_color", Color(0.9, 0.9, 0.93))
	_bd_help.add_child(help)
	ui.add_child(_bd_help)

	_bd_menu = PopupMenu.new()
	_bd_menu.id_pressed.connect(_bd_menu_pick)
	add_child(_bd_menu)
	get_viewport().size_changed.connect(_bd_apply_ui_scale)
	_bd_apply_ui_scale()
	_bd_ui_refresh()


func _bd_button(text: String, tip: String, cb: Callable, toggle := true) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE   # never steal keys from the board or a shell
	b.toggle_mode = toggle
	b.custom_minimum_size = Vector2(36, 36)
	b.add_theme_font_size_override("font_size", 17)
	b.add_theme_color_override("font_color", Color(0.85, 0.87, 0.92))
	b.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	b.add_theme_color_override("font_hover_pressed_color", Color(1, 1, 1))
	b.add_theme_stylebox_override("normal", _bd_btn_box(Color(0, 0, 0, 0)))
	b.add_theme_stylebox_override("hover", _bd_btn_box(Color(1, 1, 1, 0.08)))
	b.add_theme_stylebox_override("pressed", _bd_btn_box(Color(BD_SEL, 0.35)))
	b.add_theme_stylebox_override("hover_pressed", _bd_btn_box(Color(BD_SEL, 0.45)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(cb)
	return b


func _bd_btn_box(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb


func _bd_swatch_box(c: Color, on: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(13)
	sb.border_color = Color(1, 1, 1)
	sb.set_border_width_all(3 if on else 0)
	return sb


func _bd_panel_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.10, 0.09, 0.92)
	sb.border_color = Color(0.45, 0.85, 1.0, 0.35)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
		sb.set_content_margin(side, 6)
	return sb


func _bd_ui_refresh() -> void:
	for k in _bd_tool_btns:
		_bd_tool_btns[k].set_pressed_no_signal(k == _bd_tool)
	var st := _bd_current_style()
	for key in _bd_style_btns:
		var parts: PackedStringArray = key.split(":")
		_bd_style_btns[key].set_pressed_no_signal(str(st.get(parts[0], "")) == parts[1])
	if _bd_lock_btn:
		_bd_lock_btn.set_pressed_no_signal(_bd_lock)
	if _bd_snap_btn:
		_bd_snap_btn.set_pressed_no_signal(_bd_snap_mode)
	if _bd_arrange_row:
		_bd_arrange_row.visible = _bd_sel.size() >= 2
	_bd_update_hint()


func _bd_update_hint() -> void:
	if _bd_hint == null:
		return
	if _focused_id != -1 and _groups.has(_focused_id):
		_bd_hint.text = "⌨ typing into %s  ·  click empty ground for board keys" % _term_label(_focused_id)
	else:
		_bd_hint.text = "board keys on  ·  ? for shortcuts"


func _bd_toggle_help() -> void:
	if _bd_help:
		_bd_help.visible = not _bd_help.visible


func _bd_help_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		_bd_help.visible = false


func _bd_context_menu(p: Vector2, screen: Vector2) -> void:
	_bd_stop_edit()
	_bd_unfocus_termling()
	var id := _bd_hit(p, true)
	if id != "" and not _bd_sel.has(id):
		_bd_sel = _bd_with_groups([id])
	elif id == "":
		_bd_sel = []
	var m := _bd_menu
	m.clear()
	if not _bd_sel.is_empty():
		m.add_item("Edit text   ↵", 1)
		m.add_item("Duplicate   ⌘D", 2)
		m.add_item("Copy   ⌘C", 3)
		m.add_item("Cut   ⌘X", 4)
		m.add_separator()
		m.add_item("Bring to front   ]", 5)
		m.add_item("Send to back   [", 6)
		m.add_item("Group   ⌘G", 7)
		m.add_item("Ungroup   ⇧⌘G", 8)
		m.add_item("Flip horizontal   ⇧H", 9)
		m.add_item("Flip vertical   ⇧V", 10)
		m.add_item("Lock / unlock   ⇧L", 11)
		m.add_item("Rotate 15°   ⇧.", 18)
		m.add_item("Frame selection   ⌘⌥G", 19)
		if _bd_sel.size() >= 2:
			m.add_submenu_node_item("Arrange", _bd_arrange_menu())
		m.add_separator()
		m.add_item("Delete   ⌫", 12)
		m.add_separator()
	m.add_item("Paste   ⌘V", 13)
	m.add_item("Select all   ⌘A", 14)
	m.add_item("Zoom to fit   ⇧1", 15)
	m.add_item("Undo   ⌘Z", 16)
	m.add_item("Redo   ⇧⌘Z", 17)
	m.add_separator()
	m.add_item("Bigger toolbar   ⌘⌥=", 20)
	m.add_item("Smaller toolbar   ⌘⌥-", 21)
	_bd_menu_pos = p
	m.popup(Rect2i(Vector2i(screen), Vector2i.ZERO))
	_bd_ui_refresh()


func _bd_menu_pick(id: int) -> void:
	match id:
		1:
			if _bd_sel.size() == 1:
				_bd_start_edit(_bd_sel[0])
		2:
			_bd_duplicate()
		3:
			_bd_copy()
		4:
			_bd_cut()
		5:
			_bd_reorder("front")
		6:
			_bd_reorder("back")
		7:
			_bd_group()
		8:
			_bd_ungroup()
		9:
			_bd_flip(true)
		10:
			_bd_flip(false)
		11:
			_bd_toggle_lock()
		12:
			_bd_delete_selected()
		13:
			_bd_paste(_bd_menu_pos)
		14:
			_bd_select_all()
		15:
			_bd_zoom_to_fit(false)
		16:
			_bd_undo()
		17:
			_bd_redo()
		18:
			_bd_rotate_sel(PI / 12.0)
		19:
			_bd_frame_selection()
		20:
			_bd_ui_bump(1.15)
		21:
			_bd_ui_bump(1.0 / 1.15)
	_bd_ui_refresh()


func _bd_arrange_menu() -> PopupMenu:
	var sub: PopupMenu = _bd_menu.get_node_or_null("arrange")
	if sub == null:
		sub = PopupMenu.new()
		sub.name = "arrange"
		for i in BD_ARRANGE.size():
			sub.add_item(BD_ARRANGE[i][1], 30 + i)
		sub.id_pressed.connect(func(id): _bd_arrange(BD_ARRANGE[id - 30][2]))
		_bd_menu.add_child(sub)
	sub.content_scale_factor = _bd_ui_scale
	return sub


# The chrome's scale: the screen's backing scale (2 on Retina; the project draws
# in physical pixels), grown with the window's height in points so a big display
# gets bigger chrome, times your own ⌘⌥= / ⌘⌥- adjustment.
func _bd_ui_target_scale() -> float:
	var backing := maxf(1.0, DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen()))
	var h_pt := get_viewport().get_visible_rect().size.y / backing
	return backing * clampf(h_pt / 760.0, 1.0, 1.8) * _bd_ui_user


func _bd_ui_bump(f: float) -> void:
	_bd_ui_user = clampf(_bd_ui_user * f, 0.6, 2.5)
	_bd_apply_ui_scale()
	_bd_save_in = 0.4   # the adjustment is saved with the board


# The root is scaled by that and sized to the window in the scaled units.
func _bd_apply_ui_scale() -> void:
	if _bd_ui_root == null:
		return
	var s := _bd_ui_target_scale()
	_bd_ui_scale = s
	var roots: Array = _ui_roots.duplicate()
	roots.append(_bd_ui_root)
	for root in roots:
		root.scale = Vector2(s, s)
		root.position = Vector2.ZERO
		root.size = get_viewport().get_visible_rect().size / s
	if _bd_menu:
		_bd_menu.content_scale_factor = s


# --- board: rotation ---------------------------------------------------------------
# Boxes carry "rot" (radians, about their centre). Lines, arrows and freehand turn
# by moving their points. Hit tests, handles and the label editor work in a
# box's own unrotated frame via _bd_local / _bd_xform.

func _bd_rot(s: Dictionary) -> float:
	return float(s.get("rot", 0.0)) if _bd_is_box(s) else 0.0


func _bd_xform(s: Dictionary) -> Transform2D:
	var c := _bd_rect(s).get_center()
	return Transform2D(_bd_rot(s), c) * Transform2D(0.0, -c)


func _bd_local(s: Dictionary, p: Vector2) -> Vector2:
	if s.is_empty():
		return p
	var rot := _bd_rot(s)
	if rot == 0.0:
		return p
	var c := _bd_rect(s).get_center()
	return c + (p - c).rotated(-rot)


func _bd_rotate_shape(s: Dictionary, o: Dictionary, c: Vector2, a: float) -> void:
	match str(s["type"]):
		"arrow":
			s["a"] = _bd_a(c + (_bd_v(o["a"]) - c).rotated(a))
			s["b"] = _bd_a(c + (_bd_v(o["b"]) - c).rotated(a))
		"line", "draw":
			var pts := []
			for q in o["points"]:
				pts.append(_bd_a(c + (_bd_v(q) - c).rotated(a)))
			s["points"] = pts
		_:
			var r := _bd_rect(o)
			var nc := c + (r.get_center() - c).rotated(a)
			s["x"] = snappedf(nc.x - r.size.x * 0.5, 0.01)
			s["y"] = snappedf(nc.y - r.size.y * 0.5, 0.01)
			var nr := wrapf(_bd_rot(o) + a, -PI, PI)
			s["rot"] = 0.0 if absf(nr) < 0.0001 else snappedf(nr, 0.0001)


# ⇧. / ⇧, (tldraw): the selection turns about its centre.
func _bd_rotate_sel(a: float) -> void:
	if _bd_sel.is_empty():
		return
	_bd_begin()
	var c := _bd_sel_box().get_center()
	for i in _bd_sel:
		var s: Dictionary = _bd_by_id[i]
		_bd_rotate_shape(s, s.duplicate(true), c, a)
	_bd_commit()


# --- board: snapping ---------------------------------------------------------------
# ⌘ while dragging snaps (the 🧲 button inverts that): the dragged box's edges
# and centre line up with those of other shapes and termlings within a few
# screen pixels, and pink guides show what it lined up with.

func _bd_snapping(ev: InputEventWithModifiers) -> bool:
	return _bd_snap_mode != (ev.meta_pressed or ev.ctrl_pressed)


func _bd_toggle_snap() -> void:
	_bd_snap_mode = not _bd_snap_mode
	_bd_ui_refresh()


func _bd_snap_targets(exclude: Array) -> Array:
	var out := []
	for s in _bd_shapes:
		if not exclude.has(str(s["id"])) and str(s["type"]) != "arrow":
			out.append(_bd_bounds(s))
	for id in _groups:
		var tr = _bd_term_rect(_bd_term_key(id))
		if tr != null:
			out.append(tr)
	return out


func _bd_snap_offset(box: Rect2) -> Vector2:
	var thr := 8.0 / _cam.zoom.x
	var best := Vector2(INF, INF)
	var gx := 0.0
	var gy := 0.0
	var tx := Rect2()
	var ty := Rect2()
	for t in _bd_snap_cache:
		var tr: Rect2 = t
		for a in [box.position.x, box.get_center().x, box.end.x]:
			for b in [tr.position.x, tr.get_center().x, tr.end.x]:
				var dd: float = b - a
				if absf(dd) <= thr and absf(dd) < absf(best.x):
					best.x = dd
					gx = b
					tx = tr
		for a in [box.position.y, box.get_center().y, box.end.y]:
			for b in [tr.position.y, tr.get_center().y, tr.end.y]:
				var dd: float = b - a
				if absf(dd) <= thr and absf(dd) < absf(best.y):
					best.y = dd
					gy = b
					ty = tr
	var off := Vector2(best.x if best.x != INF else 0.0, best.y if best.y != INF else 0.0)
	var nb := Rect2(box.position + off, box.size)
	_bd_guides = []
	if best.x != INF:
		_bd_guides.append([Vector2(gx, minf(nb.position.y, tx.position.y)), Vector2(gx, maxf(nb.end.y, tx.end.y))])
	if best.y != INF:
		_bd_guides.append([Vector2(minf(nb.position.x, ty.position.x), gy), Vector2(maxf(nb.end.x, ty.end.x), gy)])
	return off


# Snap a dragged corner/edge point (resizing, drawing a box) on the given axes.
func _bd_snap_point(p: Vector2, on_x: bool, on_y: bool) -> Vector2:
	var thr := 8.0 / _cam.zoom.x
	var best := Vector2(INF, INF)
	var gx := 0.0
	var gy := 0.0
	var tx := Rect2()
	var ty := Rect2()
	for t in _bd_snap_cache:
		var tr: Rect2 = t
		if on_x:
			for b in [tr.position.x, tr.get_center().x, tr.end.x]:
				if absf(b - p.x) <= thr and absf(b - p.x) < absf(best.x):
					best.x = b - p.x
					gx = b
					tx = tr
		if on_y:
			for b in [tr.position.y, tr.get_center().y, tr.end.y]:
				if absf(b - p.y) <= thr and absf(b - p.y) < absf(best.y):
					best.y = b - p.y
					gy = b
					ty = tr
	var q := p + Vector2(best.x if best.x != INF else 0.0, best.y if best.y != INF else 0.0)
	_bd_guides = []
	if best.x != INF:
		_bd_guides.append([Vector2(gx, minf(q.y, tx.position.y)), Vector2(gx, maxf(q.y, tx.end.y))])
	if best.y != INF:
		_bd_guides.append([Vector2(minf(q.x, ty.position.x), gy), Vector2(maxf(q.x, ty.end.x), gy)])
	return q


# --- board: arrange (align / distribute / stretch / pack) ---------------------------

func _bd_arrange(mode: String) -> void:
	match mode:
		"dist-h":
			_bd_distribute(true)
		"dist-v":
			_bd_distribute(false)
		"stretch-h":
			_bd_stretch(true)
		"stretch-v":
			_bd_stretch(false)
		"pack":
			_bd_pack()
		_:
			_bd_align(mode)
	_bd_ui_refresh()


func _bd_move_by(id: String, d: Vector2) -> void:
	var s: Dictionary = _bd_by_id[id]
	_bd_translate(s, s.duplicate(true), d)
	_bd_carry_members([id], d)


func _bd_align(mode: String) -> void:
	if _bd_sel.size() < 2:
		return
	var box := _bd_sel_box()
	_bd_begin()
	for i in _bd_sel:
		var b := _bd_bounds(_bd_by_id[i])
		var d := Vector2.ZERO
		match mode:
			"left":
				d.x = box.position.x - b.position.x
			"center-h":
				d.x = box.get_center().x - b.get_center().x
			"right":
				d.x = box.end.x - b.end.x
			"top":
				d.y = box.position.y - b.position.y
			"center-v":
				d.y = box.get_center().y - b.get_center().y
			"bottom":
				d.y = box.end.y - b.end.y
		_bd_move_by(i, d)
	_bd_commit()


# Even gaps between the selection's shapes, the outermost two staying put.
func _bd_distribute(horizontal: bool) -> void:
	if _bd_sel.size() < 3:
		return
	var ax := 0 if horizontal else 1
	var ids: Array = _bd_sel.duplicate()
	ids.sort_custom(func(a, b): return _bd_bounds(_bd_by_id[a]).get_center()[ax] < _bd_bounds(_bd_by_id[b]).get_center()[ax])
	var first := _bd_bounds(_bd_by_id[ids[0]])
	var last := _bd_bounds(_bd_by_id[ids[ids.size() - 1]])
	var total := 0.0
	for i in ids:
		total += _bd_bounds(_bd_by_id[i]).size[ax]
	var gap := (last.end[ax] - first.position[ax] - total) / float(ids.size() - 1)
	_bd_begin()
	var cursor := first.end[ax] + gap
	for j in range(1, ids.size() - 1):
		var b := _bd_bounds(_bd_by_id[ids[j]])
		var d := Vector2.ZERO
		d[ax] = cursor - b.position[ax]
		_bd_move_by(ids[j], d)
		cursor += b.size[ax] + gap
	_bd_commit()


# Every shape spans the selection's full width (or height).
func _bd_stretch(horizontal: bool) -> void:
	if _bd_sel.size() < 2:
		return
	var box := _bd_sel_box()
	_bd_begin()
	for i in _bd_sel:
		var s: Dictionary = _bd_by_id[i]
		if _bd_rot(s) != 0.0:
			continue
		var b := _bd_bounds(s)
		if horizontal and b.size.x > 0.001:
			_bd_scale(s, s.duplicate(true), b.position, Vector2(box.size.x / b.size.x, 1.0))
			_bd_move_by(i, Vector2(box.position.x - b.position.x, 0.0))
		elif not horizontal and b.size.y > 0.001:
			_bd_scale(s, s.duplicate(true), b.position, Vector2(1.0, box.size.y / b.size.y))
			_bd_move_by(i, Vector2(0.0, box.position.y - b.position.y))
	_bd_commit()


# Tidy the selection into rows from its top-left, biggest first (a shelf pack).
func _bd_pack() -> void:
	if _bd_sel.size() < 2:
		return
	var box := _bd_sel_box()
	var ids: Array = _bd_sel.duplicate()
	ids.sort_custom(func(a, b): return _bd_bounds(_bd_by_id[a]).get_area() > _bd_bounds(_bd_by_id[b]).get_area())
	var area := 0.0
	for i in ids:
		area += _bd_bounds(_bd_by_id[i]).get_area()
	var gap := 16.0
	var row_w := maxf(sqrt(area) * 1.3, _bd_bounds(_bd_by_id[ids[0]]).size.x)
	var x := box.position.x
	var y := box.position.y
	var row_h := 0.0
	_bd_begin()
	for i in ids:
		var b := _bd_bounds(_bd_by_id[i])
		if x > box.position.x and x + b.size.x > box.position.x + row_w:
			x = box.position.x
			y += row_h + gap
			row_h = 0.0
		_bd_move_by(i, Vector2(x, y) - b.position)
		x += b.size.x + gap
		row_h = maxf(row_h, b.size.y)
	_bd_commit()


# ⌘⌥G: wrap the selection in a new frame (which takes in termlings inside it).
func _bd_frame_selection() -> void:
	if _bd_sel.is_empty():
		return
	_bd_begin()
	var f := _bd_new("frame")
	_bd_set_rect(f, _bd_sel_box().grow(32.0))
	_bd_shapes.push_front(f)
	_bd_by_id[str(f["id"])] = f
	_bd_adopt_into(str(f["id"]))
	_bd_sel = [str(f["id"])]
	_bd_commit()


# --- board: images ---------------------------------------------------------------------
# Paste one (⌘V), drop files on the ground, or ⌘U to pick. Each is copied into
# user://board-assets under a content hash, so the board keeps it.

func _bd_import_image(img: Image) -> String:
	if img == null or img.is_empty():
		return ""
	var m := maxi(img.get_width(), img.get_height())
	if m > 2048:
		img.resize(img.get_width() * 2048 / m, img.get_height() * 2048 / m, Image.INTERPOLATE_LANCZOS)
	var dir := ProjectSettings.globalize_path(BD_ASSETS)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/%x.png" % hash(img.get_data())
	if not FileAccess.file_exists(path):
		img.save_png(path)
	return path


func _bd_add_image(img: Image, at: Vector2) -> String:
	var src := _bd_import_image(img)
	if src == "":
		return ""
	var s := _bd_new("image")
	s["src"] = src
	var sz := Vector2(img.get_width(), img.get_height())
	sz *= minf(1.0, 480.0 / maxf(sz.x, sz.y))
	_bd_set_rect(s, Rect2(at - sz * 0.5, sz))
	_bd_add(s)
	return str(s["id"])


func _bd_texture(src: String):
	if src == "":
		return null
	if not _bd_tex.has(src):
		var tex = null
		if FileAccess.file_exists(src):
			var img := Image.load_from_file(src)
			if img != null and not img.is_empty():
				img.generate_mipmaps()
				tex = ImageTexture.create_from_image(img)
		_bd_tex[src] = tex
	return _bd_tex[src]


func _bd_draw_image(ci: CanvasItem, s: Dictionary) -> void:
	var r := _bd_rect(s)
	var tex = _bd_texture(str(s.get("src", "")))
	if tex == null:
		ci.draw_rect(r, Color(0.3, 0.3, 0.32, 0.5 * _bd_alpha))
		ci.draw_rect(r, Color(0.6, 0.6, 0.65, _bd_alpha), false, 2.0)
		ci.draw_string(_bd_font("sans"), r.position + Vector2(10, 26), "missing image",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20.0, 16, Color(0.85, 0.85, 0.9, _bd_alpha))
		return
	ci.draw_texture_rect(tex, r, false, Color(1, 1, 1, _bd_alpha))


# Files dropped on the window: onto a termling they're typed into its shell as
# quoted paths (as kitty does); anywhere else images land as image shapes and
# other files as their names.
func _bd_files_dropped(files: PackedStringArray) -> void:
	var at := get_global_mouse_position()
	var g := _group_at(at)
	if g != null and g.terminal.pane_id != 0:
		var parts := PackedStringArray()
		for f in files:
			parts.append("'" + f.replace("'", "'\\''") + "'")
		_pty(g.terminal.pane_id, (" ".join(parts) + " ").to_utf8_buffer())
		return
	_bd_place_files(files, at)


func _bd_place_files(files: PackedStringArray, at: Vector2) -> void:
	_bd_stop_edit()
	_bd_begin()
	var ids := []
	for f in files:
		var id := ""
		if f.get_extension().to_lower() in BD_IMAGE_EXTS:
			id = _bd_add_image(Image.load_from_file(f), at)
		if id == "":
			var s := _bd_new("text")
			s["text"] = f.get_file()
			s["autosize"] = true
			_bd_set_rect(s, Rect2(at, Vector2(20, 20)))
			_bd_add(s)
			_bd_relayout(s)
			id = str(s["id"])
		ids.append(id)
		at += Vector2(40, 40)
	_bd_sel = ids
	_bd_commit()
	_bd_unfocus_termling()
	_bd_ui_refresh()


func _bd_insert_media() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		return
	DisplayServer.file_dialog_show("Insert image", OS.get_system_dir(OS.SYSTEM_DIR_PICTURES), "", false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_FILES,
		PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp, *.svg, *.bmp ; Images"]), _bd_media_chosen)


func _bd_media_chosen(ok: bool, paths: PackedStringArray, _filter: int) -> void:
	if ok and not paths.is_empty():
		_bd_place_files(paths, _cam.position)


# --- board: link bookmarks -------------------------------------------------------------
# Paste a URL (or an agent's add_link) and it lands as tldraw's bookmark card:
# preview image, bold title, description, and a favicon + address row. The
# metadata comes from mcp/cove_unfurl.py, run as its own process and polled.
# It's cached per URL, so undo, copies and reloads draw at once, and written
# into the shape, so agents reading the board see it. GitHub PRs and issues also
# carry their state (a pill on the address row) and re-check it every few minutes.

func _bd_is_url(t: String) -> bool:
	if t.length() < 10 or t.contains(" ") or t.contains("\n") or t.contains("\t"):
		return false
	var lo := t.to_lower()
	return lo.begins_with("https://") or lo.begins_with("http://")


func _bd_add_bookmark(url: String, at: Vector2) -> String:
	var s := _bd_new("bookmark")
	s["url"] = url
	_bd_set_rect(s, Rect2(at - Vector2(BD_BM_W, BD_BM_H) * 0.5, Vector2(BD_BM_W, BD_BM_H)))
	_bd_add(s)
	return str(s["id"])


# Bring a bookmark up to date with what's known about its URL, and size it the
# way tldraw does: full card with an image (or while loading), short with just a
# title, a single row with nothing.
func _bd_bm_apply(s: Dictionary) -> void:
	var url := str(s.get("url", ""))
	if url == "":
		return
	if _bd_unfurl.has(url):
		var m: Dictionary = _bd_unfurl[url]
		for k in BD_BM_FIELDS:
			if m.has(k):
				s[k] = m[k]
			else:
				s.erase(k)
	elif s.has("fetched"):   # saved with the board: trust it, but re-check a PR's state
		var m := {}
		for k in BD_BM_FIELDS:
			if s.has(k):
				m[k] = s[k]
		_bd_unfurl[url] = m
		if s.has("github"):
			_bd_unfurl_start(url)
	else:
		_bd_unfurl_start(url)
	if not s.has("fetched") or str(s.get("image", "")) != "":
		s["h"] = BD_BM_H
	else:
		s["h"] = BD_BM_SHORT if str(s.get("title", "")) != "" else BD_BM_JUST_URL


func _bd_unfurl_start(url: String) -> void:
	if _bd_unfurl_pending.has(url):
		return
	var dir := DIR + "/unfurl"
	DirAccess.make_dir_recursive_absolute(dir)
	var out := dir + "/%s.json" % url.md5_text()
	if FileAccess.file_exists(out):
		DirAccess.remove_absolute(out)
	var script := ProjectSettings.globalize_path("res://mcp/cove_unfurl.py")
	var assets := ProjectSettings.globalize_path(BD_ASSETS) + "/links"
	if _create_process("/usr/bin/python3", [script, url, out, assets]) != -1:
		_bd_unfurl_pending[url] = {"out": out, "t": Time.get_ticks_msec()}


func _bd_unfurl_poll() -> void:
	var now := Time.get_ticks_msec()
	if now >= _bd_bm_next_refresh:
		if _bd_bm_next_refresh != 0:
			for s in _bd_shapes:
				if str(s["type"]) == "bookmark" and s.has("github"):
					_bd_unfurl_start(str(s["url"]))
		_bd_bm_next_refresh = now + BD_BM_REFRESH_MS
	for url in _bd_unfurl_pending.keys():
		var p: Dictionary = _bd_unfurl_pending[url]
		var res = null
		if FileAccess.file_exists(p["out"]):
			var f := FileAccess.open(p["out"], FileAccess.READ)
			if f:
				res = JSON.parse_string(f.get_as_text())
				f.close()
			DirAccess.remove_absolute(p["out"])
		elif now - int(p["t"]) < 45000:
			continue
		_bd_unfurl_pending.erase(url)
		var got: Dictionary = res if typeof(res) == TYPE_DICTIONARY else {}
		var old: Dictionary = _bd_unfurl.get(url, {})
		if not bool(got.get("ok", false)) and str(old.get("title", "")) != "":
			continue   # a failed re-check keeps what the card shows
		var m := {"fetched": int(got.get("fetched", Time.get_unix_time_from_system()))}
		for k in BD_BM_FIELDS:
			if got.has(k) and str(got[k]) != "":
				m[k] = got[k]
		for k in ["image", "favicon"]:   # GitHub rate-limits its preview images: keep the last one
			if not m.has(k) and old.has(k):
				m[k] = old[k]
		if not m.has("site"):
			m["site"] = url
		_bd_unfurl[url] = m
		for s in _bd_shapes:
			if str(s["type"]) == "bookmark" and str(s.get("url", "")) == url:
				_bd_bm_apply(s)
		_bd_dirty = true
		_bd_save_in = 0.4


func _bd_bm_open(s: Dictionary) -> void:
	var url := str(s.get("url", ""))
	if _bd_is_url(url):
		OS.shell_open(url)


func _bd_bm_font(bold: bool) -> Font:
	var key := "bm-bold" if bold else "bm"
	if not _bd_fonts.has(key):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(BD_FONT_NAMES["sans"])
		f.font_weight = 700 if bold else 400
		f.multichannel_signed_distance_field = true
		_bd_fonts[key] = f
	return _bd_fonts[key]


func _bd_bm_style(kind: String) -> StyleBoxFlat:
	if not _bd_bm_styles.has(kind):
		var b := StyleBoxFlat.new()
		b.anti_aliasing = true
		match kind:
			"card":   # .tl-bookmark__container + tldraw's rotated box shadow
				b.set_corner_radius_all(6)
				b.set_border_width_all(1)
				b.shadow_size = 5
				b.shadow_offset = Vector2(0, 2.5)
			"copy":   # .tl-bookmark__copy_container: the card's rounded bottom
				b.corner_radius_bottom_left = 5
				b.corner_radius_bottom_right = 5
			"pill":
				b.set_corner_radius_all(9)
		_bd_bm_styles[kind] = b
	return _bd_bm_styles[kind]


func _bd_bm_address(s: Dictionary) -> String:
	var site := str(s.get("site", ""))
	if site != "":
		return site
	var url := str(s.get("url", ""))
	var host := url.get_slice("://", 1).get_slice("/", 0)
	return host.trim_prefix("www.") if host != "" else url


# The address row (favicon + address), in the card's own frame. Clicking it opens the link.
func _bd_bm_link_rect(s: Dictionary) -> Rect2:
	var r := _bd_rect(s)
	var w := _bd_bm_font(false).get_string_size(_bd_bm_address(s), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	return Rect2(r.position.x + 12.0, r.end.y - 12.0 - 18.0, minf(24.0 + w, r.size.x - 24.0), 18.0)


func _bd_bm_para(text: String, font: Font, px: int, line_h: float, width: float, max_lines: int) -> TextParagraph:
	var p := TextParagraph.new()
	p.add_string(text, font, px)
	p.width = width
	p.max_lines_visible = max_lines
	p.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	p.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	p.line_spacing = maxf(line_h - font.get_height(px), 0.0)
	return p


func _bd_bm_lines(p: TextParagraph, max_lines: int) -> int:
	return mini(p.get_line_count(), max_lines)


# A rect with its top corners rounded: the image well at the top of the card.
func _bd_bm_round_top(rect: Rect2, rad: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 7:
		var t := PI + PI * 0.5 * i / 6.0
		pts.append(rect.position + Vector2(rad, rad) + Vector2(cos(t), sin(t)) * rad)
	for i in 7:
		var t := PI * 1.5 + PI * 0.5 * i / 6.0
		pts.append(Vector2(rect.end.x - rad, rect.position.y + rad) + Vector2(cos(t), sin(t)) * rad)
	pts.append(rect.end)
	pts.append(Vector2(rect.position.x, rect.end.y))
	return pts


# tldraw's BookmarkShapeComponent, laid out as its CSS does: the image well
# takes whatever the copy (12px padding, 16px bold title x2 lines, 12px
# description x3 lines, 12px address row) leaves.
func _bd_draw_bookmark(ci: CanvasItem, s: Dictionary) -> void:
	var a := _bd_alpha
	var rid := ci.get_canvas_item()
	var r := _bd_rect(s)
	var card := _bd_bm_style("card")
	card.bg_color = Color(BD_BM_PANEL, a)
	card.border_color = Color(BD_BM_EDGE, a)
	card.shadow_color = Color(0, 0, 0, 0.32 * a)
	card.draw(rid, r)
	var pad := 12.0
	var inner := r.size.x - pad * 2.0
	var loaded := s.has("fetched")
	var image := str(s.get("image", ""))
	var show_image := not loaded or image != ""
	var title := str(s.get("title", ""))
	var desc := str(s.get("description", "")) if image != "" else ""
	var bold := _bd_bm_font(true)
	var font := _bd_bm_font(false)
	var tp: TextParagraph = _bd_bm_para(title, bold, 16, 16.0 * 1.6, inner, 2) if title != "" else null
	var dp: TextParagraph = _bd_bm_para(desc, font, 12, 12.0 * 1.5, inner, 3) if desc != "" else null
	var title_h := _bd_bm_lines(tp, 2) * 16.0 * 1.6 + 4.0 if tp else 0.0
	var desc_h := _bd_bm_lines(dp, 3) * 12.0 * 1.5 + 8.0 if dp else 0.0
	var copy_h := pad + title_h + desc_h + (8.0 if tp or dp else 0.0) + 18.0 + pad
	var copy := r
	if show_image:
		var well := Rect2(r.position + Vector2(1, 1), Vector2(r.size.x - 2.0, maxf(r.size.y - copy_h - 1.0, 0.0)))
		var poly := _bd_bm_round_top(well, 4.0)
		var tex = _bd_texture(image) if image != "" else null
		if tex != null:   # object-fit: cover
			var ts: Vector2 = tex.get_size()
			var k := maxf(well.size.x / ts.x, well.size.y / ts.y)
			var src := Rect2((ts - well.size / k) * 0.5, well.size / k)
			var uvs := PackedVector2Array()
			for pt in poly:
				uvs.append((src.position + (pt - well.position) / k) / ts)
			ci.draw_colored_polygon(poly, Color(1, 1, 1, a), uvs, tex)
		else:
			ci.draw_colored_polygon(poly, Color(BD_BM_MUTED2, BD_BM_MUTED2.a * a))   # .tl-bookmark__placeholder
		var outline := poly.duplicate()
		outline.append(poly[0])
		ci.draw_polyline(outline, Color(BD_BM_DIVIDER, a), 1.0, true)
		copy = Rect2(r.position.x, well.end.y, r.size.x, r.end.y - well.end.y)
	var cb := _bd_bm_style("copy")
	cb.bg_color = Color(BD_BM_MUTED0, BD_BM_MUTED0.a * a)
	cb.draw(rid, copy.grow_individual(-1, 0, -1, -1))
	# Title and description from the top of the copy, the address row at its bottom.
	var y := copy.position.y + pad
	if tp:
		tp.draw(rid, Vector2(r.position.x + pad, y + tp.line_spacing * 0.5), Color(BD_BM_TEXT, a))
		y += title_h
	if dp:
		dp.draw(rid, Vector2(r.position.x + pad, y + 4.0 + dp.line_spacing * 0.5), Color(BD_BM_TEXT2, a))
	_bd_bm_draw_address(ci, s, Rect2(r.position.x + pad, r.end.y - pad - 18.0, inner, 18.0))


# Favicon (or tldraw's link glyph) + address; GitHub PRs/issues add their
# +/- lines and a state pill at the right.
func _bd_bm_draw_address(ci: CanvasItem, s: Dictionary, row: Rect2) -> void:
	var a := _bd_alpha
	var rid := ci.get_canvas_item()
	var font := _bd_bm_font(false)
	var bold := _bd_bm_font(true)
	var right := row.end.x
	var gh = s.get("github", null)
	if typeof(gh) == TYPE_DICTIONARY and BD_GH_STATES.has(str(gh.get("state", ""))):
		var st: Array = BD_GH_STATES[str(gh["state"])]
		var label: String = st[0]
		var lw := bold.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var pr := Rect2(right - lw - 14.0, row.get_center().y - 9.0, lw + 14.0, 18.0)
		var pill := _bd_bm_style("pill")
		pill.bg_color = Color(st[1], a)
		pill.draw(rid, pr)
		ci.draw_string(bold, Vector2(pr.position.x + 7.0, pr.get_center().y + bold.get_ascent(11) * 0.5 - 1.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, a))
		right = pr.position.x - 8.0
		if gh.get("additions", null) != null and gh.get("deletions", null) != null:
			var base := row.get_center().y + font.get_ascent(11) * 0.5 - 1.0
			var dels := "−%d" % int(gh["deletions"])
			var dw := font.get_string_size(dels, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			ci.draw_string(font, Vector2(right - dw, base), dels, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(0.973, 0.318, 0.286, a))
			var adds := "+%d" % int(gh["additions"])
			var aw := font.get_string_size(adds, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			ci.draw_string(font, Vector2(right - dw - 5.0 - aw, base), adds, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(0.247, 0.725, 0.314, a))
			right -= dw + aw + 13.0
	var icon := Rect2(row.position.x, row.get_center().y - 8.0, 16, 16)
	var fav = _bd_texture(str(s.get("favicon", "")))
	if fav != null:
		ci.draw_texture_rect(fav, icon, false, Color(1, 1, 1, a))
	else:   # tldraw's LINK_ICON (a 30x30 path), stroked
		var k := 16.0 / 30.0
		var col := Color(BD_BM_TEXT2, a)
		for path in [[13, 5, 7, 5, 5, 7, 5, 23, 7, 25, 23, 25, 25, 23, 25, 17], [19, 5, 25, 5, 25, 11], [25, 5, 13, 17]]:
			var pts := PackedVector2Array()
			for i in range(0, path.size(), 2):
				pts.append(icon.position + Vector2(path[i], path[i + 1]) * k)
			ci.draw_polyline(pts, col, 1.2, true)
	var line := TextLine.new()
	line.add_string(_bd_bm_address(s), font, 12)
	line.width = maxf(right - (row.position.x + 24.0), 10.0)
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.draw(rid, Vector2(row.position.x + 24.0, row.get_center().y - line.get_size().y * 0.5), Color(BD_BM_TEXT2, a))


# --- board: tldraw's look (hand-drawn strokes, pattern fill, tapered ink) ------------

func _bd_seed(s: Dictionary) -> int:
	return absi(hash(str(s["id"])))


# The "draw" dash: the path is resampled and nudged off the line by a smooth,
# seeded wobble (so it holds still between frames), in two passes like a pen
# going over its own line. Ends stay put so arrowheads still meet their tips.
func _bd_sketch(ci: CanvasItem, path: PackedVector2Array, col: Color, w: float, seed: int) -> void:
	var step := maxf(10.0, w * 5.0)
	var rs := PackedVector2Array([path[0]])
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var n := maxi(1, int(ceilf(a.distance_to(b) / step)))
		for j in range(1, n + 1):
			rs.append(a.lerp(b, float(j) / float(n)))
	var rng := RandomNumberGenerator.new()
	var last := rs.size() - 1
	for pass_i in 2:
		rng.seed = seed * 31 + pass_i
		var amp := maxf(1.2, w * 0.6) * (1.0 if pass_i == 0 else 0.7)
		var off := 0.0
		var out := PackedVector2Array()
		for i in rs.size():
			off = lerpf(off, rng.randf_range(-amp, amp), 0.45)
			var ends := minf(1.0, float(mini(i, last - i)) / 2.0)
			var nrm := _bd_perp(rs[mini(i + 1, last)] - rs[maxi(i - 1, 0)])
			out.append(rs[i] + nrm * off * ends)
		ci.draw_polyline(out, col, w * (1.0 if pass_i == 0 else 0.5), true)


# 45° hatching clipped to the shape (the "pattern" fill).
func _bd_hatch(ci: CanvasItem, poly: PackedVector2Array, r: Rect2, c: Color, w: float) -> void:
	var gap := 8.0 + w * 2.0
	var col := Color(c.r, c.g, c.b, 0.55 * c.a)
	var x := -r.size.y
	while x < r.size.x:
		var a := Vector2(r.position.x + x, r.end.y)
		var b := a + Vector2(r.size.y, -r.size.y)
		for seg in Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([a, b]), poly):
			if seg.size() >= 2:
				ci.draw_line(seg[0], seg[seg.size() - 1], col, maxf(1.0, w * 0.5), true)
		x += gap


func _bd_draw_free(ci: CanvasItem, s: Dictionary) -> void:
	var pts := _bd_pts(s)
	var c := _bd_col(s)
	var w := _bd_draw_w(s)
	var hl := bool(s.get("highlight", false))
	if hl:
		c.a *= 0.35
	if pts.is_empty():
		return
	if pts.size() == 1 or (pts.size() == 2 and pts[0] == pts[1]):
		ci.draw_circle(pts[0], w * 0.5, c)
		return
	var dash := str(s.get("dash", "solid"))
	if hl or dash == "solid":
		ci.draw_polyline(pts, c, w, true)
	elif dash == "draw":
		_bd_draw_tapered(ci, _bd_smooth(pts), c, w)
	else:
		_bd_stroke(ci, pts, false, c, w, dash)


# Chaikin corner-cutting: turns the mouse's polyline into a smooth ink line.
func _bd_smooth(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts
	for _k in (2 if pts.size() < 150 else 1):
		if out.size() < 3:
			break
		var nxt := PackedVector2Array([out[0]])
		for i in range(out.size() - 1):
			nxt.append(out[i].lerp(out[i + 1], 0.25))
			nxt.append(out[i].lerp(out[i + 1], 0.75))
		nxt.append(out[out.size() - 1])
		out = nxt
	return out


# Freehand ink that thins toward both ends, like a pen stroke.
func _bd_draw_tapered(ci: CanvasItem, pts: PackedVector2Array, c: Color, w: float) -> void:
	var total := 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
	var taper := maxf(minf(total * 0.25, w * 8.0), 0.001)
	var run := 0.0
	for i in range(pts.size() - 1):
		var seg := pts[i].distance_to(pts[i + 1])
		var mid := run + seg * 0.5
		var k := clampf(minf(mid, total - mid) / taper, 0.0, 1.0)
		var ww := w * (0.45 + 0.75 * k)
		ci.draw_line(pts[i], pts[i + 1], c, ww, true)
		ci.draw_circle(pts[i + 1], ww * 0.5, c)
		run += seg
