// CoveDrag -- native macOS drag-and-drop for termlings.
//
// Makes the single Godot Cove window both an NSDraggingSource and an
// NSDraggingDestination so a lifted Termling can be dragged out as a real OS
// drag session. Universal Control ferries that same session to a second Mac,
// where its Cove window (running this identical code) receives the drop. The
// payload is a self-describing `cove://` string on a private pasteboard type.
//
// GDScript drives it by polling: begin_drag() to start an outbound drag, then
// poll_drop()/poll_hover()/poll_drag_ended() once per frame to pick up drops,
// hover updates (for the landing ghost) and the outcome of an outbound drag.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

using namespace godot;

class CoveDrag : public RefCounted {
	GDCLASS(CoveDrag, RefCounted);

protected:
	static void _bind_methods();

public:
	// Attach to the Godot window's NSView (from
	// DisplayServer.window_get_native_handle(WINDOW_VIEW, ...)). Registers the
	// private dragged type and installs the destination methods. Idempotent.
	bool attach(int64_t view_handle);
	bool is_attached() const;

	// Start an outbound OS drag carrying `payload`. The drag image is a live
	// thumbnail of the termling, snapshotted from its IOSurface (`iosurface_id`
	// with native size tex_w x tex_h); `label` is drawn as a caption and used for
	// the fallback chip if the surface can't be read. Must be called while a mouse
	// button is down (during Godot's drag input handling). Returns false if no
	// usable mouse event is available or the view isn't attached.
	bool begin_drag(const String &payload, const String &label,
			int64_t iosurface_id, int tex_w, int tex_h);
	// True while an outbound drag started here is still in flight.
	bool is_dragging() const;

	// Pop the next landed drop, or {} if none. Keys: payload:String,
	// x:float, y:float (view-local, top-left origin, points).
	Dictionary poll_drop();
	// Current inbound-hover state for the landing ghost. Keys: active:bool and,
	// when active, x:float, y:float (view-local, top-left origin, points).
	Dictionary poll_hover();
	// Pop the outcome of a finished outbound drag, or {} if none. Keys:
	// accepted:bool (true if some destination took the drop).
	Dictionary poll_drag_ended();

	CoveDrag() {}
	~CoveDrag();
};
