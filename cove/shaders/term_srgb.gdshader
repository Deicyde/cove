// Terminal frames arrive as LINEAR light: kitty renders into sRGB textures and
// only sRGB-encodes in its final on-screen pass (GL_FRAMEBUFFER_SRGB), which the
// cove readback (glReadPixels in kitty/cove.c) skips. Shown as-is they look
// faded/dark (#dddddd arrives as #b9b9b9). Encode to sRGB here so termlings match
// kitty on the desktop. The vertex COLOR carries modulate/self_modulate, so focus
// dimming and search-preview fades still apply.
shader_type canvas_item;

varying vec4 v_col;

void vertex() {
	v_col = COLOR;
}

void fragment() {
	vec4 t = texture(TEXTURE, UV);
	vec3 c = clamp(t.rgb, 0.0, 1.0);
	vec3 srgb = mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
	COLOR = vec4(srgb, t.a) * v_col;
}
