"""Observe a user's English and Chinese Xfce sign-ins on a disposable image."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import time
import traceback

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, GLib, Gtk


def wait_for(check, timeout=120):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = check()
        if value:
            return value
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
        time.sleep(0.25)
    raise TimeoutError(check.__name__)


def account_language():
    service = "org.freedesktop.Accounts"
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    path = bus.call_sync(service, "/org/freedesktop/Accounts", service, "FindUserById",
                         GLib.Variant("(x)", (os.getuid(),)), None,
                         Gio.DBusCallFlags.NONE, 3000, None).unpack()[0]
    return bus.call_sync(service, path, "org.freedesktop.DBus.Properties", "Get",
                         GLib.Variant("(ss)", (service + ".User", "Language")), None,
                         Gio.DBusCallFlags.NONE, 3000, None).unpack()[0]


def button_center():
    # Coordinates are required only by the 1024×768 virtual contact fixture.
    result = subprocess.run(["xwininfo", "-name", "Display language"], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if result.returncode or "Map State: IsViewable" not in result.stdout:
        return None
    fields = ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height")
    bounds = [re.search(field + r":\s+(-?\d+)\b", result.stdout) for field in fields]
    if all(bounds):
        x, y, width, height = (int(match[1]) for match in bounds)
        if x > 100 and y > 100 and 300 <= width <= 1024 and 90 <= height <= 600:
            return x + int(width * 0.73), y + height // 2


def button_text(button):
    if isinstance(button, Gtk.Label):
        return [button.get_text()]
    if isinstance(button, Gtk.Container):
        return [text for child in button.get_children() for text in button_text(child)]
    return []


def observe(state, touch_target):
    def emit(message):
        with (state / "events").open("a", encoding="utf-8") as log:
            print(message, file=log, flush=True)

    try:
        uid = os.getuid()
        sid = os.environ["XDG_SESSION_ID"]
        assert uid != 0 and sid.isdecimal()
        properties = subprocess.check_output(["loginctl", "show-session", sid], text=True)
        session = dict(line.split("=", 1) for line in properties.splitlines() if "=" in line)
        expected = {"Service": "lightdm", "Type": "x11", "Class": "user",
                    "Seat": "seat0", "Active": "yes", "User": str(uid)}
        assert all(session.get(key) == value for key, value in expected.items()), sid

        first = state / "first-session"
        phase = 2 if first.is_file() else 1
        lang = os.environ["LANG"]
        effective = GLib.get_language_names()[0]
        emit(f"Y700_LANG_SESSION phase={phase} sid={sid} LANG={lang} glib={effective} "
             f"LANGUAGE={os.getenv('LANGUAGE', '')} GDM_LANG={os.getenv('GDM_LANG', '')} "
             f"saved={account_language()} service=lightdm type=x11 class=user active=yes")
        if phase == 1:
            assert lang.startswith("en_US") and effective.startswith("en")
            assert Gio.DesktopAppInfo.new("y700-display-language.desktop").launch([], None)
            target = "user"
            if touch_target:
                x, y = wait_for(button_center)
                target = f"{x} {y}"
            emit("Y700_LANG_CHOICE " + target)
            wait_for(lambda: account_language() in ("zh_CN.UTF-8", "zh_CN.utf8"))
            assert os.environ["LANG"] == lang and GLib.get_language_names()[0] == effective
            first.write_text(sid, encoding="ascii")
            emit("Y700_LANG_SAVED account=zh_CN.UTF-8 current_session_unchanged")
            return

        assert first.read_text(encoding="ascii") != sid
        assert lang in ("zh_CN.UTF-8", "zh_CN.utf8") and effective.startswith("zh_CN")
        assert account_language() in ("zh_CN.UTF-8", "zh_CN.utf8")
        dialog = Gtk.MessageDialog(message_type=Gtk.MessageType.INFO, buttons=Gtk.ButtonsType.OK_CANCEL,
                                   text="Y700 GTK locale")
        dialog.show_all()
        translated = button_text(dialog.get_widget_for_response(Gtk.ResponseType.CANCEL))
        assert any("取消" in label for label in translated), translated
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
        (state / "second-session").write_text(sid, encoding="ascii")
        emit("Y700_LANG_TRANSLATED_GTK standard_dialog_cancel=" + "/".join(translated))
        GLib.timeout_add_seconds(12, Gtk.main_quit)
        Gtk.main()
        dialog.destroy()
    except Exception:
        emit("Y700_LANG_SESSION_ERROR " + traceback.format_exc().replace("\n", " "))
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state", type=Path, help="Private user directory shared across the two logins")
    parser.add_argument("--report-touch-target", action="store_true",
                        help="Report the Chinese button center on the reference virtual 1024×768 seat")
    args = parser.parse_args()
    info = args.state.stat()
    if not args.state.is_dir() or info.st_uid != os.getuid() or info.st_mode & 0o077:
        parser.error("Create a private directory owned by the test user")
    observe(args.state, args.report_touch_target)
