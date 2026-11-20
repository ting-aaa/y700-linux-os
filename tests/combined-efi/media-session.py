"""Observe an ordinary GIO launch on the enrolled Xfce seat in the EFI guest."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import time

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, Gtk


def main(clip):
    assert os.getuid() != 0 and os.environ["XDG_CURRENT_DESKTOP"] == "XFCE"
    assert not any(key in os.environ for key in ("GST_REGISTRY_1_0", "GST_PLUGIN_PATH_1_0"))
    lock = json.loads(Path("/var/lib/y700/build/video-player.lock.json").read_text())
    assert lock["edition"] == "dev12.9"
    for name, expected in lock["files"].items():
        assert hashlib.sha256((Path("/") / name).read_bytes()).hexdigest() == expected, name
    for mime in ("video/mp4", "video/webm"):
        app = Gio.AppInfo.get_default_for_type(mime, False)
        assert app and app.get_id() == "org.xfce.Parole.desktop", mime
        assert app.get_filename() == "/usr/local/share/applications/org.xfce.Parole.desktop", mime
    print("COMBINED_MEDIA_GIO ordinary=1 mp4=parole webm=parole desktop=local", flush=True)

    Gtk.init([])
    root = Gdk.get_default_root_window()
    pixels = runpy.run_path(str(Path(__file__).with_name("media-pixels.py")))
    colour_pairs = pixels["colour_pairs"]
    session_players = pixels["session_players"]
    assert not session_players() and not colour_pairs(root), "Display already has a player or test pattern"
    subprocess.run(["gio", "open", str(clip)], check=True, timeout=30)
    observed = set()
    deadline = time.monotonic() + 85
    while time.monotonic() < deadline:
        observed.update(colour_pairs(root))
        if observed == {"01", "12", "20"}:
            break
        time.sleep(.08)
    pids = session_players()
    if observed != {"01", "12", "20"}:
        print(f"COMBINED_MEDIA_DIAGNOSTIC pids={pids} pairs={sorted(observed)} "
              f"geometry={root.get_width()}x{root.get_height()} scale={root.get_scale_factor()}", flush=True)
    assert len(pids) == 1, f"Expected one Parole on the enrolled seat, found {pids}"
    pid = pids[0]
    process = Path("/proc") / str(pid)
    args = (process / "cmdline").read_bytes().split(b"\0")
    assert os.fsencode(clip) in args or clip.as_uri().encode() in args
    assert observed == {"01", "12", "20"}, f"Visible colour pairs {sorted(observed)}"

    env = dict(entry.split(b"=", 1) for entry in (process / "environ").read_bytes().split(b"\0") if entry)
    private = Path("/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so")
    stock = Path("/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so")
    assert env[b"GST_PLUGIN_PATH_1_0"] == os.fsencode(private.parent)
    cache = Path(os.fsdecode(env[b"GST_REGISTRY_1_0"]))
    expected_cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    assert cache == expected_cache / "y700-parole/registry.aarch64-iris-r2.bin"
    assert cache.stat().st_uid == os.getuid()
    data = cache.read_bytes()
    assert os.fsencode(private) + b"\0" in data and os.fsencode(stock) + b"\0" not in data
    mapped = {Path(line.split()[-1]) for line in (process / "maps").read_text().splitlines()
              if line.endswith(".so")}
    copies = {lib for lib in mapped if lib.name == private.name}
    assert copies <= {private}, copies
    decoders = sorted(lib.name for lib in mapped if lib.name in ("libgstlibav.so", "libgstopenh264.so"))
    video_nodes = list(Path("/sys/class/video4linux").glob("video*"))
    assert not video_nodes, video_nodes
    print(f"COMBINED_MEDIA_PLAYBACK h264=visible pairs=01,12,20 private_registry=1 "
          f"private_mapped={int(private in copies)} stock_mapped=0 "
          f"video_nodes=0 software_plugins={','.join(decoders) or 'none'} pid={pid} scale={root.get_scale_factor()}", flush=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(strict=True))
