#!/usr/bin/python3
"""A touch-sized quick settings shade for the tablet's Xfce session."""
from concurrent.futures import ThreadPoolExecutor
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk

from devices import audio, backlight, bluetooth


ZH = GLib.get_language_names()[0].startswith("zh")


def tr(english, chinese):
    return chinese if ZH else english


TITLE = tr("Quick settings", "快捷设置")
BUTTON = Gtk.IconSize.LARGE_TOOLBAR


class Level(Gtk.Box):
    def __init__(self, name, minimum, icon, callback):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.callback = callback
        self.contact = None
        header = Gtk.Box(spacing=8)
        header.add(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON))
        header.add(Gtk.Label(label=name))
        self.value = Gtk.Label(label="—")
        header.pack_end(self.value, False, False, 0)
        self.add(header)
        self.scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, minimum, 100, 1)
        self.scale.set_draw_value(False)
        self.scale.set_increments(1, 10)
        self.scale.set_size_request(-1, 48)
        self.scale.get_accessible().set_name(name)
        self.add(self.scale)
        self.changed = self.scale.connect("value-changed", self.slide)
        self.scale.connect("touch-event", self.touch_begin)
        self.scale.connect("event-after", self.touch_end)
        self.scale.set_sensitive(False)

    def touch_begin(self, _scale, event):
        if event.type == Gdk.EventType.TOUCH_BEGIN and self.contact is None:
            self.contact = event.get_event_sequence()
        return False

    def touch_end(self, scale, event):
        if event.type not in (Gdk.EventType.TOUCH_END, Gdk.EventType.TOUCH_CANCEL):
            return
        if self.contact != event.get_event_sequence():
            return
        self.contact = None
        if event.type == Gdk.EventType.TOUCH_END:
            self.slide(scale)

    def slide(self, scale):
        value = round(scale.get_value())
        self.value.set_text(f"{value}%")
        if self.contact is None:
            self.callback(value)

    def show_value(self, value):
        self.scale.set_sensitive(value is not None)
        if self.contact is None:
            self.value.set_text("—" if value is None else f"{value}%")
            if value is not None:
                with self.scale.handler_block(self.changed):
                    self.scale.set_value(value)


class QuickWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title=TITLE)
        self.set_role("y700-quick-settings")
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.DIALOG)
        self.set_resizable(False)
        self.set_name("quick-shade")
        self.connect("delete-event", lambda *_: self.hide_on_delete())
        self.connect("key-press-event", self.key)
        self.connect("focus-out-event", self.lost_focus)
        self.connect("hide", self.hidden)
        self.timer = 0
        self.disposed = False
        self.pool = ThreadPoolExecutor(max_workers=3, thread_name_prefix="quick-settings")
        self.busy = set()
        self.queued = {}
        self.states = {}
        self.failed_write = {}
        self.levels = {}
        self.connect("destroy", self.dispose)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9, margin=16)
        self.add(body)
        head = Gtk.Box(spacing=8)
        caption = Gtk.Label(label=TITLE, xalign=0)
        caption.get_style_context().add_class("quick-title")
        head.pack_start(caption, True, True, 0)
        close = Gtk.Button.new_from_icon_name("window-close-symbolic", BUTTON)
        close.set_relief(Gtk.ReliefStyle.NONE)
        close.set_size_request(48, 48)
        close.get_accessible().set_name(tr("Close", "关闭"))
        close.connect("clicked", lambda *_: self.hide())
        head.add(close)
        body.add(head)
        self.levels["brightness"] = Level(tr("Brightness", "亮度"), 5, "display-brightness-symbolic",
                                          lambda v: self.work("brightness", {"value": v}))
        body.add(self.levels["brightness"])
        self.levels["volume"] = Level(tr("Volume", "音量"), 0, "audio-volume-high-symbolic",
                                      lambda v: self.work("audio", {"volume": v}))
        vol = Gtk.Box(spacing=8)
        vol.pack_start(self.levels["volume"], True, True, 0)
        self.mute = Gtk.ToggleButton()
        self.mute.set_size_request(52, 48)
        self.mute.set_valign(Gtk.Align.END)
        self.mute.get_accessible().set_name(tr("Mute", "静音"))
        self.mute.set_tooltip_text(tr("Mute", "静音"))
        self.mute.connect("clicked", lambda b: self.write_switch("audio", {"mute": b.get_active()}))
        vol.add(self.mute)
        body.add(vol)
        tiles = Gtk.Box(spacing=10, homogeneous=True)
        self.radio = self.tile(tiles, tr("Bluetooth", "蓝牙"), "bluetooth-symbolic")
        self.radio.connect("clicked", lambda b: self.write_switch("bluetooth", {"value": b.get_active()}))
        self.rotate = self.tile(tiles, tr("Auto-rotate", "自动旋转"), "object-rotate-right-symbolic")
        self.rotate.connect("clicked", self.rotate_clicked)
        body.add(tiles)
        source = Gio.SettingsSchemaSource.get_default()
        schema = source.lookup("org.y700.tablet", True) if source else None
        self.rotation = Gio.Settings.new_full(schema, None, None) if schema and schema.has_key("auto-rotate") else None
        self.painting = False
        self.rotation_changed = (self.rotation.connect("changed::auto-rotate", self.rotation_read)
                                 if self.rotation else None)
        self.errors = Gtk.Label(xalign=0, wrap=True, max_width_chars=42)
        self.errors.set_no_show_all(True)
        body.add(self.errors)
        self.radio.set_sensitive(False)
        self.mute.set_sensitive(False)
        body.show_all()

    @staticmethod
    def tile(box, name, icon):
        button = Gtk.ToggleButton()
        row = Gtk.Box(spacing=7, halign=Gtk.Align.CENTER)
        row.add(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON))
        labels = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER)
        labels.add(Gtk.Label(label=name, xalign=0))
        status = Gtk.Label(label="—", xalign=0)
        status.get_style_context().add_class("dim-label")
        labels.add(status)
        row.add(labels)
        button.add(row)
        button.status = status
        button.get_accessible().set_name(name)
        button.set_size_request(-1, 54)
        box.add(button)
        return button

    def rotation_read(self, *_args):
        self.painting = True
        self.rotate.set_sensitive(self.rotation is not None and self.rotation.is_writable("auto-rotate"))
        active = bool(self.rotation and self.rotation.get_boolean("auto-rotate"))
        self.rotate.set_active(active)
        self.rotate.status.set_text(self.switch_text(active) if self.rotation else "—")
        self.painting = False

    @staticmethod
    def switch_text(active):
        return tr("On", "已开启") if active else tr("Off", "已关闭")

    def rotate_clicked(self, button):
        if self.painting or self.rotation is None:
            return
        if not self.rotation.set_boolean("auto-rotate", button.get_active()):
            self.failed_write["rotation"] = True
        else:
            self.failed_write.pop("rotation", None)
        self.rotation_read()
        self.update_errors()

    def write_switch(self, key, change):
        if not self.painting:
            self.work(key, change)

    def key(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.hide()
            return True
        return False

    def lost_focus(self, *_args):
        # Let the WM move focus to this window before checking dismissal.
        GLib.idle_add(self.dismiss_if_inactive)
        return False

    def dismiss_if_inactive(self):
        if self.get_visible() and not self.is_active():
            self.hide()
        return False

    def hidden(self, *_args):
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0
        for level in self.levels.values():
            level.contact = None

    def dispose(self, *_args):
        self.hidden()
        self.disposed = True
        if self.rotation_changed:
            self.rotation.disconnect(self.rotation_changed)
        self.pool.shutdown(wait=False, cancel_futures=True)

    def position(self, tray):
        display = self.get_display()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        area = monitor.get_workarea()
        anchor = None
        if tray and tray.is_embedded():
            ok, _screen, rect, _orientation = tray.get_geometry()
            if ok:
                monitor = display.get_monitor_at_point(rect.x, rect.y)
                area = monitor.get_workarea()
                anchor = rect
        width = min(420, area.width)
        self.set_size_request(width, -1)
        x = (area.x + area.width - width) if anchor is None else anchor.x + anchor.width - width
        y = area.y if anchor is None else max(area.y, anchor.y + anchor.height)
        self.move(max(area.x, min(x, area.x + area.width - width)), y)

    def open(self, tray):
        self.position(tray)
        self.rotation_read()
        self.refresh()
        self.show()
        self.present()
        if not self.timer:
            self.timer = GLib.timeout_add(1200, self.refresh)

    def refresh(self):
        for key in ("brightness", "audio", "bluetooth"):
            self.work(key)
        return True

    def work(self, key, change=None):
        if key in self.busy:
            if change is not None:
                self.queued.setdefault(key, {}).update(change)
            return
        self.busy.add(key)
        operations = {"brightness": backlight, "audio": audio, "bluetooth": bluetooth}
        argument = change if key == "audio" else (change or {}).get("value")
        future = self.pool.submit(operations[key], argument)
        future.add_done_callback(lambda f: GLib.idle_add(self.completed, key, change is not None, f))

    def completed(self, key, writing, future):
        self.busy.discard(key)
        if self.disposed:
            return False
        try:
            state = future.result()
        except Exception:
            state = None
            if writing:
                self.failed_write[key] = True
        else:
            if writing:
                self.failed_write.pop(key, None)
        queued = self.queued.pop(key, None)
        if queued:
            self.work(key, queued)
            return False
        self.states[key] = state
        self.painting = True
        if key == "audio":
            self.levels["volume"].show_value(state[0] if state else None)
            muted = state[1] if state else False
            self.mute.set_active(muted)
            self.mute.set_sensitive(state is not None)
            name = "audio-volume-muted-symbolic" if muted else "audio-volume-high-symbolic"
            self.mute.set_image(Gtk.Image.new_from_icon_name(name, Gtk.IconSize.BUTTON))
        elif key == "bluetooth":
            self.radio.set_sensitive(state is not None)
            self.radio.set_active(bool(state))
            self.radio.status.set_text(self.switch_text(state) if state is not None else "—")
        else:
            self.levels[key].show_value(state)
        self.painting = False
        self.update_errors()
        return False

    def update_errors(self):
        names = {"audio": tr("Volume", "音量"), "bluetooth": tr("Bluetooth", "蓝牙"),
                 "brightness": tr("Brightness", "亮度"), "rotation": tr("Auto-rotate", "自动旋转")}
        bad = [label for key, label in names.items() if key in self.failed_write or
               (key in self.states and self.states[key] is None) or (key == "rotation" and not self.rotation)]
        text = ", ".join(bad)
        self.errors.set_text(tr("Unavailable: ", "暂时无法设置：") + text if bad else "")
        self.errors.set_visible(bool(bad))


class QuickSettings(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="org.y700.QuickSettings",
                         flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.tray = None
        self.window = None
        self.press = None
        self.locked = False
        self.screen_subscription = None
        self.screen_watch = 0

    def do_startup(self):
        Gtk.Application.do_startup(self)
        css = Gtk.CssProvider()
        css.load_from_data(b"""
            #quick-shade { border: 1px solid alpha(currentColor,.24); }
            #quick-shade .quick-title { font-size: 1.25em; font-weight: bold; }
            #quick-shade button:checked { background-image: none; background-color: @theme_selected_bg_color;
                                         color: @theme_selected_fg_color; }
            #quick-shade scale slider { min-width: 20px; min-height: 20px; }
        """)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.hold()

    def do_command_line(self, command):
        args = command.get_arguments()[1:]
        if args == ["--quit"]:
            self.quit()
        elif args in ([], ["--tray"]):
            self.ensure_tray()
            if not args:
                self.open()
        else:
            command.printerr_literal("Usage: y700-quick-settings [--tray|--quit]\n")
            return 2
        return 0

    def do_activate(self):
        self.ensure_tray()
        self.open()

    def ensure_tray(self):
        if self.tray:
            return
        self.tray = Gtk.StatusIcon.new_from_icon_name("preferences-system-symbolic")
        self.tray.set_title(TITLE)
        self.tray.set_tooltip_text(TITLE)
        self.tray.set_name("y700-quick-settings")
        self.tray.connect("button-press-event", self.tray_press)
        self.tray.connect("button-release-event", self.tray_release)
        self.tray.connect("activate", lambda *_: self.toggle())
        self.tray.set_visible(True)
        self.screen_watch = Gio.bus_watch_name(Gio.BusType.SESSION, "org.xfce.ScreenSaver",
                                                Gio.BusNameWatcherFlags.NONE, self.saver_appeared,
                                                self.saver_gone)
        Gdk.Screen.get_default().connect("size-changed", self.screen_changed)

    def screen_changed(self, *_args):
        if self.window and self.window.get_visible():
            self.window.position(self.tray)

    def saver_appeared(self, bus, _name, owner):
        def changed(_bus, _sender, _path, _interface, _signal, args):
            self.set_locked(args.unpack()[0])
        self.clear_saver()
        sub = bus.signal_subscribe(owner, "org.xfce.ScreenSaver", "ActiveChanged", "/org/xfce/ScreenSaver",
                                   None, Gio.DBusSignalFlags.NONE, changed)
        self.screen_subscription = bus, sub
        # Check the current session, including an independently started locker.
        def initial(connection, result):
            try:
                value, = connection.call_finish(result).unpack()
            except GLib.Error:
                return
            if self.screen_subscription == (bus, sub):
                self.set_locked(value)
        bus.call(owner, "/org/xfce/ScreenSaver", "org.xfce.ScreenSaver", "GetActive", None,
                 GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE, 1500, None, initial)

    def set_locked(self, locked):
        self.locked = locked
        if locked:
            self.press = None
            if self.window:
                self.window.hide()

    def clear_saver(self):
        if self.screen_subscription:
            bus, sub = self.screen_subscription
            bus.signal_unsubscribe(sub)
            self.screen_subscription = None

    def saver_gone(self, *_args):
        self.clear_saver()
        self.set_locked(False)

    def tray_press(self, _icon, event):
        if event.button != 1:
            return False
        self.press = event.x_root, event.y_root
        return True

    def tray_release(self, _icon, event):
        if event.button != 1 or self.press is None:
            return False
        x, y = self.press
        self.press = None
        dx, dy = event.x_root - x, event.y_root - y
        if dy >= 18 and dy > abs(dx):
            self.open()
        elif abs(dx) <= 15 and abs(dy) <= 15:
            self.toggle()
        return True

    def open(self):
        if self.locked:
            return
        if self.window is None:
            self.window = QuickWindow(self)
        self.window.open(self.tray)

    def toggle(self):
        if self.window and self.window.get_visible():
            self.window.hide()
        else:
            self.open()

    def do_shutdown(self):
        if self.window:
            self.window.destroy()
        if self.tray:
            self.tray.set_visible(False)
        self.clear_saver()
        if self.screen_watch:
            Gio.bus_unwatch_name(self.screen_watch)
        Gtk.Application.do_shutdown(self)


if __name__ == "__main__":
    sys.exit(QuickSettings().run(sys.argv))
