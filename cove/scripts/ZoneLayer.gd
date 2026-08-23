# Named regions on the ground. Each zone is a translucent coloured rectangle
# with a label, drawn under the termlings so a cluster reads as "this is the
# kitty patch, that's the fuzzing patch". Cove owns the data and hands us a flat
# draw list; we just paint it in world space (the camera transforms us).
extends Node2D

var items: Array = []   # [{rect: Rect2, color: Color, label: String}]
var preview := {}       # {rect: Rect2, color: Color} while the user rubber-bands a new region

var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	for it in items:
		var rect: Rect2 = it["rect"]
		var col: Color = it["color"]
		# Soft fill + a firmer border so the patch reads without shouting.
		draw_rect(rect, Color(col.r, col.g, col.b, 0.06), true)
		draw_rect(rect, Color(col.r, col.g, col.b, 0.30), false, 3.0)
		if _font:
			var label := str(it["label"])
			var pos := rect.position + Vector2(26.0, 50.0)
			draw_string(_font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 40,
				Color(col.r, col.g, col.b, 0.85))
	if not preview.is_empty():
		# The rubber-band for a region being drawn: brighter than a settled zone.
		var rect: Rect2 = preview["rect"]
		var col: Color = preview["color"]
		draw_rect(rect, Color(col.r, col.g, col.b, 0.10), true)
		draw_rect(rect, Color(col.r, col.g, col.b, 0.65), false, 3.0)
