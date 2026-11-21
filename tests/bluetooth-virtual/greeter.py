"""Read the focused username entry of the actual Arctica/LightDM greeter."""
from contextlib import contextmanager
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
import time


def greeter_environment():
    names = subprocess.run(["pgrep", "-u", "lightdm", "-x", "arctica-greeter"],
                           capture_output=True, text=True).stdout.split()
    for pid in names:
        try:
            rows = Path(f"/proc/{pid}/environ").read_text().split("\0")
        except FileNotFoundError:
            continue
        env = dict(row.split("=", 1) for row in rows if "=" in row)
        if "DISPLAY" in env and "DBUS_SESSION_BUS_ADDRESS" in env:
            return env


@contextmanager
def observer(address, nonce):
    from central import wait

    account = pwd.getpwnam("lightdm")
    env = wait("ARCTICA_SESSION_BUS_AVAILABLE", greeter_environment)
    args = [k + "=" + env[k] for k in ("DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR", "XAUTHORITY") if k in env]
    with tempfile.TemporaryDirectory(prefix="classic-greeter-", dir="/run") as temp:
        os.chown(temp, account.pw_uid, account.pw_gid)
        witness = subprocess.Popen(["runuser", "-u", "lightdm", "--", "env", *args,
                                    "UV_CACHE_DIR=" + temp + "/cache", "./uv", "run", "--offline",
                                    "--no-project", "--python", "/usr/bin/python3", "python", "-B",
                                    "greeter.py", temp, address, nonce])
        def seen(name):
            if witness.poll() not in (None, 0):
                raise RuntimeError("Arctica observer exited early")
            return Path(temp, name).exists()
        try:
            wait("ARCTICA_USERNAME_READY_BEFORE_HID_CONNECT", lambda: seen("ready"), 65)
            def verify_typing(emit):
                Path(temp, "attached").touch()
                wait("ARCTICA_XINPUT_BOUND_TO_PEER", lambda: seen("sources"), 25)
                emit(nonce)
                wait("ARCTICA_USERNAME_MATCHED", lambda: seen("typed"), 20)
            yield verify_typing
            assert witness.wait(timeout=5) == 0
        finally:
            if witness.poll() is None:
                witness.terminate()
                witness.wait(timeout=5)


def children(obj, depth=0):
    if not obj or depth > 24:
        return
    yield obj
    for i in range(obj.get_child_count()):
        yield from children(obj.get_child_at_index(i), depth + 1)


def check(directory, address, nonce):
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
    from desktop import Gdk, GLib, matching_sources

    assert pwd.getpwuid(os.getuid()).pw_name == "lightdm"
    deadline = time.monotonic() + 85
    work = Path(directory)
    entry = None
    def focused_username():
        registry = Atspi.get_desktop(0)
        for i in range(registry.get_child_count()):
            app = registry.get_child_at_index(i)
            if not app:
                continue
            process = Path("/proc") / str(app.get_process_id())
            try:
                owner = process.stat().st_uid
                name = (process / "comm").read_text().strip()
            except FileNotFoundError:
                continue
            if owner != os.getuid() or name != "arctica-greeter":
                continue
            for child in children(app):
                if child.get_role() not in (Atspi.Role.ENTRY, Atspi.Role.TEXT):
                    continue
                states = child.get_state_set()
                if states.contains(Atspi.StateType.FOCUSED) and states.contains(Atspi.StateType.EDITABLE):
                    return child
        return None

    while time.monotonic() < deadline:
        try:
            if entry is None:
                entry = focused_username()
            if entry is not None:
                # Ignore password roles, and read only the greeter's focused username.
                value = Atspi.Text.get_text(entry, 0, -1)
                if value == "" and not (work / "ready").exists():
                    (work / "ready").touch()
                if (work / "sources").exists() and value == "Hid " + nonce + "-X!":
                    (work / "typed").touch()
                    print("Y700_ARCTICA_BONDED_USERNAME_PASS", flush=True)
                    return
        except GLib.Error:
            # Arctica can replace accessible objects during greeter startup.
            entry = None
        if (work / "attached").exists() and not (work / "sources").exists():
            context = GLib.MainContext.default()
            while context.pending():
                context.iteration(False)
            sources = matching_sources(Gdk.Display.get_default(), address)
            if {s["keyboard"] for s in sources.values()} == {False, True}:
                (work / "sources").touch()
        time.sleep(.2)
    raise RuntimeError("Arctica username field or edited value was not observed")


if __name__ == "__main__":
    check(sys.argv[1], sys.argv[2], sys.argv[3])
