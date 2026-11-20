"""Tap the installed apps inside the isolated tablet desktop supplied by ambient-namespace.sh."""
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import sys
import time

from probe import Atspi, Gdk, Gio, GLib, LABELS, check_layout, named, tap, value, wait_for


SYSTEM = Gio.BusType.SYSTEM
IFACE = "org.y700.AmbientFixture"
KEY = "automatic-brightness"


def fixture(bus, method, signature=None, *args):
    params = GLib.Variant(signature, args) if signature else None
    return bus.call_sync(IFACE, "/org/y700/AmbientFixture", IFACE, method, params, None,
                         Gio.DBusCallFlags.NO_AUTO_START, 2000, None).unpack()


def desktop_exec(path):
    entry = GLib.KeyFile()
    entry.load_from_file(path, GLib.KeyFileFlags.NONE)
    executable = entry.get_string("Desktop Entry", "Exec")
    assert executable.startswith("/usr/libexec/y700-") and Path(executable).is_file()
    return executable


@contextmanager
def running(command, **options):
    child = subprocess.Popen(command, **options)
    try:
        yield child
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=8)


def wait(condition, label):
    def observe():
        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)
        return condition()
    return wait_for(observe, label)


def ui(lang):
    controls = check_layout(lang)
    title = LABELS[lang][0]
    frame = named(Atspi.get_desktop(0), Atspi.Role.FRAME, title)
    caption = "Automatic brightness" if lang == "en" else "自动亮度"
    toggle = named(frame, Atspi.Role.CHECK_BOX, caption)
    assert toggle is not None, caption
    bounds = toggle.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    assert bounds.width >= 50 and bounds.height >= 56
    return controls, (toggle, bounds), frame


def main():
    assert os.getuid() == 1000 and os.environ["DISPLAY"] == ":76"
    work = Path.home() / "case"
    assert Path("/sys/class/backlight").resolve() == work / "sys/class/backlight"
    assert os.environ["DBUS_SYSTEM_BUS_ADDRESS"] != os.environ["DBUS_SESSION_BUS_ADDRESS"]
    Atspi.init()
    Atspi.set_timeout(2500, 2500)
    assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
    worker = desktop_exec("/etc/xdg/autostart/y700-ambient-backlight.desktop")
    app = desktop_exec("/usr/share/applications/y700-tablet-brightness.desktop")
    settings = Gio.Settings.new("org.y700.tablet")
    assert not settings.get_boolean(KEY)
    bus = Gio.bus_get_sync(SYSTEM, None)
    def state():
        return fixture(bus, "State")
    def level():
        return value("brightness")

    mock = Path(__file__).resolve().parents[1] / "ambient-backlight/check.py"
    with running([sys.executable, "-B", str(mock), worker, str(work), "--serve"]) as service:
        wait(lambda: (work / "ready").exists(), "private services")
        with running([worker]) as daemon:
            with running([app], env=dict(os.environ, LANG="en_US.UTF-8", LANGUAGE="en")):
                controls, toggle, frame = ui("en")
                assert state() == (0, 0) and level() == 400
                tap(*toggle)
                wait(lambda: settings.get_boolean(KEY) and state() == (1, 1) and level() == 161, "10 lux")
                fixture(bus, "Lux", "(d)", 350.0)
                wait(lambda: level() == 1228 and state() == (1, 2), "350 lux")
                wait(lambda: named(frame, Atspi.Role.LABEL, "60%"), "live percentage")
                fixture(bus, "Locked", "(b)", True)
                wait(lambda: state() == (0, 2), "lock release")
                fixture(bus, "Panel", "(b)", False)
                fixture(bus, "Locked", "(b)", False)
                fixture(bus, "Lux", "(d)", 60.0)
                time.sleep(6)
                assert state() == (0, 2) and level() == 1228
                fixture(bus, "Panel", "(b)", True)
                wait(lambda: state()[0] == 1, "lit panel claim")
                tap(*controls[4])  # 25% preset
                wait(lambda: not settings.get_boolean(KEY) and state()[0] == 0 and level() == 511,
                     "manual override")
                count = state()
                fixture(bus, "Lux", "(d)", 1000.0)
                time.sleep(6)
                assert state() == count and level() == 511
                print("AMBIENT_UI 10_lux=161 350_lux=1228 visible=60% manual=511 lock_and_blank=paused",
                      flush=True)
            chinese = dict(os.environ, LANG="zh_CN.UTF-8", LANGUAGE="zh_CN:zh")
            with running([app], env=chinese):
                _, toggle, _ = ui("zh")
                assert not toggle[0].get_state_set().contains(Atspi.StateType.CHECKED)
                tap(*toggle)
                wait(lambda: state()[0] == 1 and settings.get_boolean(KEY), "Chinese toggle")
            with running([app], env=chinese):
                _, toggle, frame = ui("zh")
                assert toggle[0].get_state_set().contains(Atspi.StateType.CHECKED)
                service.terminate()
                service.wait(timeout=8)
                wait(lambda: named(frame, Atspi.Role.LABEL, "正在等待环境光传感器。"), "sensor absent hint")
                before = level()
                tap(*toggle)
                wait(lambda: not settings.get_boolean(KEY), "Chinese toggle off")
                assert level() == before and daemon.poll() is None
                print("AMBIENT_UI english_chinese=pass preference_reopened=yes missing_sensor_hint=yes", flush=True)


if __name__ == "__main__":
    main()
