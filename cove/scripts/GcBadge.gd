extends Node2D

# The hourglass on an object marked for auto-delete (Cove.gd's garbage
# collector). Sand runs from the top bulb into the bottom one as the object sits
# unused: frac 0 = just used, 1 = due for collection.

var frac := 0.0:
	set(v):
		v = clampf(v, 0.0, 1.0)
		if not is_equal_approx(v, frac):
			frac = v
			queue_redraw()
var height := 16.0


func _draw() -> void:
	draw_hourglass(self, Vector2.ZERO, height, frac)


static func draw_hourglass(ci: CanvasItem, c: Vector2, h: float, frac: float) -> void:
	var w := h * 0.7
	var top := c.y - h * 0.5
	var bot := c.y + h * 0.5
	var sand := Color(0.98, 0.75, 0.25) if frac < 0.8 else Color(0.95, 0.35, 0.3)
	var left := 1.0 - frac
	if left > 0.0:   # what's left sits in the neck of the top bulb
		var y := c.y - h * 0.5 * left
		var hw := w * 0.5 * left
		ci.draw_colored_polygon(PackedVector2Array([Vector2(c.x - hw, y), Vector2(c.x + hw, y), c]), sand)
	if frac > 0.0:   # what's fallen piles up from the base of the bottom bulb
		var y := bot - h * 0.5 * frac
		var hw := w * 0.5 * (1.0 - frac)
		ci.draw_colored_polygon(PackedVector2Array([Vector2(c.x - w * 0.5, bot), Vector2(c.x + w * 0.5, bot),
			Vector2(c.x + hw, y), Vector2(c.x - hw, y)]), sand)
	ci.draw_polyline(PackedVector2Array([Vector2(c.x - w * 0.5, top), Vector2(c.x + w * 0.5, top), c,
		Vector2(c.x + w * 0.5, bot), Vector2(c.x - w * 0.5, bot), c, Vector2(c.x - w * 0.5, top)]),
		Color(0.9, 0.9, 0.9), maxf(h * 0.09, 0.5), true)
