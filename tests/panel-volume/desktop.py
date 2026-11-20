"""Verify the real Xfce panel and PulseAudio applet in a private X11 session."""
import configparser
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time

import gi

gi.require_version("Gdk", "3.0")
from gi.repository import Gdk


CHANNEL = ("xfconf-query", "-c", "xfce4-panel")
PACTL = os.environ["QA_PACTL"]
AUTOSTART = "/etc/xdg/autostart/y700-session.desktop"
STATE = Path(os.environ["XDG_STATE_HOME"])
MARKER = "y700/panel-audio-v1"
LOG = Path(os.environ["XDG_RUNTIME_DIR"])
SINK = "y700_test_sink"
KEYBOARD = ("xfconf-query", "-c", "xfce4-keyboard-shortcuts")
OWNER_KEY = "/commands/custom/XF86AudioLowerVolume"
panel = None
worker = None


def run(*args, timeout=8):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=timeout).strip()


def wait_for(check, description, seconds=22):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.3)
    raise TimeoutError(description)


def config(path):
    return run(*CHANNEL, "-p", path)


def ids(path):
    return tuple(int(line) for line in config(path).splitlines() if line.isdecimal())


def layout():
    return {panel_id: ids(f"/panels/panel-{panel_id}/plugin-ids") for panel_id in ids("/panels")}


def plugin_name(plugin_id):
    return config(f"/plugins/plugin-{plugin_id}")


def audio_items(current):
    return [(panel_id, item) for panel_id, items in current.items() for item in items
            if plugin_name(item) == "pulseaudio"]


def volumes():
    sinks = json.loads(run(PACTL, "--format=json", "list", "sinks"))
    assert len(sinks) == 1 and sinks[0]["name"] == SINK, sinks
    sink = sinks[0]
    sample = tuple(sink["volume"][channel]["value"] for channel in ("front-left", "front-right"))
    return (*sample, sink["mute"])


def start_panel():
    global panel
    with (LOG / "panel.log").open("a") as trace:
        panel = subprocess.Popen(["xfce4-panel"], stdout=trace, stderr=trace, start_new_session=True)
    wait_for(lambda: '"xfce4-panel"' in run("xwininfo", "-root", "-tree"), "real Xfce panel window")
    wait_for(lambda: layout().keys() == {1, 2}, "stock two-panel layout")


def stop_panel():
    global panel
    run("xfce4-panel", "--quit")
    panel.wait(timeout=10)
    panel = None
    wait_for(lambda: '"xfce4-panel"' not in run("xwininfo", "-root", "-tree"), "panel had not closed")


def stop_worker():
    global worker
    if worker is not None:
        try:
            os.killpg(worker.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        worker.wait(timeout=10)
        worker = None


def invoke(startup_state):
    global worker
    stop_worker()
    desktop = configparser.ConfigParser(interpolation=None)
    desktop.read(AUTOSTART)
    entry = desktop["Desktop Entry"]
    assert "XFCE" in entry["OnlyShowIn"].split(";")
    args = shlex.split(entry["Exec"])
    assert args == ["/usr/libexec/y700-session"], args
    with (LOG / "autostart.log").open("a") as trace:
        worker = subprocess.Popen(
            args, env={**os.environ, "XDG_STATE_HOME": str(startup_state)},
            stdout=trace, stderr=trace, start_new_session=True,
        )


def wrappers():
    found = {}
    display = f"DISPLAY={os.environ['DISPLAY']}".encode()
    for filename in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            args = filename.read_bytes().split(b"\0")
            module = next((i for i, arg in enumerate(args) if arg.endswith(b"/libpulseaudio-plugin.so")), None)
            if module is None or display not in filename.with_name("environ").read_bytes().split(b"\0"):
                continue
            plugin_id, socket = map(int, args[module + 1:module + 3])
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        assert plugin_id not in found, found
        found[plugin_id] = socket
    return found


def visible(plugin_id):
    socket = wrappers().get(plugin_id)
    if socket is None:
        return None
    state = run("xwininfo", "-id", hex(socket))
    if "Map State: IsViewable" not in state:
        return None
    bounds = tuple(int(re.search(rf"{field}: +(-?\d+)", state)[1]) for field in
                   ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height"))
    x, y, width, height = bounds
    if x >= 0 and y >= 0 and width >= 40 and height >= 40:
        return bounds
    return None


def panel_configure(panel_id, items):
    args = [arg for item in items for arg in ("-t", "int", "-s", str(item))]
    run(*CHANNEL, "-p", f"/panels/panel-{panel_id}/plugin-ids", "-a", *args)


def no_chooser():
    tree = run("xwininfo", "-root", "-tree")
    assert "Add New Item" not in tree


def stable(expected, label):
    assert volumes() == expected, volumes()
    print(f"PANEL_AUDIO_PRESERVED case={label} raw={expected[0]},{expected[1]} mute={int(expected[2])}", flush=True)


def media_keys(original):
    try:
        run(PACTL, "set-sink-mute", SINK, "0")
        previous = (*original[:2], False)
        wait_for(lambda: volumes() == previous, "fixture unmute")
        for key, delta in (("XF86AudioLowerVolume", -1), ("XF86AudioRaiseVolume", 1)):
            run("xdotool", "key", key)

            def change():
                sample = volumes()
                if (sample[0] - previous[0]) * delta > 0 and sample[0] == sample[1] and not sample[2]:
                    return sample
                return None

            after = wait_for(change, key, seconds=8)
            print(f"PANEL_MEDIA key={key} before={previous[0]} after={after[0]}", flush=True)
            previous = after
        run("xdotool", "key", "XF86AudioMute")
        wait_for(lambda: volumes() == (*previous[:2], True), "XF86AudioMute")
        print(f"PANEL_MEDIA key=XF86AudioMute raw={previous[0]} mute=1", flush=True)
    finally:
        run(PACTL, "set-sink-volume", SINK, *(str(value) for value in original[:2]))
        run(PACTL, "set-sink-mute", SINK, str(int(original[2])))
        wait_for(lambda: volumes() == original, "exact restore after media keys")
        stable(original, "media-restore")


def key_preference(plugin_id, group="enable-keyboard-shortcuts"):
    try:
        return config(f"/plugins/plugin-{plugin_id}/{group}")
    except subprocess.CalledProcessError:
        return None


def set_owner_key():
    script = LOG / "owner-lower-volume"
    script.write_text(f"#!/bin/sh\nprintf '%s\\n' handled >> {shlex.quote(str(LOG / 'owner-key.log'))}\n")
    script.chmod(0o755)
    run(*KEYBOARD, "-p", "/commands/custom/override", "-n", "-t", "bool", "-s", "true")
    run(*KEYBOARD, "-p", OWNER_KEY, "-n", "-t", "string", "-s", str(script))
    return script


def check():
    display = Gdk.Display.get_default()
    assert display.get_monitor(0).get_scale_factor() == 2
    assert run(PACTL, "get-default-sink") == SINK
    audio = volumes()
    assert audio == (26214, 26214, True), audio
    start_panel()
    clean = layout()
    assert not audio_items(clean), clean
    assert not wrappers(), wrappers()
    assert not (STATE / MARKER).exists()
    print(f"PANEL_STOCK scale=2 panels=2 audio_items=0 ids={clean}", flush=True)
    invoke(STATE)
    wait_for(lambda: (STATE / MARKER).is_file(), "candidate migration marker")
    current = layout()
    items = audio_items(current)
    assert len(items) == 1 and items[0][0] == 1, items
    plugin_id = items[0][1]
    assert current[2] == clean[2]
    assert tuple(i for i in current[1] if i != plugin_id) == clean[1]
    assert plugin_name(current[1][current[1].index(plugin_id) - 1]) == "systray"
    x, y, width, height = wait_for(lambda: visible(plugin_id), "new volume icon in the main panel")
    assert set(wrappers()) == {plugin_id}
    no_chooser()
    print(f"PANEL_NEW_VISIBLE panel=1 plugin={plugin_id} box={x},{y},{width},{height} order=stock-plus-audio", flush=True)
    stable(audio, "fresh")
    if sys.argv[1] == "transport":
        assert key_preference(plugin_id, "enable-multimedia-keys") == "false"
        assert key_preference(plugin_id) != "false"
        assert run(*KEYBOARD, "-p", "/xfwm4/custom/XF86AudioPlay") == "show_desktop_key"
        print("PANEL_TRANSPORT_BINDING provider=xfwm4 transport_grabs_disabled=yes volume_unchanged=yes", flush=True)
        media_keys(audio)
        print("Y700_PANEL_TRANSPORT_CONFLICT_PASS", flush=True)
        return
    media_keys(audio)

    invoke(STATE)
    time.sleep(1.2)
    assert layout() == current and set(wrappers()) == {plugin_id}
    no_chooser()
    stable(audio, "repeat")

    stop_worker()
    stop_panel()
    owner_script = set_owner_key()
    original_key_preference = key_preference(plugin_id)
    panel_configure(1, clean[1])
    panel_configure(2, (*clean[2], plugin_id))
    start_panel()
    moved = layout()
    assert audio_items(moved) == [(2, plugin_id)], moved
    wait_for(lambda: plugin_id in wrappers(), "live user-moved applet on panel 2")
    migrated_state = LOG / "state-existing-profile"
    old_defaults = migrated_state / "y700/desktop-defaults-v1"
    old_defaults.parent.mkdir(parents=True)
    old_defaults.touch()
    assert not (migrated_state / MARKER).exists()
    invoke(migrated_state)
    wait_for(lambda: (migrated_state / MARKER).is_file(), "record an existing linked applet")
    assert layout() == moved and set(wrappers()) == {plugin_id}
    assert key_preference(plugin_id) == original_key_preference
    assert run(*KEYBOARD, "-p", OWNER_KEY) == str(owner_script)
    print(f"PANEL_EXISTING_MOVED panel=2 id={plugin_id} duplicate=0", flush=True)
    stable(audio, "moved")

    stop_worker()
    stop_panel()
    panel_configure(2, clean[2])
    run(*CHANNEL, "-p", f"/plugins/plugin-{plugin_id}", "-r", "-R")
    start_panel()
    removed = layout()
    assert removed == clean and not audio_items(removed)
    invoke(migrated_state)
    time.sleep(1.7)
    assert layout() == removed and not wrappers()
    assert (migrated_state / MARKER).is_file()
    no_chooser()
    print("PANEL_REMOVED kept_removed=yes", flush=True)
    stable(audio, "removed")

    # A fresh migration with a real custom keyboard command must preserve the
    # existing command and leave the new applet visible.
    conflict_state = LOG / "state-key-conflict"
    invoke(conflict_state)
    wait_for(lambda: (conflict_state / MARKER).is_file(), "migration with an existing volume binding")
    items = audio_items(layout())
    assert len(items) == 1 and items[0][0] == 1, items
    conflict_id = items[0][1]
    assert key_preference(conflict_id) == "false"
    assert key_preference(conflict_id, "enable-multimedia-keys") != "false"
    assert run(*KEYBOARD, "-p", OWNER_KEY) == str(owner_script)
    wait_for(lambda: visible(conflict_id), "conflict applet remains visible")
    run("xdotool", "key", "XF86AudioLowerVolume")
    owner_log = LOG / "owner-key.log"
    wait_for(lambda: owner_log.is_file() and owner_log.read_text() == "handled\n", "existing owner's media command")
    stable(audio, "custom-key")
    print(f"PANEL_CUSTOM_BINDING owner_command=observed plugin={conflict_id} volume_grabs_disabled=yes transport_unchanged=yes", flush=True)
    print("Y700_PANEL_VOLUME_BOOTSTRAP_PASS", flush=True)


if __name__ == "__main__":
    try:
        check()
    finally:
        stop_worker()
        if panel is not None:
            stop_panel()
