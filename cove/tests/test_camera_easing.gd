extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


func _check_close(actual: Vector2, expected: Vector2, label: String) -> void:
	if not actual.is_equal_approx(expected):
		push_error("%s: expected %s, got %s" % [label, expected, actual])
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := Cove.new()
	var camera := Camera2D.new()
	cove._cam = camera
	var target := Vector2(1000.0, -400.0)

	camera.position = Vector2.ZERO
	cove._ease_cam(target, 8.0 * 0.4)
	_check_close(camera.position, target, "slow frame lands on the target, not past it")

	camera.position = Vector2.ZERO
	cove._ease_cam(target, maxf(1.0, 6.0 * 2.0))
	_check_close(camera.position, target, "multi-second stall while tracking")

	# A run of slow frames under load used to compound the overshoot each frame
	# and fling the camera off the board.
	camera.position = Vector2(-3000.0, 2000.0)
	for i in 30:
		cove._ease_cam(target, 8.0 * 0.5)
	_check_close(camera.position, target, "repeated slow frames stay on the target")

	camera.position = Vector2.ZERO
	cove._ease_cam(target, 8.0 / 60.0)
	_check_close(camera.position, target * (8.0 / 60.0), "normal frame keeps existing easing")

	camera.free()
	cove.free()
	quit(1 if _failures else 0)
