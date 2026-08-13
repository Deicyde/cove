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
