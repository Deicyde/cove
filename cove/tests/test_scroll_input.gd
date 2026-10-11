extends SceneTree

const Cove := preload("res://scripts/Cove.gd")
const CarryGroup := preload("res://scripts/CarryGroup.gd")

var _failures := 0


class ScrollTestCove extends Cove:
	var method := StringName()
	var args: Array = []
	var calls: Array = []

	func _input_has_method(_method: StringName) -> bool:
		return true

	func _call_input(called: StringName, called_args: Array = []) -> bool:
		method = called
		args = called_args
		calls.append([called, called_args])
		return true

	func _world_mouse() -> Vector2:
		return Vector2.ZERO


class FakeTerminal extends RefCounted:
	var godot := false
	var page := false
	var pane_id := 43
	var mouse_mode := 0
	var cols := 100
	var pixel := Vector2(123.4, 456.6)

	func native_size() -> Vector2i:
		return Vector2i(1000, 500)

	func pixel_at(_world: Vector2) -> Vector2:
		return pixel

	func cell_and_half(_world: Vector2) -> Dictionary:
		return {"cell": Vector2i(1, 2), "left": true}


class FakeGroup extends Node2D:
	var term_id := 44
	var terminal := FakeTerminal.new()
	var ended := 0

	func end_pointer_interaction() -> void:
		ended += 1


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := ScrollTestCove.new()
	cove._sock = RefCounted.new()

	# Fractional trackpad residue belongs to one target and one direction.
	_check(cove._scroll_steps(7, 0.6) == 0, "first fractional step scrolled early")
	_check(cove._scroll_steps(7, 0.6) == 1, "same-direction residue was lost")
	_check(cove._scroll_steps(7, -0.2) == 0, "direction reversal used stale residue")
	_check(cove._scroll_steps(7, -0.9) == -1, "reversed gesture did not scroll promptly")
	_check(cove._scroll_steps(8, -0.2) == 0, "new target inherited old residue")
	_check(cove._scroll_steps(8, -0.9) == -1, "new target did not build its own residue")

	_check(cove._send_history_scroll(42, -7), "fast history scroll was rejected")
	var msg: PackedByteArray = cove.args[0]
	_check(cove.method == "send_raw", "history scroll did not use the persistent socket")
	_check(msg.size() == 13 and msg[0] == 7, "history scroll wire header is wrong")
	_check(int(msg.decode_u64(1)) == 42 and msg.decode_s32(9) == -7,
		"history scroll wire payload is wrong")

	cove._sel_shift = true
	cove._pointer_mods = 1
	_check(cove._send_pointer(FakeTerminal.new(), 43, Vector2.ZERO, 1),
		"native pointer message was rejected")
	msg = cove.args[0]
	_check(msg.size() == 22 and msg[0] == 9, "pointer wire header is wrong")
	_check(int(msg.decode_u64(1)) == 43 and msg[9] == 1, "pointer target/phase is wrong")
	_check(msg.decode_u32(10) == 123 and msg.decode_u32(14) == 457,
		"pointer pixel coordinates are wrong")
	_check(msg.decode_u32(18) == 1, "pointer modifiers are wrong")

	var scrollbar_term := FakeTerminal.new()
	scrollbar_term.pixel = Vector2(990.0, 250.0)
	_check(cove._scrollbar_candidate(scrollbar_term, Vector2.ZERO),
		"visible right-edge scrollbar was not recognized")
	_check(cove._send_scrollbar(scrollbar_term, 44, Vector2.ZERO, 0),
		"native scrollbar message was rejected")
	msg = cove.args[0]
	_check(msg.size() == 18 and msg[0] == 8, "scrollbar wire header is wrong")
	_check(int(msg.decode_u64(1)) == 44 and msg[9] == 0,
		"scrollbar target/phase is wrong")

	var group := FakeGroup.new()
	cove._press_group = group
	cove._pointer_active = true
	cove._stop_terminal_pointer(true)
	msg = cove.args[0]
	_check(msg[0] == 9 and msg[9] == 3, "pointer cancellation did not use native phase 3")
	_check(not cove._pointer_active and group.ended == 1,
		"pointer cancellation did not unlock the termling")
	group.free()

	var click_group := FakeGroup.new()
	cove._press_group = click_group
	cove._focused_id = click_group.term_id
	cove._selecting = true
	cove._sel_started = false
	cove._pointer_active = false
	cove._scrollbar_active = false
	cove._press_dbl = false
	cove._pointer_mods = 10   # Ctrl + Super
	cove.calls.clear()
	_check(cove._send_terminal_click_if_needed(), "focused terminal click was not synthesized")
	cove._stop_terminal_pointer(false)
	_check(cove.calls.size() == 2, "terminal click did not emit press and release")
	if cove.calls.size() == 2:
		var press: PackedByteArray = cove.calls[0][1][0]
		var release: PackedByteArray = cove.calls[1][1][0]
		_check(press[0] == 9 and press[9] == 0 and release[0] == 9 and release[9] == 2,
			"terminal click pointer phases are wrong")
		_check(press.decode_u32(10) == release.decode_u32(10) \
			and press.decode_u32(14) == release.decode_u32(14),
			"terminal click press/release coordinates differ")
		_check(press.decode_u32(18) == 10 and release.decode_u32(18) == 10,
			"terminal click modifiers were not preserved")
	cove._press_group = click_group
	cove._focused_id = click_group.term_id + 1
	cove._selecting = true
	cove._pointer_active = false
	cove.calls.clear()
	_check(not cove._send_terminal_click_if_needed() and cove.calls.is_empty(),
		"first click on an unfocused termling was forwarded")
	cove._focused_id = click_group.term_id
	cove._sel_started = true
	_check(not cove._send_terminal_click_if_needed(), "selection drag was misclassified as a click")
	cove._sel_started = false
	cove._scrollbar_active = true
	_check(not cove._send_terminal_click_if_needed(), "scrollbar press was misclassified as a click")
	cove._scrollbar_active = false
	cove._press_dbl = true
	_check(not cove._send_terminal_click_if_needed(), "double/triple click was misclassified")
	cove._press_dbl = false
	click_group.terminal.page = true
	_check(not cove._send_terminal_click_if_needed(), "page click was sent to kitty")
	click_group.terminal.page = false
	cove._selecting = false
	_check(not cove._send_terminal_click_if_needed(), "hold-to-move release became a click")
	cove._press_group = null
	cove._selecting = false
	click_group.free()

	var carry := CarryGroup.new()
	carry.setup(999, "/tmp/nonexistent-cove-scroll-test.rgba", Rect2(-1000, -1000, 2000, 2000))
	root.add_child(carry)
	await process_frame
	carry._rig.position.y = -11.0
	carry.terminal.position.y = -123.0
	carry.begin_pointer_interaction()
	carry._process(0.1)
	carry._layout(0.1)
	_check(carry._rig.position.y == -11.0 and carry.terminal.position.y == -123.0,
		"termling geometry moved during pointer interaction")
	carry.end_pointer_interaction()
	root.remove_child(carry)
	carry.free()

	cove.free()
	quit(1 if _failures else 0)
