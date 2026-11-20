"""Exercise the native locker only in the fixture's disposable X display and PAM root."""
import ctypes
import os
from pathlib import Path
import re
import secrets
import subprocess
import threading
import time


def run(*args, check=True):
    return subprocess.run(args, text=True, capture_output=True, timeout=5, check=check).stdout.strip()


def wait(label, fn, seconds=12):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = fn()
        if result:
            return result
        time.sleep(.12)
    raise RuntimeError(label)


def geometry(xid):
    info = run("xwininfo", "-id", str(xid), check=False)
    if "Map State: IsViewable" not in info:
        return None
    keys = ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height")
    return tuple(int(re.search(r"^\s*" + k + r":\s*(-?\d+)", info, re.M)[1]) for k in keys)


def ancestors(xid):
    result = []
    for _ in range(12):
        tree = run("xwininfo", "-tree", "-id", str(xid), check=False)
        parent = re.search(r"Parent window id:\s+(0x[\da-f]+)", tree, re.I)
        root = re.search(r"Root window id:\s+(0x[\da-f]+)", tree, re.I)
        if not parent or not root or parent[1] == root[1]:
            break
        xid = int(parent[1], 16)
        result.append(xid)
    return result


def entry_geometry(dialog):
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    def search(node):
        if node.get_role() == Atspi.Role.PASSWORD_TEXT:
            owner = Path(f"/proc/{node.get_process_id()}/cmdline")
            if (node.get_state_set().contains(Atspi.StateType.SHOWING) and owner.exists()
                    and b"xfce4-screensaver-dialog" in owner.read_bytes()):
                return node
        for i in range(node.get_child_count()):
            child = node.get_child_at_index(i)
            if child and (match := search(child)):
                return match
        return None

    Atspi.init()
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if not app:
            continue
        for j in range(app.get_child_count()):
            top = app.get_child_at_index(j)
            if not top or not (entry := search(top)):
                continue
            screen = Atspi.CoordType.SCREEN
            top_rect, rect = top.get_extents(screen), entry.get_extents(screen)
            x, y, width, height = geometry(dialog)
            if top_rect.width <= 0:
                continue
            scale = round(width / top_rect.width)
            if scale not in (1, 2) or abs(height - top_rect.height * scale) > 4:
                continue
            return (x + (rect.x - top_rect.x) * scale, y + (rect.y - top_rect.y) * scale,
                    rect.width * scale, rect.height * scale)
    return None


def ephemeral_login():
    assert Path("/etc/y700-private-lock-fixture").is_file() and os.geteuid() == 0
    assert not Path("/etc/shadow").exists() and os.environ["DISPLAY"] == ":73"
    # The plaintext stays local to the checker. Only its salted verifier is
    # written into the private tmpfs PAM database, which vanishes on exit.
    password = "".join(secrets.choice("ehlo") for _ in range(12))
    lib = ctypes.CDLL("libcrypt.so.1")
    lib.crypt.argtypes = (ctypes.c_char_p, ctypes.c_char_p)
    lib.crypt.restype = ctypes.c_char_p
    hashed = lib.crypt(password.encode(), ("$6$" + secrets.token_hex(8) + "$").encode())
    assert hashed and hashed.startswith(b"$6$")
    path = Path("/etc/shadow")
    with path.open("xb") as out:
        out.write(b"root:!:20000:0:99999:7:::\nlocktest:" + hashed + b":20000:0:99999:7:::\n")
    os.chown(path, 0, 42)
    path.chmod(0o640)
    os.setgroups([])
    os.setgid(47319)
    os.setuid(47319)
    return password


def main():
    password = ephemeral_login()
    bus = run("dbus-daemon", "--session", "--fork", "--print-address=1")
    os.environ["DBUS_SESSION_BUS_ADDRESS"] = bus
    run("gsettings", "set", "org.gnome.desktop.interface", "toolkit-accessibility", "true")
    panel = tuple(map(int, run("xdotool", "getdisplaygeometry").split()))
    assert panel == (2560, 1600) and os.environ["GDK_SCALE"] == "2"
    expected = "/usr/bin/onboard --xid --layout=Compact"
    assert run("xfconf-query", "-c", "xfce4-screensaver", "-p", "/lock/embedded-keyboard/command") == expected
    daemon = subprocess.Popen(["xfce4-screensaver", "--debug"], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, errors="replace")
    keyboards, dialogs, states = [], [], set()

    def monitor():
        for line in daemon.stdout:
            for pattern, ids in ((r"Keyboard command output:\s*(\d+)", keyboards),
                                 (r"Command output:\s*WINDOW ID=\s*(\d+)", dialogs)):
                m = re.search(pattern, line)
                if m:
                    ids.append(int(m[1]))
            if "Got CANCEL response" in line:
                states.add("cancel")
            if "Got OK response" in line:
                states.add("ok")
            if "Authorization failed" in line:
                states.add("failed")

    threading.Thread(target=monitor, daemon=True).start()

    def active():
        return "is active" in run("xfce4-screensaver-command", "--query", check=False)

    def show_prompt(index):
        run("xdotool", "key", "Shift_L")
        wait("mapped native unlock dialog and embedded keyboard", lambda: len(keyboards) > index
             and len(dialogs) > index and geometry(keyboards[index]) and geometry(dialogs[index]), 20)
        xid = keyboards[index]
        assert "_XEMBED_INFO(_XEMBED_INFO)" in run("xprop", "-id", str(xid), "_XEMBED_INFO")
        assert set(ancestors(xid)).intersection(ancestors(dialogs[index]))
        x, y, width, height = geometry(xid)
        assert width >= 600 and height >= 120 and x >= 0 and y >= 0 and x + width <= panel[0] and y + height <= panel[1]
        ex, ey, ew, eh = wait("mapped private password entry geometry", lambda: entry_geometry(dialogs[index]), 6)
        assert ew > 0 and eh > 0 and ex >= 0 and ey >= 0 and ex + ew <= panel[0] and ey + eh <= y
        print(f"PRIVATE_LOCK display={panel[0]}x{panel[1]} gdk_scale=2 embedded=yes shared_locker_ancestor=yes "
              f"keyboard={width}x{height}+{x}+{y} password_entry={ew}x{eh}+{ex}+{ey}", flush=True)
        return x, y, width, height

    try:
        wait("private screensaver service", lambda: "is inactive" in
             run("xfce4-screensaver-command", "--query", check=False))
        run("xfce4-screensaver-command", "--lock")
        wait("private lock activated", active)
        show_prompt(0)
        run("xdotool", "key", "Escape")
        wait("cancel dismissed the prompt with lock retained", lambda: "cancel" in states and active())
        print("PRIVATE_LOCK cancel=still-locked", flush=True)
        x, y, width, height = show_prompt(1)
        keys = {"e": (.251, .30), "h": (.448, .50), "l": (.631, .50), "o": (.616, .30)}
        for key in password:
            dx, dy = keys[key]
            run("xdotool", "mousemove", str(x + round(dx * width)), str(y + round(dy * height)), "click", "1")
        run("xdotool", "key", "Return")
        wait("native PAM accepted temporary identity", lambda: "ok" in states and not active(), 12)
        assert "failed" not in states
        print("PRIVATE_LOCK_PASS temporary_pam=authenticated input=embedded-key-clicks display=Xvfb", flush=True)
    finally:
        print(f"PRIVATE_LOCK state dialog_count={len(dialogs)} keyboard_count={len(keyboards)} "
              f"cancel={'cancel' in states} pam_ok={'ok' in states} rejected={'failed' in states}", flush=True)
        daemon.terminate()


if __name__ == "__main__":
    main()
