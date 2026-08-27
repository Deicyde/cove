/*
 * cove.c -- Walking Terminals (kitty x Godot) frame export. See
 * godot/DESIGN.md. Renders each kitty OS window (hidden) into its indirect
 * FBO and exports the pixels to a per-window memory-mapped file, so a separate
 * Godot process can display each terminal as its own moving sprite.
 *
 * One file per OS window: <dir>/term-<id>.rgba (dir = $KITTY_COVE_DIR or
 * /tmp/cove). Godot discovers terminals by scanning that directory;
 * a file is removed when its OS window closes.
 *
 * File layout (little-endian):
 *   [ 0] uint32 magic  = 0x4B4D454E ('KMEN')
 *   [ 4] uint32 width
 *   [ 8] uint32 height
 *   [12] uint32 seq            (bumped last, after pixels are written)
 *   [16] uint32 bytes_per_px   (always 4, RGBA)
 *   [20] uint32 flags          (bit0: rows are bottom-to-top / GL order)
 *   [24] uint32 pane_id_lo     (kitty window/pane id, for `@ --match id:`)
 *   [28] uint32 pane_id_hi
 *   [32] uint32 cols           (terminal grid columns)
 *   [36] uint32 rows           (terminal grid rows)
 *   [40] uint32 mouse_mode     (0 none, 1 button, 2 motion, 3 any)
 *   [44] uint32 mouse_proto    (0 normal, 1 utf8, 2 sgr, 3 urxvt, 4 sgr-pixel)
 *   [48] uint32 iosurface_id   (buffer A; 0 = pixels are in this file)
 *   [52] uint32 iosurface_id_b (buffer B, for double-buffering)
 *   [56] uint32 ready_index    (0=A, 1=B: which holds the latest complete frame)
 *   [60..63] reserved
 *   [64] RGBA pixels, width*height*4, bottom-left origin (OpenGL row order)
 *        (absent when iosurface_id != 0)
 */
#include "state.h"
#include "screen.h"
#include "gl.h"
#include "cove.h"
#include "glfw-wrapper.h"
#ifdef __APPLE__
#include "cove_macos.h"
#endif
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <inttypes.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>

#define COVE_MAGIC 0x4B4D454EU
#define COVE_HEADER_BYTES 64u
#define COVE_FLAG_BOTTOM_UP 0x1u
#define DEFAULT_DIR "/tmp/cove"
#define COVE_MAX 64

typedef struct {
    id_type id;          // 0 == free slot
    int fd;
    void *base;
    size_t mapped;
    unsigned w, h;
    uint32_t seq;
#ifdef __APPLE__
    CoveSurface iosurf[2];  // double-buffered: kitty writes one, Godot reads the other
    int io_current;              // index of the buffer holding the latest complete frame
#endif
} Slot;

static int state = -1;         // -1 unknown, 0 disabled, 1 enabled
static int iosurface_mode = -1;  // -1 unknown, 0 readback, 1 zero-copy IOSurface
static const char *base_dir = NULL;
static Slot slots[COVE_MAX];

static bool
cove_iosurface_on(void) {
    if (iosurface_mode == -1) {
#ifdef __APPLE__
        iosurface_mode = getenv("KITTY_COVE_IOSURFACE") ? 1 : 0;
#else
        iosurface_mode = 0;
#endif
    }
    return iosurface_mode == 1;
}

static const char*
resolve_dir(void) {
    const char *p = getenv("KITTY_COVE_DIR");
    if (p && p[0]) return p;
    return DEFAULT_DIR;
}

// --- input socket -----------------------------------------------------------
// A listener thread accepts a persistent connection from Godot and injects
// input, avoiding a `kitten` process per event. Wire format (repeated):
//   [kind u8][id u64 LE] then, by kind:
//     kind 0 (pty write): [len u32 LE][len bytes]  -> written to pane `id`
//     kind 1 (resize):    [cols u32 LE][rows u32 LE] -> resize OS window `id`
// pty writes go straight in (schedule_write_to_child is thread-safe + self-waking);
// resizes touch global state so they're queued for the main render thread.

#define MSG_PTY 0
#define MSG_RESIZE 1
#define MSG_SPAWN 2
#define MSG_MOUSE 3
#define MSG_DETACH 4
#define MSG_ADOPT 5

typedef struct { id_type id; uint32_t cols, rows; } PendingResize;
static PendingResize resize_queue[COVE_MAX];
static int resize_count = 0;
static int pending_spawns = 0;

// Drag-out: os-window ids queued for detach (become normal desktop windows),
// and the set of currently detached ids (not exported to Godot). The queue is
// filled from the input thread; both are drained/read on the main thread.
typedef struct { id_type id; int32_t x, y; } PendingDetach;
static PendingDetach detach_queue[COVE_MAX];
static int detach_count = 0;
static id_type adopt_queue[COVE_MAX];   // programmatic drag-in (MSG_ADOPT)
static int adopt_count = 0;
static id_type detached_ids[COVE_MAX];
static int detached_n = 0;

// Mouse-driven text selection: Godot sends cell coords as you drag over the
// focused terminal; we replay them into kitty's own selection so highlighting +
// copy-to-clipboard work exactly as if the mouse were real. phase: 0 start,
// 1 update (drag), 2 end. These touch the Screen, so they run on the main thread.
#define COVE_MOUSE_MAX 256
typedef struct { id_type id; uint8_t phase; uint8_t in_left_half; uint32_t x, y; } PendingMouse;
static PendingMouse mouse_queue[COVE_MOUSE_MAX];
static int mouse_count = 0;

static pthread_mutex_t resize_lock = PTHREAD_MUTEX_INITIALIZER;

static pthread_t input_thread;
static bool input_thread_started = false;

static bool
read_all(int fd, void *dst, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (char*)dst + got, n - got);
        if (r <= 0) return false;
        got += (size_t)r;
    }
    return true;
}

static void
enqueue_resize(id_type id, uint32_t cols, uint32_t rows) {
    pthread_mutex_lock(&resize_lock);
    for (int i = 0; i < resize_count; i++) {
        if (resize_queue[i].id == id) { resize_queue[i].cols = cols; resize_queue[i].rows = rows; pthread_mutex_unlock(&resize_lock); return; }
    }
    if (resize_count < COVE_MAX) resize_queue[resize_count++] = (PendingResize){ id, cols, rows };
    pthread_mutex_unlock(&resize_lock);
    wakeup_main_loop();  // ensure the main thread wakes to drain + apply the resize
}

// Queue a selection step. Runs of drag-updates for the same window collapse to
// the latest position (like resizes) so a fast drag can't overflow the queue;
// start/end steps are always kept so the selection brackets stay intact.
static void
enqueue_mouse(id_type id, uint8_t phase, uint32_t x, uint32_t y, uint8_t in_left_half) {
    pthread_mutex_lock(&resize_lock);
    if (phase == 1 && mouse_count > 0) {
        PendingMouse *last = &mouse_queue[mouse_count - 1];
        if (last->id == id && last->phase == 1) {
            last->x = x; last->y = y; last->in_left_half = in_left_half;
            pthread_mutex_unlock(&resize_lock);
            wakeup_main_loop();
            return;
        }
    }
    if (mouse_count < COVE_MOUSE_MAX) mouse_queue[mouse_count++] = (PendingMouse){ id, phase, in_left_half, x, y };
    pthread_mutex_unlock(&resize_lock);
    wakeup_main_loop();
}

bool
cove_has_pending_control(void) {
    pthread_mutex_lock(&resize_lock);
    bool any = resize_count > 0 || pending_spawns > 0 || mouse_count > 0 || detach_count > 0 || adopt_count > 0;
    pthread_mutex_unlock(&resize_lock);
    return any;
}

bool
cove_window_is_detached(id_type id) {
    for (int i = 0; i < detached_n; i++) if (detached_ids[i] == id) return true;
    return false;
}

// Queue an os-window to be detached to the desktop (same path as MSG_DETACH, but
// callable in-process). Used by the boss's cove_new_os_window action so a Cmd+N
// pressed in a detached window spawns another desktop window rather than a hidden
// termling. x == COVE_DETACH_CASCADE asks the macOS side to place it near the key
// window. Safe to call outside cove mode: cove_drain_control() no-ops there.
void
cove_enqueue_detach(id_type id, int32_t x, int32_t y) {
    pthread_mutex_lock(&resize_lock);
    if (detach_count < COVE_MAX) detach_queue[detach_count++] = (PendingDetach){ id, x, y };
    pthread_mutex_unlock(&resize_lock);
    wakeup_main_loop();
}

static void
detached_remove(id_type id) {
    for (int i = 0; i < detached_n; i++) {
        if (detached_ids[i] == id) { detached_ids[i] = detached_ids[--detached_n]; return; }
    }
}

// Append one event line for Godot (it pumps <dir>/events.jsonl like notify.jsonl).
static void
cove_emit_event(const char *fmt, ...) {
    char path[4096];
    snprintf(path, sizeof path, "%s/events.jsonl", base_dir);
    FILE *f = fopen(path, "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static void
handle_input_client(int cfd) {
    for (;;) {
        unsigned char kind;
        uint64_t id;
        if (!read_all(cfd, &kind, 1)) return;
        if (!read_all(cfd, &id, 8)) return;
        if (kind == MSG_PTY) {
            uint32_t len;
            if (!read_all(cfd, &len, 4)) return;
            if (len == 0 || len > (1u << 20)) return;  // sanity
            char *buf = malloc(len);
            if (!buf) return;
            if (!read_all(cfd, buf, len)) { free(buf); return; }
            schedule_write_to_child((id_type)id, 1, buf, (size_t)len);
            free(buf);
        } else if (kind == MSG_RESIZE) {
            uint32_t cr[2];
            if (!read_all(cfd, cr, 8)) return;
            enqueue_resize((id_type)id, cr[0], cr[1]);
        } else if (kind == MSG_SPAWN) {
            pthread_mutex_lock(&resize_lock);
            pending_spawns++;
            pthread_mutex_unlock(&resize_lock);
            wakeup_main_loop();
        } else if (kind == MSG_MOUSE) {
            unsigned char phase, in_left_half;
            uint32_t xy[2];
            if (!read_all(cfd, &phase, 1)) return;
            if (!read_all(cfd, xy, 8)) return;
            if (!read_all(cfd, &in_left_half, 1)) return;
            enqueue_mouse((id_type)id, phase, xy[0], xy[1], in_left_half);
        } else if (kind == MSG_DETACH) {
            int32_t xy[2];
            if (!read_all(cfd, xy, 8)) return;
            cove_enqueue_detach((id_type)id, xy[0], xy[1]);
        } else if (kind == MSG_ADOPT) {
            pthread_mutex_lock(&resize_lock);
            if (adopt_count < COVE_MAX) adopt_queue[adopt_count++] = (id_type)id;
            pthread_mutex_unlock(&resize_lock);
            wakeup_main_loop();
        } else return;  // unknown kind: drop the connection
    }
}

// Replay one selection step into kitty's own selection machinery. Setting the
// window's mouse_pos first mirrors what a real mouse move would have done, so
// start/update behave identically to a hand-drawn selection.
static void
apply_mouse(const PendingMouse *m) {
    Window *w = window_for_window_id(m->id);
    if (!w || !w->render_data.screen) return;
    Screen *screen = w->render_data.screen;
    bool left = m->in_left_half != 0;
    w->mouse_pos.cell_x = m->x;
    w->mouse_pos.cell_y = m->y;
    w->mouse_pos.in_left_half_of_cell = left;
    switch (m->phase) {
        case 0: screen_start_selection(screen, m->x, m->y, left, false, EXTEND_CELL); break;
        case 1: screen_update_selection(screen, m->x, m->y, left, (SelectionUpdate){0}); break;
        case 2:
            screen_update_selection(screen, m->x, m->y, left, (SelectionUpdate){.ended = true});
            // kitty's own end-of-selection copies from its *active* window, which
            // isn't our hidden cove terminal -- copy from this window explicitly.
            call_boss(cove_copy_selection, "K", m->id);
            break;
    }
}

// Drag-out: hide-the-termling becomes show-the-window. Stop exporting the
// frame (Godot sees the term file vanish and removes the termling), then hand
// the NSWindow to the macOS side to be placed on the desktop and watched for a
// drag back in. Main thread.
static void
apply_detach(const PendingDetach *d) {
#ifdef __APPLE__
    OSWindow *osw = os_window_for_id(d->id);
    if (!osw || !osw->handle || cove_window_is_detached(d->id)) return;
    void *nsw = glfwGetCocoaWindow((GLFWwindow*)osw->handle);
    if (!nsw) return;
    cove_remove_window(d->id);          // unlink the term file; Godot drops the termling
    if (detached_n < COVE_MAX) detached_ids[detached_n++] = d->id;
    cove_macos_detach_window(nsw, d->x, d->y, d->id, base_dir);
    osw->redraw_count++;                // the now-visible window needs a real present
    log_error("cove: detached os-window %llu to the desktop", (unsigned long long)d->id);
#else
    (void)d;
#endif
}

// Programmatic drag-in (MSG_ADOPT, e.g. a "bring it home" command): hide the
// detached window and re-adopt it. Main thread.
static void
apply_adopt(id_type id) {
#ifdef __APPLE__
    if (!cove_window_is_detached(id)) return;
    OSWindow *osw = os_window_for_id(id);
    if (!osw || !osw->handle) return;
    cove_macos_adopt_window(glfwGetCocoaWindow((GLFWwindow*)osw->handle), id);
    cove_readopt(id);
#else
    (void)id;
#endif
}

// Drag-in landed (macOS watcher, main thread): resume exporting and tell Godot,
// which places the reborn termling under the cursor.
void
cove_readopt(uint64_t os_window_id) {
    detached_remove((id_type)os_window_id);
    OSWindow *osw = os_window_for_id((id_type)os_window_id);
    if (osw) osw->redraw_count++;       // force a frame so the term file reappears now
    cove_emit_event("{\"event\":\"adopted\",\"term_id\":%llu}", (unsigned long long)os_window_id);
    wakeup_main_loop();
    log_error("cove: re-adopted os-window %llu into the cove", (unsigned long long)os_window_id);
}

void
cove_drain_control(void) {
    if (state != 1) return;
    PendingResize local[COVE_MAX];
    PendingMouse mlocal[COVE_MOUSE_MAX];
    PendingDetach dlocal[COVE_MAX];
    id_type alocal[COVE_MAX];
    int n, spawns, mn, dn, an;
    pthread_mutex_lock(&resize_lock);
    n = resize_count;
    memcpy(local, resize_queue, (size_t)n * sizeof(PendingResize));
    resize_count = 0;
    spawns = pending_spawns;
    pending_spawns = 0;
    mn = mouse_count;
    memcpy(mlocal, mouse_queue, (size_t)mn * sizeof(PendingMouse));
    mouse_count = 0;
    dn = detach_count;
    memcpy(dlocal, detach_queue, (size_t)dn * sizeof(PendingDetach));
    detach_count = 0;
    an = adopt_count;
    memcpy(alocal, adopt_queue, (size_t)an * sizeof(id_type));
    adopt_count = 0;
    pthread_mutex_unlock(&resize_lock);
    for (int i = 0; i < n; i++) {
        call_boss(resize_os_window, "Kiis", local[i].id, (int)local[i].cols, (int)local[i].rows, "cells");
    }
    for (int i = 0; i < spawns; i++) {
        call_boss(new_os_window, NULL);
    }
    for (int i = 0; i < mn; i++) apply_mouse(&mlocal[i]);
    for (int i = 0; i < dn; i++) apply_detach(&dlocal[i]);
    for (int i = 0; i < an; i++) apply_adopt(alocal[i]);
}

// One thread per client: Godot holds a persistent connection, but short-lived
// tools (tests, scripts) must be able to talk to the socket at the same time.
static void*
input_client_main(void *arg) {
    int cfd = (int)(intptr_t)arg;
    handle_input_client(cfd);
    close(cfd);
    return NULL;
}

static void*
input_thread_main(void *arg) {
    (void)arg;
    char path[4096];
    snprintf(path, sizeof path, "%s/input.sock", base_dir);
    unlink(path);
    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sfd < 0) { perror("cove: input socket"); return NULL; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", path);
    if (bind(sfd, (struct sockaddr*)&addr, sizeof addr) != 0) { perror("cove: input bind"); close(sfd); return NULL; }
    if (listen(sfd, 8) != 0) { perror("cove: input listen"); close(sfd); return NULL; }
    log_error("cove: input socket at %s", path);
    for (;;) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; break; }
        pthread_t ct;
        if (pthread_create(&ct, NULL, input_client_main, (void*)(intptr_t)cfd) == 0) pthread_detach(ct);
        else close(cfd);
    }
    close(sfd);
    return NULL;
}

static void
cove_start_input_thread(void) {
    if (input_thread_started) return;
    input_thread_started = true;
    if (pthread_create(&input_thread, NULL, input_thread_main, NULL) == 0) pthread_detach(input_thread);
}

bool
cove_enabled(void) {
    if (state == -1) {
        state = getenv("KITTY_COVE") ? 1 : 0;
        base_dir = resolve_dir();
        if (state) {
            mkdir(base_dir, 0755);
            log_error("cove: enabled, exporting terminals to %s/term-<id>.rgba", base_dir);
            cove_start_input_thread();
#ifdef __APPLE__
            cove_macos_keep_awake();  // stop App Nap throttling the hidden window
#endif
        }
    }
    return state == 1;
}

static void
path_for(id_type id, char *buf, size_t n) {
    snprintf(buf, n, "%s/term-%llu.rgba", base_dir, (unsigned long long)id);
}

static Slot*
slot_for(id_type id) {
    Slot *free_slot = NULL;
    for (int i = 0; i < COVE_MAX; i++) {
        if (slots[i].id == id) return &slots[i];
        if (!free_slot && slots[i].id == 0) free_slot = &slots[i];
    }
    if (free_slot) { memset(free_slot, 0, sizeof *free_slot); free_slot->id = id; free_slot->fd = -1; }
    return free_slot;
}

static bool
remap(Slot *s, id_type id, size_t needed) {
    if (s->base) { munmap(s->base, s->mapped); s->base = NULL; s->mapped = 0; }
    if (s->fd < 0) {
        char path[4096];
        path_for(id, path, sizeof path);
        s->fd = open(path, O_RDWR | O_CREAT, 0644);
        if (s->fd < 0) { perror("cove: open term file"); return false; }
    }
    if (ftruncate(s->fd, (off_t)needed) != 0) { perror("cove: ftruncate"); return false; }
    s->base = mmap(NULL, needed, PROT_READ | PROT_WRITE, MAP_SHARED, s->fd, 0);
    if (s->base == MAP_FAILED) { perror("cove: mmap"); s->base = NULL; return false; }
    s->mapped = needed;
    return true;
}

// Read the finished frame for os_window. In cove mode the frame lives in
// the indirect_output FBO (an app-owned texture), readable regardless of window
// visibility. Falls back to the default framebuffer otherwise.
static void
readback(OSWindow *os_window, unsigned width, unsigned height, unsigned char *dst) {
    uint32_t fbo = os_window->indirect_output.framebuffer_id;
    if (os_window->needs_layers && fbo) {
        GLint prev = 0;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_UNSIGNED_BYTE, dst);
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev);
    } else {
        Region region = { .left = 0, .top = 0, .right = width, .bottom = height };
        unsigned tw = width, th = height;
        take_screenshot_of_rectangular_region(os_window, region, dst, &tw, &th, true);
    }
}

void
cove_publish_frame(OSWindow *os_window) {
    if (!cove_enabled()) return;
    if (cove_window_is_detached(os_window->id)) return;  // it lives on the desktop now
    unsigned w = (unsigned)os_window->viewport_width, h = (unsigned)os_window->viewport_height;
    if (!w || !h) return;
    Slot *s = slot_for(os_window->id);
    if (!s) return;  // table full
    bool zero_copy = cove_iosurface_on();
    // In zero-copy mode pixels travel via the IOSurface, so the file is header-only.
    size_t needed = zero_copy ? COVE_HEADER_BYTES : COVE_HEADER_BYTES + (size_t)w * h * 4u;
    if (!s->base || w != s->w || h != s->h || needed > s->mapped || (!zero_copy && needed != s->mapped)) {
        if (!remap(s, os_window->id, needed)) { s->id = 0; return; }
        s->w = w; s->h = h;
    }

    uint32_t iosurface_id = 0, iosurface_id_b = 0, ready_index = 0;
#ifdef __APPLE__
    if (zero_copy) {
        uint32_t src_fbo = os_window->indirect_output.framebuffer_id;
        // Ensure both buffers exist at the current size, then blit into the one
        // Godot isn't reading (io_current holds the last complete frame).
        uint32_t ida = cove_macos_ensure(&s->iosurf[0], w, h);
        uint32_t idb = cove_macos_ensure(&s->iosurf[1], w, h);
        if (!ida || !idb) { iosurface_mode = 0; }
        else {
            int write = s->io_current ^ 1;
            cove_macos_blit(&s->iosurf[write], src_fbo);
            s->io_current = write;
            iosurface_id = ida;
            iosurface_id_b = idb;
            ready_index = (uint32_t)write;
        }
    }
#endif
    // Pull metadata from the active pane's Screen: pane id (so Godot can target
    // input with `@ --match id:<pane_id>`), grid size, and mouse-tracking state.
    uint64_t pane_id = os_window->id;
    uint32_t cols = 0, rows = 0, mmode = 0, mproto = 0;
    if (os_window->num_tabs) {
        Tab *tab = os_window->tabs + os_window->active_tab;
        if (tab->num_windows) {
            Window *win = tab->windows + tab->active_window;
            pane_id = win->id;
            Screen *screen = win->render_data.screen;
            if (screen) {
                cols = screen->columns;
                rows = screen->lines;
                mmode = (uint32_t)screen->modes.mouse_tracking_mode;
                mproto = (uint32_t)screen->modes.mouse_tracking_protocol;
            }
        }
    }
    unsigned char *bytes = (unsigned char*)s->base;
    if (!zero_copy) readback(os_window, w, h, bytes + COVE_HEADER_BYTES);
    uint32_t *hdr = (uint32_t*)bytes;
    hdr[0] = COVE_MAGIC;
    hdr[1] = w;
    hdr[2] = h;
    hdr[4] = 4u;
    hdr[5] = COVE_FLAG_BOTTOM_UP;
    hdr[6] = (uint32_t)(pane_id & 0xffffffffu);
    hdr[7] = (uint32_t)(pane_id >> 32);
    hdr[8] = cols;
    hdr[9] = rows;
    hdr[10] = mmode;
    hdr[11] = mproto;
    hdr[12] = iosurface_id;    // buffer A id (0 = pixels are in this file)
    hdr[13] = iosurface_id_b;  // buffer B id (double-buffering)
    hdr[14] = ready_index;     // which of A/B holds the latest complete frame
    __sync_synchronize();  // ensure pixels + dims are visible before seq bump
    hdr[3] = ++s->seq;
}

void
cove_remove_window(id_type id) {
    if (state != 1) return;
    // If it was out on the desktop, stop watching it (window closed for real).
    if (cove_window_is_detached(id)) {
        detached_remove(id);
#ifdef __APPLE__
        cove_macos_forget_window(id);
#endif
    }
    for (int i = 0; i < COVE_MAX; i++) {
        if (slots[i].id == id) {
#ifdef __APPLE__
            cove_macos_free(&slots[i].iosurf[0]);
            cove_macos_free(&slots[i].iosurf[1]);
#endif
            if (slots[i].base) munmap(slots[i].base, slots[i].mapped);
            if (slots[i].fd >= 0) close(slots[i].fd);
            char path[4096];
            path_for(id, path, sizeof path);
            unlink(path);
            memset(&slots[i], 0, sizeof slots[i]);
            return;
        }
    }
}
