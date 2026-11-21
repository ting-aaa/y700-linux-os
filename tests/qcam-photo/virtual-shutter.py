"""Operate one packaged qcam instance through its Qt chooser and shutter."""

import os
from pathlib import Path
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Atspi, GdkPixbuf, GLib


CAMERAS = {
    "main": ("/base/soc@0/cci@ac15000/i2c-bus@0/camera@20", "Rear main camera", 800, 600),
    "front": ("/base/soc@0/cci@ac15000/i2c-bus@1/camera@10", "Front camera", 640, 480),
    "macro": ("/base/soc@0/cci@ac16000/i2c-bus@0/camera@36", "Rear macro camera", 320, 240),
}
CHINESE_NAMES = {"main": "后置主摄", "front": "前置摄像头", "macro": "后置微距"}


def run(*args):
    return subprocess.check_output(args, text=True, timeout=5).strip()


def wait_for(check, label, seconds=18):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (GLib.Error, subprocess.CalledProcessError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for {label}")


def walk(node):
    yield node
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child is not None:
            yield from walk(child)


class CameraWindow:
    def __init__(self, pid, modern, chinese):
        self.pid = pid
        self.modern = modern
        self.shutter = "拍照" if chinese else "Take photo"
        self.accept = "确定" if chinese and modern else "OK"
        Atspi.init()
        desktop = Atspi.get_desktop(0)

        def application():
            for index in range(desktop.get_child_count()):
                app = desktop.get_child_at_index(index)
                if app is not None and app.get_process_id() == self.pid:
                    return app

        self.app = wait_for(application, "qcam on the accessibility bus", seconds=120)
        title = "选择镜头" if chinese else "Select camera"
        frame = self.find(Atspi.Role.DIALOG, title) if modern else self.find(Atspi.Role.FRAME)
        window, = run("xdotool", "search", "--all", "--onlyvisible", "--pid", str(pid),
                      "--name", f"^{title}$" if modern else "^QCam").splitlines()
        geometry = dict(line.split("=", 1) for line in
                        run("xdotool", "getwindowgeometry", "--shell", window).splitlines())
        rect = frame.get_extents(Atspi.CoordType.SCREEN)
        self.scale = round(int(geometry["WIDTH"]) / rect.width)
        assert self.scale == 2 and abs(rect.width * self.scale - int(geometry["WIDTH"])) <= 4

    def find(self, role, name=None):
        def search():
            os.kill(self.pid, 0)
            for node in walk(self.app):
                if node.get_role() != role or (name is not None and node.get_name() != name):
                    continue
                if node.get_state_set().contains(Atspi.StateType.SHOWING):
                    return node

        try:
            return wait_for(search, f"{role.value_nick} {name!r} in PID {self.pid}")
        except RuntimeError:
            for node in walk(self.app):
                print(f"QCAM_TREE {node.get_role_name()} {node.get_name()!r}", flush=True)
            raise

    def click(self, node):
        role, name = node.get_role_name(), node.get_name()
        rect = node.get_extents(Atspi.CoordType.SCREEN)
        assert rect.width > 0 and rect.height > 0, (rect.x, rect.y, rect.width, rect.height)
        x = round((rect.x + rect.width / 2) * self.scale)
        y = round((rect.y + rect.height / 2) * self.scale)
        assert 0 <= x < 1600 and 0 <= y < 2560, (x, y)
        if self.modern or name == self.shutter:
            assert rect.height * self.scale >= 96, (name, rect.height, self.scale)
        if name == self.shutter:
            assert rect.width * self.scale >= 224
        run("xdotool", "mousemove", str(x), str(y), "click", "1")
        print(f"QCAM_TAP {role} {name!r} x={x} y={y} "
              f"height={rect.height * self.scale}", flush=True)

    def choose(self, requested, current=None):
        if current:
            self.click(self.find(Atspi.Role.PUSH_BUTTON, current))
        chooser = self.find(Atspi.Role.COMBO_BOX)
        if self.modern and current:
            assert chooser.get_name() == current, (chooser.get_name(), current)
        self.click(chooser)
        # The address suffix matches the board's main camera but the full ID
        # does not. The chooser must leave the external camera name intact.
        self.find(Atspi.Role.LIST_ITEM, "/fixture/unknown/camera@20")
        self.click(self.find(Atspi.Role.LIST_ITEM, requested))
        self.click(self.find(Atspi.Role.PUSH_BUTTON, self.accept))
        self.find(Atspi.Role.PUSH_BUTTON, requested)


def generate_marker(path):
    # Generate a known scene without any input file or device.
    scene = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, False, 8, 320, 240)
    scene.fill(0xd32d29ff)
    scene.new_subpixbuf(160, 0, 160, 240).fill(0x29bc48ff)
    scene.savev(path, "jpeg", ["quality"], ["97"])


def check_bars(row):
    # The eight bars rotate horizontally. Ignore JPEG chroma transitions.
    expected = ("111", "110", "011", "010", "101", "100", "001", "000")
    segments = []
    for rgb in row:
        color = "".join("1" if channel > 127 else "0" for channel in rgb)
        if segments and segments[-1][0] == color:
            segments[-1][1] += 1
        else:
            segments.append([color, 1])
    bars = [segment for segment in segments if segment[1] >= 10]
    if len(bars) > 1 and bars[0][0] == bars[-1][0]:
        _, length = bars.pop()
        bars[0][1] += length
    assert len(bars) == 8 and all(65 <= length <= 125 for _, length in bars), bars
    assert tuple(color for color, _ in bars) in [expected[i:] + expected[:i] for i in range(8)]


def check_photo(photo, lens):
    _, _, expected_width, expected_height = CAMERAS[lens]
    fmt, width, height = GdkPixbuf.Pixbuf.get_file_info(str(photo))
    assert fmt.get_name() == "jpeg" and (width, height) == (expected_width, expected_height)
    pixels = GdkPixbuf.Pixbuf.new_from_file(str(photo))
    assert pixels.get_n_channels() == 3 and photo.read_bytes().endswith(b"\xff\xd9")
    data, stride = pixels.get_pixels(), pixels.get_rowstride()

    def rgb(x, y):
        start = y * stride + x * 3
        return data[start:start + 3]

    if lens == "main":
        check_bars(rgb(x, height // 2) for x in range(width))
    elif lens == "front":
        # A 64-pixel vertical displacement inverts the monochrome diagonal
        # stripes. One horizontal and one vertical pixel advance the same phase.
        for x in range(0, width - 1, 7):
            a, b = rgb(x, 100), rgb(x, 164)
            assert max(a) - min(a) < 8 and max(b) - min(b) < 8
            assert (a[0] > 127) != (b[0] > 127)
            assert (rgb(x + 1, 100)[0] > 127) == (rgb(x, 101)[0] > 127)
    else:
        for y in (30, 110, 220):
            left, right = rgb(80, y), rgb(240, y)
            assert left[0] > max(left[1:]) + 90 and right[1] > max(right[0], right[2]) + 65
    print(f"QCAM_JPEG lens={lens} width={width} height={height} pattern=verified", flush=True)


def main(pid, version, app_locale):
    pictures = Path(os.environ["HOME"]) / "Pictures"
    assert not pictures.exists(), "fixture must start with a fresh Pictures directory"
    log = pictures.parent.parent / "qcam.log"
    modern, chinese = not version.endswith(".y7003"), app_locale.startswith("zh")
    window = CameraWindow(pid, modern, chinese)
    labels = {lens: data[int(modern)] for lens, data in CAMERAS.items()}
    if modern and chinese:
        labels = CHINESE_NAMES
    if modern:
        window.choose(labels["main"])
        print("QCAM_STARTUP_CHOOSER main selected without --camera", flush=True)
    current = "main"
    captured = set()
    for lens in ("main", "front", "macro", "main"):
        ui_label = labels[lens]
        if current != lens:
            before = log.stat().st_size
            window.choose(ui_label, labels[current])
            expected = f"Switching to camera {CAMERAS[lens][0]}".encode()
            wait_for(lambda: expected in log.read_bytes()[before:].replace(b'"', b""),
                     "backend switch to the requested camera")
        else:
            window.find(Atspi.Role.PUSH_BUTTON, ui_label)
        before = log.stat().st_size
        wait_for(lambda: log.read_bytes()[before:].count(b"\nseq:") >= 3, "three live frames")
        if version.endswith((".y7005", ".y7006")):
            focus_label = "对焦" if chinese else "Focus"
            assert not any(node.get_role() == Atspi.Role.PUSH_BUTTON
                           and node.get_name() == focus_label
                           and node.get_state_set().contains(Atspi.StateType.SHOWING)
                           for node in walk(window.app)), "focus button on a fixed-focus source"
        window.click(window.find(Atspi.Role.PUSH_BUTTON, window.shutter))
        photo, = wait_for(lambda: set(pictures.glob("*.jpg")) - captured, "a newly published JPEG")
        check_photo(photo, lens)
        captured.add(photo)
        before = log.stat().st_size
        wait_for(lambda: log.read_bytes()[before:].count(b"\nseq:") >= 3, "preview after shutter")
        assert set(pictures.iterdir()) == captured
        print(f"QCAM_PREVIEW pid={pid} lens={lens} continued=yes", flush=True)
        current = lens
    assert len(captured) == 4
    for photo in captured:
        photo.unlink()
    print("Y700_QCAM_VIRTUAL_LENS_PASS switches=3 shutters=4 published=4 "
          "same_process=yes preview_continued=yes", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "--generate":
        generate_marker(sys.argv[2])
    else:
        main(int(sys.argv[1]), sys.argv[2], sys.argv[3])
