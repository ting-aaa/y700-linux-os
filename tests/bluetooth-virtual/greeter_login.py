"""Submit the disposable VM account through the bonded LE keyboard at LightDM."""
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import time


def credential_reports(command):
    import keyboard
    assert {"y700.virtual_login=1", "y700.virtual_greeter=1"} <= set(Path("/proc/cmdline").read_text().split())
    if command == b"login-user":
        text = "y700"
    elif command == b"login-secret":
        text = Path("/var/lib/bluetooth/.qa-password").read_text()
        assert re.fullmatch("[a-f0-9]{16}", text)
    elif command == b"login-wrong":
        text = "z"
    elif command == b"login-wake":
        yield keyboard.report(0, 2)  # Shift without typing a character.
        yield keyboard.CLEAR
        return
    elif command == b"login-escape":
        yield keyboard.report(0x29)
        yield keyboard.CLEAR
        return
    elif command == b"login-enter":
        yield keyboard.report(0x28)
        yield keyboard.CLEAR
        return
    else:
        raise ValueError("unsupported fixture key sequence")
    for char in text:
        usage = ord(char) - ord("a") + 4 if char.isalpha() else (0x27 if char == "0" else 0x1d + int(char))
        yield keyboard.report(usage)
        yield keyboard.CLEAR


def output(*args, timeout=7):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


def seat():
    session = output("loginctl", "show-seat", "seat0", "-p", "ActiveSession", "--value")
    if not session:
        return {}
    data = output("loginctl", "show-session", session, "-p", "Name", "-p", "Class", "-p", "Service",
                  "-p", "Type", "-p", "Active", "-p", "LockedHint")
    return dict(line.split("=", 1) for line in data.splitlines()) | {"id": session}


def session_command(account, env, *args, timeout=24):
    user = pwd.getpwnam(account)
    selected = [k + "=" + env[k] for k in ("DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR") if k in env]
    return output("setpriv", "--reuid", str(user.pw_uid), "--regid", str(user.pw_gid), "--init-groups",
                  "env", *selected, "HOME=" + user.pw_dir, "LC_ALL=C", *args, timeout=timeout)


def as_user(account, env, *args):
    return session_command(account, env, "env", "UV_CACHE_DIR=" + env["XDG_RUNTIME_DIR"] + "/hid-qa-uv",
                           "./uv", "run", "--offline", "--no-project", "--python", "/usr/bin/python3",
                           "python", "-B", "greeter_login.py", *args, timeout=38)


def pointer_position():
    # Read only the root-relative pointer coordinates with XQueryPointer.
    import ctypes as c
    lib = c.CDLL("libX11.so.6")
    lib.XOpenDisplay.argtypes = [c.c_char_p]
    lib.XOpenDisplay.restype = c.c_void_p
    lib.XDefaultRootWindow.argtypes = [c.c_void_p]
    lib.XDefaultRootWindow.restype = c.c_ulong
    ptr = c.POINTER
    lib.XQueryPointer.argtypes = [c.c_void_p, c.c_ulong, ptr(c.c_ulong), ptr(c.c_ulong),
                                  ptr(c.c_int), ptr(c.c_int), ptr(c.c_int), ptr(c.c_int), ptr(c.c_uint)]
    lib.XCloseDisplay.argtypes = [c.c_void_p]
    display = lib.XOpenDisplay(None)
    assert display
    root, child, x, y, local_x, local_y, mask = c.c_ulong(), c.c_ulong(), c.c_int(), c.c_int(), c.c_int(), c.c_int(), c.c_uint()
    assert lib.XQueryPointer(display, lib.XDefaultRootWindow(display), *map(c.byref, (root, child, x, y, local_x, local_y, mask)))
    lib.XCloseDisplay(display)
    print(x.value, y.value)


def observe(role, address):
    if role == "pointer":
        assert pwd.getpwuid(os.getuid()).pw_name == "y700"
        pointer_position()
        return
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi, GLib
    from desktop import Gdk, matching_sources
    from greeter import children

    display = Gdk.Display.get_default()
    assert pwd.getpwuid(os.getuid()).pw_name == "lightdm"
    assert {info["keyboard"] for info in matching_sources(display, address).values()} == {True, False}
    registry = Atspi.get_desktop(0)
    observed = set()
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline:
        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)
        try:
            value = focused(registry, role, Atspi, children, observed)
        except (GLib.Error, FileNotFoundError):
            value = None
        if value:
            print(value)
            return
        time.sleep(.2)
    print("LE_PROMPT_WAIT role=" + role + " controls=" + ",".join(sorted(observed)), file=sys.stderr)


def focused(registry, role, Atspi, children, observed):
    for i in range(registry.get_child_count()):
        app = registry.get_child_at_index(i)
        if not app:
            continue
        path = Path("/proc") / str(app.get_process_id())
        if not path.exists() or path.stat().st_uid != os.getuid():
            continue
        if (path / "comm").read_text().strip() != "arctica-greeter":
            continue
        for entry in children(app):
            kind = entry.get_role()
            if kind not in (Atspi.Role.ENTRY, Atspi.Role.TEXT, Atspi.Role.PASSWORD_TEXT):
                continue
            states = entry.get_state_set()
            observed.add(f"{kind.value_nick}:focused={int(states.contains(Atspi.StateType.FOCUSED))}"
                         f":editable={int(states.contains(Atspi.StateType.EDITABLE))}")
            if not (states.contains(Atspi.StateType.FOCUSED) and states.contains(Atspi.StateType.EDITABLE)):
                continue
            if role in ("initial", "password") and kind == Atspi.Role.PASSWORD_TEXT:
                return "password" if role == "initial" else "ready"
            if role in ("initial", "typed") and kind in (Atspi.Role.ENTRY, Atspi.Role.TEXT):
                expected = "y700" if role == "typed" else ""
                if Atspi.Text.get_text(entry, 0, -1) == expected:
                    return "username" if role == "initial" else "ready"


def login(address):
    from central import control, verify_evdev, wait
    from greeter import greeter_environment
    assert seat()["Class"] == "greeter"
    env = wait("LE_ARCTICA_AVAILABLE", greeter_environment)
    def probe(kind):
        try:
            return as_user("lightdm", env, kind, address)
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            print("LE_GREETER_PROBE_RETRY", kind, type(exc).__name__, flush=True)
            return False
    initial = wait("LE_ARCTICA_XINPUT_PEER_AND_FIELD", lambda: probe("initial"), 50)
    if initial == "username":
        assert control(b"login-user")
        wait("LE_ARCTICA_USERNAME_IS_FIXTURE_ACCOUNT", lambda: probe("typed") == "ready", 20)
        assert control(b"login-enter")
        wait("LE_ARCTICA_PASSWORD_ROLE_FOCUSED", lambda: probe("password") == "ready", 30)
    else:
        assert initial == "password"
        print("LE_ARCTICA_PRESELECTED_PASSWORD_ROLE", flush=True)
    assert control(b"login-secret") and control(b"login-enter")
    def logged_in():
        info = seat()
        return (info.get("Name") == "y700" and info.get("Class") == "user" and
                info.get("Type") == "x11" and info.get("Service") == "lightdm" and info.get("Active") == "yes" and info)
    current = wait("LE_LIGHTDM_PAM_USER_SESSION", logged_in, 55)
    def desktop_pid():
        ps = subprocess.run(["pgrep", "-o", "-u", "y700", "-x", "xfce4-session"], capture_output=True, text=True)
        return ps.stdout.strip()
    pid = wait("LE_AUTHENTICATED_XFCE_SESSION", desktop_pid, 35)
    desktop = dict(item.split("=", 1) for item in Path(f"/proc/{pid}/environ").read_text().split("\0") if "=" in item)
    assert desktop["XDG_SESSION_ID"] == current["id"]
    def pointer():
        return tuple(map(int, as_user("y700", desktop, "pointer", address).split()))
    before = pointer()
    verify_evdev(address, lambda: control(b"emit"))
    after = pointer()
    assert after[0] > before[0] and after[1] < before[1] and seat()["id"] == current["id"]
    print("LE_DESKTOP_MOUSE evdev_xy=verified xorg_motion=right_up account=y700")
    print("Y700_LE_PAM_XFCE_PASS", flush=True)
    def screensaver(action):
        return session_command("y700", desktop, "xfce4-screensaver-command", action)
    def saver_is(active):
        try:
            return ("is active" if active else "is inactive") in screensaver("--query")
        except subprocess.SubprocessError:
            return False
    # Xfce starts its saver in the final XDG autostart phase, after its panel and window manager.
    def owner():
        return session_command("y700", desktop, "gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
                               "--object-path", "/org/freedesktop/DBus", "--method",
                               "org.freedesktop.DBus.NameHasOwner", "org.xfce.ScreenSaver") == "(true,)"
    wait("LE_XFCE_SAVER_AUTOSTART", owner, 95)
    wait("LE_XFCE_SAVER_IDLE", lambda: saver_is(False))
    screensaver("--lock")
    wait("LE_XFCE_SAVER_LOCKED", lambda: saver_is(True))
    def dialog():
        procs = subprocess.run(["pgrep", "-u", "y700", "-f", "^/usr/libexec/xfce4-screensaver-dialog( |$)"],
                               capture_output=True, text=True).stdout.split()
        for proc in procs:
            if Path(f"/proc/{proc}/exe").resolve() == Path("/usr/libexec/xfce4-screensaver-dialog"):
                return proc
    def wake_dialog():
        if proc := dialog():
            if subprocess.run(["pgrep", "-u", "y700", "-f", "/onboard .*--xid"],
                              stdout=subprocess.DEVNULL).returncode == 0:
                return proc
            return None
        assert control(b"login-wake")
        time.sleep(.5)
    first_dialog = wait("LE_NATIVE_LOCK_DIALOG", wake_dialog, 45)
    def rejected():
        found = subprocess.run(["journalctl", "-b", "-q", "-n1", "-o", "cat", "--grep",
                                r"pam_unix\(xfce4-screensaver:auth\): authentication failure"],
                               capture_output=True, text=True, timeout=7)
        assert found.returncode in (0, 1)
        return "authentication failure" in found.stdout
    assert not rejected()
    assert control(b"login-wrong") and control(b"login-enter")
    wait("LE_NATIVE_LOCK_WRONG_CREDENTIAL_REJECTED", rejected, 20)
    assert saver_is(True) and seat()["id"] == current["id"]
    def dismiss():
        if not dialog():
            return True
        assert control(b"login-escape")
        time.sleep(.5)
    wait("LE_NATIVE_LOCK_CANCELLED_AFTER_REJECTION", dismiss, 20)
    assert saver_is(True)
    assert wait("LE_NATIVE_LOCK_REOPENED", wake_dialog, 45) != first_dialog
    assert control(b"login-secret") and control(b"login-enter")
    wait("LE_NATIVE_LOCK_PASSWORD_ACCEPTED", lambda: saver_is(False), 25)
    assert logged_in()["id"] == current["id"] and desktop_pid() == pid
    print("Y700_LE_SAME_SESSION_UNLOCK_PASS", flush=True)


if __name__ == "__main__":
    observe(*sys.argv[1:])
