"""Tap the packaged Qt shutter and verify its synthetic JPEG independently."""

import os
from pathlib import Path
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Atspi, GdkPixbuf, GLib


def find_shutter(node):
    if node.get_role() == Atspi.Role.PUSH_BUTTON and node.get_name() == "Take photo":
        return node if node.get_state_set().contains(Atspi.StateType.ENABLED) else None
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child is not None and (shutter := find_shutter(child)) is not None:
            return shutter
    return None


def run(*args):
    return subprocess.check_output(args, text=True, timeout=5).strip()


def wait_for(check, label, seconds=22):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (GLib.Error, subprocess.CalledProcessError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f"Timed out: {label}")


def click(pid):
    Atspi.init()
    desktop = Atspi.get_desktop(0)

    def bounds():
        os.kill(pid, 0)
        for index in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(index)
            if app is None or app.get_process_id() != pid:
                continue
            for child in range(app.get_child_count()):
                top = app.get_child_at_index(child)
                if top is not None and (shutter := find_shutter(top)) is not None:
                    return top.get_extents(Atspi.CoordType.SCREEN), shutter.get_extents(Atspi.CoordType.SCREEN)
        return None

    frame, button = wait_for(bounds, "enabled shutter on qcam's accessibility tree")
    [window] = run("xdotool", "search", "--all", "--onlyvisible", "--pid", str(pid), "--name", "^QCam").splitlines()
    geo = dict(line.split("=", 1) for line in run("xdotool", "getwindowgeometry", "--shell", window).splitlines())
    scale = round(int(geo["WIDTH"]) / frame.width)
    assert scale in (1, 2) and abs(frame.width * scale - int(geo["WIDTH"])) <= 4
    assert button.width * scale >= 112 * 2 and button.height * scale >= 48 * 2, (scale, button.width, button.height)
    x = round((button.x - frame.x + button.width / 2) * scale)
    y = round((button.y - frame.y + button.height / 2) * scale)
    assert 0 <= x < int(geo["WIDTH"]) and 0 <= y < int(geo["HEIGHT"]), (x, y, geo)
    run("xdotool", "mousemove", "--window", window, str(x), str(y), "click", "1")
    print(f"QCAM_VIRTUAL_TAP width={button.width * scale} height={button.height * scale} x={x} y={y}", flush=True)


def check_bars(photo):
    # ColourBarsGenerator rotates its eight bars horizontally each frame.
    # Compare their cyclic order and width, independent of the capture phase.
    expected = ("111", "110", "011", "010", "101", "100", "001", "000")
    fmt, width, height = GdkPixbuf.Pixbuf.get_file_info(str(photo))
    assert fmt.get_name() == "jpeg" and (width, height) == (800, 600)
    pixels = GdkPixbuf.Pixbuf.new_from_file(str(photo))
    layout = pixels.get_pixels()
    channels = pixels.get_n_channels()
    assert channels == 3
    offset = pixels.get_rowstride() * (height // 2)
    segments = []
    for x in range(width):
        rgb = layout[offset + x * channels:offset + (x + 1) * channels]
        color = "".join("1" if channel > 127 else "0" for channel in rgb)
        if segments and segments[-1][0] == color:
            segments[-1][1] += 1
        else:
            segments.append([color, 1])
    # Chroma interpolation may add short colour transitions at bar boundaries.
    bars = [segment for segment in segments if segment[1] >= 10]
    if len(bars) > 1 and bars[0][0] == bars[-1][0]:
        _, length = bars.pop()
        bars[0][1] += length
    assert len(bars) == 8 and all(65 <= length <= 125 for _, length in bars), bars
    color_order = tuple(color for color, _ in bars)
    assert color_order in [expected[i:] + expected[:i] for i in range(8)], bars
    assert photo.read_bytes().endswith(b"\xff\xd9")
    print(f"QCAM_VIRTUAL_JPEG width={width} height={height} colour_bars={len(bars)} complete=yes", flush=True)


def main():
    pid = int(sys.argv[1])
    pictures = Path(os.environ["HOME"]) / "Pictures"
    assert not pictures.exists(), "fixture must start without a Pictures directory"
    log = Path(os.environ["HOME"]).parent / "qcam.log"
    wait_for(lambda: log.read_text(errors="replace").count("\nseq:") >= 3, "live camera frames")
    click(pid)
    [photo] = wait_for(lambda: list(pictures.glob("*.jpg")), "a single JPEG")
    check_bars(photo)
    before = log.read_text(errors="replace").count("\nseq:")
    wait_for(lambda: log.read_text(errors="replace").count("\nseq:") >= before + 3,
             "preview retains three more frames")
    time.sleep(0.4)
    assert list(pictures.iterdir()) == [photo]
    photo.unlink()
    print("Y700_QCAM_VIRTUAL_SHUTTER_PASS clicks=1 published=1 preview_continued=yes", flush=True)


if __name__ == "__main__":
    main()
