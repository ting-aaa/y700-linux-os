"""Exercise the ordinary desktop launcher and the packaged Debian shell entry on ARM64."""
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "brightness"))
from probe import Atspi, Gdk, Gio, named, tap, wait_for


def launcher(*extra):
    url = "file:///nonexistent/Y700 fixture with spaces.html"
    raw = subprocess.check_output(["/usr/bin/chromium", "--enable-features=FixtureFeature", *extra, url])
    args = raw.decode().split("\0")[:-1]
    assert args.count(url) == 1
    assert "--enable-features=FixtureFeature,WebRtcPipeWireCamera" in args
    assert "--disable-pings" in args and "--enable-gpu-rasterization" in args, args
    return args


def software():
    args = launcher()
    assert "--disable-gpu" in args and "--use-angle=vulkan" not in args


def enabled():
    return subprocess.check_output(["gsettings", "get", "org.y700.chromium", "hardware-acceleration"],
                                   text=True).strip() == "true"


if sys.argv[1:] == ["software"]:
    software()
    print("CHROMIUM_SOFTWARE default launcher flag confirmed")
    sys.exit(0)

assert os.getuid() == 1000
assert not enabled()
Atspi.init()
Atspi.set_timeout(2000, 2000)
assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
app = Gio.DesktopAppInfo.new("y700-chromium-graphics.desktop")
assert app.get_executable() == "/usr/libexec/y700-chromium-graphics"
assert "X-XFCE-SettingsDialog" in app.get_categories()
assert app.launch([], None)
frame = wait_for(lambda: named(Atspi.get_desktop(0), Atspi.Role.FRAME, "Chromium 图形"), "settings window", 30)
control = named(frame, Atspi.Role.CHECK_BOX, "在 Chromium 中使用 GPU 加速")
assert control is not None
bounds = control.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
assert bounds.height >= 64
software()
tap(control, bounds)
wait_for(enabled, "hardware choice saved")
args = launcher()
assert "--disable-gpu" not in args and "--enable-gpu" not in args
assert "--use-gl=angle" in args and "--use-angle=vulkan" in args
args = launcher("--headless")
assert "--enable-gpu" in args and "--disable-gpu" not in args
args = launcher("--headless", "--disable-gpu")
assert args.count("--disable-gpu") == 1 and "--enable-gpu" not in args and "--use-angle=vulkan" not in args
args = launcher("--use-angle=swiftshader")
assert "--use-angle=vulkan" not in args and "--use-angle=swiftshader" in args
tap(control, bounds)
wait_for(lambda: not enabled(), "software choice restored")
software()
tap(control, bounds)
wait_for(enabled, "persistent hardware preference")
print(f"CHROMIUM_GRAPHICS_UI_PASS zh_CN=1 uid=1000 scale=2 hit_height={bounds.height} choices=software,hardware,software,hardware")
