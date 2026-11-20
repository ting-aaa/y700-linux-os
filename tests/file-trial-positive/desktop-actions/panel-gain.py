"""Measure and restore the default VM sink's numerical gain by real touchscreen taps."""
from collections import Counter
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

import panel


def track(menu):
    import gi
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk

    switch_x, switch_y = panel.output_switch(menu)
    root = Gdk.get_default_root_window()
    bitmap = Gdk.pixbuf_get_from_window(root, 0, 0, root.get_width(), root.get_height())
    if (bitmap.get_width(), bitmap.get_height()) != (1024, 768):
        raise RuntimeError("Unexpected captured X11 display scale")
    pixels = bitmap.get_pixels()
    stride = bitmap.get_rowstride()
    channels = bitmap.get_n_channels()

    def rgb(x, y):
        i = y * stride + x * channels
        return pixels[i:i+3]

    _, (x, y, width, _) = menu
    scale = root.get_scale_factor()
    # In the first output row the themed volume rail is between the speaker
    # icon and the mute switch. Measure the actual painted rail on this display.
    left, right = x + 32 * scale, switch_x - 27 * scale
    if not (x < left < right < x + width):
        raise RuntimeError("Invalid speaker menu content geometry")
    # Sample the same scanline outside the rail, including GTK-selected rows.
    sample_x = [*range(left, left + 4 * scale), *range(right - 4 * scale, right)]
    def backdrop(yy):
        return Counter(rgb(xx, yy) for xx in sample_x).most_common(1)[0][0]

    best = None
    for yy in range(max(y + 4 * scale, switch_y - 10 * scale), switch_y + 13 * scale):
        background = backdrop(yy)
        ink = [xx for xx in range(left, right)
               if sum(abs(a - b) for a, b in zip(rgb(xx, yy), background)) > 45]
        if len(ink) < 55 * scale or ink[0] == left or ink[-1] == right - 1:
            continue
        if best is None or len(ink) > best[0]:
            best = len(ink), ink[0], ink[-1], yy
    if not best:
        raise RuntimeError("Could not identify horizontal output rail")
    _, left, right, y = best
    # Only the round handle extends this far above/below the horizontal
    # track. Save its initial centre for touch-only restoration, including
    # when a later audio observation fails.
    for yy in (y - 6 * scale, y + 6 * scale):
        background = backdrop(yy)
        outline = [xx for xx in range(left, right + 1)
                   if sum(abs(a - b) for a, b in zip(rgb(xx, yy), background)) > 45]
        if outline and 5 * scale <= outline[-1] - outline[0] <= 28 * scale:
            handle = (outline[0] + outline[-1] + 1) // 2
            print(f"PANEL_OUTPUT_RAIL left={left} right={right} y={y} handle={handle}", flush=True)
            return left, right, y, handle
    raise RuntimeError("Could not identify the initial output slider handle")


def sample():
    volume, muted = panel.audio_state()
    return Decimal(volume), muted


def sink_snapshot():
    props = panel.run("wpctl", "inspect", panel.DEFAULT)
    object_id = re.search(r"^id (\d+),", props)[1]
    objects = json.loads(panel.run("pw-dump", object_id))
    data = next((item for item in objects if item["id"] == int(object_id)
                 and item.get("info", {}).get("props", {}).get("node.name") == "auto_null"), None)
    if not data:
        raise RuntimeError("No matching auto_null playback node in PipeWire")
    for param in data["info"]["params"]["Props"]:
        if "channelVolumes" in param and "mute" in param:
            return data["info"]["state"], (object_id, tuple(param["channelVolumes"]), param["mute"])
    raise RuntimeError("PipeWire did not expose playback channel volume")


def gain_test():
    panel.wait_for(lambda: sink_snapshot()[0] == "running", "negotiated virtual playback")
    pid, rect = panel.wait_for(panel.speaker_button, "running top speaker")
    x, y, w, h = rect
    initial, muted = sample()
    original = sink_snapshot()[1]
    if panel.owner_menu(pid):
        raise RuntimeError("Expected the speaker menu to start closed")
    panel.tap(x + w // 2, y + h // 2)
    menu = panel.wait_for(lambda: panel.owner_menu(pid), "real speaker menu")
    measured = []

    def tap_gain(px, before):
        time.sleep(0.5)
        panel.tap(px, row)
        def changed():
            value, is_muted = sample()
            if is_muted:
                raise RuntimeError("Numerical slider changed mute")
            return (value,) if value != before else None
        return panel.wait_for(changed, "numerical gain response", 10)[0]

    def set_original_mute(wanted):
        if sample()[1] != wanted:
            time.sleep(0.6)
            panel.tap(*panel.output_switch(menu))
            panel.wait_for(lambda: sample()[1] == wanted, "mute switch state", 14)

    try:
        if muted:
            set_original_mute(False)
        left, right, row, handle = track(menu)
        unmuted = sink_snapshot()[1]
        span = right - left
        points = [left + round(span * fraction) for fraction in (0.22, 0.52)]
        if abs(points[0] - handle) < 4:
            points[0] = left + round(span * 0.12)
        try:
            before = initial
            for px in points:
                value = tap_gain(px, before)
                measured.append(value)
                before = value
                print(f"PANEL_GAIN_OBSERVED x={px} gain={value} mute=0", flush=True)
            if measured[1] - measured[0] <= Decimal("0.03"):
                raise RuntimeError("Slider did not produce two increasing gains")
        finally:
            if sample() != (initial, False) or sink_snapshot()[1] != unmuted:
                offsets = [0]
                for radius in range(1, 9):
                    offsets.extend((-radius, radius))
                for offset in offsets:
                    time.sleep(0.5)
                    panel.tap(max(left, min(right, handle + offset)), row)
                    time.sleep(0.4)
                    if sample() == (initial, False) and sink_snapshot()[1] == unmuted:
                        break
                else:
                    raise RuntimeError("Real slider could not restore original channel gains")
    finally:
        try:
            set_original_mute(muted)
        finally:
            if panel.owner_menu(pid):
                panel.tap(4, 740)
            panel.wait_for(lambda: not panel.owner_menu(pid), "closed speaker menu")
    if sample() != (initial, muted) or panel.sink_info() != "auto_null" or sink_snapshot()[1] != original:
        raise RuntimeError("Original default virtual sink changed")
    print(f"PANEL_TOUCH_GAIN_PASS input=type-b sink=auto_null initial={initial} "
          f"measured={measured[0]},{measured[1]} restored={initial} "
          f"raw_channels={original[1]} restored_mute={int(muted)}", flush=True)


def main():
    if os.getuid() == 0 or b"linux,dummy-virt" not in Path("/proc/device-tree/compatible").read_bytes().split(b"\0"):
        raise RuntimeError("Requires the ordinary account on the test VM desktop")
    if panel.wait_for(panel.sink_info, "VM default sink") != "auto_null":
        raise RuntimeError("Expected ordinary user on the default silent test sink")
    # Keep a negotiated PCM format while the Pulse plugin changes volume.
    # This playback is digital zero and is routed only to the virtual sink.
    with open("/dev/zero", "rb") as silence:
        stream = subprocess.Popen(["pw-cat", "--playback", "--raw", "--target", "auto_null",
                                  "--rate", "48000", "--channels", "2", "--format", "s16", "-"],
                                  stdin=silence, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            panel.wait_for(lambda: sink_snapshot()[0] == "running", "active silent audio node")
            if stream.poll() is not None:
                raise RuntimeError("Silent virtual playback could not start")
            panel.main()
            gain_test()
        finally:
            stream.terminate()
            stream.wait(timeout=10)


if __name__ == "__main__":
    def timed_out(signum, frame):
        raise TimeoutError("Numerical volume test exceeded its wall-clock budget")
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(175 + panel.ALLOCATION_WAIT)
    main()
