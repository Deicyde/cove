# Infinite ground: a clean two-tone checkerboard floor tile, drawn tiled across
# the camera's visible world rect and snapped to tile boundaries so it stays
# world-fixed (scrolls under a panning/zooming camera). Faint grid on top.
extends Node2D

const TILE := 256.0        # texture size; one checker cell is TILE/2

var camera: Camera2D
var extra := Rect2()   # also cover this world rect (a board screenshot off to the side)
var step := 128.0
var _floor: Texture2D


func _ready() -> void:
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	var t := int(TILE)
	var cell := t / 2
	var a := Color(0.165, 0.148, 0.138)
	var b := Color(0.150, 0.134, 0.124)
	var img := Image.create(t, t, false, Image.FORMAT_RGBA8)
	img.fill(a)
	img.fill_rect(Rect2i(cell, 0, cell, cell), b)
	img.fill_rect(Rect2i(0, cell, cell, cell), b)
	_floor = ImageTexture.create_from_image(img)


var _drawn := Rect2()     # world rect last painted: the view plus half a view each side


# Repaint only when the view leaves what was painted, or shrinks a lot (the grid
# lines would get dense). The margin also covers a camera that moves after this
# runs in the frame (flights are stepped deferred).
func _process(_delta: float) -> void:
	if camera == null:
		return
	var view := _view()
	if not _drawn.encloses(view) or view.size.x * 3.0 < _drawn.size.x:
		queue_redraw()


func _view() -> Rect2:
	var half := get_viewport_rect().size * 0.5 / camera.zoom
	var r := Rect2(camera.get_screen_center_position() - half, half * 2.0)
	return r.merge(extra) if extra.has_area() else r


func _draw() -> void:
	if camera == null:
		return
	var v := _view()
	_drawn = v.grow_individual(v.size.x * 0.5, v.size.y * 0.5, v.size.x * 0.5, v.size.y * 0.5)
	var tl := _drawn.position
	var br := _drawn.end

	if _floor:
		var start := Vector2(floorf(tl.x / TILE) * TILE, floorf(tl.y / TILE) * TILE)
		draw_texture_rect(_floor, Rect2(start, (br - start) + Vector2(TILE, TILE)), true)

	# Faint grid lines on tile boundaries for a bit of structure.
	var line := Color(1, 1, 1, 0.035)
	var x := floorf(tl.x / step) * step
	while x < br.x:
		draw_line(Vector2(x, tl.y), Vector2(x, br.y), line, 1.0)
		x += step
	var y := floorf(tl.y / step) * step
	while y < br.y:
		draw_line(Vector2(tl.x, y), Vector2(br.x, y), line, 1.0)
		y += step
