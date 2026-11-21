"""Observe Parole 4.18's visible playback of a red/green/blue/yellow 4 s per colour clip."""
import argparse
import atexit
import ctypes
import gettext
import os
from pathlib import Path
import re
import subprocess
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Atspi, Gdk, Gio, GLib, Gtk


PLAYER = "org.Parole.Media.Player"
DBUS = "org.freedesktop.DBus"
translate = gettext.translation("parole", fallback=True).gettext
PLAY, PAUSE = translate("Play"), translate("Pause")


def until(probe, timeout, message):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = probe()
        if result:
            return result
        time.sleep(.08)
    raise RuntimeError(message)


def windows_for(pid, scale):
    tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
    for line in tree.splitlines():
        if '("parole" "parole")' not in line.lower():
            continue
        xid = line.split()[0]
        owner = subprocess.check_output(["xprop", "-id", xid, "_NET_WM_PID"], text=True)
        if not owner.rstrip().endswith(f" = {pid}"):
            continue
        info = subprocess.check_output(["xwininfo", "-id", xid], text=True)
        if "Map State: IsViewable" not in info:
            continue
        keys = ["Absolute upper-left X", "Absolute upper-left Y", "Width", "Height"]
        box = [int(re.search(rf"^\s*{key}:\s*(-?\d+)", info, re.M)[1]) // scale for key in keys]
        if box[2] >= 200 and box[3] >= 140:
            return box
    return None


def picture(root, box):
    # Read the display, not a decoded buffer. Require a broad solid rectangle
    # in the same part of two client rows, avoiding title bar, controls and playlist.
    x, y, width, height = box
    left = max(x + width // 12, 0)
    right = min(x + width // 2, root.get_width())
    if right <= left:
        return None
    bands = []
    for fraction in (.44, .55):
        pos = y + int(height * fraction)
        if not 0 <= pos < root.get_height():
            return None
        row = Gdk.pixbuf_get_from_window(root, left, pos, right - left, 1)
        if row is None:
            return None
        pixels = row.get_pixels()
        colours = []
        for i in range(12):
            index = (2 * i + 1) * row.get_width() // 24 * row.get_n_channels()
            r, g, b = pixels[index:index + 3]
            if r > 135 and g > 135 and b < min(r, g) - 70:
                colours.append("yellow")
            elif r > 135 and r - max(g, b) > 70:
                colours.append("red")
            elif g > 80 and g - max(r, b) > 55:
                colours.append("green")
            elif b > 135 and b - max(r, g) > 70:
                colours.append("blue")
            else:
                colours.append(None)
        bands.append(colours)
    for colour in ("red", "green", "blue", "yellow"):
        if sum(a == b == colour for a, b in zip(*bands)) >= 6:
            return colour
    return None


def controls(pid):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app is None or app.get_process_id() != pid:
            continue
        frame = button = slider = None
        pending = [app]
        while pending:
            widget = pending.pop()
            role = widget.get_role()
            if role == Atspi.Role.FRAME:
                frame = widget
            elif role == Atspi.Role.PUSH_BUTTON and widget.get_name() in (PLAY, PAUSE):
                button = widget
            elif role == Atspi.Role.SLIDER:
                # The playback slider uses clip seconds. The separate volume
                # control has a different range. No accessible names need translation.
                if widget.get_minimum_value() == 0 and abs(widget.get_maximum_value() - 16) <= .25:
                    slider = widget
            if frame and button and slider:
                return frame, button, slider
            pending.extend(child for i in range(widget.get_child_count())
                           if (child := widget.get_child_at_index(i)) is not None)
    return None


def pointer_controls(widgets, box, scale):
    frame, button, slider = widgets
    outer = frame.get_extents(Atspi.CoordType.SCREEN)
    # ATK may report a 2x X11 window in logical or device units.
    ratio = min((1, scale), key=lambda factor: abs(outer.width * factor - box[2] * scale))
    assert abs(outer.width * ratio - box[2] * scale) <= 30, "Unexpected Parole frame units"

    def bounds(widget):
        rect = widget.get_extents(Atspi.CoordType.SCREEN)
        assert rect.width > 8 and rect.height > 8 and rect.x >= outer.x and rect.y >= outer.y
        # SCREEN coordinates already include the frame decoration. The client
        # origin in xwininfo is below the WM title bar; adding it would count
        # that offset twice and put the click underneath the toolbar.
        x, y, w, h = [value * ratio for value in (rect.x, rect.y, rect.width, rect.height)]
        assert box[0] * scale <= x + w / 2 < (box[0] + box[2]) * scale
        assert box[1] * scale <= y + h / 2 < (box[1] + box[3]) * scale
        return x, y, w, h

    x11 = ctypes.CDLL("libX11.so.6")
    xtest = ctypes.CDLL("libXtst.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    xtest.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
    xtest.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    display = x11.XOpenDisplay(None)
    assert display
    atexit.register(x11.XCloseDisplay, display)

    def move(x, y):
        assert xtest.XTestFakeMotionEvent(display, -1, round(x), round(y), 0)
        x11.XSync(display, 0)

    def press(down):
        assert xtest.XTestFakeButtonEvent(display, 1, down, 0)
        x11.XSync(display, 0)

    def reveal():
        # Parole hides its toolbar on a timer and reveals it on video motion.
        move((box[0] + box[2] * .3) * scale, (box[1] + box[3] * .55) * scale)
        time.sleep(.05)
        move((box[0] + box[2] * .32) * scale, (box[1] + box[3] * .55) * scale)
        time.sleep(.35)

    def tap_button(expected):
        reveal()
        initial = button.get_name()
        assert initial in (PLAY, PAUSE) and initial != expected, f"Unexpected initial button state {initial}"
        x, y, w, h = bounds(button)
        move(x + w / 2, y + h / 2)
        press(True)
        press(False)
        until(lambda: button.get_name() == expected, 2, f"Pointer did not toggle {initial}")

    def seek(target, drag_from=None):
        reveal()
        x, y, w, h = bounds(slider)
        y += h / 2
        # Stay clear of trough end padding. Both marker targets have a
        # one-second margin inside a four-second colour block.
        def xpos(seconds):
            return x + w * seconds / 16
        if drag_from is None:
            move(xpos(target), y)
            press(True)
            press(False)
        else:
            start = xpos(drag_from)
            move(start, y)
            press(True)
            try:
                for i in range(1, 7):
                    move(start + (xpos(target) - start) * i / 6, y)
                    time.sleep(.045)
            finally:
                press(False)
    reveal()
    return bounds(button)[2:], bounds(slider)[2:], tap_button, seek


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("clip", type=Path)
    cli.add_argument("--already-open", action="store_true")
    cli.add_argument("--pointer", action="store_true", help="tap and drag the visible X11 transport controls")
    cli.add_argument("--seek-cycles", type=int, choices=range(1, 6), default=1)
    cli.add_argument("--single-seek", action="store_true",
                     help="verify one GStreamer seek per completed pointer gesture")
    cli.add_argument("--require-iris", choices=("v4l2h264dec", "v4l2h265dec", "v4l2vp9dec"))
    args = cli.parse_args()
    if args.single_seek and not (args.pointer and args.require_iris):
        cli.error("--single-seek requires --pointer and --require-iris")
    clip = args.clip.resolve(strict=True)
    assert os.getuid() != 0
    Gtk.init([])
    root = Gdk.get_default_root_window()
    assert root.get_scale_factor() == 2
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)

    def dbus(target, path, interface, method, params=None):
        return bus.call_sync(target, path, interface, method, params, None,
                             Gio.DBusCallFlags.NO_AUTO_START, 2000, None).unpack()

    def pid_for_file():
        try:
            pid, = dbus(DBUS, "/org/freedesktop/DBus", DBUS, "GetConnectionUnixProcessID",
                        GLib.Variant("(s)", (PLAYER,)))
        except GLib.Error:
            return None
        proc = Path("/proc") / str(pid)
        if proc.stat().st_uid != os.getuid():
            return None
        argv = (proc / "cmdline").read_bytes().split(b"\0")
        return pid if os.fsencode(clip) in argv or clip.as_uri().encode() in argv else None

    if not args.already_open:
        subprocess.run(["gio", "open", str(clip)], check=True, timeout=20)
    pid = until(pid_for_file, 40, "No Parole D-Bus owner playing the requested file")
    box = until(lambda: windows_for(pid, 2), 12, "No viewable Parole window owned by the player")
    print(f"PAROLE_TRANSPORT_START file={clip.name} pid={pid}", flush=True)
    log = Path(os.environ["XDG_RUNTIME_DIR"]) / f"media-{pid}.log"

    def checkpoint():
        return log.stat().st_size if args.require_iris else 0

    def observe(colour):
        until(lambda: picture(root, box) == colour, 10, f"Parole did not display {colour}")

    def progress(step, colour, previous):
        observe(colour)
        count = 0
        if args.require_iris:
            expression = rb"<" + args.require_iris.encode() + rb"[0-9]+> Got buffer for frame number [0-9]+"

            def new_buffers():
                with log.open("rb") as stream:
                    stream.seek(previous)
                    return len(re.findall(expression, stream.read()))
            count = until(new_buffers, 4, f"No new {args.require_iris} buffers after {step}")
        detail = ""
        if args.single_seek and step.startswith("seek-"):
            with log.open("rb") as stream:
                stream.seek(previous)
                seeks = len(re.findall(rb"<multiqueue\d+:sink_\d+> Got upstream event seek", stream.read()))
            assert seeks == 1, f"{step} sent {seeks} seek events"
            detail = f" seek_events={seeks}"
        print(f"PAROLE_TRANSPORT_STEP file={clip.name} pid={pid} action={step} pixels={colour} "
              f"new_decoder_buffers={count}{detail}", flush=True)

    def toggle():
        assert pid_for_file() == pid
        dbus(PLAYER, "/org/Parole/Media/Player", PLAYER, "Play")

    observe("red")
    if not args.pointer:
        toggle()  # Parole 4.18.2's normal remote Play action toggles Play/Pause.
    Atspi.init()
    widgets = until(lambda: controls(pid), 12, "Parole transport controls missing")
    # The player may have resized to the clip since its splash appeared.
    box = windows_for(pid, 2)
    button_size, slider_size, tap, seek = pointer_controls(widgets, box, 2)
    print(f"PAROLE_TRANSPORT_CONTROLS file={clip.name} pid={pid} slider_px={slider_size[0]}x{slider_size[1]} "
          f"play_pause_px={button_size[0]}x{button_size[1]} mode={'pointer' if args.pointer else 'accessible'}",
          flush=True)
    if args.pointer:
        tap(PLAY)
    assert widgets[1].get_name() == PLAY, "Parole did not pause"
    for cycle in range(1, args.seek_cycles + 1):
        for target, direction, colour in ((13, "seek-forward", "yellow"), (6, "seek-back", "green")):
            previous = checkpoint()
            if args.pointer:
                seek(target, drag_from=13 if direction == "seek-back" else None)
            else:
                assert widgets[2].set_current_value(target), "Accessible GtkScale refused seek"
            progress(direction, colour, previous)
        print(f"PAROLE_SEEK_CYCLE file={clip.name} pid={pid} completed={cycle}", flush=True)

    # A key-unit seek may land before second 6. Even from the first green
    # frame at 4 s an advancing clock must cross the 8 s boundary in 4 s.
    begin = time.monotonic()
    samples = 0
    while time.monotonic() - begin < 4.4:
        assert picture(root, box) == "green", "Paused video changed or became hidden"
        samples += 1
        time.sleep(.1)
    held = time.monotonic() - begin
    assert samples >= 12
    print(f"PAROLE_TRANSPORT_STEP file={clip.name} pid={pid} action=pause-hold pixels=green "
          f"seconds={held:.2f} samples={samples}", flush=True)
    previous = checkpoint()
    if args.pointer:
        tap(PAUSE)
    else:
        toggle()
    progress("resume", "blue", previous)
    assert pid_for_file() == pid
    print(f"PAROLE_TRANSPORT_PASS file={clip.name} pid={pid} gtk_scale=2 "
          f"decoder={args.require_iris or 'unverified'}", flush=True)


if __name__ == "__main__":
    main()
