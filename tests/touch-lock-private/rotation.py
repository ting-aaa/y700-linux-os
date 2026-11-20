"""Observe the packaged rotation client across a real Xfce/PAM lock cycle."""
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time

from gi.repository import Gio, GLib


SETTLE = 3.5
SAVER = "org.xfce.ScreenSaver"
SAVER_PATH = "/org/xfce/ScreenSaver"


def main():
    assert os.geteuid() == 47319 and not os.getgroups()
    assert os.environ["DISPLAY"] == ":73" and not Path("/run/dbus/system_bus_socket").exists()
    root = Path("/qa/rotation")
    supports = runpy.run_path(str(root / "providers.py"))
    # A private bus is visible only to this witness and the rotation client.
    # The actual saver and PAM dialog keep their normal private desktop bus.
    bus = subprocess.check_output(["dbus-daemon", "--session", "--fork", "--print-address=1"], text=True).strip()
    os.environ["DBUS_SYSTEM_BUS_ADDRESS"] = bus
    os.environ["XDG_SESSION_ID"] = "c42"
    assert bus != os.environ["DBUS_SESSION_BUS_ADDRESS"]
    login = supports["Provider"](supports["LOGIN"])
    login.object(supports["LOGIN_PATH"], supports["LOGIN"] + ".Manager", supports["MANAGER_API"])
    login.object(supports["SESSION_PATH"], supports["LOGIN"] + ".Session", supports["SESSION_API"],
                 Active=True, LockedHint=False)
    login.publish()
    sensor, pose = supports["sensor_with"]("left-up")
    session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    saver = Gio.DBusProxy.new_sync(session_bus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
                                   SAVER, SAVER_PATH, SAVER, None)
    assert saver.get_name_owner()

    def active():
        return saver.call_sync("GetActive", None, Gio.DBusCallFlags.NO_AUTO_START, 3000, None).unpack()[0]

    changes = []
    def changed(_proxy, _sender, signal, data):
        if signal == "ActiveChanged":
            changes.append(data.unpack()[0])
    saver.connect("g-signal", changed)
    assert not active()
    with tempfile.TemporaryDirectory(prefix="rotation-lock-") as tmp:
        work = Path(tmp)
        log = work / "calls"
        log.touch()
        helper = work / "y700-display"
        helper.write_text('#!/bin/sh\nset -eu\nread -r time idle < /proc/uptime\n'
                          'printf "%s %s %s 0\\n" "$time" "$1" "$2" >> "$ROTATION_LOG"\n')
        helper.chmod(0o755)
        env = dict(os.environ, XDG_SESSION_TYPE="x11", GSETTINGS_BACKEND="keyfile",
                   XDG_CONFIG_HOME=str(work / "config"), GSETTINGS_SCHEMA_DIR=str(root),
                   ROTATION_LOG=str(log), PATH=f"{work}:{os.environ['PATH']}")
        subprocess.run(["gsettings", "set", "org.y700.tablet", "auto-rotate", "true"], env=env, check=True)
        client = subprocess.Popen([sys.executable, "-B", str(root / "y700-auto-rotate.py"),
                                   "--session", "--settle", str(SETTLE)], env=env)
        check = supports["Checks"](client, log)
        try:
            check.applied("left", timeout=18)
            assert login.count("GetSession") == 1 and len(sensor.claimants) == 1
            original, = sensor.claimants
            before = sensor.count("ClaimAccelerometer")
            pose(AccelerometerOrientation="right-up")
            sent = time.monotonic()
            check.wait(.25)
            subprocess.run(["xfce4-screensaver-command", "--lock"], check=True)
            check.until(lambda: changes == [True] and active(), "native saver activated")
            check.until(lambda: not sensor.claimants and sensor.count("ReleaseAccelerometer") > 0,
                        "lease released during the native lock", timeout=SETTLE + 1)
            delay = time.monotonic() - sent
            assert delay < SETTLE, f"lock did not preempt the pending pose (elapsed {delay:.2f}s)"
            pose(AccelerometerOrientation="bottom-up")
            check.wait(SETTLE + .4)
            check.verify()
            assert active() and not sensor.claimants and sensor.count("ClaimAccelerometer") == before
            print(f"ROTATION_LOCK_HELD real_saver=active logind_hint=false pending=right "
                  f"released_before_settle={delay:.2f}s simulated_locked_pose=inverted helper_calls=left", flush=True)
            (Path(os.environ["XDG_RUNTIME_DIR"]) / "rotation-lock-checked").touch()
            deadline = time.monotonic() + 95
            while changes == [True] and time.monotonic() < deadline:
                check.pump()
                if sensor.claimants:
                    assert not active(), "sensor reacquired while Xfce still reported an active lock"
                if active():
                    check.verify()
            assert changes == [True, False] and not active(), f"unexpected saver transitions {changes}"
            check.applied("inverted", timeout=SETTLE + 5)
            assert len(sensor.claimants) == 1 and original not in sensor.claimants
            assert sensor.count("ClaimAccelerometer") == before + 1
            print("ROTATION_LOCK_RESUMED real_saver=inactive logind_hint=false fresh_lease=1 "
                  "helper_calls=left,inverted stale_right=absent", flush=True)
        finally:
            client.terminate()
            context = GLib.MainContext.default()
            end = time.monotonic() + 5
            while client.poll() is None and time.monotonic() < end:
                context.iteration(False)
                time.sleep(.02)
            if client.poll() is None:
                client.kill()
            client.wait()
            sensor.bus.close_sync(None)
            login.bus.close_sync(None)


if __name__ == "__main__":
    main()
