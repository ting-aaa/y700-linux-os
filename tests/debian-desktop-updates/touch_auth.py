"""Operate only the installed MATE authentication dialog and Onboard on a QA seat."""
from pathlib import Path
import re
import subprocess
import time

from gi.repository import Atspi, Gio, GLib


def wait_for(check, reason, seconds=16):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if result := check():
                return result
        except GLib.Error:
            pass
        time.sleep(.15)
    raise RuntimeError(reason)


def keyboard():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    visible, = bus.call_sync(
        "org.onboard.Onboard", "/org/onboard/Onboard/Keyboard", "org.freedesktop.DBus.Properties",
        "Get", GLib.Variant("(ss)", ("org.onboard.Onboard.Keyboard", "Visible")), None,
        Gio.DBusCallFlags.NONE, 2000, None,
    ).unpack()
    if visible:
        tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
        for line in tree.splitlines():
            if '"Onboard"' not in line:
                continue
            size = re.search(r'\s2560x840[+-]\d+[+-]\d+\s+\+0\+(\d+)', line)
            if size and int(size[1]) + 840 == 1600:
                return 0, int(size[1]), 2560, 840
    return None


def agent():
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        try:
            exe = Path(f"/proc/{app.get_process_id()}/exe").readlink()
        except (FileNotFoundError, PermissionError):
            continue
        if exe == Path("/usr/libexec/polkit-mate-authentication-agent-1"):
            return app
    return None


def authenticate(nodes, tap, tap_pixel):
    app = wait_for(agent, "MATE agent did not present an accessible dialog", 35)

    def control(role, label=None):
        for node in nodes(app):
            state = node.get_state_set()
            if (node.get_role() == role and state.contains(Atspi.StateType.SHOWING)
                    and state.contains(Atspi.StateType.ENABLED)
                    and (label is None or node.get_name().strip() == label)):
                return node
        return None

    field = wait_for(lambda: control(Atspi.Role.PASSWORD_TEXT), "expected masked MATE password entry")
    print("UPDATER_AUTH_DIALOG agent=mate-polkit password_field=masked", flush=True)
    focused = lambda: field.get_state_set().contains(Atspi.StateType.FOCUSED)
    if not focused():
        tap(field)
        wait_for(focused, "password field did not receive focus")
    x, y, width, height = wait_for(keyboard, "Onboard did not auto-show in the authentication dialog")
    time.sleep(.6)  # Allow dock animation and the window manager's work-area adjustment to finish.
    print(f"UPDATER_AUTH_FOCUS focused={int(focused())} dock={width}x{height}", flush=True)
    text = field.get_text_iface()
    assert text.get_character_count() == 0
    password = Path("/run/updater-qa-password").read_text().strip()
    assert re.fullmatch(r"[a-z]{10}", password)
    centers = {letter: (first + i * .061, cy)
               for row, first, cy in [("qwertyuiop", .129, .30), ("asdfghjkl", .144, .50),
                                      ("zxcvbnm", .181, .70)]
               for i, letter in enumerate(row)}
    for length, letter in enumerate(password, 1):
        rx, ry = centers[letter]
        tap_pixel(x + round(width * rx), y + round(height * ry))
        try:
            wait_for(lambda: text.get_character_count() == length, "masked field did not receive touch key", 6)
        except RuntimeError:
            print(f"UPDATER_AUTH_INPUT_FAIL index={length} count={text.get_character_count()} "
                  f"focused={int(focused())} dock={int(bool(keyboard()))}", flush=True)
            raise
    # Onboard's top-right hide button leaves the password field intact.
    tap_pixel(x + round(width * .955), y + round(height * .10))
    wait_for(lambda: not keyboard(), "keyboard did not hide")
    approve = wait_for(lambda: control(Atspi.Role.PUSH_BUTTON, "Authenticate"), "Authenticate button missing")
    tap(approve)
    print("UPDATER_AUTH_INPUT onscreen=Onboard type_b_keys=10 submit=touch", flush=True)
