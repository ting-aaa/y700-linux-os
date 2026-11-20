"""Keep the ordinary applet running and passively observe password dialogs."""

import os
from pathlib import Path
import sys
import time


sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from probe import Atspi, GLib, ProbeError, application, await_value, password_dialog


def observe(pid):
    root = Path("/run/wifi-fixture/rejoin")
    assert Path("/proc/cmdline").read_text().split().count("y700.wifi_fixture=1") == 1
    assert os.geteuid() != 0
    Atspi.init()
    Atspi.set_timeout(2000, 2000)
    app = await_value(lambda: application(pid), "rejoin-applet-not-present")
    await_value(lambda: password_dialog(app) is None, "initial-dialog-still-present")
    (root / "user/ready").touch()
    deadline = time.monotonic() + 245
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        os.kill(pid, 0)
        if password_dialog(app):
            raise RuntimeError("unexpected-password-dialog")
        if (root / "done").exists():
            print("WIFI_REJOIN_APPLET monitored=1 no_prompt=1", flush=True)
            return
        time.sleep(0.25)
    raise RuntimeError("observer-timeout")


if __name__ == "__main__":
    try:
        observe(int(sys.argv[1]))
    except (OSError, RuntimeError, GLib.Error, ProbeError) as error:
        print(f"WIFI_PROBE_ERROR rejoin-observer-{type(error).__name__}", file=sys.stderr)
        raise SystemExit(1) from None
