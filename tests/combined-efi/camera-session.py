"""Observe the installed, camera-free qcam chooser on the enrolled Xfce seat."""

import os
from pathlib import Path
import re
import subprocess
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib


def children(node):
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child is not None:
            yield child
            yield from children(child)


def main():
    assert os.getuid() != 0 and os.environ["XDG_CURRENT_DESKTOP"] == "XFCE"
    assert not Path("/dev/media0").exists()
    env = dict(os.environ, LC_ALL="C.UTF-8", QT_SCALE_FACTOR="2", QT_LINUX_ACCESSIBILITY_ALWAYS_ON="1")
    subprocess.run(["gio", "launch", "/usr/share/applications/org.y700.Camera.desktop"],
                   env=env, check=True, timeout=15)
    Atspi.init()
    desktop = Atspi.get_desktop(0)
    deadline = time.monotonic() + 80
    seen = set()
    while time.monotonic() < deadline:
        try:
            for i in range(desktop.get_child_count()):
                app = desktop.get_child_at_index(i)
                if app is None:
                    continue
                proc = Path("/proc") / str(app.get_process_id())
                if (proc / "exe").resolve() != Path("/opt/y700-camera/bin/qcam"):
                    continue
                roles = {(node.get_role(), node.get_name()): node for node in children(app)
                         if node.get_state_set().contains(Atspi.StateType.SHOWING)}
                seen.update(name for role, name in roles if role in (Atspi.Role.DIALOG, Atspi.Role.PUSH_BUTTON))
                dialog = roles.get((Atspi.Role.DIALOG, "Select camera"))
                cancel = roles.get((Atspi.Role.PUSH_BUTTON, "Cancel"))
                if dialog is not None and cancel is not None:
                    return exercise(proc, dialog, cancel)
        except (FileNotFoundError, GLib.Error):
            pass
        time.sleep(0.25)
    raise TimeoutError(f"Packaged camera chooser missing on the accessibility bus, observed controls {sorted(seen)}")


def exercise(proc, dialog, cancel):
    maps = (proc / "maps").read_text()
    assert "/opt/y700-camera/lib/libcamera.so.0.7.2" in maps
    assert "/qt6/plugins/platforms/libqxcb.so" in maps
    assert b"QT_SCALE_FACTOR=2" in (proc / "environ").read_bytes().split(b"\0")
    window = subprocess.check_output(["xwininfo", "-name", "Select camera"], text=True, timeout=8)
    width = int(re.search(r"(?m)^\s*Width:\s*(\d+)\s*$", window)[1])
    rect = dialog.get_extents(Atspi.CoordType.SCREEN)
    assert abs(width - 2 * rect.width) <= 4, (width, rect.width)
    button = cancel.get_extents(Atspi.CoordType.SCREEN)
    assert button.height * 2 >= 96
    x = round((button.x + button.width / 2) * 2)
    y = round((button.y + button.height / 2) * 2)
    print(f"COMBINED_CAMERA_GEOMETRY width_px={width} width_logical={rect.width} button_height_px={button.height * 2}", flush=True)
    print(f"COMBINED_CAMERA_BUTTON {x} {y}", flush=True)
    deadline = time.monotonic() + 45
    while (proc / "exe").exists() and time.monotonic() < deadline:
        time.sleep(0.15)
    assert not (proc / "exe").exists(), "Touching Cancel must close the camera chooser"
    print("COMBINED_CAMERA_TOUCH ordinary=1 qt_scale=2 chooser_cancelled=1", flush=True)


if __name__ == "__main__":
    main()
