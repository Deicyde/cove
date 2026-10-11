extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


class DummyTerminal extends Node:
	var custom_name := ""

	func set_custom_name(value: String) -> void:
		custom_name = value


class DummyGroup extends Node2D:
	var term_id := -1
	var terminal := DummyTerminal.new()

	func _init() -> void:
		add_child(terminal)


func _check(ok: bool, label: String) -> void:
	if not ok:
		push_error(label)
		_failures += 1


func _group(cove: Node, id: int, name := "") -> DummyGroup:
	var group := DummyGroup.new()
	group.term_id = id
	group.terminal.custom_name = name
	cove.add_child(group)
	cove._groups[id] = group
	if name != "":
		cove._names[id] = name
	return group


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := Cove.new()
	cove._bd_by_id["frame"] = {
		"id": "frame", "type": "frame", "text": "Cove Development",
		"x": 0.0, "y": 0.0, "w": 800.0, "h": 500.0,
	}

	var named := _group(cove, 1, "worker-a")
	cove._maybe_name_from_zone(1, "frame")
	_check(named.terminal.custom_name == "worker-a",
		"dropping into a frame must preserve a distinct termling name")
	_check(cove._names[1] == "worker-a",
		"frame membership must not overwrite the id-keyed name")

	var unnamed := _group(cove, 2)
	cove._maybe_name_from_zone(2, "frame")
	_check(unnamed.terminal.custom_name == "Cove Development",
		"an unnamed termling should still inherit its frame name")
	_check(cove._name_pending_session.has(2),
		"an inherited name assigned before session discovery should be pending")

	var pending := _group(cove, 3)
	cove._name_by_session["cove-worker"] = "Cove Development"
	_check(cove._exec_command({"cmd": "rename", "id": 3, "name": "worker-new"}) == "",
		"MCP rename should succeed before session discovery")
	cove._learn_session(3, pending, "cove-worker")
	_check(pending.terminal.custom_name == "worker-new",
		"session discovery must not replay an older frame name over a newer name")
	_check(cove._name_by_session["cove-worker"] == "worker-new",
		"pending explicit name should refresh the session-keyed name")
	_check(not cove._name_pending_session.has(3),
		"learning the session should consume pending name state")

	var stale_id := _group(cove, 4, "wrong-id-name")
	cove._name_by_session["cove-restored"] = "right-session-name"
	cove._learn_session(4, stale_id, "cove-restored")
	_check(stale_id.terminal.custom_name == "right-session-name",
		"saved session name should still beat an unmarked stale id-keyed name")

	var learned := _group(cove, 5)
	cove._sessions[5] = "cove-known"
	cove._set_term_name(5, "known-worker")
	_check(cove._name_by_session["cove-known"] == "known-worker",
		"renaming a learned session should update durable name state immediately")

	var departing := _group(cove, 42)
	cove._sessions[42] = "cove-departing"
	cove._set_term_name(42, "departing-worker")
	cove._remove_group(42)
	_check(not cove._names.has(42),
		"removing a sessioned termling should clear its reusable id-keyed name")
	var replacement := _group(cove, 42)
	cove._learn_session(42, replacement, "cove-replacement")
	_check(replacement.terminal.custom_name == "",
		"a fresh session reusing a kitty id must not inherit the departed name")
	var pre_session := _group(cove, 43)
	cove._set_term_name(43, "pending-departure")
	cove._remove_group(43)
	_check(not cove._names.has(43),
		"removing a pre-session termling should clear its reusable id-keyed name")
	var pre_replacement := _group(cove, 43)
	_check(pre_replacement.terminal.custom_name == "",
		"id reuse must not inherit a departed pre-session name")

	var reloaded := Cove.new()
	reloaded._name_by_session["cove-hot-reload"] = "old-frame-name"
	reloaded._restore_id_name(6, "new-before-session", true)
	var after_reload := _group(reloaded, 6, str(reloaded._names[6]))
	reloaded._learn_session(6, after_reload, "cove-hot-reload")
	_check(after_reload.terminal.custom_name == "new-before-session",
		"hot reload must preserve a pending pre-session rename")
	_check(reloaded._name_by_session["cove-hot-reload"] == "new-before-session",
		"pending hot-reload name should replace stale durable session state")
	var cleared := Cove.new()
	cleared._name_by_session["cove-cleared"] = "old-frame-name"
	cleared._restore_id_name(7, "", true)
	var after_clear := _group(cleared, 7, str(cleared._names.get(7, "")))
	cleared._learn_session(7, after_clear, "cove-cleared")
	_check(after_clear.terminal.custom_name == "",
		"hot reload must preserve an explicit pre-session name clear")
	_check(cleared._name_by_session["cove-cleared"] == "",
		"explicit clear should remove the stale session name")

	cove.free()
	reloaded.free()
	cleared.free()
	quit(1 if _failures else 0)
