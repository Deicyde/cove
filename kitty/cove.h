/*
 * cove.h -- Walking Terminals (kitty x Godot) frame export.
 * See godot/DESIGN.md. Phase 0: publish the rendered framebuffer of an OS
 * window into a memory-mapped file that an external compositor (Godot) reads.
 */
#pragma once
#include "state.h"

// True when kitty is running in cove mode (KITTY_COVE env set).
// In this mode the OS window is created hidden and each frame is rendered into
// an offscreen FBO and exported for an external compositor (Godot). Cached.
bool cove_enabled(void);

// Publish the current frame of os_window to its shared mmap file. No-op unless
// cove mode is on. Reads from the window's indirect_output FBO (an
// app-owned texture), so it works even when the window is hidden/occluded.
// Call after the frame is rendered, with the window's GL context current.
void cove_publish_frame(OSWindow *os_window);

// Remove a terminal's exported file when its OS window is destroyed.
void cove_remove_window(id_type id);

// Apply queued control requests (e.g. resize) from the input socket. Call once
// per frame on the main render thread (GIL held), before rendering windows.
void cove_drain_control(void);

// True if there are queued control requests waiting to be applied.
bool cove_has_pending_control(void);

// True if this OS window has been dragged out of the Cove: it lives on the
// desktop as a normal, visible kitty window and is not exported to Godot.
bool cove_window_is_detached(id_type id);
// Suspended by Godot (MSG_SUSPEND): not rendered until resumed.
bool cove_window_suspended(id_type id);

// x sentinel for cove_enqueue_detach: let the macOS side place the window near
// the current key window (a fresh cascade) instead of centring on a point.
#define COVE_DETACH_CASCADE INT32_MIN

// Queue an os-window for detach to the desktop (same effect as a drag-out, but
// callable in-process — used by the boss's cove_new_os_window action). Applied on
// the next cove_drain_control(); a no-op outside cove mode.
void cove_enqueue_detach(id_type id, int32_t x, int32_t y);

// Re-adopt a previously detached OS window (called from the macOS drop watcher
// when the user drags the native window back onto the Cove; main thread). Hides
// it again, resumes frame export, and announces the adoption to Godot.
void cove_readopt(uint64_t os_window_id);
