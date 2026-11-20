"""Check real GIO launch and the registries in a disposable ordinary-user desktop session."""
import os
from pathlib import Path
import subprocess
import sys
import time

from gi.repository import Gio


def inspect(env):
    output = subprocess.check_output(["gst-inspect-1.0", "video4linux2"], env=env, text=True)
    return Path(next(line.split(None, 1)[1] for line in output.splitlines() if line.strip().startswith("Filename ")))


def player_for(clip):
    for entry in Path("/proc").glob("[0-9]*"):
        try:
            if entry.stat().st_uid != os.getuid():
                continue
            args = (entry / "cmdline").read_bytes().split(b"\0")
            if b"/usr/bin/parole" in args and os.fsencode(clip) in args:
                data = (entry / "environ").read_bytes().split(b"\0")
                return int(entry.name), dict(os.fsdecode(item).split("=", 1) for item in data if b"=" in item)
        except (PermissionError, FileNotFoundError, ProcessLookupError):
            pass
    return None


def main():
    assert os.getuid() != 0 and os.environ.get("XDG_CURRENT_DESKTOP") == "XFCE"
    for mime in ("video/mp4", "video/webm"):
        app = Gio.AppInfo.get_default_for_type(mime, False)
        assert app.get_id() == "org.xfce.Parole.desktop"
        assert app.get_filename() == "/usr/local/share/applications/org.xfce.Parole.desktop"
        print(f"DESKTOP_LAUNCHER mime={mime} file={app.get_filename()}", flush=True)
    assert "GST_PLUGIN_PATH_1_0" not in os.environ and "GST_REGISTRY_1_0" not in os.environ
    stock = Path("/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so")
    private = Path("/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so")
    cache = Path(os.environ["XDG_CACHE_HOME"]) / "y700-parole/registry.aarch64-iris-r2.bin"
    clip = Path(sys.argv[1]).resolve(strict=True)
    assert not player_for(clip) and not cache.exists()
    subprocess.run(["gio", "open", str(clip)], check=True, timeout=20)
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        player = player_for(clip)
        if player and cache.is_file():
            break
        time.sleep(.2)
    else:
        raise AssertionError("No running Parole with this file and a fresh private registry")
    pid, env = player
    assert env.get("DISPLAY") == os.environ["DISPLAY"]
    assert env.get("GST_REGISTRY_1_0") == str(cache) and env.get("GST_PLUGIN_PATH_1_0") == str(private.parent)
    assert inspect(env) == private and inspect(os.environ.copy()) == stock
    print(f"PLAYER_REGISTRY pid={pid} file_arg=1 cache={cache.name} private_plugin=1 ordinary_plugin=debian", flush=True)


if __name__ == "__main__":
    main()
