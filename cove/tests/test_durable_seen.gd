extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


class FakeTerminal extends RefCounted:
	var custom_name := ""


class FakeGroup extends Node2D:
	var terminal := FakeTerminal.new()


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := Cove.new()
	cove._apply_durable({"by_session": {
		"cove-1": {"name": "gone", "pos": [0, 0], "seen": 100},
		"cove-2": {"name": "back", "pos": [0, 0], "seen": 100},
	}})
	for id in [2, 3]:
		var g := FakeGroup.new()
		cove._groups[id] = g
		cove._sessions[id] = "cove-%d" % id

	var by: Dictionary = cove._durable_by_session(500)
	_check(int(by["cove-2"]["seen"]) == 500 and int(by["cove-3"]["seen"]) == 500,
		"every session on the board is stamped: %s" % [by])
	_check(int(by["cove-1"]["seen"]) == 100 and by["cove-1"]["name"] == "gone",
		"a session that didn't come back keeps its last stamp: %s" % [by["cove-1"]])

	for id in cove._groups.keys():
		cove._groups[id].free()
	cove._groups.clear()
	cove.free()
	quit(1 if _failures else 0)
