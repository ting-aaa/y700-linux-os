"""Approve only the GTK camera and Chromium loopback website dialogs in the simulated session."""

import subprocess
import time
import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib


def walk(node, depth=0):
    yield node
    if depth < 18:
        for index in range(node.get_child_count()):
            child = node.get_child_at_index(index)
            if child:
                yield from walk(child, depth + 1)


done = set()
deadline = time.monotonic() + 320
while time.monotonic() < deadline and len(done) < 2:
    desktop = Atspi.get_desktop(0)
    try:
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            name = (app.get_name() or "").lower()
            portal = name == "xdg-desktop-portal-gtk"
            kind = "portal" if portal else "site"
            if kind in done or (not portal and "chrom" not in name):
                continue
            nodes = list(walk(app))
            names = [x.get_name() or "" for x in nodes]
            if portal:
                checked = "Allow app to Use the Camera?" in names
                choices = {"Grant Access"}
            else:
                checked = any("127.0.0.1" in n for n in names) and any(
                    "camera" in n.lower() and "use" in n.lower() for n in names
                )
                choices = {
                    "Allow this time",
                    "Allow while visiting the site",
                    "Allow on every visit",
                    "Allow",
                }
            if checked:
                for node in nodes:
                    if (
                        node.get_role() != Atspi.Role.PUSH_BUTTON
                        or node.get_name() not in choices
                    ):
                        continue
                    r = node.get_extents(Atspi.CoordType.SCREEN)
                    if min(r.x, r.y) < 0 or min(r.width, r.height) <= 0:
                        continue
                    subprocess.run(
                        [
                            "xdotool",
                            "mousemove",
                            str(r.x + r.width // 2),
                            str(r.y + r.height // 2),
                            "click",
                            "1",
                        ],
                        check=True,
                    )
                    done.add(kind)
                    print(f"BROWSER_CONSENT {kind}=1", flush=True)
                    break
    except GLib.Error:
        pass
    time.sleep(0.25)
assert done == {"portal", "site"}, done
