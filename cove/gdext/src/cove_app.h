// CoveApp -- bits of the macOS app the Cove needs to own.
//
// Cmd+H never reaches Godot: AppKit hides the app before the key gets to the
// window (even with the Hide menu item's key equivalent cleared). watch_hide_key()
// installs a local event monitor that swallows Cmd+H first; GDScript polls
// take_hide_press() each frame and decides (an Emacs critter gets it as M-h),
// and hide() does what AppKit would have done for everything else.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

using namespace godot;

class CoveApp : public RefCounted {
	GDCLASS(CoveApp, RefCounted);

protected:
	static void _bind_methods();

public:
	// Start swallowing Cmd+H (Cmd alone, no other modifiers). Idempotent.
	void watch_hide_key();
	// How many Cmd+H presses were swallowed since the last call.
	int take_hide_press();
	// Hide the app, as Cmd+H would have.
	void hide();
};
