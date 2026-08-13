/*
 * cove_macos.c -- zero-copy IOSurface frame export (macOS). See
 * cove_macos.h. This file deliberately uses Apple's own OpenGL headers
 * (not kitty's GL loader) so the CGL/IOSurface interop headers don't clash with
 * kitty/gl-wrapper.h. It operates on the currently-current GL context, which is
 * the same context kitty renders with, so FBO ids from kitty are valid here.
 */
#ifdef __APPLE__
#include "cove_macos.h"
#include <OpenGL/gl3.h>
#include <OpenGL/CGLCurrent.h>
#include <OpenGL/CGLIOSurface.h>
#include <IOSurface/IOSurface.h>
#include <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <stdio.h>

// Cove's OS window is hidden, so macOS App Nap throttles the app's timers
// (keystroke->pixels lag jumps to ~400ms). Hold a user-initiated, latency-
// critical activity to keep the render loop running at full speed.
static id cove_activity_token = nil;
void
cove_macos_keep_awake(void) {
    if (cove_activity_token) return;
    NSActivityOptions opts = NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical;
    id tok = [[NSProcessInfo processInfo] beginActivityWithOptions:opts reason:@"cove live rendering"];
    cove_activity_token = [tok retain];
}

// A few enums that gl3.h doesn't expose but the IOSurface interop needs.
#ifndef GL_TEXTURE_RECTANGLE
#define GL_TEXTURE_RECTANGLE 0x84F5
#endif
#ifndef GL_BGRA
#define GL_BGRA 0x80E1
#endif
#ifndef GL_UNSIGNED_INT_8_8_8_8_REV
#define GL_UNSIGNED_INT_8_8_8_8_REV 0x8367
#endif

static IOSurfaceRef
create_surface(unsigned w, unsigned h) {
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!props) return NULL;
#define SET_INT(key, value) do { \
    int _v = (int)(value); CFNumberRef _n = CFNumberCreate(NULL, kCFNumberIntType, &_v); \
    CFDictionarySetValue(props, key, _n); CFRelease(_n); } while (0)
    SET_INT(kIOSurfaceWidth, w);
    SET_INT(kIOSurfaceHeight, h);
    SET_INT(kIOSurfaceBytesPerElement, 4);
    SET_INT(kIOSurfacePixelFormat, 0x42475241 /* 'BGRA' */);
#undef SET_INT
    // Make it discoverable by IOSurfaceLookup(id) from another process. This is
    // the simple (deprecated but functional) global-id path; the alternative is
    // passing a mach port over the control socket.
    CFDictionarySetValue(props, CFSTR("IOSurfaceIsGlobal"), kCFBooleanTrue);
    IOSurfaceRef s = IOSurfaceCreate(props);
    CFRelease(props);
    return s;
}

uint32_t
cove_macos_ensure(CoveSurface *s, unsigned w, unsigned h) {
    if (s->surface && s->w == w && s->h == h) return s->id;
    cove_macos_free(s);
    s->surface = create_surface(w, h);
    if (!s->surface) { fprintf(stderr, "cove: IOSurfaceCreate failed\n"); return 0; }
    s->w = w; s->h = h;
    s->id = IOSurfaceGetID((IOSurfaceRef)s->surface);
    glGenTextures(1, &s->gl_texture);
    glBindTexture(GL_TEXTURE_RECTANGLE, s->gl_texture);
    CGLError e = CGLTexImageIOSurface2D(
        CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE, GL_RGBA, (GLsizei)w, (GLsizei)h,
        GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, (IOSurfaceRef)s->surface, 0);
    if (e != kCGLNoError) { fprintf(stderr, "cove: CGLTexImageIOSurface2D failed: %d\n", e); cove_macos_free(s); return 0; }
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glGenFramebuffers(1, &s->gl_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, s->gl_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, s->gl_texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        fprintf(stderr, "cove: IOSurface FBO incomplete\n");
    return s->id;
}

void
cove_macos_blit(CoveSurface *s, uint32_t src_fbo) {
    if (!s->gl_fbo) return;
    unsigned w = s->w, h = s->h;
    // GPU->GPU blit of the finished frame into the IOSurface. No CPU readback.
    GLint prev_read = 0, prev_draw = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, src_fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, s->gl_fbo);
    glBlitFramebuffer(0, 0, (GLint)w, (GLint)h, 0, 0, (GLint)w, (GLint)h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_read);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prev_draw);
    glFlush();  // ensure the blit is visible to the other process sampling the surface
}

void
cove_macos_free(CoveSurface *s) {
    if (s->gl_fbo) { glDeleteFramebuffers(1, &s->gl_fbo); s->gl_fbo = 0; }
    if (s->gl_texture) { glDeleteTextures(1, &s->gl_texture); s->gl_texture = 0; }
    if (s->surface) { CFRelease((IOSurfaceRef)s->surface); s->surface = NULL; }
    s->w = s->h = 0; s->id = 0;
}
#endif
