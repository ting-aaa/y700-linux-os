"""Open the installed display controls on the enrolled user's Xfce seat."""

from contextlib import contextmanager
import os
from pathlib import Path
import signal
import subprocess

from probe import Atspi, Gdk, GLib, named, wait_for


@contextmanager
def open_control(program, role, name):
    desktop = Path("/usr/share/applications") / f"{program}.desktop"
    subprocess.run(["gio", "launch", str(desktop)], check=True, timeout=20)
    expected = f"/usr/libexec/{program}".encode()

    def find():
        screen = Atspi.get_desktop(0)
        for index in range(screen.get_child_count()):
            app = screen.get_child_at_index(index)
            if app is None:
                continue
            try:
                pid = app.get_process_id()
                cmd = (Path("/proc") / str(pid) / "cmdline").read_bytes()
                if expected in cmd.split(b"\0"):
                    control = named(app, role, name)
                    if control is not None:
                        return pid, control
            except (FileNotFoundError, ProcessLookupError, GLib.Error):
                continue

    pid, control = wait_for(find, program, timeout=55)
    try:
        yield control
    finally:
        os.kill(pid, signal.SIGTERM)


def preference():
    return subprocess.check_output(
        ["gsettings", "get", "org.y700.chromium", "hardware-acceleration"], text=True
    ).strip()


def main():
    assert os.getuid() == 1000 and os.environ["XDG_CURRENT_DESKTOP"] == "XFCE"
    Atspi.init()
    assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
    with open_control("y700-tablet-brightness", Atspi.Role.SLIDER, "Screen brightness") as slider:
        assert (slider.get_minimum_value(), slider.get_maximum_value()) == (5, 100)
        assert slider.get_extents(Atspi.CoordType.SCREEN).height >= 56
    assert preference() == "false"
    with open_control("y700-chromium-graphics", Atspi.Role.CHECK_BOX, "Use GPU acceleration in Chromium") as toggle:
        for label, expected in (("ON", "true"), ("OFF", "false")):
            rect = toggle.get_extents(Atspi.CoordType.SCREEN)
            assert rect.height >= 64
            print(f"COMBINED_GPU_{label}_BUTTON {2 * rect.x + rect.width} {2 * rect.y + rect.height}", flush=True)
            wait_for(lambda: preference() == expected, f"touch toggle {label}", timeout=40)
    print("COMBINED_SETTINGS brightness_slider=5..100 gpu_toggle=off,on,off gtk_scale=2 ordinary=1", flush=True)


if __name__ == "__main__":
    main()
