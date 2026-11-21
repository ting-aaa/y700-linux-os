"""Open generated files via the default desktop association and sample pixels on the Xorg display."""
import argparse
import ctypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk


def colour_pairs(root):
    # Thin rows avoid transferring an entire HiDPI framebuffer for each sample.
    hits = {}
    for y in range(10, root.get_height(), 20):
        strip = Gdk.pixbuf_get_from_window(root, 0, y, root.get_width(), 1)
        data, channels = strip.get_pixels(), strip.get_n_channels()
        row = []
        for x in range(0, strip.get_width(), 12):
            i = x * channels
            rgb = data[i:i + 3]
            top = max(rgb)
            c = rgb.index(top)
            label = str(c) if top > 185 and sum(rgb) - top < 95 else "x"
            row.append(label)
        # Broad, adjacent rectangles distinguish the test video from individual UI icons.
        line = "".join(row)
        for pair in ("01", "12", "20"):
            if re.search(pair[0] + "{5,}.{0,3}" + pair[1] + "{5,}", line):
                hits[pair] = hits.get(pair, 0) + 1
                if hits[pair] == 2:
                    return {pair}
    return set()


def session_players():
    wanted = {f"{key}={os.environ[key]}".encode() for key in ("DISPLAY", "DBUS_SESSION_BUS_ADDRESS")}
    found = []
    for entry in Path("/proc").glob("[0-9]*"):
        try:
            if entry.stat().st_uid != os.getuid() or (entry / "exe").resolve() != Path("/usr/bin/parole"):
                continue
            if wanted.issubset((entry / "environ").read_bytes().split(b"\0")):
                found.append(int(entry.name))
        except (PermissionError, ProcessLookupError, FileNotFoundError):
            continue
    return found


def thunar_open(path):
    # Wait for the folder view to select the intended file before pressing Return.
    # The X11 window can already be mapped while Thunar is still updating its selection.
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
    Atspi.init()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    interface = "org.freedesktop.FileManager1"
    bus.call_sync(interface, "/org/freedesktop/FileManager1", interface, "ShowItems",
                  GLib.Variant("(ass)", ([path.as_uri()], "")), None, Gio.DBusCallFlags.NONE, 10000, None)
    title = f"{path.parent.name} - Thunar"

    def selected_file():
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            if not app or (app.get_name() or "").lower() != "thunar":
                continue
            frames = [app.get_child_at_index(j) for j in range(app.get_child_count())]
            pending = [frame for frame in frames if frame and frame.get_name() == title]
            while pending:
                item = pending.pop()
                if item.get_role() == Atspi.Role.STATUS_BAR:
                    if (item.get_name() or "").startswith(f'"{path.name}"'):
                        return True
                    continue
                pending.extend(child for j in range(item.get_child_count())
                               if (child := item.get_child_at_index(j)) is not None)
        return False

    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        windows = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
        matches = [line for line in windows.splitlines() if f'"{title}"' in line
                   and '("thunar" "thunar")' in line.lower()]
        if len(matches) == 1 and selected_file():
            break
        time.sleep(.1)
    else:
        raise AssertionError(f"Thunar did not select {path.name} in {title}")
    xid = int(matches[0].split()[0], 16)
    info = subprocess.check_output(["xwininfo", "-id", hex(xid)], text=True)
    assert "Map State: IsViewable" in info
    x11 = ctypes.CDLL("libX11.so.6")
    xtest = ctypes.CDLL("libXtst.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    x11.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    xtest.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    connection = x11.XOpenDisplay(None)
    assert connection
    try:
        x11.XRaiseWindow(connection, xid)
        x11.XSetInputFocus(connection, xid, 2, 0)  # RevertToParent, CurrentTime
        x11.XSync(connection, 0)
        focused, revert = ctypes.c_ulong(), ctypes.c_int()
        x11.XGetInputFocus(connection, ctypes.byref(focused), ctypes.byref(revert))
        assert focused.value == xid, "X11 input focus is outside the selected Thunar folder"
        key = x11.XKeysymToKeycode(connection, Gdk.KEY_Return)
        assert key
        assert xtest.XTestFakeKeyEvent(connection, key, True, 0)
        assert xtest.XTestFakeKeyEvent(connection, key, False, 0)
    finally:
        x11.XCloseDisplay(connection)
    print(f"THUNAR_ACTIVATE file={path.name} selection_verified=1 folder_focused=1 key=Return", flush=True)


def main(work):
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--opener", choices=["gio", "thunar"], default="gio")
    cli.add_argument("--installed-iris", action="store_true", help="verify the combined Y700 desktop launcher and plugin")
    cli.add_argument("--transport", type=Path, help="exercise the seekable clips with the hardware decoder")
    cli.add_argument("--codec", choices=("h264", "hevc", "vp9"))
    args = cli.parse_args()
    assert os.getuid() == 1000
    Gtk.init([])
    root = Gdk.get_default_root_window()
    assert root.get_scale_factor() == 2
    print(f"PLAYER_DISPLAY uid=1000 gtk_scale={root.get_scale_factor()} "
          f"gdk_root={root.get_width()}x{root.get_height()}", flush=True)
    for mime in ("video/mp4", "video/webm"):
        app = Gio.AppInfo.get_default_for_type(mime, False)
        print(f"PLAYER_ASSOCIATION mime={mime} default={app.get_id() if app else 'none'}", flush=True)
        assert app and app.get_id() == "org.xfce.Parole.desktop"
        if args.installed_iris:
            assert app.get_filename() == "/usr/local/share/applications/org.xfce.Parole.desktop"
    for name in ("h264.mp4", "hevc.mp4", "vp9.webm"):
        if args.codec and args.codec != Path(name).stem:
            continue
        assert not session_players(), "Use a private display and session bus with no running Parole"
        assert not colour_pairs(root), "Unexpected pre-existing test colours"
        path = Path(name).resolve()
        if args.opener == "thunar":
            # A second launch can map another window for the same folder after
            # the older window is found. Give each file its own unique folder.
            folder = work / (path.stem + "-" + work.name)
            folder.mkdir()
            path = Path(shutil.copyfile(path, folder / path.name))
            thunar_open(path)
        else:
            subprocess.Popen(["gio", "open", str(path)])
        observed = set()
        deadline = time.monotonic() + 30
        samples = 0
        if args.transport:
            decoder = {"h264.mp4": "v4l2h264dec", "hevc.mp4": "v4l2h265dec", "vp9.webm": "v4l2vp9dec"}[name]
            gesture_args = []
            if Path("/qa/single-seek").is_file():
                gesture_args.append("--single-seek")
            subprocess.run([sys.executable, "-B", str(args.transport), str(path), "--already-open",
                            "--pointer", "--seek-cycles", "3", "--require-iris", decoder, *gesture_args],
                           check=True, timeout=55)
        else:
            while time.monotonic() < deadline and len(observed) < 3:
                observed.update(colour_pairs(root))
                samples += 1
                time.sleep(.06)
        pids = session_players()
        assert len(pids) == 1
        argv = Path(f"/proc/{pids[0]}/cmdline").read_bytes().split(b"\0")
        assert str(path).encode() in argv or path.as_uri().encode() in argv, (path.name, argv)
        if args.installed_iris:
            proc = Path("/proc") / str(pids[0])
            private_plugin = "/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so"
            mappings = {line.split()[-1] for line in (proc / "maps").read_text().splitlines()
                        if line.endswith("/libgstvideo4linux2.so")}
            assert mappings == {private_plugin}, mappings
            env = dict(entry.split(b"=", 1) for entry in (proc / "environ").read_bytes().split(b"\0") if entry)
            registry = Path(os.fsdecode(env[b"GST_REGISTRY_1_0"]))
            assert registry.is_file() and registry.parent == Path.home() / ".cache/y700-parole", registry
            print(f"PLAYER_PLUGIN file={name} pid={pids[0]} installed_iris=1 private_cache=1", flush=True)
        result = "transport=passed" if args.transport else f"observed={','.join(sorted(observed))} samples={samples}"
        print(f"PLAYER_OPEN file={name} via={args.opener} program=parole pid={pids[0]} file_arg=1 {result}", flush=True)
        if not args.transport:
            assert observed == {"01", "12", "20"}, name
        for pid in pids:
            os.kill(pid, 15)
        for _ in range(40):
            if not session_players() and not colour_pairs(root):
                break
            time.sleep(.1)
        else:
            raise AssertionError(f"Parole did not exit cleanly after {name}")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="parole-probe-", dir=os.environ["XDG_RUNTIME_DIR"]) as temp:
        main(Path(temp))
