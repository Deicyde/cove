# Soft ground-shadow helper: a radial-gradient blob squashed into an ellipse.
extends Object

static func make(width: float, squash := 0.45, alpha := 0.38) -> Sprite2D:
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 1))
	grad.set_color(1, Color(0, 0, 0, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 128
	tex.height = 128
	var s := Sprite2D.new()
	s.texture = tex
	s.scale = Vector2(width / 128.0, width / 128.0 * squash)
	s.modulate = Color(0, 0, 0, alpha)
	return s
