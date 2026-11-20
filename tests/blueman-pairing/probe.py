"""Drive the packaged Blueman pairing controls on two private buses."""

import os
import re
import secrets
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Atspi, Gdk, Gio, GLib


DBUS = "org.freedesktop.DBus"
DBUS_PATH = "/org/freedesktop/DBus"
BLUEZ = "org.bluez"
BLUEZ_PATH = "/org/bluez"
AGENT = "/org/bluez/agent/blueman"
AGENT_IFACE = "org.bluez.Agent1"
MOCK_IFACE = "org.freedesktop.DBus.Mock"
NOTIFY = "org.freedesktop.Notifications"


class ProbeError(Exception):
    pass


def require(condition, failure):
    if not condition:
        raise ProbeError(failure)


def emit(receipt):
    print(receipt, flush=True)


def await_value(callback, failure, seconds=10):
    context = GLib.MainContext.default()
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        while context.pending():
            context.iteration(False)
        try:
            if value := callback():
                return value
        except GLib.Error:
            pass
        time.sleep(0.08)
    raise ProbeError(failure)


def call(bus, name, path, interface, member, arguments=None):
    return bus.call_sync(
        name, path, interface, member, arguments, None, Gio.DBusCallFlags.NONE, 2500, None
    ).unpack()


def owner(bus, name):
    return call(bus, DBUS, DBUS_PATH, DBUS, "GetNameOwner", GLib.Variant("(s)", (name,)))[0]


def pid(bus, name):
    return call(
        bus, DBUS, DBUS_PATH, DBUS, "GetConnectionUnixProcessID", GLib.Variant("(s)", (name,))
    )[0]


def application(process):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child and child.get_process_id() == process:
            return child
    return None


def showing_nodes(root, depth=0):
    if not root or depth > 10:
        return
    if root.get_state_set().contains(Atspi.StateType.SHOWING):
        yield root
    for index in range(min(root.get_child_count(), 128)):
        yield from showing_nodes(root.get_child_at_index(index), depth + 1)


def matching_label(process, passkey):
    app = application(process)
    pattern = rf"(?<!\d){passkey:06}(?!\d)"
    return next(
        (
            node for node in showing_nodes(app)
            if node.get_role() == Atspi.Role.LABEL and re.search(pattern, node.get_name() or "")
        ),
        None,
    )


def pairing_dialog(label):
    parent = label.get_parent()
    for _ in range(6):
        if not parent:
            break
        if parent.get_role() in (Atspi.Role.DIALOG, Atspi.Role.ALERT):
            return parent
        parent = parent.get_parent()
    return None


def bluetooth_window(title="Bluetooth"):
    windows = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", f"^{re.escape(title)}$"],
                             check=True, capture_output=True, text=True, timeout=4).stdout.split()
    require(len(windows) == 1 and windows[0].isdecimal(), "pairing-dialog-x11-window-not-unique")
    return windows[0]


def bounds(window_id):
    window = subprocess.run(["xwininfo", "-id", window_id], check=True, capture_output=True,
                            text=True, timeout=4).stdout
    dimensions = dict(re.findall(r"^\s*(Absolute upper-left X|Absolute upper-left Y|Width|Height):\s+(-?\d+)$",
                                 window, re.M))
    require(len(dimensions) == 4, "pairing-dialog-x11-geometry-missing")
    return tuple(int(dimensions[key]) for key in ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height"))


def tap(node, dialog, title="Bluetooth"):
    xid = bluetooth_window(title)
    origin_x, origin_y, width, height = bounds(xid)
    require(0 <= origin_x < origin_x + width <= 2560 and 0 <= origin_y < origin_y + height <= 1600,
            "pairing-dialog-outside-screen")
    frame = dialog.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    button = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    require(frame.width > 0 and frame.height > 0, "pairing-dialog-empty-geometry")
    # AT-SPI's top-level rectangle includes Xfwm decorations. The X client
    # origin and size from xwininfo exclude them. Undecorated Xvfb uses zero.
    prop = subprocess.check_output(["xprop", "-id", xid, "_NET_FRAME_EXTENTS"], text=True, timeout=4)
    decoration = re.search(r"=\s*(\d+), (\d+), (\d+), (\d+)", prop)
    left, right, top, bottom = map(int, decoration.groups()) if decoration else (0, 0, 0, 0)
    sx, sy = (width + left + right) / frame.width, (height + top + bottom) / frame.height
    require(abs(sx - sy) < 0.05 and 0.95 <= sx <= 2.05, "pairing-dialog-inconsistent-coordinate-scale")
    x = origin_x - left + round((button.x + button.width / 2 - frame.x) * sx)
    y = origin_y - top + round((button.y + button.height / 2 - frame.y) * sy)
    require(button.width > 0 and button.height > 0 and 0 < x < 2560 and 0 < y < 1600,
            "pairing-button-invalid-geometry")
    subprocess.run(["xdotool", "mousemove", str(x), str(y), "click", "1"], check=True,
                   timeout=4, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return round(button.width * sx), round(button.height * sy)


def call_agent_async(bus, destination, member, arguments):
    outcome = {}

    def ended(connection, result):
        try:
            outcome["reply"] = connection.call_finish(result).unpack()
        except GLib.Error as error:
            outcome["error"] = Gio.DBusError.get_remote_error(error) or "local-no-reply"
            if "_on_display_passkey" in error.message and "IndexError: string index out of range" in error.message:
                outcome["cause"] = "passkey-index"

    bus.call(destination, AGENT, AGENT_IFACE, member, arguments, None,
             Gio.DBusCallFlags.NONE, 45000, None, ended)
    return outcome


def system_agent(system, process):
    for name in call(system, DBUS, DBUS_PATH, DBUS, "ListNames")[0]:
        if not name.startswith(":") or pid(system, name) != process:
            continue
        try:
            xml = call(system, name, AGENT, "org.freedesktop.DBus.Introspectable", "Introspect")[0]
        except GLib.Error:
            continue
        if f'<interface name="{AGENT_IFACE}">' in xml:
            return name
    return None


def registered(system):
    def arguments(member):
        return call(system, BLUEZ, BLUEZ_PATH, MOCK_IFACE, "GetMethodCalls",
                    GLib.Variant("(s)", (member,)))[0]

    registered_agents = [tuple(values) for _, values in arguments("RegisterAgent")]
    defaults = [tuple(values) for _, values in arguments("RequestDefaultAgent")]
    return (AGENT, "KeyboardDisplay") in registered_agents and (AGENT,) in defaults


def confirm_path(system, agent, keyboard, applet_pid, passkey, action):
    result = call_agent_async(system, agent, "RequestConfirmation", GLib.Variant("(ou)", (keyboard, passkey)))
    label = await_value(lambda: matching_label(applet_pid, passkey), "matching-confirmation-text-missing")
    dialog = pairing_dialog(label)
    require(dialog, "matching-confirmation-dialog-missing")
    button_name = {"confirm": "Confirm", "deny": "Deny"}[action]
    button = next((node for node in showing_nodes(dialog)
                   if node.get_role() == Atspi.Role.PUSH_BUTTON and node.get_name() == button_name), None)
    require(button, "matching-confirmation-button-missing")
    require(not result, "confirmation-completed-before-tap")
    width, height = tap(button, dialog)
    receipt = await_value(lambda: result, "agent-confirmation-result-missing")
    expected = {"reply": ()} if action == "confirm" else {"error": "org.bluez.Error.Canceled"}
    require(receipt == expected, "agent-confirmation-result-mismatch")
    await_value(lambda: not matching_label(applet_pid, passkey), "pairing-dialog-still-visible-after-tap")
    emit(f"BLUEMAN_CONFIRMATION action={action} code_matched=1 agent_receipt=1 button_px={width}x{height}")


def display_passkey(system, agent, keyboard, applet_pid, passkey, stock):
    previous_window = None
    for count in (0, 3, 6):
        result = call_agent_async(system, agent, "DisplayPasskey",
                                  GLib.Variant("(ouq)", (keyboard, passkey, count)))
        receipt = await_value(lambda: result, "display-passkey-agent-reply-missing")
        if stock and count == 6:
            require(receipt == {"error": "org.freedesktop.DBus.Error.Failed", "cause": "passkey-index"},
                    "stock-display-passkey-error-did-not-reproduce")
            emit("BLUEMAN_DISPLAY_COMPLETION entered=6 dbus_error=Failed index_error=1")
            break
        require(receipt == {"reply": ()}, "display-passkey-agent-reply-mismatch")
        await_value(lambda: matching_label(applet_pid, passkey), "display-passkey-text-missing")
        window = bluetooth_window()
        require(window != previous_window, "display-passkey-update-did-not-replace-dialog")
        previous_window = window
        emit(f"BLUEMAN_DISPLAY_PASSKEY entered={count} code_matched=1 agent_receipt=1")
    call(system, agent, AGENT, AGENT_IFACE, "Cancel")
    await_value(lambda: not matching_label(applet_pid, passkey), "display-passkey-cancel-not-observed")
    emit("BLUEMAN_CANCEL display_dismissed=1 agent_receipt=1")


def control(dialog, role, name):
    return next((node for node in showing_nodes(dialog)
                 if node.get_role() == role and node.get_name() == name), None)


def entry_dialog(applet_pid):
    return next((node for node in showing_nodes(application(applet_pid))
                 if node.get_name() == "Pairing request" and node.get_role() == Atspi.Role.DIALOG), None)


def onboard_bounds(session):
    visible, = call(session, "org.onboard.Onboard", "/org/onboard/Onboard/Keyboard",
                    "org.freedesktop.DBus.Properties", "Get",
                    GLib.Variant("(ss)", ("org.onboard.Onboard.Keyboard", "Visible")))
    if not visible:
        return None
    found = subprocess.run(["xdotool", "search", "--onlyvisible", "--class", "^Onboard$"],
                           capture_output=True, text=True, timeout=4).stdout.split()
    for xid in found:
        box = bounds(xid)
        x, y, width, height = box
        if width >= 1200 and height >= 250 and 0 <= x <= 2560 - width and 0 <= y <= 1600 - height:
            return box
    return None


def enter_with_onboard(session, text, entry):
    # Centers on the normal alpha layer of Debian Onboard's Compact layout.
    keys = {"e": (.251, .30), "h": (.448, .50), "l": (.631, .50), "o": (.616, .30)}
    for i, digit in enumerate("1234567890"):
        keys[digit] = (.091 + .061 * i, .10)
    for index, character in enumerate(text, 1):
        x, y, width, height = await_value(lambda: onboard_bounds(session), "onboard-not-visible-on-entry")
        dx, dy = keys[character]
        subprocess.run(["xdotool", "mousemove", str(x + round(dx * width)), str(y + round(dy * height)),
                        "click", "1"], check=True, timeout=4)
        try:
            await_value(lambda: entry.get_character_count() == index, "screen-key-did-not-append-character", 4)
        except ProbeError:
            focused = subprocess.run(["xdotool", "getwindowfocus", "getwindowname"],
                                     text=True, capture_output=True, timeout=3).stdout.strip()
            emit(f"BLUEMAN_KEY_INPUT count={entry.get_character_count()} index={index} "
                 f"entry_focused={int(entry.get_state_set().contains(Atspi.StateType.FOCUSED))} "
                 f"pairing_has_x_focus={int(focused == 'Pairing request')}")
            raise


def check_local_entry(system, session, agent, keyboard, applet_pid, method, other_device=None):
    result = call_agent_async(system, agent, method, GLib.Variant("(o)", (keyboard,)))
    dialog = await_value(lambda: entry_dialog(applet_pid), "local-pairing-dialog-missing")
    numeric = method == "RequestPasskey"
    role = Atspi.Role.TEXT if numeric else Atspi.Role.PASSWORD_TEXT
    entry = await_value(lambda: next((n for n in showing_nodes(dialog) if n.get_role() == role and
                                     n.get_state_set().contains(Atspi.StateType.EDITABLE)), None),
                        "editable-pairing-field-missing")
    accept = control(dialog, Atspi.Role.PUSH_BUTTON, "OK")
    require(accept and not accept.get_state_set().contains(Atspi.StateType.SENSITIVE),
            "empty-entry-can-submit")
    if other_device:
        xid = bluetooth_window("Pairing request")
        pending = call_agent_async(system, agent, "RequestPinCode", GLib.Variant("(o)", (other_device,)))
        require(await_value(lambda: pending, "second-device-no-reply") == {"error": "org.bluez.Error.Canceled"},
                "second-device-did-not-defer")
        require(bluetooth_window("Pairing request") == xid and not result, "first-entry-replaced")
    # Gtk may already have focused the entry and shown the dock. In that case
    # tapping its old screen position can hit a key before the window settles.
    if not entry.get_state_set().contains(Atspi.StateType.FOCUSED):
        tap(entry, dialog, "Pairing request")
    await_value(lambda: entry.get_state_set().contains(Atspi.StateType.FOCUSED), "entry-did-not-get-focus")
    require(entry.get_character_count() == 0, "entry-no-longer-empty-before-first-key")
    # Use a leading zero so that the numeric protocol type and the string PIN
    # are independently checked. Keep all generated values out of the receipt.
    text = ("0" + "".join(secrets.choice("0123456789") for _ in range(5)) if numeric else
            "".join(secrets.choice("ehlo") for _ in range(4)) + secrets.choice("0123456789"))
    enter_with_onboard(session, text, entry)
    require(not result and accept.get_state_set().contains(Atspi.StateType.SENSITIVE),
            "entry-completion-state-incorrect")
    # The docked keyboard can cover the dialog's action row. GTK sets OK as
    # this entry's default action, so the on-screen Return works in either layout.
    x, y, width, height = await_value(lambda: onboard_bounds(session), "onboard-return-unavailable")
    subprocess.run(["xdotool", "mousemove", str(x + round(.873 * width)),
                    str(y + round(.40 * height)), "click", "1"], check=True, timeout=4)
    outcome = await_value(lambda: result, "local-entry-result-missing")
    require(outcome == {"reply": (int(text) if numeric else text,)}, "screen-keyboard-entry-value-mismatch")
    await_value(lambda: not entry_dialog(applet_pid), "local-entry-still-visible")
    emit(f"BLUEMAN_LOCAL_ENTRY method={method} input=onboard-pointer matched=1 masked={int(not numeric)} "
         f"second_request_deferred={int(bool(other_device))}")


def zero_confirmation(system, agent, keyboard, applet_pid, fixed):
    if fixed:
        confirm_path(system, agent, keyboard, applet_pid, 0, "deny")
    else:
        result = call_agent_async(system, agent, "RequestConfirmation", GLib.Variant("(ou)", (keyboard, 0)))
        deny = await_value(lambda: control(application(applet_pid), Atspi.Role.PUSH_BUTTON, "Deny"),
                           "zero-comparison-dialog-missing")
        require(not matching_label(applet_pid, 0) and not result, "old-zero-comparison-state-unexpected")
        tap(deny, pairing_dialog(deny))
        require(await_value(lambda: result, "zero-comparison-denial-missing") ==
                {"error": "org.bluez.Error.Canceled"}, "zero-comparison-denial-failed")
    emit(f"BLUEMAN_ZERO_COMPARISON six_digits_visible={int(fixed)} denied=1")


def main():
    require(os.geteuid() != 0, "ordinary-user-required")
    require(os.environ["DBUS_SYSTEM_BUS_ADDRESS"].startswith("unix:path=/run/blueman-pairing/"),
            "isolated-system-bus-required")
    Atspi.init()
    Atspi.set_timeout(2500, 2500)
    system = Gio.bus_get_sync(Gio.BusType.SYSTEM)
    session = Gio.bus_get_sync(Gio.BusType.SESSION)
    settings = Gio.Settings.new("org.blueman.general")
    require(settings.get_boolean("notification-daemon") and settings.get_user_value("notification-daemon") is None,
            "packaged-notification-default-is-false")
    activatable = call(session, DBUS, DBUS_PATH, DBUS, "ListActivatableNames")[0]
    has_owner = call(session, DBUS, DBUS_PATH, DBUS, "NameHasOwner", GLib.Variant("(s)", (NOTIFY,)))[0]
    candidates = sum("notification" in name.lower() or "notify" in name.lower() for name in activatable)
    emit(f"BLUEMAN_NOTIFICATIONS activatable={int(NOTIFY in activatable)} owner={int(has_owner)} "
         f"related_names={candidates} default_enabled=1")
    require(NOTIFY not in activatable and not has_owner, "notification-provider-present-in-fixture")
    require(Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2, "gtk-scale-not-200-percent")
    emit("BLUEMAN_GTK scale=2 resolution=2560x1600")

    await_value(lambda: owner(system, BLUEZ), "bluez5-mock-missing")
    adapter = "hci0"
    call(system, BLUEZ, "/", "org.bluez.Mock", "AddAdapter",
         GLib.Variant("(ss)", (adapter, "Fixture adapter")))
    keyboard = call(system, BLUEZ, "/", "org.bluez.Mock", "AddDevice",
                    GLib.Variant("(sss)", (adapter, "02:00:00:00:00:01", "Fixture keyboard")))[0]
    call(system, BLUEZ, keyboard, MOCK_IFACE, "UpdateProperties",
         GLib.Variant("(sa{sv})", ("org.bluez.Device1", {
             "Class": GLib.Variant("u", 0x0540),
             "Appearance": GLib.Variant("q", 0x03C1),
             "UUIDs": GLib.Variant("as", ["00001812-0000-1000-8000-00805f9b34fb"]),
         })))

    applet = subprocess.Popen(["blueman-applet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        await_value(lambda: registered(system), "keyboarddisplay-registration-missing")
        agent = await_value(lambda: system_agent(system, applet.pid), "applet-agent-interface-missing")
        emit("BLUEMAN_AGENT capability=KeyboardDisplay default_requested=1 applet_pid_matched=1")
        confirm_passkey, deny_passkey, display_key = secrets.SystemRandom().sample(range(1, 100000), 3)
        confirm_path(system, agent, keyboard, applet.pid, confirm_passkey, "confirm")
        confirm_path(system, agent, keyboard, applet.pid, deny_passkey, "deny")
        stock = os.environ["BLUEMAN_EXPECTED_VERSION"] == "2.4.4-1"
        display_passkey(system, agent, keyboard, applet.pid, display_key, stock)
        if os.environ.get("BLUEMAN_TOUCH_ENTRY") == "1":
            fixed = os.environ["BLUEMAN_EXPECTED_VERSION"] == "2.4.4-1+y7002"
            zero_confirmation(system, agent, keyboard, applet.pid, fixed)
            other = call(system, BLUEZ, "/", "org.bluez.Mock", "AddDevice",
                         GLib.Variant("(sss)", (adapter, "02:00:00:00:00:02", "Second fixture device")))[0]
            check_local_entry(system, session, agent, keyboard, applet.pid, "RequestPinCode")
            check_local_entry(system, session, agent, keyboard, applet.pid, "RequestPasskey", other if fixed else None)
        if stock:
            emit("BLUEMAN_STOCK_BOUNDARY_REPRODUCED")
        else:
            emit("BLUEMAN_CANDIDATE_PAIRING_UI_PASS")
    finally:
        applet.terminate()
        try:
            applet.wait(timeout=4)
        except subprocess.TimeoutExpired:
            applet.kill()
            applet.wait()


if __name__ == "__main__":
    try:
        main()
    except ProbeError as error:
        print(f"BLUEMAN_PAIRING_UI_ERROR {error}", file=sys.stderr)
        raise SystemExit(1)
    except GLib.Error as error:
        remote = Gio.DBusError.get_remote_error(error) or "local"
        print(f"BLUEMAN_PAIRING_UI_ERROR dbus={remote}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as error:
        print(f"BLUEMAN_PAIRING_UI_ERROR {type(error).__name__}", file=sys.stderr)
        raise SystemExit(1)
