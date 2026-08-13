# A little carrier (Sarah) who helps haul a terminal. Reuses the character art
# from gates-of-poseidon. Self-contained: 2-frame walk, idle, and a panic state
# (X-eyes + jitter). Built in code so it's easy to spawn two per terminal.
extends Node2D

const ShadowUtil := preload("res://scripts/ShadowUtil.gd")

const BASE1 := preload("res://assets/characters/sarah/base-1.png")
const BASE2 := preload("res://assets/characters/sarah/base-2.png")
const FACE_NORMAL := preload("res://assets/characters/sarah/face-normal.png")
const FACE_HAPPY := preload("res://assets/characters/sarah/happy.png")
const FACE_PANIK := preload("res://assets/characters/sarah/face-panik.png")
const FACE_SURPRISED := preload("res://assets/characters/sarah/surprised.png")

const HEIGHT_PX := 104.0     # on-screen height of the character
const BOB_PX := 4.0

var _body: Sprite2D
var _face: Sprite2D
var _shadow: Sprite2D
var _state := "idle"         # idle | walk | panic
var _t := 0.0
var _facing := 1.0           # +1 right, -1 left


func _ready() -> void:
	var scale_factor := HEIGHT_PX / float(BASE1.get_height())

	_shadow = ShadowUtil.make(HEIGHT_PX * 0.55, 0.4, 0.32)
	_shadow.position = Vector2(0, 4)
	add_child(_shadow)

	_body = Sprite2D.new()
	_body.texture = BASE1
	_body.scale = Vector2(scale_factor, scale_factor)
	_body.centered = true
	_body.position = Vector2(0, -HEIGHT_PX * 0.5)  # feet at origin
	add_child(_body)

	_face = Sprite2D.new()
	_face.texture = FACE_NORMAL
	_face.scale = Vector2(scale_factor, scale_factor)
	_face.centered = true
	_face.position = _body.position
	add_child(_face)


func set_state(s: String) -> void:
	_state = s


func set_facing(dir: float) -> void:
	if absf(dir) > 0.01:
		_facing = signf(dir)


func set_airborne(airborne: bool) -> void:
	if _shadow:
		_shadow.visible = not airborne


func _process(delta: float) -> void:
	_t += delta
	_body.flip_h = _facing < 0
	_face.flip_h = _facing < 0
	match _state:
		"walk":
			# 2-frame walk + gentle bob
			_body.texture = BASE1 if fmod(_t, 0.34) < 0.17 else BASE2
			_face.texture = FACE_HAPPY
			var bob := -absf(sin(_t * 10.0)) * BOB_PX
			_body.position.y = -HEIGHT_PX * 0.5 + bob
			_face.position.y = _body.position.y
			_shadow.scale.x = (HEIGHT_PX * 0.55 / 128.0) * (1.0 + bob * 0.01)
		"panic":
			_body.texture = BASE1 if fmod(_t, 0.12) < 0.06 else BASE2
			_face.texture = FACE_PANIK
			# frantic jitter
			var jx := (randf() - 0.5) * 6.0
			var jy := (randf() - 0.5) * 6.0
			_body.position = Vector2(jx, -HEIGHT_PX * 0.5 + jy)
			_face.position = _body.position
		"surprised":
			_body.texture = BASE1
			_face.texture = FACE_SURPRISED
			var hop := -absf(sin(_t * 8.0)) * 3.0
			_body.position = Vector2(0, -HEIGHT_PX * 0.5 + hop)
			_face.position = _body.position
		_:  # idle
			_body.texture = BASE1
			_face.texture = FACE_NORMAL
			var breathe := sin(_t * 2.5) * 1.5
			_body.position.y = -HEIGHT_PX * 0.5 + breathe
			_face.position.y = _body.position.y
