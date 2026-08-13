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
