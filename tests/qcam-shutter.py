"""Click one real qcam shutter in the fixture's private X11 session."""
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Atspi, GdkPixbuf, GLib


def widgets(node):
    yield node
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child is not None:
            yield from widgets(child)


def click_shutter(pid, log):
    desktop = Atspi.get_desktop(0)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        os.kill(pid, 0)
        if log.read_text(errors="replace").count("\nseq:") >= 3:
            try:
                for index in range(desktop.get_child_count()):
                    app = desktop.get_child_at_index(index)
                    if app is None or app.get_process_id() != pid:
                        continue
                    for widget in widgets(app):
                        if widget.get_role() != Atspi.Role.PUSH_BUTTON or widget.get_name() != "Take photo":
                            continue
                        if not widget.get_state_set().contains(Atspi.StateType.ENABLED):
                            continue
                        rect = widget.get_extents(Atspi.CoordType.SCREEN)
                        if rect.width < 44 or rect.height < 44 or min(rect.x, rect.y) < 0:
                            raise RuntimeError("Shutter is outside the window or too small")
                        subprocess.run(["xdotool", "mousemove", str(rect.x + rect.width // 2),
                                        str(rect.y + rect.height // 2), "click", "1"], check=True)
                        return rect.width, rect.height
            except GLib.Error:
                pass
        time.sleep(0.1)
    raise RuntimeError("No enabled and accessible shutter with a running viewfinder")


def verify_photo(pictures, log, model, target):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline and not any(pictures.glob("*.jpg")):
        time.sleep(0.05)
    photo, = pictures.glob("*.jpg")
    try:
        fmt, width, height = GdkPixbuf.Pixbuf.get_file_info(str(photo))
        assert fmt and fmt.get_name() == "jpeg"
        pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(photo))
        assert (pixbuf.get_width(), pixbuf.get_height()) == (width, height)
        with photo.open("rb") as data:
            data.seek(-2, os.SEEK_END)
            assert data.read() == b"\xff\xd9"
        output = log.read_text(errors="replace")
        assert re.search(rf"\(0\) {width}x{height}-\w+", output), "Mismatch with configured stream"
        frames = output.count("\nseq:")
    finally:
        photo.unlink()
    assert not any(pictures.iterdir()), "Unexpected additional output"
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if log.read_text(errors="replace").count("\nseq:") > frames:
            print(f"{model} decoded JPEG {width}x{height}, shutter {target[0]}x{target[1]}, "
                  "preview continued, file removed", flush=True)
            return
        time.sleep(0.1)
    raise RuntimeError("Preview did not continue after shutter")


if __name__ == "__main__":
    pid, model, log, pictures = sys.argv[1:]
    root = Path(os.environ["HOME"])
    directory = Path(pictures)
    assert root.parent.parent == Path("/dev/shm") and root.parent.name.startswith("qcam-photo.")
    assert directory.resolve() == root / "照片" and not any(directory.iterdir())
    print(f"{model} waiting for preview and shutter", flush=True)
    target = click_shutter(int(pid), Path(log))
    print(f"{model} clicked once", flush=True)
    verify_photo(directory, Path(log), model, target)
