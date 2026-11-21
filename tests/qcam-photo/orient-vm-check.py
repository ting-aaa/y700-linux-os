"""Check only the packaged qcam window and generated JPEGs inside the synthetic-camera VM."""
import importlib.util
import os
from pathlib import Path
import re
import sys

import gi
gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import Gdk, GdkPixbuf, GdkX11


spec = importlib.util.spec_from_file_location("shutter", Path(__file__).with_name("virtual-shutter.py"))
shutter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shutter)

WORK = Path("/run/qcam-qa")
COLORS = dict(R=0xE9292AFF, G=0x2CD242FF, B=0x2B35E9FF, Y=0xEAD827FF)
MARKERS = {"main": "RGBY", "macro": "BYRG", "front": "GRYB"}
# Clockwise Qt image rotation, independently tabulated from the fixed board mounting.
DEGREES = {"main": (180, 90, 0, 270), "macro": (180, 90, 0, 270), "front": (0, 90, 180, 270)}
ROTATIONS = ("left", "normal", "right", "inverted")
ORDERS = {0: (0, 1, 2, 3), 90: (2, 0, 3, 1), 180: (3, 2, 1, 0), 270: (1, 3, 0, 2)}


def generate():
    for lens, pattern in MARKERS.items():
        _, _, w, h = shutter.CAMERAS[lens]
        image = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, False, 8, w, h)
        for i, c in enumerate(pattern):
            image.new_subpixbuf(i % 2 * (w // 2), i // 2 * (h // 2), w // 2, h // 2).fill(COLORS[c])
        image.savev(str(WORK / f"{lens}-source.jpg"), "jpeg", ["quality"], ["98"])


def corners(image, preview=False):
    w, h = image.get_width(), image.get_height()
    data, stride, channels = image.get_pixels(), image.get_rowstride(), image.get_n_channels()

    def color(x, y):
        start = y * stride + x * channels
        r, g, b = data[start:start+3]
        if min(r, g) > b + 75 and abs(r-g) < 65:
            return "Y"
        for name, value, other1, other2 in (("R", r, g, b), ("G", g, r, b), ("B", b, r, g)):
            if value > max(other1, other2) + 75:
                return name
        return "-"

    x0, y0, x1, y1 = 0, 0, w, h
    if preview:
        # The real top-level qcam client also contains a toolbar and black letterboxing.
        # Locate rows belonging to its colored chart, then sample well inside four quadrants.
        points = []
        for y in range(8, h, 14):
            line = [(x, y) for x in range(8, w, 14) if color(x, y) != "-"]
            if len(line) >= 8:
                points.extend(line)
        if not points:
            return ""
        x0, x1 = min(x for x, _ in points), max(x for x, _ in points)
        y0, y1 = min(y for _, y in points), max(y for _, y in points)
        if x1 - x0 < 70 or y1 - y0 < 70:
            return ""
    return "".join(color(x0 + (x1-x0) * x // 4, y0 + (y1-y0) * y // 4) for y in (1, 3) for x in (1, 3))


class Window(shutter.CameraWindow):
    def click(self, node):
        rect = node.get_extents(shutter.Atspi.CoordType.SCREEN)
        x = round((rect.x + rect.width / 2) * self.scale)
        y = round((rect.y + rect.height / 2) * self.scale)
        w, h = map(int, shutter.run("xdotool", "getdisplaygeometry").split())
        assert rect.width > 0 and rect.height > 0 and 0 <= x < w and 0 <= y < h
        shutter.run("xdotool", "mousemove", str(x), str(y), "click", "1")


def check(pid, version):
    assert version.endswith((".y7007", ".y7008"))
    legacy = version.endswith(".y7007")
    display = Gdk.Display.get_default()
    assert display is not None
    win = Window(pid, False, False)
    win.modern = True
    xid = int(shutter.run("xdotool", "search", "--onlyvisible", "--pid", str(pid), "--name", "^QCam"))
    foreign = GdkX11.X11Window.foreign_new_for_display(display, xid)
    assert foreign
    pictures = Path.home() / "Pictures"
    assert not pictures.exists()

    def preview():
        _, _, width, height = foreign.get_geometry()
        pix = Gdk.pixbuf_get_from_window(foreign, 0, 0, width, height)
        return corners(pix, True) if pix else ""

    previous = "main"
    for lens in ("main", "front", "macro"):
        if lens != previous:
            win.choose(shutter.CAMERAS[lens][1], shutter.CAMERAS[previous][1])
            expected = "Switching to camera " + shutter.CAMERAS[lens][0]
            shutter.wait_for(lambda: expected in (WORK / "qcam.log").read_text().replace('"', ''), "lens ID")
        for index, rotation in enumerate(ROTATIONS):
            shutter.run("xrandr", "--output", "DSI-1", "--rotate", rotation)
            line = next(s for s in shutter.run("xrandr", "--current").splitlines() if s.startswith("DSI-1 connected"))
            geometry = "1600x2560" if rotation in ("normal", "inverted") else "2560x1600"
            crtc = re.search(r"(\d+x\d+)\+0\+0(?: (left|right|inverted))? \(", line)
            assert crtc and crtc[1] == geometry and (crtc[2] or "normal") == rotation, line
            shutter.run("xdotool", "windowmove", str(xid), "12", "12", "windowsize", str(xid), "1050", "850")
            angle = 0 if legacy else DEGREES[lens][index]
            wanted = "".join(MARKERS[lens][i] for i in ORDERS[angle])
            try:
                shutter.wait_for(lambda: preview() == wanted, f"{lens} {rotation} preview {wanted}", seconds=24)
            except RuntimeError:
                print(f"QCAM_PREVIEW_MISMATCH lens={lens} rotation={rotation} expected={wanted} observed={preview()}", flush=True)
                raise
            win.click(win.find(shutter.Atspi.Role.PUSH_BUTTON, win.shutter))
            photo, = shutter.wait_for(lambda: list(pictures.glob("*.jpg")), "new shutter JPEG")
            image = GdkPixbuf.Pixbuf.new_from_file(str(photo))
            w, h = shutter.CAMERAS[lens][2:]
            dims = (h, w) if angle in (90, 270) else (w, h)
            assert (image.get_width(), image.get_height()) == dims
            assert corners(image) == wanted and photo.read_bytes().endswith(b"\xff\xd9")
            photo.unlink()
            assert not list(pictures.iterdir())
            print(f"QCAM_ORIENT lens={lens} crtc={rotation} negotiated=Rotate270 clockwise={angle} "
                  f"preview={wanted} jpeg={wanted} size={dims[0]}x{dims[1]} removed=1", flush=True)
            if legacy:
                print("QCAM_ORIENTATION_LEGACY lenses=1 rotations=1 preview_checks=1 jpeg_checks=1 uncorrected=1", flush=True)
                return
        previous = lens
    os.kill(pid, 0)
    print("QCAM_ORIENTATION_PASS lenses=3 rotations=4 preview_checks=12 jpeg_checks=12 single_process=1", flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--generate"]:
        generate()
    else:
        check(int(sys.argv[1]), sys.argv[2])
