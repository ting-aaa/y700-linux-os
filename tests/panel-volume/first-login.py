"""Verify the packaged Xsession default before the first real panel starts."""

import os
from pathlib import Path
import shlex
import sys
import time
import xml.etree.ElementTree as ET

import desktop as panel
from gi.repository import Gdk


ORIGINAL_DIRS = os.environ["Y700_PANEL_ORIGINAL_CONFIG_DIRS"]
TEMPLATE = Path("xfce4/panel/default.xml")
CHANNELS = Path(os.environ["XDG_CONFIG_HOME"]) / "xfce4/xfconf/xfce-perchannel-xml"
OWNER = panel.LOG / "owner-command"
OWNER_LOG = panel.LOG / "owner-command.log"
HOOK = "/etc/X11/Xsession.d/61y700_panel_default"
STOCK = Path("/etc/xdg") / TEMPLATE


def prepare(mode):
    if mode == "first-login":
        return
    CHANNELS.mkdir(parents=True)
    if mode == "first-login-shortcut":
        OWNER.write_text(f"#!/bin/sh\nprintf '%s\\n' handled >> {shlex.quote(str(OWNER_LOG))}\n")
        OWNER.chmod(0o755)
        root = ET.Element("channel", name="xfce4-keyboard-shortcuts", version="1.0")
        commands = ET.SubElement(root, "property", name="commands", type="empty")
        custom = ET.SubElement(commands, "property", name="custom", type="empty")
        ET.SubElement(custom, "property", name="override", type="bool", value="true")
        ET.SubElement(custom, "property", name="XF86AudioLowerVolume", type="string", value=str(OWNER))
        ET.ElementTree(root).write(CHANNELS / "xfce4-keyboard-shortcuts.xml", encoding="utf-8")
    else:
        config = ET.parse(STOCK)
        members = config.find("./property[@name='panels']/property[@name='panel-2']/property[@name='plugin-ids']")
        last = members[-1]
        members.remove(last)
        members.insert(0, last)  # Put the existing directory menu first on the dock.
        config.write(CHANNELS / "xfce4-panel.xml", encoding="utf-8")
        marker = panel.STATE / "y700/desktop-defaults-v1"
        marker.parent.mkdir()
        marker.touch()


def panel_owner():
    return panel.run("gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
                     "--object-path", "/org/freedesktop/DBus",
                     "--method", "org.freedesktop.DBus.GetNameOwner", "org.xfce.Panel")


def new_login_dirs():
    return panel.run("sh", "-ec", f'''
        BASESTARTUP=xfce4-session
        XDG_CONFIG_DIRS=$Y700_PANEL_ORIGINAL_CONFIG_DIRS
        . {HOOK}
        printf '%s\n' "$XDG_CONFIG_DIRS"
    ''')


def verify_pre_start(mode):
    fresh = mode == "first-login"
    dirs = os.environ["XDG_CONFIG_DIRS"]
    if fresh:
        generated, original = dirs.split(":", 1)
        assert original == ORIGINAL_DIRS
        target = Path(generated)
        assert target.parent == panel.LOG and (target.stat().st_mode & 0o777) == 0o700
        assert not CHANNELS.exists(), "template generator populated the user profile"
        tree = ET.parse(target / TEMPLATE)
        plugins = tree.find("./property[@name='plugins']")
        [audio] = plugins.findall("./property[@value='pulseaudio']")
        number = audio.get("name").removeprefix("plugin-")
        plugins.remove(audio)
        members = tree.find("./property[@name='panels']/property[@name='panel-1']/property[@name='plugin-ids']")
        [entry] = members.findall(f"./value[@value='{number}']")
        members.remove(entry)
        assert ET.canonicalize(ET.tostring(tree.getroot()), strip_text=True) == ET.canonicalize(
            from_file=STOCK, strip_text=True
        ), "generated template must retain every other stock property"
    else:
        assert dirs == ORIGINAL_DIRS, "existing settings must take the regular migration path"


def verify(mode):
    stock_bytes = STOCK.read_bytes()
    fresh = mode == "first-login"
    assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
    initial_audio = panel.volumes()
    panel.start_panel()
    owner = panel.wait_for(panel_owner, "original panel bus owner")
    layout_before = panel.layout()
    if fresh:
        [(panel_id, plugin_id)] = panel.audio_items(layout_before)
        assert panel_id == 1
        panel.wait_for(lambda: panel.visible(plugin_id), "volume applet before Y700 startup")
        print("PANEL_NATIVE_FIRST_START scale=2 applet_before_autostart=yes", flush=True)
    else:
        assert panel.audio_items(layout_before) == []
        if mode == "first-login-existing":
            assert panel.plugin_name(layout_before[2][0]) == "directorymenu"

    marker = panel.STATE / panel.MARKER
    assert not marker.exists()
    panel.invoke(panel.STATE)
    panel.wait_for(marker.is_file, "first login volume marker", seconds=70)
    layout_after = panel.layout()
    [(panel_id, plugin_id)] = panel.audio_items(layout_after)
    assert panel_id == 1
    panel.wait_for(lambda: panel.visible(plugin_id), "volume icon after Y700 startup")
    assert layout_after[2] == layout_before[2]
    top = layout_after[1]
    assert panel.plugin_name(top[top.index(plugin_id) - 1]) == "systray"
    if fresh:
        assert layout_after == layout_before and panel_owner() == owner
        panel.media_keys(initial_audio)
        panel.stop_worker()
        panel.stop_panel()
        expected = tuple(item for item in top if item != plugin_id)
        panel.panel_configure(1, expected)
        panel.run(*panel.CHANNEL, "-p", f"/plugins/plugin-{plugin_id}", "-r", "-R")
        os.environ["XDG_CONFIG_DIRS"] = new_login_dirs()
        assert os.environ["XDG_CONFIG_DIRS"] == ORIGINAL_DIRS
        panel.start_panel()
        owner = panel.wait_for(panel_owner, "panel bus owner at second login")
        panel.invoke(panel.STATE)
        time.sleep(2.5)
        assert panel_owner() == owner
        assert panel.layout() == {1: expected, 2: layout_after[2]}
        assert not panel.audio_items(panel.layout()) and marker.is_file()
        print("PANEL_NATIVE_RELOGIN kept_removed=yes", flush=True)
    else:
        assert tuple(item for item in top if item != plugin_id) == layout_before[1]
        if mode == "first-login-shortcut":
            assert panel.key_preference(plugin_id) == "false"
            assert panel.key_preference(plugin_id, "enable-multimedia-keys") != "false"
            panel.run("xdotool", "key", "XF86AudioLowerVolume")
            panel.wait_for(lambda: OWNER_LOG.is_file() and OWNER_LOG.read_text() == "handled\n",
                           "owner shortcut handled")

    assert STOCK.read_bytes() == stock_bytes
    panel.stable(initial_audio, mode)
    print(f"Y700_PANEL_FIRST_LOGIN_PASS case={mode}", flush=True)


if __name__ == "__main__":
    action, mode = sys.argv[1:]
    if action == "prepare":
        prepare(mode)
    elif action == "verify-pre-start":
        verify_pre_start(mode)
    else:
        try:
            verify(mode)
        finally:
            panel.stop_worker()
            if panel.panel is not None:
                panel.stop_panel()
