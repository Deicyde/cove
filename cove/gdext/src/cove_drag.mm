// Obj-C++ implementation of CoveDrag. See cove_drag.h.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>

#include "cove_drag.h"

#include <godot_cpp/core/class_db.hpp>

#include <deque>
#include <mutex>
#include <string>

using namespace godot;

// Private pasteboard type carrying the cove:// handoff payload. A drag with this
// type set is "ours"; anything else (a file drag onto the window, say) is passed
// through to Godot's own handlers untouched.
static NSString *const COVE_TYPE = @"ai.basis.cove.termling";

// There is exactly one Godot window (the whole Cove stage renders into it), so a
// single set of globals backs the one attached view.
static NSView *g_view = nil;
static id g_source = nil;      // CoveDragSource, retained
static bool g_installed = false;  // destination methods swizzled onto the class

struct DropEvt {
	std::string payload;
	double x = 0, y = 0;
};
struct EndEvt {
	bool accepted = false;
	double sx = 0, sy = 0;    // end point, Cocoa screen coords (bottom-left origin)
	bool inside_self = false; // ended over our own window
};
static std::deque<DropEvt> g_drops;
static std::deque<EndEvt> g_ended;   // one entry per finished outbound drag
static bool g_hover_active = false;
static double g_hover_x = 0, g_hover_y = 0;
static bool g_dragging = false;
static std::mutex g_mtx;

// Original destination IMPs, when the content view already implemented them (it
// does for file drops). Our versions call through to these for non-cove drags.
static IMP g_orig_entered = NULL;
static IMP g_orig_updated = NULL;
static IMP g_orig_exited = NULL;
static IMP g_orig_prepare = NULL;
static IMP g_orig_perform = NULL;
static IMP g_orig_conclude = NULL;

// --- helpers ----------------------------------------------------------------

static bool is_cove_drag(id<NSDraggingInfo> sender) {
	NSPasteboard *pb = [sender draggingPasteboard];
	return [pb availableTypeFromArray:@[ COVE_TYPE ]] != nil;
}

// draggingLocation is window base coords (bottom-left origin); return it in the
// view's local space with a top-left origin, matching Godot's input positions.
static void hover_from(id<NSDraggingInfo> sender, double &x, double &y) {
	NSPoint p = [sender draggingLocation];
	NSPoint v = [g_view convertPoint:p fromView:nil];
	x = v.x;
	y = g_view.bounds.size.height - v.y;
}

// A small rounded chip drawn with the termling's label, used as the drag image.
static NSImage *make_drag_image(NSString *label) {
	const CGFloat w = 230, h = 56;
	NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
	[img lockFocus];
	NSRect r = NSMakeRect(1, 1, w - 2, h - 2);
	NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:r xRadius:12 yRadius:12];
	[[NSColor colorWithCalibratedRed:0.12 green:0.14 blue:0.18 alpha:0.94] setFill];
	[bp fill];
	[[NSColor colorWithCalibratedRed:0.90 green:0.58 blue:0.30 alpha:0.9] setStroke];
	[bp setLineWidth:2];
	[bp stroke];
	NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
	ps.alignment = NSTextAlignmentCenter;
	ps.lineBreakMode = NSLineBreakByTruncatingTail;
	NSDictionary *attrs = @{
		NSFontAttributeName : [NSFont boldSystemFontOfSize:15],
		NSForegroundColorAttributeName : [NSColor whiteColor],
		NSParagraphStyleAttributeName : ps,
	};
	NSString *text = label.length ? [@"🐚 " stringByAppendingString:label] : @"🐚 termling";
	[text drawInRect:NSInsetRect(r, 14, 17) withAttributes:attrs];
	[img unlockFocus];
	return img;
}

// A live thumbnail of the termling, read straight from its IOSurface (the same
// BGRA buffer the terminal renders from). Returns nil if the surface can't be
// looked up, so the caller can fall back to the text chip.
static NSImage *make_drag_image_from_iosurface(uint32_t sid, int tex_w, int tex_h, NSString *label) {
	if (sid == 0) {
		return nil;
	}
	IOSurfaceRef surf = IOSurfaceLookup((IOSurfaceID)sid);
	if (!surf) {
		return nil;
	}
	IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
	size_t w = IOSurfaceGetWidth(surf);
	size_t h = IOSurfaceGetHeight(surf);
	size_t bpr = IOSurfaceGetBytesPerRow(surf);
	void *base = IOSurfaceGetBaseAddress(surf);
	CGImageRef cg = NULL;
	if (base && w > 0 && h > 0) {
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		// IOSurface is MTLPixelFormatBGRA8Unorm: byte-order-little + alpha-first.
		CGContextRef bmp = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
				kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
		if (bmp) {
			cg = CGBitmapContextCreateImage(bmp);  // copies, so we can unlock after
			CGContextRelease(bmp);
		}
		CGColorSpaceRelease(cs);
	}
	IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
	CFRelease(surf);
	if (!cg) {
		return nil;
	}

	// Scale to a tidy drag thumbnail, preserving aspect.
	double nw = tex_w > 0 ? tex_w : (double)w;
	double nh = tex_h > 0 ? tex_h : (double)h;
	const double maxdim = 280.0;
	double scale = fmin(1.0, maxdim / fmax(nw, nh));
	CGFloat sw = (CGFloat)fmax(1.0, nw * scale);
	CGFloat sh = (CGFloat)fmax(1.0, nh * scale);

	NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(sw, sh)];
	[out lockFocus];
	NSGraphicsContext *gc = [NSGraphicsContext currentContext];
	CGContextRef c = (CGContextRef)[gc CGContext];
	// The IOSurface holds GL bottom-up pixels, so flip vertically to draw upright.
	CGContextSaveGState(c);
	CGContextTranslateCTM(c, 0, sh);
	CGContextScaleCTM(c, 1, -1);
	CGContextDrawImage(c, CGRectMake(0, 0, sw, sh), cg);
	CGContextRestoreGState(c);
	// A warm border so the thumbnail reads as a picked-up termling.
	NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSMakeRect(1, 1, sw - 2, sh - 2)];
	[[NSColor colorWithCalibratedRed:0.90 green:0.58 blue:0.30 alpha:0.95] setStroke];
	[border setLineWidth:2];
	[border stroke];
	// Name caption on a dark strip along the bottom.
	if (label.length) {
		NSRect strip = NSMakeRect(0, 0, sw, 22);
		[[NSColor colorWithCalibratedWhite:0.06 alpha:0.72] setFill];
		NSRectFillUsingOperation(strip, NSCompositingOperationSourceOver);
		NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
		ps.alignment = NSTextAlignmentCenter;
		ps.lineBreakMode = NSLineBreakByTruncatingTail;
		NSDictionary *attrs = @{
			NSFontAttributeName : [NSFont boldSystemFontOfSize:13],
			NSForegroundColorAttributeName : [NSColor whiteColor],
			NSParagraphStyleAttributeName : ps,
		};
		[[@"🐚 " stringByAppendingString:label] drawInRect:NSMakeRect(6, 3, sw - 12, 17) withAttributes:attrs];
	}
	[out unlockFocus];
	CGImageRelease(cg);
	return out;
}

// --- drag source ------------------------------------------------------------

@interface CoveDragSource : NSObject <NSDraggingSource>
@end

@implementation CoveDragSource
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
		sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
	// Copy in both contexts so the drag is allowed to leave the app and cross to
	// the other Mac over Universal Control.
	(void)session;
	(void)context;
	return NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session
		endedAtPoint:(NSPoint)screenPoint
		operation:(NSDragOperation)operation {
	(void)session;
	EndEvt e;
	e.accepted = operation != NSDragOperationNone;
	e.sx = screenPoint.x;
	e.sy = screenPoint.y;
	e.inside_self = g_view && g_view.window && NSPointInRect(screenPoint, g_view.window.frame);
	std::lock_guard<std::mutex> lk(g_mtx);
	g_ended.push_back(e);
	g_dragging = false;
	g_hover_active = false;
}
@end

// --- swizzled destination methods -------------------------------------------
// Each runs with `self` = the Godot content view. For cove drags we enqueue and
// answer ourselves; otherwise we defer to the view's original implementation.

static NSDragOperation cove_draggingEntered(id self, SEL _cmd, id<NSDraggingInfo> sender) {
	if (is_cove_drag(sender)) {
		std::lock_guard<std::mutex> lk(g_mtx);
		g_hover_active = true;
		hover_from(sender, g_hover_x, g_hover_y);
		return NSDragOperationCopy;
	}
	if (g_orig_entered) {
		return ((NSDragOperation (*)(id, SEL, id))g_orig_entered)(self, _cmd, sender);
	}
	return NSDragOperationNone;
}

static NSDragOperation cove_draggingUpdated(id self, SEL _cmd, id<NSDraggingInfo> sender) {
	if (is_cove_drag(sender)) {
		std::lock_guard<std::mutex> lk(g_mtx);
		g_hover_active = true;
		hover_from(sender, g_hover_x, g_hover_y);
		return NSDragOperationCopy;
	}
	if (g_orig_updated) {
		return ((NSDragOperation (*)(id, SEL, id))g_orig_updated)(self, _cmd, sender);
	}
	return NSDragOperationNone;
}

static void cove_draggingExited(id self, SEL _cmd, id<NSDraggingInfo> sender) {
	if (is_cove_drag(sender)) {
		std::lock_guard<std::mutex> lk(g_mtx);
		g_hover_active = false;
		return;
	}
	if (g_orig_exited) {
		((void (*)(id, SEL, id))g_orig_exited)(self, _cmd, sender);
	}
}

static BOOL cove_prepareForDragOperation(id self, SEL _cmd, id<NSDraggingInfo> sender) {
	if (is_cove_drag(sender)) {
		return YES;
	}
	if (g_orig_prepare) {
		return ((BOOL (*)(id, SEL, id))g_orig_prepare)(self, _cmd, sender);
	}
	return NO;
}

static BOOL cove_performDragOperation(id self, SEL _cmd, id<NSDraggingInfo> sender) {
	if (is_cove_drag(sender)) {
		NSString *payload = [[sender draggingPasteboard] stringForType:COVE_TYPE];
		DropEvt e;
		e.payload = payload ? std::string(payload.UTF8String) : std::string();
		hover_from(sender, e.x, e.y);
		{
			std::lock_guard<std::mutex> lk(g_mtx);
			g_drops.push_back(e);
			g_hover_active = false;
		}
		return YES;
	}
	if (g_orig_perform) {
		return ((BOOL (*)(id, SEL, id))g_orig_perform)(self, _cmd, sender);
	}
	return NO;
}

static void cove_concludeDragOperation(id self, SEL _cmd, id<NSDraggingInfo> sender) {
	if (sender && is_cove_drag(sender)) {
		std::lock_guard<std::mutex> lk(g_mtx);
		g_hover_active = false;
		return;
	}
	if (g_orig_conclude) {
		((void (*)(id, SEL, id))g_orig_conclude)(self, _cmd, sender);
	}
}

// Install one destination method on `cls`: if the class already implements it,
// swap in ours and stash the original for pass-through; otherwise add ours.
static void install_method(Class cls, SEL sel, IMP imp, const char *types, IMP *saved_orig) {
	Method m = class_getInstanceMethod(cls, sel);
	if (m) {
		*saved_orig = method_getImplementation(m);
		method_setImplementation(m, imp);
	} else {
		*saved_orig = NULL;
		class_addMethod(cls, sel, imp, types);
	}
}

static void install_destination(NSView *view) {
	if (g_installed) {
		return;
	}
	Class cls = object_getClass(view);
	// Type encodings vary by arch (BOOL is signed char vs bool), so build them
	// from @encode at compile time.
	char t_op[8], t_bool[8], t_void[8];
	snprintf(t_op, sizeof t_op, "%s@:@", @encode(NSDragOperation));
	snprintf(t_bool, sizeof t_bool, "%s@:@", @encode(BOOL));
	snprintf(t_void, sizeof t_void, "%s@:@", @encode(void));
	install_method(cls, @selector(draggingEntered:), (IMP)cove_draggingEntered, t_op, &g_orig_entered);
	install_method(cls, @selector(draggingUpdated:), (IMP)cove_draggingUpdated, t_op, &g_orig_updated);
	install_method(cls, @selector(draggingExited:), (IMP)cove_draggingExited, t_void, &g_orig_exited);
	install_method(cls, @selector(prepareForDragOperation:), (IMP)cove_prepareForDragOperation, t_bool, &g_orig_prepare);
	install_method(cls, @selector(performDragOperation:), (IMP)cove_performDragOperation, t_bool, &g_orig_perform);
	install_method(cls, @selector(concludeDragOperation:), (IMP)cove_concludeDragOperation, t_void, &g_orig_conclude);
	g_installed = true;
	fprintf(stderr, "cove-gdext: CoveDrag destination installed on %s\n", class_getName(cls));
}

// --- CoveDrag (Godot-facing) ------------------------------------------------

void CoveDrag::_bind_methods() {
	ClassDB::bind_method(D_METHOD("attach", "view_handle"), &CoveDrag::attach);
	ClassDB::bind_method(D_METHOD("is_attached"), &CoveDrag::is_attached);
	ClassDB::bind_method(D_METHOD("begin_drag", "payload", "label", "iosurface_id", "tex_w", "tex_h"), &CoveDrag::begin_drag);
	ClassDB::bind_method(D_METHOD("is_dragging"), &CoveDrag::is_dragging);
	ClassDB::bind_method(D_METHOD("poll_drop"), &CoveDrag::poll_drop);
	ClassDB::bind_method(D_METHOD("poll_hover"), &CoveDrag::poll_hover);
	ClassDB::bind_method(D_METHOD("poll_drag_ended"), &CoveDrag::poll_drag_ended);
	ClassDB::bind_method(D_METHOD("window_number"), &CoveDrag::window_number);
}

bool CoveDrag::attach(int64_t view_handle) {
	NSView *view = (__bridge NSView *)(void *)(uintptr_t)view_handle;
	if (!view || ![view isKindOfClass:[NSView class]]) {
		fprintf(stderr, "cove-gdext: CoveDrag.attach got a bad view handle\n");
		return false;
	}
	g_view = view;
	if (!g_source) {
		g_source = [[CoveDragSource alloc] init];
	}
	// Union our type into whatever the view already registers (file types etc.).
	NSArray<NSPasteboardType> *existing = [view registeredDraggedTypes];
	NSMutableArray *types = existing ? [existing mutableCopy] : [NSMutableArray array];
	if (![types containsObject:COVE_TYPE]) {
		[types addObject:COVE_TYPE];
	}
	[view registerForDraggedTypes:types];
	install_destination(view);
	return true;
}

bool CoveDrag::is_attached() const {
	return g_view != nil;
}

bool CoveDrag::begin_drag(const String &payload, const String &label,
		int64_t iosurface_id, int tex_w, int tex_h) {
	if (!g_view) {
		return false;
	}
	NSString *pl = [NSString stringWithUTF8String:payload.utf8().get_data()];
	NSString *lbl = [NSString stringWithUTF8String:label.utf8().get_data()];

	NSEvent *ev = [NSApp currentEvent];
	NSEventType et = ev ? ev.type : NSEventTypeApplicationDefined;
	bool usable = ev && (et == NSEventTypeLeftMouseDown || et == NSEventTypeLeftMouseDragged ||
			et == NSEventTypeRightMouseDown || et == NSEventTypeOtherMouseDown);
	if (!usable) {
		// Synthesize a drag event at the current pointer so we can start even when
		// Godot has already consumed the real one.
		NSWindow *win = g_view.window;
		if (!win) {
			return false;
		}
		NSPoint loc = [win mouseLocationOutsideOfEventStream];
		ev = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
							location:loc
					   modifierFlags:0
						   timestamp:[[NSProcessInfo processInfo] systemUptime]
						windowNumber:win.windowNumber
							 context:nil
						 eventNumber:0
						  clickCount:1
							pressure:1.0];
		if (!ev) {
			return false;
		}
	}

	NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
	[item setString:pl forType:COVE_TYPE];
	NSDraggingItem *di = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
	NSImage *img = make_drag_image_from_iosurface((uint32_t)iosurface_id, tex_w, tex_h, lbl);
	if (!img) {
		img = make_drag_image(lbl);  // surface unavailable; fall back to the chip
	}
	NSPoint locInView = [g_view convertPoint:ev.locationInWindow fromView:nil];
	NSRect frame = NSMakeRect(locInView.x - img.size.width / 2,
			locInView.y - img.size.height / 2, img.size.width, img.size.height);
	[di setDraggingFrame:frame contents:img];

	NSDraggingSession *s = [g_view beginDraggingSessionWithItems:@[ di ]
														   event:ev
														  source:(id<NSDraggingSource>)g_source];
	g_dragging = (s != nil);
	return g_dragging;
}

bool CoveDrag::is_dragging() const {
	std::lock_guard<std::mutex> lk(g_mtx);
	return g_dragging;
}

Dictionary CoveDrag::poll_drop() {
	std::lock_guard<std::mutex> lk(g_mtx);
	Dictionary d;
	if (g_drops.empty()) {
		return d;
	}
	DropEvt e = g_drops.front();
	g_drops.pop_front();
	d["payload"] = String::utf8(e.payload.c_str());
	d["x"] = e.x;
	d["y"] = e.y;
	return d;
}

Dictionary CoveDrag::poll_hover() {
	std::lock_guard<std::mutex> lk(g_mtx);
	Dictionary d;
	d["active"] = g_hover_active;
	if (g_hover_active) {
		d["x"] = g_hover_x;
		d["y"] = g_hover_y;
	}
	return d;
}

Dictionary CoveDrag::poll_drag_ended() {
	std::lock_guard<std::mutex> lk(g_mtx);
	Dictionary d;
	if (g_ended.empty()) {
		return d;
	}
	EndEvt e = g_ended.front();
	g_ended.pop_front();
	d["accepted"] = e.accepted;
	d["sx"] = e.sx;
	d["sy"] = e.sy;
	d["inside_self"] = e.inside_self;
	return d;
}

int64_t CoveDrag::window_number() const {
	if (!g_view || !g_view.window) {
		return 0;
	}
	return (int64_t)g_view.window.windowNumber;
}

CoveDrag::~CoveDrag() {
	// The swizzle stays installed for the class lifetime; just drop our view ref.
	g_view = nil;
}
