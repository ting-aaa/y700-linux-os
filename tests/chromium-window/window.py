"""Present an input-transparent X11 window and sample only Xephyr's own child pixmap."""
import ctypes as C
from pathlib import Path
import sys
import time

def function(lib, name, result, *args):
    f = getattr(lib, name)
    f.restype, f.argtypes = result, args
    return f


def last_input():
    class Info(C.Structure):
        _fields_ = [("window", C.c_ulong), ("state", C.c_int), ("kind", C.c_int),
                    ("until", C.c_ulong), ("idle", C.c_ulong), ("mask", C.c_ulong)]
    x = C.CDLL("libX11.so.6")
    d = function(x, "XOpenDisplay", C.c_void_p, C.c_char_p)(None)
    assert d
    root = function(x, "XDefaultRootWindow", C.c_ulong, C.c_void_p)(d)
    info = Info()
    assert function(C.CDLL("libXss.so.1"), "XScreenSaverQueryInfo", C.c_int, C.c_void_p,
                    C.c_ulong, C.POINTER(Info))(d, root, C.byref(info))
    print(time.monotonic_ns() // 1000000 - info.idle)


def run(state):
    ptr, xid, integer = C.c_void_p, C.c_ulong, C.c_int
    x = C.CDLL("libX11.so.6")
    composite = C.CDLL("libXcomposite.so.1")
    shape = C.CDLL("libXext.so.6")
    display = function(x, "XOpenDisplay", ptr, C.c_char_p)(None)
    assert display
    sync = function(x, "XSync", integer, ptr, integer)
    tree = function(x, "XQueryTree", integer, ptr, xid, C.POINTER(xid), C.POINTER(xid),
                    C.POINTER(C.POINTER(xid)), C.POINTER(C.c_uint))
    free = function(x, "XFree", integer, ptr)
    redirect = function(composite, "XCompositeRedirectWindow", None, ptr, xid, integer)
    name_pixmap = function(composite, "XCompositeNameWindowPixmap", xid, ptr, xid)
    get = function(x, "XGetImage", ptr, ptr, xid, integer, integer, C.c_uint, C.c_uint, xid, integer)
    pixel = function(x, "XGetPixel", xid, ptr, integer, integer)
    destroy = function(x, "XDestroyImage", integer, ptr)
    empty = function(shape, "XShapeCombineRectangles", None, ptr, xid, integer, integer, integer,
                     ptr, integer, integer, integer)
    rectangles = function(shape, "XShapeGetRectangles", ptr, ptr, xid, integer,
                          C.POINTER(integer), C.POINTER(integer))
    # Match Xephyr's root visual, depth and colormap exactly using CopyFromParent.
    root = function(x, "XDefaultRootWindow", xid, ptr)(display)
    win = function(x, "XCreateSimpleWindow", xid, ptr, xid, integer, integer, C.c_uint,
                   C.c_uint, C.c_uint, xid, xid)(display, root, 24, 24, 640, 480, 0, 0, 0)
    class Attributes(C.Structure):
        _fields_ = [(n, xid) for n in ("background_pixmap", "background_pixel", "border_pixmap",
                    "border_pixel")] + [(n, integer) for n in ("bit_gravity", "win_gravity",
                    "backing_store")] + [(n, xid) for n in ("backing_planes", "backing_pixel")] + [
                    ("save_under", integer), ("event_mask", C.c_long),
                    ("do_not_propagate_mask", C.c_long), ("override_redirect", integer),
                    ("colormap", xid), ("cursor", xid)]
    attrs = Attributes(override_redirect=1, event_mask=1 << 16)  # VisibilityChangeMask
    function(x, "XChangeWindowAttributes", integer, ptr, xid, xid, C.POINTER(Attributes))(
        display, win, (1 << 9) | (1 << 11), C.byref(attrs))
    class Visibility(C.Structure):
        _fields_ = [("type", integer), ("serial", xid), ("send_event", integer), ("display", ptr),
                    ("window", xid), ("state", integer)]
    event = (C.c_long * 24)()
    check_event = function(x, "XCheckTypedWindowEvent", integer, ptr, xid, integer, ptr)
    visibility = None
    count, ordering = integer(), integer()
    empty(display, win, 2, 0, 0, None, 0, 0, 0)  # ShapeInput, ShapeSet
    sync(display, 0)
    r = rectangles(display, win, 2, C.byref(count), C.byref(ordering))
    free(r)
    assert count.value == 0
    function(x, "XMapRaised", integer, ptr, xid)(display, win)
    sync(display, 0)
    (state / "parent").write_text(str(win))
    deadline = time.monotonic() + 150
    pixmap = 0
    last = None
    matches = 0
    while time.monotonic() < deadline:
        while check_event(display, win, 15, C.byref(event)):  # VisibilityNotify
            visibility = Visibility.from_buffer(event).state
        if (state / "nested-ready").exists():
            if not pixmap:
                root, parent, children, n = xid(), xid(), C.POINTER(xid)(), C.c_uint()
                assert tree(display, win, C.byref(root), C.byref(parent), C.byref(children), C.byref(n))
                assert n.value == 1, f"expected one embedded Xephyr child, found {n.value}"
                child = children[0]
                free(children)
                redirect(display, child, 0)  # Automatic redirect preserves presentation.
                sync(display, 0)
                pixmap = name_pixmap(display, child)
                sync(display, 0)
                assert pixmap
                (state / "pixmap-ready").touch()
            if not (state / "client/browser-ready").exists():
                time.sleep(.1)
                continue
            colors = []
            for xx, yy in ((160, 120), (480, 120), (160, 360), (480, 360)):
                img = get(display, pixmap, xx, yy, 1, 1, ~0, 2)
                assert img
                colors.append(pixel(img, 0, 0) & 0xffffff)
                destroy(img)
            if colors == [0, 0xff0000, 0x00ff00, 0x0000ff]:
                matches += 1
                if matches == 3:
                    assert visibility == 0, f"parent visibility={visibility}"
                    print("WINDOW_PRESENT child=xephyr viewable=1 unobscured=1 input_shape=empty "
                          "samples=000000,ff0000,00ff00,0000ff repeats=3", flush=True)
                    (state / "presented").touch()
                    while not (state / "done").exists() and time.monotonic() < deadline:
                        time.sleep(.1)
                    return
            else:
                matches = 0
            last = colors
        time.sleep(.1)
    raise TimeoutError(f"Expected quadrants did not reach the owned child pixmap, last={last}")


if __name__ == "__main__":
    if sys.argv[1] == "--last-input":
        last_input()
    else:
        run(Path(sys.argv[1]))
