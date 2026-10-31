extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


class TestCove extends Cove:
	var connect_failures := 0
	var attempts := 0
	var connected := false
	var fail_first_send := false
	var sends := 0
	var received := PackedByteArray()

	func _connect_input_socket() -> bool:
		attempts += 1
		connected = attempts > connect_failures
		return connected

	func _input_socket_connected() -> bool:
		return connected

	func _input_has_method(_method: StringName) -> bool:
		return true

	func _call_input_once(_method: StringName, args: Array) -> bool:
		sends += 1
		if fail_first_send and sends == 1:
			connected = false
			return false
		if args.size() > 1 and args[1] is PackedByteArray:
			received = (args[1] as PackedByteArray).duplicate()
		return true


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var output := "/tmp/cove-input-fallback-test-%d.bin" % OS.get_process_id()
	DirAccess.remove_absolute(output)
	var cove := TestCove.new()
	cove._sock = RefCounted.new()  # enter the fast-socket path; methods are overridden above

	# A restart longer than the former 100-frame cap must still reconnect.
	cove.connect_failures = 101
	for _i in 102:
		cove._poll_input_socket(0.25)
	_check(cove.connected and cove.attempts == 102, "input reconnect gave up before kitty returned")

	# The event that discovers EPIPE is retried, not silently dropped.
	cove.attempts = 0
	cove.connect_failures = 0
	cove.connected = true
	cove.fail_first_send = true
	cove.sends = 0
	var resend_payload := PackedByteArray([0x1b, 0x5b, 0x41])
	cove._pty(7, resend_payload)
	_check(cove.sends == 2 and cove.received == resend_payload,
		"input event was not resent after a stale socket")

	# The same checked path protects non-PTY actions such as Cmd+N.
	cove.connected = true
	cove.fail_first_send = true
	cove.sends = 0
	_check(cove._call_input("spawn") and cove.sends == 2,
		"non-PTY input action was not resent after a stale socket")

	# Exercise the raw-byte fallback with no fast socket available.
	cove._sock = null
	cove.kitten_exe = ProjectSettings.globalize_path("res://tests/fake_kitten_stdin.py")
	cove.kitty_socket = output
	# NUL/high bytes plus an X10 mouse report at its coordinate clamp. None of
	# these bytes is allowed to take a round-trip through a Godot String.
	var payload := PackedByteArray()
	payload.resize(131077)  # comfortably larger than a pipe buffer
	for i in payload.size():
		payload[i] = (i * 131 + 17) & 0xff
	var marker := PackedByteArray([0x00, 0x80, 0xa0, 0xed, 0xff,
		0x1b, 0x5b, 0x4d, 0x60, 0xed, 0xff])
	for i in marker.size():
		payload[i] = marker[i]
	cove._pty(42, payload)
	var fallback_paths: Array = cove._pty_fallback_files.values()

	var deadline := Time.get_ticks_msec() + 3000
	while not FileAccess.file_exists(output) and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	var actual := FileAccess.get_file_as_bytes(output) if FileAccess.file_exists(output) else PackedByteArray()
	while not cove._pty_fallback_files.is_empty() and Time.get_ticks_msec() < deadline:
		cove._reap_children()
		await create_timer(0.01).timeout
	DirAccess.remove_absolute(output)
	_check(actual == payload, "PTY fallback changed raw bytes: expected %s, got %s" % [payload, actual])
	_check(cove._pty_fallback_files.is_empty(), "PTY fallback child/file was not reaped")
	for path in fallback_paths:
		_check(not FileAccess.file_exists(str(path)), "PTY fallback left temporary file %s" % path)
	cove.free()
	quit(1 if _failures else 0)
