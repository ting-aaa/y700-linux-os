"""Open the two production GTK programs on the private test display and inspect their controls."""
import argparse
import re
import time
from pathlib import Path

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Atspi, Gdk, Gio, GLib


def nodes(root):
    pending = [root]
    while pending:
        item = pending.pop()
        if item is None:
            continue
        yield item
        if item.get_role() != Atspi.Role.TREE_TABLE:
            pending.extend(item.get_child_at_index(i) for i in range(item.get_child_count()))


def main(allow_saved, expect_no_service):
    Gdk.init([])
    app = Gio.DesktopAppInfo.new("y700-software-updates.desktop")
    assert app and app.should_show() and app.get_executable() == "y700-software-updates"
    display = Gdk.Display.get_default()
    monitor = display.get_primary_monitor() or display.get_monitor(0)
    assert monitor.get_scale_factor() == 2
    desktop = Atspi.get_desktop(0)
    assert app.launch([], None)
    deadline = time.monotonic() + 170
    saw_refresh = False
    saw_error = False
    opened_saved = False
    while time.monotonic() < deadline:
        try:
            for i in range(desktop.get_child_count()):
                program = desktop.get_child_at_index(i)
                rows = candidates = 0
                buttons = {}
                for node in nodes(program):
                    role = node.get_role()
                    name = node.get_name() or ""
                    if role == Atspi.Role.LABEL:
                        if name == "Checking Debian for updates…":
                            saw_refresh = True
                        if name.startswith("Could not check for updates."):
                            if not (allow_saved or expect_no_service):
                                raise RuntimeError(name)
                            saw_refresh = True
                            saw_error = True
                        label = re.fullmatch(r"There (?:are|is) (\d+) updates? available", name.rstrip("."))
                        if label:
                            candidates = int(label[1])
                    if (role == Atspi.Role.PUSH_BUTTON and name == "View saved list"
                            and allow_saved and saw_error and not opened_saved):
                        opened_saved = node.get_action_iface().do_action(0)
                    if role == Atspi.Role.PUSH_BUTTON and node.get_state_set().contains(Atspi.StateType.SHOWING):
                        buttons[name] = node
                    if role == Atspi.Role.TREE_TABLE:
                        rows = node.get_table_iface().get_n_rows()
                binary = Path(f"/proc/{program.get_process_id()}/exe")
                if expect_no_service and saw_error and {"Retry", "Close"} <= buttons.keys():
                    assert "View saved list" not in buttons
                    assert buttons["Close"].get_action_iface().do_action(0)
                    print("GTK_SOFTWARE_UPDATES desktop_entry=1 scale=2 no_backend_error_visible=1 retry_visible=1 empty_cache_hidden=1 close=1", flush=True)
                    return
                if rows >= candidates > 0 and saw_refresh and binary.resolve().name == "gpk-update-viewer":
                    print(f"GTK_SOFTWARE_UPDATES desktop_entry=1 scale=2 refresh_window=1 refresh_error={int(saw_error)} saved_list_selected={int(opened_saved)} table_rows={rows} update_candidates={candidates} real_viewer=1", flush=True)
                    return
        except GLib.Error:
            # The refresh window exits when the update selector opens.
            pass
        time.sleep(0.2)
    states = []
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        states.append((app.get_name(), [(n.get_role_name(), n.get_name()) for n in nodes(app)][:30]))
    raise RuntimeError(f"No populated GTK update selector in the private session: {states}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--allow-saved", action="store_true")
    mode.add_argument("--expect-no-service", action="store_true")
    args = parser.parse_args()
    main(args.allow_saved, args.expect_no_service)
