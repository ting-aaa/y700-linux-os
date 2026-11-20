"""Hold back Xfce's Terminate reply and plugin registration on a private bus."""

import os
from pathlib import Path
import subprocess
import sys
import time

from gi.repository import Gio, GLib


PANEL = "/org/xfce/Panel"
WRAPPERS = PANEL + "/Wrapper"
MARKER = Path(os.environ["XDG_STATE_HOME"]) / "y700/panel-audio-v1"
QUERY = ("xfconf-query", "-c", "xfce4-panel", "-p")


def set_property(path, *args):
    subprocess.run([*QUERY, path, "-n", *args], check=True, timeout=5)


def interface(name, body=""):
    return Gio.DBusNodeInfo.new_for_xml(
        f'<node><interface name="{name}">{body}</interface></node>'
    ).interfaces[0]


def check(helper, existing):
    set_property("/panels", "-a", "-t", "int", "-s", "1")
    set_property("/plugins/plugin-1", "-t", "string", "-s", "systray")
    members = ["-a", "-t", "int", "-s", "1"]
    if existing:
        set_property("/plugins/plugin-2", "-t", "string", "-s", "pulseaudio")
        members.extend(["-t", "int", "-s", "2"])
    set_property("/panels/panel-1/plugin-ids", *members)

    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    requested, = bus.call_sync(
        "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "RequestName",
        GLib.Variant("(su)", ("org.xfce.Panel", 4)), None,
        Gio.DBusCallFlags.NONE, 3000,
    ).unpack()
    assert requested == 1
    terminations = []

    def terminate(_conn, _sender, _path, _interface, method, args, invocation):
        assert method == "Terminate"
        # Retain the invocation and deliberately leave it unanswered.
        terminations.append((args.unpack(), invocation))

    panel_api = interface("org.xfce.Panel", '<method name="Terminate"><arg type="b" direction="in"/></method>')
    wrapper_api = interface("org.y700.TestWrapper", '<method name="Unused"/>')
    bus.register_object(PANEL, panel_api, terminate)
    bus.register_object(WRAPPERS, wrapper_api, None)
    proc = subprocess.Popen([helper])
    context = GLib.MainContext.default()

    def pump():
        while context.pending():
            context.iteration(False)
        time.sleep(0.03)

    try:
        deadline = time.monotonic() + (4 if existing else 15)
        saw_request = False
        # Exceed the old three-second synchronous D-Bus timeout.
        while time.monotonic() < deadline:
            pump()
            assert not MARKER.exists(), "marker written before Wrapper/2 appeared"
            assert proc.poll() is None, f"helper exited early: {proc.returncode}"
            if not existing and terminations and not saw_request:
                saw_request = True
                deadline = time.monotonic() + 4
        if existing:
            assert not terminations, "restarted panel for an existing configured applet"
        else:
            assert len(terminations) == 1, terminations
            args, invocation = terminations[0]
            assert args == (True,), args
            message = invocation.get_message()
            assert message.get_destination() == bus.get_unique_name()
            assert message.get_flags() & Gio.DBusMessageFlags.NO_REPLY_EXPECTED

        # A directly registered sibling must not satisfy this applet's wait.
        bus.register_object(WRAPPERS + "/3", wrapper_api, None)
        stop = time.monotonic() + 0.45
        while time.monotonic() < stop:
            pump()
            assert not MARKER.exists()
        bus.register_object(WRAPPERS + "/2", wrapper_api, None)
        stop = time.monotonic() + 8
        while proc.poll() is None and time.monotonic() < stop:
            pump()
        assert proc.poll() == 0 and MARKER.is_file(), "registered wrapper must complete migration"
        raw = subprocess.check_output([*QUERY, "/panels/panel-1/plugin-ids"], text=True, timeout=5)
        assert [line for line in raw.splitlines() if line.isdecimal()] == ["1", "2"], raw
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=3)
    print(f"PANEL_TIMING_PASS existing={int(existing)} terminate_calls={len(terminations)} marker_after_wrapper=yes")


if __name__ == "__main__":
    check(sys.argv[1], sys.argv[2] == "existing")
