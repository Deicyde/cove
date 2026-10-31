extends SceneTree

const TermScene := preload("res://scenes/TermCritter.tscn")
const MAGIC := 0x4B4D454E
const FLAG_BOTTOM_UP := 0x1
const FLAG_PAGE := 0x10000

var _failures := 0


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _write_frame(path: String, seq: int, flags: int) -> void:
	var data := PackedByteArray()
	data.resize(68)
	data.encode_u32(0, MAGIC)
	data.encode_u32(4, 1)
	data.encode_u32(8, 1)
	data.encode_u32(12, seq)
	data.encode_u32(16, 4)
	data.encode_u32(20, flags)
	data.encode_u32(24, 99)
	data.encode_u32(32, 1)
	data.encode_u32(36, 1)
	data[64] = 0x22
	data[65] = 0x44
	data[66] = 0x66
	data[67] = 0xff
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := "/tmp/cove-frame-seqlock-%d.rgba" % OS.get_process_id()
	DirAccess.remove_absolute(path)
	var term = TermScene.instantiate()
	term.setup(99, path)
	term.force_read = true
	root.add_child(term)
	await process_frame

	_write_frame(path, 1, FLAG_BOTTOM_UP)
	term._file = null
	term.poll()
	_check(term._last_seq == -1, "odd in-progress kitty frame was displayed")

	_write_frame(path, 2, FLAG_BOTTOM_UP)
	term._file = null
	term.poll()
	_check(term._last_seq == 2 and term.native_size() == Vector2i(1, 1),
		"completed kitty frame was not displayed")

	# Page producers publish by atomic rename and retain their legacy arbitrary
	# sequence values, so parity filtering applies only to kitty mmap frames.
	_write_frame(path, 3, FLAG_PAGE)
	term._file = null
	term.poll()
	_check(term._last_seq == 3, "odd page-producer sequence was incorrectly rejected")

	root.remove_child(term)
	term.free()
	DirAccess.remove_absolute(path)
	quit(1 if _failures else 0)
