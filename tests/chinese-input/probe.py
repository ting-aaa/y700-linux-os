"""Use pointer clicks on the stock Onboard keyboard and IBus GTK candidate panel."""

import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("Gdk", "3.0")
gi.require_version("IBus", "1.0")
from gi.repository import Atspi, Gdk, Gio, GLib, IBus


ROOT = Path(os.environ["CHINESE_INPUT_TEST_DIR"])
SCREEN = (2560, 1600)
KEYS = {
    "a": (0.144, 0.50),
    "e": (0.251, 0.30),
    "h": (0.448, 0.50),
    "i": (0.556, 0.30),
    "l": (0.631, 0.50),
    "n": (0.486, 0.70),
    "o": (0.616, 0.30),
    " ": (0.420, 0.90),
}


class ProbeError(Exception):
    pass


def wait_for(read, failure, seconds=14):
    deadline = time.monotonic() + seconds
    events = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while events.pending():
            events.iteration(False)
        try:
            if value := read():
                return value
        except (GLib.Error, FileNotFoundError):
            pass
        time.sleep(0.10)
    raise ProbeError(failure)


def command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=4, check=False)


def extent(window):
    values = dict(re.findall(
        r"^\s*(Absolute upper-left X|Absolute upper-left Y|Width|Height):\s+(-?\d+)$",
        command("xwininfo", "-id", window).stdout, re.M,
    ))
    if len(values) == 4:
        return tuple(int(values[key]) for key in ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height"))
    return None


def windows(kind, expression):
    for window in command("xdotool", "search", "--onlyvisible", kind, expression).stdout.split():
        if window.isdecimal():
            if box := extent(window):
                yield box


def tap(x, y):
    if not 0 <= x < SCREEN[0] or not 0 <= y < SCREEN[1]:
        raise ProbeError("pointer-coordinate-outside-private-display")
    if command("xdotool", "mousemove", str(x), str(y), "click", "1").returncode:
        raise ProbeError("pointer-click-failed")


def tap_center(box):
    x, y, width, height = box
    tap(x + width // 2, y + height // 2)


def keyboard_geometry():
    session = Gio.bus_get_sync(Gio.BusType.SESSION)
    visible, = session.call_sync(
        "org.onboard.Onboard", "/org/onboard/Onboard/Keyboard", "org.freedesktop.DBus.Properties", "Get",
        GLib.Variant("(ss)", ("org.onboard.Onboard.Keyboard", "Visible")), None,
        Gio.DBusCallFlags.NONE, 2500, None,
    ).unpack()
    if visible:
        return next((box for box in windows("--class", "^Onboard$") if box[2] >= 1200 and box[3] >= 250), None)
    return None


def type_onboard(text):
    for character in text:
        x, y, width, height = wait_for(keyboard_geometry, "stock-onboard-keyboard-not-visible")
        key_x, key_y = KEYS[character]
        tap(x + round(key_x * width), y + round(key_y * height))


def accessible_nodes(root, depth=0):
    if not root or depth > 10:
        return
    yield root
    for index in range(min(root.get_child_count(), 150)):
        yield from accessible_nodes(root.get_child_at_index(index), depth + 1)


def visible_named_nodes(match, roles):
    for node in accessible_nodes(Atspi.get_desktop(0)):
        if (node.get_role() in roles and node.get_state_set().contains(Atspi.StateType.SHOWING)
                and match(node.get_name() or "")):
            yield node


def visible_named(match, roles):
    return next(visible_named_nodes(match, roles), None)


def rect(node):
    component = node.get_component_iface()
    if not component:
        raise ProbeError("application-or-popup-has-no-screen-geometry")
    return component.get_extents(Atspi.CoordType.SCREEN)


def candidate_number(candidate):
    group = candidate.get_parent()
    if not group:
        return None
    return next((node for node in accessible_nodes(group)
                 if node.get_role() == Atspi.Role.LABEL
                 and node.get_state_set().contains(Atspi.StateType.SHOWING)
                 and re.fullmatch(r"\d+\.", (node.get_name() or "").strip())), None)


def accessible_scale(entry_box):
    app = wait_for(lambda: visible_named(lambda name: name == "Y700 input fixture", (Atspi.Role.FRAME,)),
                   "gtk-window-not-accessible")
    frame = rect(app)
    if not frame.width:
        raise ProbeError("empty-accessible-window-geometry")
    ratio = entry_box[2] / frame.width
    if 0.95 <= ratio <= 1.05:
        return 1
    if 1.9 <= ratio <= 2.1:
        return 2
    raise ProbeError("unrecognized-atspi-coordinate-scale")


def touch_accessible(node, scale):
    position = rect(node)
    if position.width <= 0 or position.height <= 0:
        raise ProbeError("popup-control-has-no-area")
    tap((position.x + position.width // 2) * scale, (position.y + position.height // 2) * scale)


def current_engine(bus):
    engine = bus.get_global_engine()
    return engine.get_name() if engine else None


def switch_engine(bus, expected, match, scale):
    icon = next((box for box in windows("--name", "^IBus Panel$") if 16 <= box[2] <= 160 and 0 <= box[1] < 160),
                None)
    if not icon:
        if os.environ.get("CHINESE_INPUT_DISCOVERY") == "1":
            for line in command("xwininfo", "-root", "-tree").stdout.splitlines():
                if "ibus" in line.lower():
                    print(line, flush=True)
        raise ProbeError("ibus-tray-icon-not-found")
    tap_center(icon)
    if os.environ.get("CHINESE_INPUT_DISCOVERY") == "1":
        time.sleep(0.4)
        screenshot()
    roles = (Atspi.Role.MENU_ITEM, Atspi.Role.CHECK_MENU_ITEM, Atspi.Role.RADIO_MENU_ITEM)
    items = wait_for(lambda: list(visible_named_nodes(match, roles)), "ibus-engine-menu-item-not-visible")
    anchor_x = icon[0] + icon[2] // 2
    item = min(items, key=lambda node: abs((rect(node).x + rect(node).width // 2) * scale - anchor_x))
    if os.environ.get("CHINESE_INPUT_DISCOVERY") == "1":
        print(f"CHINESE_INPUT_MENU_GEOMETRY scale={scale} menu_candidates={len(items)} "
              f"anchor_x={anchor_x} item_x={rect(item).x} item_y={rect(item).y}", flush=True)
        for box in windows("--class", "^Ibus-ui-gtk3$"):
            print(f"CHINESE_INPUT_IBUS_WINDOW {box}", flush=True)
    touch_accessible(item, scale)
    wait_for(lambda: current_engine(bus) == expected, "tap-did-not-select-requested-ibus-engine")


def state():
    return json.loads((ROOT / "entry.json").read_text(encoding="utf-8"))


def screenshot():
    screen = Gdk.Screen.get_default()
    root = screen.get_root_window()
    snapshot = Gdk.pixbuf_get_from_window(root, 0, 0, SCREEN[0] // 2, SCREEN[1] // 2)
    if snapshot:
        snapshot.savev(str(ROOT / "display.png"), "png", [], [])


def pointer_input_windows():
    x11 = ctypes.CDLL("libX11.so.6")
    pointer, ulong = ctypes.c_void_p, ctypes.c_ulong
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = pointer
    x11.XDefaultRootWindow.argtypes = [pointer]
    x11.XDefaultRootWindow.restype = ulong
    x11.XCloseDisplay.argtypes = [pointer]
    window_ref, int_ref = ctypes.POINTER(ulong), ctypes.POINTER(ctypes.c_int)
    x11.XQueryPointer.argtypes = [pointer, ulong, window_ref, window_ref, *([int_ref] * 4),
                                  ctypes.POINTER(ctypes.c_uint)]
    xdisplay = x11.XOpenDisplay(None)
    if not xdisplay:
        return []
    window = x11.XDefaultRootWindow(xdisplay)
    root, child = ulong(), ulong()
    coords = [ctypes.c_int() for _ in range(4)]
    mask = ctypes.c_uint()
    inspected = []
    try:
        for _ in range(10):
            if not x11.XQueryPointer(xdisplay, window, ctypes.byref(root), ctypes.byref(child),
                                     *(ctypes.byref(item) for item in coords), ctypes.byref(mask)):
                break
            if not child.value:
                break
            window = child.value
            klass = command("xprop", "-id", str(window), "WM_CLASS").stdout.strip()
            inspected.append((window, klass, extent(str(window))))
        return inspected
    finally:
        x11.XCloseDisplay(xdisplay)


def main():
    if os.geteuid() == 0:
        raise ProbeError("ordinary-user-required")
    Atspi.init()
    Atspi.set_timeout(2200, 2200)
    IBus.init()
    initial = wait_for(state, "gtk-test-entry-not-ready")
    if initial != {"committed": "", "preedit": "", "scale": 2}:
        raise ProbeError("empty-gtk-entry-at-200-percent-required")
    entry_box = wait_for(lambda: next(windows("--name", "^Y700 input fixture$"), None), "gtk-test-window-not-visible")
    scale = accessible_scale(entry_box)
    entry = wait_for(lambda: visible_named(lambda name: name == "Y700 text entry",
                                           (Atspi.Role.TEXT, Atspi.Role.ENTRY)), "gtk-entry-not-accessible")
    ready = wait_for(lambda: visible_named(lambda name: name == "Ready", (Atspi.Role.PUSH_BUTTON,)),
                     "gtk-non-editable-focus-target-not-accessible")
    if entry.get_state_set().contains(Atspi.StateType.FOCUSED):
        raise ProbeError("gtk-entry-already-focused-before-tap")
    touch_accessible(entry, scale)
    try:
        keyboard = wait_for(keyboard_geometry, "stock-onboard-did-not-auto-show", 5)
    except ProbeError:
        # A freshly started accessibility listener can miss the initial focus event.
        touch_accessible(ready, scale)
        wait_for(lambda: ready.get_state_set().contains(Atspi.StateType.FOCUSED),
                 "gtk-non-editable-focus-transition-missing")
        touch_accessible(entry, scale)
        keyboard = wait_for(keyboard_geometry, "stock-onboard-did-not-auto-show")
    layout = Gio.Settings.new("org.onboard").get_string("layout")
    if layout and Path(layout).stem != "Compact":
        raise ProbeError("stock-compact-keyboard-required")
    print(f"CHINESE_INPUT_ONBOARD layout=Compact geometry={keyboard}", flush=True)
    bus = IBus.Bus.new()
    wait_for(lambda: current_engine(bus) == "xkb:us::eng", "configured-english-engine-not-active")
    panel_clicks = []
    if os.environ.get("CHINESE_INPUT_DISCOVERY") == "1":
        bus.get_connection().signal_subscribe(
            None, "org.freedesktop.IBus.Panel", "CandidateClicked", "/org/freedesktop/IBus/Panel",
            None, Gio.DBusSignalFlags.NONE,
            lambda _bus, _sender, _path, _interface, _member, values: panel_clicks.append(values.unpack()),
        )
    switch_engine(bus, "libpinyin", lambda name: "Intelligent Pinyin" in name, scale)
    touch_accessible(entry, scale)
    type_onboard("nihao")
    candidate = wait_for(lambda: visible_named(lambda name: name.strip() == "你好", (Atspi.Role.LABEL,)),
                         "matching-libpinyin-candidate-not-visible")
    if state()["committed"] != "" or not state()["preedit"]:
        raise ProbeError("pinyin-was-not-preedit-before-the-candidate-tap")
    if os.environ.get("CHINESE_INPUT_DISCOVERY") == "1":
        position = rect(candidate)
        print(f"CHINESE_INPUT_CANDIDATE_DEBUG app={candidate.get_application().get_name()} "
              f"x={position.x} y={position.y} w={position.width} h={position.height} state={state()}", flush=True)
        for label in visible_named_nodes(lambda name: name.strip() == "你好", (Atspi.Role.LABEL,)):
            parent = label
            path = []
            for _ in range(5):
                if not parent:
                    break
                branch_position = rect(parent)
                path.append((parent.get_role_name(), parent.get_name(),
                             branch_position.x, branch_position.y, branch_position.width, branch_position.height))
                parent = parent.get_parent()
            print(f"CHINESE_INPUT_CANDIDATE_TREE {path}", flush=True)
        for box in windows("--class", "^Ibus-ui-gtk3$"):
            print(f"CHINESE_INPUT_IBUS_WINDOW {box}", flush=True)
        screenshot()
    selector = os.environ.get("CHINESE_INPUT_CANDIDATE", "number")
    if selector not in ("number", "word"):
        raise ProbeError("unknown-popup-selector")
    original_preedit = state()["preedit"]

    def committed():
        current = state()
        return current["committed"] == "你好" and not current["preedit"]

    clicked = False
    attempts = 0
    for attempt in (1, 2):
        candidate = visible_named(lambda name: name.strip() == "你好", (Atspi.Role.LABEL,))
        if not candidate or state()["committed"] or state()["preedit"] != original_preedit:
            break
        target = candidate_number(candidate) if selector == "number" else candidate
        if not target:
            raise ProbeError("number-for-matching-candidate-not-visible")
        position = rect(target)
        target_x = (position.x + position.width // 2) * scale
        target_y = (position.y + position.height // 2) * scale
        command("xdotool", "mousemove", str(target_x), str(target_y))
        chain = pointer_input_windows()
        if not chain or '"ibus-ui-gtk3"' not in chain[0][1]:
            raise ProbeError("candidate-tap-target-not-owned-by-ibus-panel")
        print(f"CHINESE_INPUT_POPUP selector={selector} attempt={attempt} ibus_input_window=1", flush=True)
        if os.environ.get("CHINESE_INPUT_DISCOVERY") == "1":
            print(f"CHINESE_INPUT_POINTER_CHAIN {chain}", flush=True)
        tap(target_x, target_y)
        attempts = attempt
        try:
            wait_for(committed, "candidate-tap-did-not-commit-chinese-in-gtk", 3)
            clicked = True
            break
        except ProbeError:
            print(f"CHINESE_INPUT_AFTER_CANDIDATE {state()}", flush=True)
    if not clicked:
        selector = "space"
        type_onboard(" ")
        wait_for(committed, "onboard-space-did-not-commit-candidate")
    if os.environ.get("CHINESE_INPUT_DISCOVERY") == "1":
        print(f"CHINESE_INPUT_IBUS_CANDIDATE_CLICKED {panel_clicks}", flush=True)
    print(f"CHINESE_INPUT_GTK pinyin_osk_letters=5 candidate_pointer_tap={int(selector != 'space')} "
          f"selector={selector} candidate_taps={attempts} text=你好 scale=2", flush=True)
    switch_engine(bus, "xkb:us::eng", lambda name: "English" in name and "US" in name, scale)
    touch_accessible(entry, scale)
    type_onboard(" hello")
    wait_for(lambda: state()["committed"] == "你好 hello" and not state()["preedit"],
             "ordinary-english-did-not-commit-in-gtk-after-switch")
    print("CHINESE_INPUT_GTK_LATIN tray_switch=1 text=你好_hello", flush=True)
    if selector == "space":
        raise ProbeError("candidate-tap-did-not-commit-chinese-in-gtk")
    print("CHINESE_INPUT_UI_PASS", flush=True)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as error:
        print(f"CHINESE_INPUT_ERROR {error}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as error:
        print(f"CHINESE_INPUT_ERROR {type(error).__name__}", file=sys.stderr)
        raise SystemExit(1)
