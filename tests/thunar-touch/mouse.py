"""Check ordinary mouse selection and double-click in a private Xorg session."""
import ctypes
from ctypes import c_char_p, c_int, c_ulong, c_void_p
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from exercise import Atspi, box, title, touch, wait, widget


def exercise(work, scale):
    (work / "Travel").mkdir(parents=True)
    if scale == 2:
        for i in range(96):
            (work / "Travel" / f"Box{i:03}").mkdir()
    x11 = ctypes.CDLL("libX11.so.6")
    xtst = ctypes.CDLL("libXtst.so.6")
    x11.XOpenDisplay.argtypes = [c_char_p]
    x11.XOpenDisplay.restype = c_void_p
    x11.XSync.argtypes = [c_void_p, c_int]
    x11.XCloseDisplay.argtypes = [c_void_p]
    x11.XKeysymToKeycode.argtypes = [c_void_p, c_ulong]
    xtst.XTestFakeKeyEvent.argtypes = [c_void_p, ctypes.c_uint, c_int, c_ulong]
    xtst.XTestFakeMotionEvent.argtypes = [c_void_p, c_int, c_int, c_int, c_ulong]
    xtst.XTestFakeButtonEvent.argtypes = [c_void_p, ctypes.c_uint, c_int, c_ulong]
    display = x11.XOpenDisplay(None)
    assert display

    def click():
        for down in (1, 0):
            assert xtst.XTestFakeButtonEvent(display, 1, down, 0)
        x11.XSync(display, 0)

    def move(x, y):
        assert xtst.XTestFakeMotionEvent(display, -1, x*scale, y*scale, 0)

    proc = subprocess.Popen(["thunar", work], stdout=subprocess.DEVNULL)
    try:
        wait(lambda: title() == "PointerFiles - Thunar", "mouse file manager", 45)
        pane = box(widget("directory pane", "Icon view"))
        move(pane.x+45, pane.y+36)
        click()
        wait(lambda: "Travel" in widget("status bar").get_name(), "mouse selection")
        assert title() == "PointerFiles - Thunar"
        time.sleep(.7)
        click()
        time.sleep(.07)
        click()
        wait(lambda: title() == "Travel - Thunar", "mouse double-click")
        print(f"THUNAR_MOUSE scale={scale} single_selected=1 double_opened=1", flush=True)
        if scale == 2:
            # Shift and Ctrl come from XTEST, the directory tap from Type-B.
            pane = box(widget("directory pane", "Icon view"))
            x, y = pane.x + 45, pane.y + 36
            for name, keysym in (("Shift", 0xffe1), ("Control", 0xffe3)):
                key = x11.XKeysymToKeycode(display, keysym)
                assert key and xtst.XTestFakeKeyEvent(display, key, 1, 0)
                x11.XSync(display, 0)
                try:
                    touch("tap", x, y)
                finally:
                    assert xtst.XTestFakeKeyEvent(display, key, 0, 0)
                    x11.XSync(display, 0)
                assert title() == "Travel - Thunar", name
            move(x, y)
            click()
            wait(lambda: "Box000" in widget("status bar").get_name(), "unscrolled selection")
            touch("swipe-up", pane.x + pane.width//2, pane.y + pane.height*3//4)
            time.sleep(1.6)
            # A native mouse click independently identifies the visible icon.
            # End at different offsets to accommodate a partially visible row.
            for offset in (36, 54, 80, 103):
                y = pane.y + offset
                move(x, y)
                click()
                time.sleep(.5)
                selection = re.search(r'"(Box[0-9]{3})"', widget("status bar").get_name())
                if selection and selection[1] != "Box000":
                    break
            else:
                raise RuntimeError("visible scrolled directory")
            touch("tap", x, y)
            wait(lambda: title() == selection[1] + " - Thunar", "scrolled touch hit")
            print("THUNAR_SCROLL direct_swipe=1 visible_hit=1 shift_kept=1 ctrl_kept=1", flush=True)
    finally:
        x11.XCloseDisplay(display)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)


if __name__ == "__main__":
    assert os.getuid() != 0
    Atspi.init()
    Atspi.set_timeout(3500, 3500)
    with tempfile.TemporaryDirectory(dir=os.environ["XDG_RUNTIME_DIR"]) as tmp:
        exercise(Path(tmp)/"PointerFiles", int(os.environ["GDK_SCALE"]))
