extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

const DAY := 86400.0

var _failures := 0


# Records what the collector would do instead of saving screens or ending sessions.
class GcCove extends Cove:
	var calls := []
	var save_ok := true

	func _gc_save_screen(id: int, _sess: String) -> String:
		calls.append("save %d" % id)
		return "/tmp/screen-%d.ansi" % id if save_ok else ""

	func _delete_term(id: int) -> bool:
		calls.append("delete %d" % id)
		return true

	func _gc_log(_msg: String) -> void:
		pass


class FakeTerminal extends RefCounted:
	var page := false
	var remote := false
	var pane_id := 0
	var custom_name := ""
	var gc_marked := false

	func set_gc(marked: bool, _frac: float) -> void:
		gc_marked = marked


class FakeGroup extends RefCounted:
	var terminal := FakeTerminal.new()


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _shape(id: String, extra := {}) -> Dictionary:
	var s := {"id": id, "type": "note", "x": 0.0, "y": 0.0, "w": 100.0, "h": 100.0,
		"text": id, "color": "yellow"}
	s.merge(extra, true)
	return s


func _run() -> void:
	var cove := Cove.new()
	var now := 1800000000.0
	cove._gc_days = 14.0
	cove._bd_shapes = [
		_shape("old-marked", {"gc": true}),
		_shape("new-marked", {"gc": true}),
		_shape("old-unmarked"),
		_shape("old-locked", {"gc": true, "locked": true}),
		_shape("no-record", {"gc": true}),
	]
	cove._bd_reindex()
	cove._gc_used = {"old-marked": now - 20 * DAY, "new-marked": now - DAY,
		"old-unmarked": now - 30 * DAY, "old-locked": now - 30 * DAY}

	var gone: Array = cove._gc_collect_board(now)
	_check(gone == ["old-marked"], "only a marked, unlocked shape unused past the threshold goes: %s" % [gone])
	_check(not cove._bd_by_id.has("old-marked"), "the collected shape left the board")
	_check(cove._bd_by_id.has("old-unmarked") and cove._bd_by_id.has("old-locked"),
		"unmarked and locked shapes stay")
	_check(cove._bd_by_id.has("no-record"), "a marked shape with no recorded use is not due")
	_check(cove._gc_trash.size() == 1 and str(cove._gc_trash[0]["shape"]["id"]) == "old-marked",
		"the collected shape waits in the trash")

	cove._gc_trash.append({"shape": _shape("stale"), "at": now - 8 * DAY})
	cove._gc_purge_trash(now)
	_check(cove._gc_trash.size() == 1 and str(cove._gc_trash[0]["shape"]["id"]) == "old-marked",
		"trash older than seven days is purged")

	cove._gc_restore_trash()
	_check(cove._bd_by_id.has("old-marked"), "restore puts the shape back")
	_check(not cove._bd_by_id["old-marked"].has("gc"), "a restored shape is no longer marked")
	_check(cove._gc_trash.is_empty(), "restore empties the trash")

	cove._bd_sel = ["old-unmarked"]
	cove._bd_toggle_gc()
	_check(bool(cove._bd_by_id["old-unmarked"].get("gc", false)), "the toggle marks the selection")
	_check(cove._gc_now() - float(cove._gc_used["old-unmarked"]) < 5.0, "marking counts as a use")
	cove._bd_toggle_gc()
	_check(not cove._bd_by_id["old-unmarked"].has("gc"), "toggling again unmarks it")

	cove._gc_used.erase("no-record")
	cove._gc_start_clocks()
	_check(cove._gc_used.has("no-record"), "a shape without a record starts its clock")

	var idle := {"agent": "claude", "act": ["idle", now - DAY, false], "tool": false}
	_check(Cove._gc_term_idle(idle, false), "an agent whose turn ended is idle")
	_check(not Cove._gc_term_idle(idle, true), "a termling waiting on you is not idle")
	_check(not Cove._gc_term_idle({"agent": "claude", "act": ["working", now, false]}, false),
		"a working agent is busy")
	_check(not Cove._gc_term_idle({"agent": "claude", "act": ["idle", now, false], "tool": true}, false),
		"a running tool is busy")
	_check(not Cove._gc_term_idle({"agent": "codex", "act": []}, false), "an unknown agent state counts as busy")
	_check(Cove._gc_term_idle({"agent": "shell", "idle": true}, false), "a bare shell prompt is idle")
	_check(not Cove._gc_term_idle({"agent": "shell", "idle": false}, false), "a shell running something is busy")
	_check(not Cove._gc_term_idle({}, false), "no information counts as busy")
	_check(not Cove._gc_term_idle({"agent": "claude", "act": ["idle", now, false], "remote_host": "mac2"}, false),
		"remote termlings are left alone")

	cove._gc_term_used = {"cove-1": now - 3 * DAY}
	_check(is_equal_approx(cove._gc_term_last_used("cove-1", {"act": ["idle", now - DAY, false]}), now - DAY),
		"an agent's latest turn counts as a use")
	_check(is_equal_approx(cove._gc_term_last_used("cove-1", {}), now - 3 * DAY),
		"otherwise the last time you focused it")

	cove.free()
	_run_termlings()
	quit(1 if _failures else 0)


func _run_termlings() -> void:
	var cove := GcCove.new()
	var now := cove._gc_now()
	cove._gc_days = 14.0
	var idle_old := ["idle", now - 20 * DAY, false]
	# id: [session, marked, act, attention]
	var cases := {
		1: ["cove-1", true, idle_old, false],                             # due
		2: ["cove-2", true, ["working", now - 20 * DAY, false], false],  # mid-turn
		3: ["cove-3", true, ["idle", now - DAY, false], false],           # used yesterday
		4: ["cove-4", false, idle_old, false],                            # never marked
		5: ["cove-5", true, idle_old, true],                              # waiting on you
	}
	for id in cases:
		var c: Array = cases[id]
		var g := FakeGroup.new()
		g.terminal.pane_id = id
		cove._groups[id] = g
		cove._sessions[id] = c[0]
		cove._agents[id] = {"agent": "claude", "act": c[2], "tool": false}
		if c[1]:
			cove._gc_term_mark[c[0]] = true
			cove._gc_term_used[c[0]] = now - 30 * DAY
		if c[3]:
			cove._attn_ids[id] = true

	cove._gc_collect_terms(now)
	_check(cove.calls == ["save 1", "delete 1"],
		"only the marked, idle, overdue termling goes, screen saved first: %s" % [cove.calls])
	_check(not cove._gc_term_mark.has("cove-1"), "a collected termling's mark is cleared")
	_check(cove._gc_term_mark.has("cove-2") and cove._gc_term_mark.has("cove-5"), "kept termlings stay marked")

	cove.calls = []
	cove.save_ok = false
	cove._gc_term_mark["cove-1"] = true
	cove._gc_collect_terms(now)
	_check(cove.calls == ["save 1"], "no screen saved, no delete: %s" % [cove.calls])

	cove._gc_update_term_badges()
	_check(cove._groups[2].terminal.gc_marked and not cove._groups[4].terminal.gc_marked,
		"marked termlings wear the hourglass, others don't")
	for id in cove._groups.keys():
		cove._groups.erase(id)
	cove.free()
