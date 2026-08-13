// Obj-C++ implementation: IOSurface -> Metal texture -> Godot Texture2DRD.
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <CoreFoundation/CoreFoundation.h>

#include "cove_iosurface.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void CoveIOSurface::_bind_methods() {
	ClassDB::bind_method(D_METHOD("import_surface", "iosurface_id", "width", "height"),
			&CoveIOSurface::import_surface);
	ClassDB::bind_method(D_METHOD("release"), &CoveIOSurface::release);
}

void CoveIOSurface::release() {
	RenderingServer *rs = RenderingServer::get_singleton();
	RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
	if (_tex.is_valid()) {
		_tex->set_texture_rd_rid(RID());
		_tex.unref();
	}
	if (rd && _rid.is_valid()) {
		rd->free_rid(_rid);
	}
	_rid = RID();
	if (_mtl_texture) {
		[(id<MTLTexture>)_mtl_texture release];
		_mtl_texture = nullptr;
	}
	if (_surface) {
		CFRelease((IOSurfaceRef)_surface);
		_surface = nullptr;
	}
	_id = _w = _h = 0;
}

Ref<Texture2DRD> CoveIOSurface::import_surface(int iosurface_id, int width, int height) {
	if (iosurface_id == _id && width == _w && height == _h && _tex.is_valid()) {
		return _tex;  // unchanged; reuse (the IOSurface updates in place)
	}
	release();
	if (iosurface_id == 0 || width <= 0 || height <= 0) {
		return Ref<Texture2DRD>();
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
	if (!rd) {
		fprintf(stderr, "cove-gdext: no RenderingDevice\n");
		return Ref<Texture2DRD>();
	}
	IOSurfaceRef surf = IOSurfaceLookup((IOSurfaceID)iosurface_id);
	if (!surf) {
		fprintf(stderr, "cove-gdext: IOSurfaceLookup(%d) failed\n", iosurface_id);
		return Ref<Texture2DRD>();
	}
	uint64_t dev_handle = rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0);
	id<MTLDevice> dev = (id<MTLDevice>)(void *)dev_handle;
	if (!dev) {
		fprintf(stderr, "cove-gdext: null MTLDevice (handle=%llu)\n", (unsigned long long)dev_handle);
		CFRelease(surf);
		return Ref<Texture2DRD>();
	}
	MTLTextureDescriptor *desc = [MTLTextureDescriptor
			texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
										 width:width
										height:height
									 mipmapped:NO];
	desc.usage = MTLTextureUsageShaderRead;
	desc.storageMode = MTLStorageModeShared;
	id<MTLTexture> tex = [dev newTextureWithDescriptor:desc iosurface:surf plane:0];
	if (!tex) {
		fprintf(stderr, "cove-gdext: newTextureWithDescriptor:iosurface failed\n");
		CFRelease(surf);
		return Ref<Texture2DRD>();
	}
	[tex retain];
	RID rid = rd->texture_create_from_extension(
			RenderingDevice::TEXTURE_TYPE_2D,
			RenderingDevice::DATA_FORMAT_B8G8R8A8_UNORM,
			RenderingDevice::TEXTURE_SAMPLES_1,
			RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT,
			(int64_t)(uintptr_t)tex,
			width, height, 1, 1, 1);
	if (!rid.is_valid()) {
		fprintf(stderr, "cove-gdext: texture_create_from_extension failed\n");
		[tex release];
		CFRelease(surf);
		return Ref<Texture2DRD>();
	}
	Ref<Texture2DRD> t;
	t.instantiate();
	t->set_texture_rd_rid(rid);
	(void)0;  // imported OK

	_surface = surf;
	_mtl_texture = tex;
	_rid = rid;
	_tex = t;
	_id = iosurface_id;
	_w = width;
	_h = height;
	return t;
}
