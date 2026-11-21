"""Drive the mapped GtkScale and count real TIME seek events in the player."""
import ctypes as ct
import os
from pathlib import Path
import re
import time

from gi.repository import Atspi, Gdk


def check(playback, widgets, box, scale, deferred):
    frame, _, slider = widgets
    outer = frame.get_extents(Atspi.CoordType.SCREEN)
    units = min((1, scale), key=lambda i: abs(outer.width * i - box[2] * scale))
    text = []
    pending = [frame]
    while pending:
        node = pending.pop()
        if node.get_role() == Atspi.Role.LABEL:
            text.append(node)
        else:
            pending.extend(child for i in range(node.get_child_count())
                           if (child := node.get_child_at_index(i)) is not None)

    x = ct.CDLL("libX11.so.6")
    xt = ct.CDLL("libXtst.so.6")
    display_t = ct.c_void_p
    x.XOpenDisplay.argtypes, x.XOpenDisplay.restype = [ct.c_char_p], display_t
    x.XCloseDisplay.argtypes = [display_t]
    x.XSync.argtypes = [display_t, ct.c_int]
    x.XKeysymToKeycode.argtypes = [display_t, ct.c_ulong]
    xt.XTestFakeMotionEvent.argtypes = [display_t, ct.c_int, ct.c_int, ct.c_int, ct.c_ulong]
    xt.XTestFakeButtonEvent.argtypes = [display_t, ct.c_uint, ct.c_int, ct.c_ulong]
    xt.XTestFakeKeyEvent.argtypes = [display_t, ct.c_uint, ct.c_int, ct.c_ulong]
    display = x.XOpenDisplay(None)
    assert display
    log = Path(os.environ["GST_DEBUG_FILE"])
    event = re.compile(rb"creating seek rate 1\.000000, format TIME, flags 5, start_type 1, start 0:00:(\d{2})\.")
    until = playback["until"]

    def motion(px, py):
        assert xt.XTestFakeMotionEvent(display, -1, round(px), round(py), 0)
        x.XSync(display, 0)

    def reveal():
        nonlocal box, units
        box = playback["windows_for"](frame.get_process_id(), scale)
        outer = frame.get_extents(Atspi.CoordType.SCREEN)
        units = min((1, scale), key=lambda i: abs(outer.width * i - box[2] * scale))
        motion((box[0] + box[2] * .3) * scale, (box[1] + box[3] * .55) * scale)
        time.sleep(.05)
        motion((box[0] + box[2] * .32) * scale, (box[1] + box[3] * .55) * scale)
        # The default GtkRevealer slides the entire toolbar before it is clickable.
        time.sleep(.35)
        return slider.get_extents(Atspi.CoordType.SCREEN)

    def move(rect, second):
        motion((rect.x + rect.width * second / 16) * units, (rect.y + rect.height / 2) * units)

    def press(down):
        assert xt.XTestFakeButtonEvent(display, 1, down, 0)
        x.XSync(display, 0)

    def events(offset):
        with log.open("rb") as src:
            src.seek(offset)
            return [int(val) for val in event.findall(src.read())]

    def wait_picture(target):
        until(lambda: playback["picture"](Gdk.get_default_root_window(), box) == target, 5, f"Missing {target} frame")

    def observed(offset):
        result = until(lambda: events(offset), 4, "Missing GStreamer TIME seek")
        return result

    def stamp():
        return log.stat().st_size

    try:
        # One legacy gesture establishes continuous seeking. Exercise three
        # successive completed gestures for the new release behaviour.
        for cycle in range(1, 4 if deferred else 2):
            mark = stamp()
            rect = reveal()
            move(rect, 13)
            press(True)
            press(False)
            click = until(lambda: events(mark), 5,
                          f"Tap missed scale box={(rect.x, rect.y, rect.width, rect.height)}, "
                          f"frame={box}, factor={units}, thumb={slider.get_current_value()}")
            assert len(click) == 1 and 12 <= click[0] <= 14, click
            wait_picture("yellow")

            mark = stamp()
            rect = reveal()
            move(rect, 13)
            press(True)
            samples = []
            try:
                for sec in (12, 11, 10, 9, 8, 7, 6):
                    move(rect, sec)
                    time.sleep(.035)
                    samples.append(round(slider.get_current_value(), 2))
                until(lambda: 0 <= slider.get_current_value() < 10, 2,
                      f"Thumb did not move back, GTK values {samples}, seek events {events(mark)}")
                preview = int(slider.get_current_value())
                held = events(mark)
                if deferred:
                    assert not held, held
                    assert any(re.fullmatch(r"0+:0*" + str(preview), node.get_name()) for node in text), (
                        preview, [node.get_name() for node in text])
                    wait_picture("yellow")
                else:
                    assert held, "The original control should seek before release"
            finally:
                press(False)
            drag = observed(mark)
            assert 0 <= drag[-1] < 10 and (not deferred or drag == [preview]), (drag, preview)
            colour = ("red", "green", "blue", "yellow")[drag[-1] // 4]
            wait_picture(colour)
            print(f"SCRUB_CYCLE scale={scale} deferred={int(deferred)} cycle={cycle} tap={click} "
                  f"while_held={held} final_requests={drag} thumb={preview} pixels={colour}", flush=True)

        mark = stamp()
        assert slider.set_current_value(2), "Accessibility value action refused"
        wait_picture("red")
        assert observed(mark) == [2], events(mark)

        assert slider.grab_focus(), "Cannot focus mapped slider"
        mark = stamp()
        code = x.XKeysymToKeycode(display, 0xff53)  # Right
        assert code and xt.XTestFakeKeyEvent(display, code, 1, 0)
        assert xt.XTestFakeKeyEvent(display, code, 0, 0)
        x.XSync(display, 0)
        keys = observed(mark)
        assert len(keys) == 1 and keys[0] > 2, keys
        print(f"SCRUB_INPUT_PASS scale={scale} accessible=[2] keyboard={keys}", flush=True)
        # Leave enough playing time for the ordinary progress-tick check.
        assert slider.set_current_value(1)
        wait_picture("red")
    finally:
        x.XCloseDisplay(display)
