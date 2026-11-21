"""Read lens labels on the physical tablet using a private X display; cancel before capture."""

import os
from pathlib import Path
import runpy
import subprocess
import sys


fixture = runpy.run_path(str(Path(__file__).with_name("virtual-shutter.py")))
CameraWindow = fixture["CameraWindow"]
Atspi = fixture["Atspi"]
run = fixture["run"]
wait_for = fixture["wait_for"]


def inspect_chooser(locale_name, names, expect_main):
    chinese = locale_name.startswith("zh")
    env = dict(os.environ, LC_ALL=locale_name, LANGUAGE="zh_CN" if chinese else "en")
    subprocess.run(["gio", "launch", "/usr/share/applications/org.y700.Camera.desktop"],
                   env=env, check=True, timeout=15)
    xid = wait_for(lambda: run("xdotool", "search", "--onlyvisible", "--class", "^qcam$"),
                   "private qcam chooser")
    pid = int(run("xdotool", "getwindowpid", xid))
    process = Path("/proc") / str(pid)
    assert (process / "exe").resolve() == Path("/opt/y700-camera/bin/qcam")
    window = CameraWindow(pid, True, chinese)
    first = names.index(window.find(Atspi.Role.COMBO_BOX).get_name())
    print(f"QCAM_INITIAL_SELECTION locale={locale_name} lens={('main', 'front', 'macro')[first]}", flush=True)
    if expect_main:
        assert first == 0, "The rear main camera should be selected on first open"
    models = ("hi1339", "s5k4h7", "sc202cs")
    window.find(Atspi.Role.LABEL, models[first])
    for offset in (1, 2, 3):
        index = (first + offset) % len(names)
        window.click(window.find(Atspi.Role.COMBO_BOX))
        window.click(window.find(Atspi.Role.LIST_ITEM, names[index]))
        window.find(Atspi.Role.COMBO_BOX, names[index])
        window.find(Atspi.Role.LABEL, models[index])
    window.click(window.find(Atspi.Role.PUSH_BUTTON, "取消" if chinese else "Cancel"))
    wait_for(lambda: not (process / "exe").exists(), "exit after cancelling")
    print(f"QCAM_BOARD_CHOOSER locale={locale_name} sensors=3 scale=2 cancelled=1", flush=True)


def main():
    if sys.argv[1:] not in ([], ["--expect-main"]):
        raise SystemExit("usage: board-chooser.py [--expect-main]")
    expect_main = len(sys.argv) > 1
    assert os.getuid() != 0 and not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY")
    sensors = {}
    for dev in Path("/sys/bus/i2c/devices").glob("*-????"):
        name_file = dev / "name"
        if not name_file.is_file():
            continue
        name = name_file.read_text().strip()
        if name in ("hi1339", "s5k4h7", "sc202cs"):
            sensors[name] = dev / "power"
    assert len(sensors) == 3

    def snapshot():
        return {name: ((power / "runtime_status").read_text().strip(),
                       int((power / "runtime_active_time").read_text())) for name, power in sensors.items()}

    before = snapshot()
    assert all(state == "suspended" for state, _ in before.values())
    # The caller supplies a private mount and network namespace for this X server.
    read_fd, write_fd = os.pipe()
    with os.fdopen(read_fd) as display:
        xvfb = subprocess.Popen(["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1600x2560x24",
                                 "-nolisten", "tcp"], pass_fds=(write_fd,))
        os.close(write_fd)
        try:
            os.environ.update(DISPLAY=":" + str(int(display.readline())), QT_SCALE_FACTOR="2",
                              QT_LINUX_ACCESSIBILITY_ALWAYS_ON="1", XDG_CURRENT_DESKTOP="XFCE")
            subprocess.run(["dbus-update-activation-environment", "DISPLAY"], check=True, timeout=5)
            lenses = ("main", "front", "macro")
            inspect_chooser("C.UTF-8", [fixture["CAMERAS"][lens][1] for lens in lenses], expect_main)
            inspect_chooser("zh_CN.UTF-8", [fixture["CHINESE_NAMES"][lens] for lens in lenses], expect_main)
        finally:
            xvfb.terminate()
            xvfb.wait(timeout=8)
    assert snapshot() == before
    print("QCAM_BOARD_CHOOSER_PASS streams=0 sensors_suspended=3 active_ms_delta=0")


if __name__ == "__main__":
    main()
