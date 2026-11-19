"""An ordinary GTK entry that reports its committed text and preedit to the test."""

import json
import os
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk


state = Path(os.environ["CHINESE_INPUT_TEST_DIR"]) / "entry.json"
window = Gtk.Window(title="Y700 input fixture")
lower = os.environ.get("CHINESE_INPUT_POSITION") == "lower"
window.set_default_size(470, 100 if lower else 50)
window.move(140, 100 if lower else 0)
window.connect("destroy", Gtk.main_quit)
entry = Gtk.Entry()
entry.set_placeholder_text("Input fixture")
entry.get_accessible().set_name("Y700 text entry")
entry.set_margin_start(20)
entry.set_margin_end(20)
entry.set_margin_top(24 if lower else 6)
entry.set_margin_bottom(24 if lower else 6)
ready = Gtk.Button(label="Ready")
ready.set_valign(Gtk.Align.CENTER)
ready.set_margin_end(16)
content = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
content.pack_start(entry, True, True, 0)
content.pack_start(ready, False, False, 0)
window.add(content)

preedit = ""


def report(*_):
    pending = state.with_suffix(".tmp")
    pending.write_text(json.dumps({
        "committed": entry.get_text(),
        "preedit": preedit,
        "scale": window.get_scale_factor(),
    }, ensure_ascii=False), encoding="utf-8")
    pending.replace(state)


def preedit_changed(_entry, value):
    global preedit
    preedit = value
    report()


entry.connect("preedit-changed", preedit_changed)
entry.connect("changed", report)
window.show_all()
ready.grab_focus()
window.present()
report()
Gtk.main()
