extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


class RestoreTestCove extends Cove:
	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func _bd_setup() -> void:
		pass


func _check_close(actual: float, expected: float, label: String) -> void:
	if not is_equal_approx(actual, expected):
		push_error("%s: expected %f, got %f" % [label, expected, actual])
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := Cove.new()
	var camera := Camera2D.new()
	cove._cam = camera

	camera.zoom = Vector2(8.0, 8.0)
	cove._ease_zoom(0.35, 0.2)
	_check_close(camera.zoom.x, 0.35, "slow frame while zooming out")

	camera.zoom = Vector2(0.35, 0.35)
	cove._ease_zoom(8.0, 0.2)
	_check_close(camera.zoom.x, 8.0, "slow frame while zooming in")

	camera.zoom = Vector2(8.0, 8.0)
	cove._ease_zoom(0.35, 1.0 / 60.0)
	_check_close(camera.zoom.x, 6.98, "normal frame keeps existing easing")

	camera.zoom = Vector2(-0.5, -0.5)
	cove._ease_zoom(0.9, 1.0 / 60.0)
	if camera.zoom.x < cove.MIN_ZOOM and not is_equal_approx(camera.zoom.x, cove.MIN_ZOOM):
		push_error("invalid zoom was not repaired: %f" % camera.zoom.x)
		_failures += 1

	var restored := RestoreTestCove.new()
	restored.set_process(false)
	root.add_child(restored)
	restored._saved = {"cam": [0.0, 0.0, -4.24]}
	restored._build_world()
	_check_close(restored._cam.zoom.x, restored.MIN_ZOOM, "poisoned saved zoom")
	root.remove_child(restored)
	restored.free()

	camera.free()
	cove.free()
	quit(1 if _failures else 0)
