// Obj-C++ implementation of CoveApp. See cove_app.h.
#import <AppKit/AppKit.h>

#include "cove_app.h"

#include <godot_cpp/core/class_db.hpp>

#include <atomic>

using namespace godot;

static id hide_monitor = nil;
static std::atomic<int> hide_presses{ 0 };

void CoveApp::_bind_methods() {
	ClassDB::bind_method(D_METHOD("watch_hide_key"), &CoveApp::watch_hide_key);
	ClassDB::bind_method(D_METHOD("take_hide_press"), &CoveApp::take_hide_press);
	ClassDB::bind_method(D_METHOD("hide"), &CoveApp::hide);
}

void CoveApp::watch_hide_key() {
	if (hide_monitor != nil) {
		return;
	}
	hide_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
														 handler:^NSEvent *(NSEvent *event) {
		NSEventModifierFlags mods = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask
				& ~(NSEventModifierFlagCapsLock | NSEventModifierFlagFunction | NSEventModifierFlagNumericPad);
		if (mods == NSEventModifierFlagCommand && [event keyCode] == 0x04 /* kVK_ANSI_H */) {
			if (![event isARepeat]) {
				hide_presses++;
			}
			return nil;
		}
		return event;
	}];
	[hide_monitor retain];
}

int CoveApp::take_hide_press() {
	return hide_presses.exchange(0);
}

void CoveApp::hide() {
	[NSApp hide:nil];
}
