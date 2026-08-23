/*
 * cove_macos.h -- zero-copy frame export via IOSurface (macOS). See
 * godot/DESIGN.md Phase 2. Blits a terminal's finished frame (in kitty's
 * indirect FBO) into a per-terminal IOSurface on the GPU, and hands back the
 * global IOSurfaceID so Godot can import it as a Metal texture (no CPU copy).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>

// Cached per-terminal IOSurface + its GL texture/FBO. Zero-initialise.
typedef struct CoveSurface {
    void *surface;                 // IOSurfaceRef (retained), or NULL
    unsigned gl_texture, gl_fbo;
    unsigned w, h;
    uint32_t id;                   // global IOSurfaceID
} CoveSurface;

// Ensure s has an IOSurface (+ GL texture/FBO) of the given size, creating or
// recreating as needed. Returns its IOSurfaceID (0 on failure).
uint32_t cove_macos_ensure(CoveSurface *s, unsigned w, unsigned h);

// Blit src_fbo (RGBA, bottom-up) into s's IOSurface. s must be ensured first.
void cove_macos_blit(CoveSurface *s, uint32_t src_fbo);

// Release the IOSurface and its GL objects.
void cove_macos_free(CoveSurface *s);

// Hold a latency-critical activity so App Nap doesn't throttle the hidden
// window's render loop (keeps keystroke->pixels latency low). Idempotent.
void cove_macos_keep_awake(void);

// Drag-out: turn a hidden cove NSWindow into a normal, visible desktop window
// centred on (x, y) (Cocoa screen coords, bottom-left origin, points), flip the
// app into the Dock, and start watching the window so a later titlebar-drag
// back onto the Cove re-adopts it. base_dir is the cove dir (for state.json).
// Main thread only.
void cove_macos_detach_window(void *nswindow, int x, int y, uint64_t os_window_id, const char *base_dir);

// Stop watching a detached window (it was re-adopted or destroyed). Restores
// the Dock-hidden activation policy when no detached windows remain. Main
// thread only; safe to call for ids that aren't being watched.
void cove_macos_forget_window(uint64_t os_window_id);

// Programmatic drag-in: hide a detached window again and stop watching it (the
// caller then runs cove_readopt to resume export). Main thread only.
void cove_macos_adopt_window(void *nswindow, uint64_t os_window_id);
