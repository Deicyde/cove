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
#include <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
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

// --- drag-out / drag-in (detach a termling to the desktop, adopt it back) ----
// A detached window is a normal kitty NSWindow on the desktop. There is no
// public "window drag ended" notification, so a 120ms main-queue timer watches
// each detached window: a frame move while the left button is down marks it as
// being dragged; on release with the cursor inside the Cove's Godot window the
// window is hidden again and cove_readopt() resumes its export to Godot.

extern void cove_readopt(uint64_t os_window_id);  // cove.c (main thread)

typedef struct {
    NSWindow *win;        // retained
    uint64_t osw_id;
    NSRect last_frame;
    bool dragging;
} CoveDetached;

#define COVE_DETACHED_MAX 64
static CoveDetached detached_wins[COVE_DETACHED_MAX];
static int detached_wins_n = 0;
static dispatch_source_t detach_timer = nil;
static char detach_dir[4096] = "/tmp/cove";

// The Godot window's CGWindowID, published by Cove.gd into state.json as
// window.wnum. 0 = unknown (drag-in disabled until Godot writes it).
static CGWindowID
cove_godot_window_number(void) {
    char path[4200];
    snprintf(path, sizeof path, "%s/state.json", detach_dir);
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!data) return 0;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![d isKindOfClass:[NSDictionary class]]) return 0;
    NSDictionary *w = d[@"window"];
    if (![w isKindOfClass:[NSDictionary class]]) return 0;
    NSNumber *n = w[@"wnum"];
    return [n isKindOfClass:[NSNumber class]] ? (CGWindowID)n.unsignedIntValue : 0;
}

// Is the mouse cursor currently over the Cove's Godot window? Uses CG global
// coordinates (top-left origin) from the window server, so it works regardless
// of Godot's own coordinate conventions.
static bool
cursor_over_cove_window(void) {
    CGWindowID wnum = cove_godot_window_number();
    if (!wnum) return false;
    CFArrayRef ids = CFArrayCreate(NULL, (const void*[]){ (void*)(uintptr_t)wnum }, 1, NULL);
    CFArrayRef info = CGWindowListCreateDescriptionFromArray(ids);
    CFRelease(ids);
    if (!info) return false;
    bool inside = false;
    if (CFArrayGetCount(info) > 0) {
        NSDictionary *d = (__bridge NSDictionary*)CFArrayGetValueAtIndex(info, 0);
        CGRect bounds = CGRectZero;
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &bounds)) {
            NSPoint m = [NSEvent mouseLocation];  // Cocoa: bottom-left origin of primary screen
            CGFloat primary_h = [[NSScreen screens] firstObject].frame.size.height;
            inside = CGRectContainsPoint(bounds, CGPointMake(m.x, primary_h - m.y));
        }
    }
    CFRelease(info);
    return inside;
}

static void
detach_watch_tick(void) {
    bool down = ([NSEvent pressedMouseButtons] & 1) != 0;
    for (int i = 0; i < detached_wins_n; i++) {
        CoveDetached *d = &detached_wins[i];
        NSRect f = d->win.frame;
        if (down) {
            // A frame *move* (same size) while the button is held = a titlebar drag.
            if (!NSEqualPoints(f.origin, d->last_frame.origin) && NSEqualSizes(f.size, d->last_frame.size))
                d->dragging = true;
            d->last_frame = f;
            continue;
        }
        d->last_frame = f;
        if (!d->dragging) continue;
        d->dragging = false;
        if (cursor_over_cove_window()) {
            uint64_t id = d->osw_id;
            [d->win orderOut:nil];
            cove_macos_forget_window(id);   // compacts the array; restart the scan
            cove_readopt(id);
            i = -1;
        }
    }
}

static void
detach_timer_ensure(void) {
    if (detach_timer) return;
    detach_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(detach_timer, DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC, 30 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(detach_timer, ^{ detach_watch_tick(); });
    dispatch_resume(detach_timer);
}

void
cove_macos_detach_window(void *nswindow, int x, int y, uint64_t os_window_id, const char *base_dir) {
    NSWindow *nw = (__bridge NSWindow*)nswindow;
    if (!nw || detached_wins_n >= COVE_DETACHED_MAX) return;
    if (base_dir && base_dir[0]) snprintf(detach_dir, sizeof detach_dir, "%s", base_dir);
    NSRect f = nw.frame;
    // Centre the window on the drop point, clamped so the titlebar stays reachable.
    NSPoint origin = NSMakePoint(x - f.size.width / 2, y - f.size.height / 2);
    NSScreen *scr = [NSScreen mainScreen];
    if (scr) {
        NSRect vis = scr.visibleFrame;
        origin.x = fmax(vis.origin.x - f.size.width + 80, fmin(origin.x, NSMaxX(vis) - 80));
        origin.y = fmax(vis.origin.y - f.size.height + 40, fmin(origin.y, NSMaxY(vis) - f.size.height));
    }
    [nw setFrameOrigin:origin];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [nw makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    detached_wins[detached_wins_n++] = (CoveDetached){ [nw retain], os_window_id, nw.frame, false };
    detach_timer_ensure();
}

void
cove_macos_adopt_window(void *nswindow, uint64_t os_window_id) {
    NSWindow *nw = (__bridge NSWindow*)nswindow;
    if (nw) [nw orderOut:nil];
    cove_macos_forget_window(os_window_id);
}

void
cove_macos_forget_window(uint64_t os_window_id) {
    for (int i = 0; i < detached_wins_n; i++) {
        if (detached_wins[i].osw_id != os_window_id) continue;
        [detached_wins[i].win release];
        detached_wins[i] = detached_wins[--detached_wins_n];
        break;
    }
    if (detached_wins_n == 0) {
        if (detach_timer) { dispatch_source_cancel(detach_timer); dispatch_release(detach_timer); detach_timer = nil; }
        // No termling out on the desktop any more: tuck the app back out of the Dock.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}
#endif
