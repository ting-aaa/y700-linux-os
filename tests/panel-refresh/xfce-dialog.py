"""Drive the installed Xfce refresh controls over AT-SPI on a private X server."""
import os
import subprocess
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Atspi, Gdk, GLib


def children(node):
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child is not None:
            yield child


def shown(node):
    return node.get_state_set().contains(Atspi.StateType.SHOWING)


def find(node, role, name):
    if node.get_role() == role and node.get_name() == name and shown(node):
        return node
    for child in children(node):
        match = find(child, role, name)
        if match:
            return match


def wait_for(query, description):
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        try:
            result = query()
        except GLib.Error:
            result = None
        if result:
            return result
        time.sleep(.2)
    raise TimeoutError(description)


def active_mode():
    listing = subprocess.check_output(["/usr/bin/xrandr", "--current"], text=True)
    return next(line.split()[0] for line in listing.splitlines() if line.startswith("   ") and "*" in line)


def main():
    assert os.getuid() == 1000
    Atspi.init()
    Atspi.set_timeout(4500, 4500)
    assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
    version = subprocess.check_output(["dpkg-query", "-W", "-f=${Version}", "xfce4-settings"], text=True)
    assert version == "4.20.1-1" and active_mode() == "portrait120"
    proc = subprocess.Popen(["/usr/bin/xfce4-display-settings"])
    try:
        def dialog():
            for app in children(Atspi.get_desktop(0)):
                if app.get_process_id() == proc.pid:
                    return next((win for win in children(app) if win.get_name() == "Display" and shown(win)), None)

        win = wait_for(dialog, "display dialog")
        combo = find(win, Atspi.Role.COMBO_BOX, "120.00 Hz")
        apply = find(win, Atspi.Role.PUSH_BUTTON, "Apply")
        choices = [item.get_name() for item in children(combo.get_child_at_index(0))]
        assert sorted(choices) == ["120.00 Hz", "60.00 Hz"]

        def confirmation():
            for popup in children(win.get_parent()):
                if popup != win:
                    button = find(popup, Atspi.Role.PUSH_BUTTON, "Keep this configuration")
                    if button:
                        return button

        for rate in (60, 120):
            label = f"{rate}.00 Hz"
            assert combo.get_selection_iface().select_child(choices.index(label))
            wait_for(lambda: combo.get_name() == label and apply.get_state_set().contains(Atspi.StateType.SENSITIVE),
                     "selected rate")
            assert apply.get_action_iface().do_action(0)
            keep = wait_for(confirmation, "confirmation dialog")
            assert keep.get_action_iface().do_action(0)
            wait_for(lambda: active_mode() == f"portrait{rate}", "RandR rate")
            wait_for(lambda: confirmation() is None, "confirmation dismissed")
            print(f"XFCE_DISPLAY_CONFIRM_PASS rate={rate} gtk_scale=2 method=atspi", flush=True)
        print(f"XFCE_DISPLAY_DIALOG_PASS sequence=120,60,120 actual_package={version}", flush=True)
    finally:
        proc.terminate()
        proc.wait(timeout=8)


if __name__ == "__main__":
    main()
