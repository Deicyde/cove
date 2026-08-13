// CoveIOSurface -- imports a kitty IOSurface (by global id) as a Metal
// texture wrapped in a Godot Texture2DRD, for zero-copy terminal display.
// See godot/DESIGN.md Phase 2.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/variant/rid.hpp>

using namespace godot;

class CoveIOSurface : public RefCounted {
	GDCLASS(CoveIOSurface, RefCounted);

	void *_surface = nullptr;   // IOSurfaceRef
	void *_mtl_texture = nullptr;  // id<MTLTexture> (manually retained)
	RID _rid;
	Ref<Texture2DRD> _tex;
	int _id = 0, _w = 0, _h = 0;

protected:
	static void _bind_methods();

public:
	// Look up IOSurface `iosurface_id` and return a Texture2DRD backed by it.
	// Cheap no-op if the id/size are unchanged. Returns null on failure.
	Ref<Texture2DRD> import_surface(int iosurface_id, int width, int height);
	void release();

	CoveIOSurface() {}
	~CoveIOSurface() { release(); }
};
