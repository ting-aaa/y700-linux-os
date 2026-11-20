"""Tap the running Xfce volume applet and observe the VM's default sink."""
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time

os.environ["LC_ALL"] = "C"
DEFAULT = "@DEFAULT_AUDIO_SINK@"
ALLOCATION_WAIT = 100


def run(*args):
    return subprocess.check_output(args, text=True, timeout=15, stderr=subprocess.DEVNULL).strip()


def wait_for(read, label, seconds=24):
    end = time.monotonic() + seconds
    error = None
    while time.monotonic() < end:
        try:
            result = read()
            if result:
                return result
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            error = exc
        time.sleep(0.4)
    raise RuntimeError(f"Timed out waiting for {label}: {error}")


def tap(x, y):
    if not (0 <= x < 1024 and 0 <= y < 768):
        raise ValueError(f"Tap outside guest display: {x},{y}")
    request, ack = (Path(os.environ[name]) for name in ("Y700_TOUCH_REQUEST", "Y700_TOUCH_ACK"))
    if not all(stat.S_ISFIFO(path.stat().st_mode) for path in (request, ack)):
        raise RuntimeError("Expected test touchscreen request and acknowledgement FIFOs")
    with request.open("w") as tx:
        print(f"tap {x} {y}", file=tx, flush=True)
    with ack.open() as rx:
        if rx.readline().strip() != "OK":
            raise RuntimeError("Touchscreen rejected tap")
    print(f"PANEL_TYPE_B_TAP x={x} y={y}", flush=True)


def bounds(xid):
    info = run("xwininfo", "-id", xid)
    if "Map State: IsViewable" not in info:
        return None
    fields = ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height")
    return tuple(int(re.search(rf"{field}:\s+(-?\d+)", info)[1]) for field in fields)


def speaker_geometry(pid, xid):
    socket = bounds(xid)
    tree = run("xwininfo", "-id", xid, "-tree")
    plug = re.search(r'^\s*(0x[\da-f]+) .*\("[^"]*" "Wrapper-2\.0"\)', tree, re.I | re.M)
    plug_id = plug[1] if plug else None
    plug_rect = None
    if plug_id:
        owner = run("xprop", "-id", plug_id, "_NET_WM_PID")
        plug_pid = re.search(r"_NET_WM_PID\(CARDINAL\) = (\d+)", owner)
        if plug_pid and int(plug_pid[1]) != pid:
            raise RuntimeError(f"Socket {xid} bounds={socket} embeds pid={plug_pid[1]}, expected pid={pid}")
        plug_rect = bounds(plug_id)

    for _ in range(8):
        parent = re.search(r"Parent window id: (0x[\da-f]+)", tree, re.I)
        if not parent or int(parent[1], 16) == 0:
            break
        panel_id = parent[1]
        if '"xfce4-panel"' in run("xprop", "-id", panel_id, "WM_CLASS").lower():
            bar = bounds(panel_id)
            if not bar or bar[2] <= bar[3] or not 0 <= bar[1] + bar[3] // 2 < 768 // 2:
                raise RuntimeError(f"Socket {xid} bounds={socket} has unusable top panel {panel_id} bounds={bar}")
            return socket, plug_id, plug_rect, panel_id, bar
        tree = run("xwininfo", "-id", panel_id, "-tree")
    raise RuntimeError(f"Socket {xid} bounds={socket} has no Xfce panel ancestor")


def mapped_speaker(pid, socket_id):
    xid = hex(socket_id)
    started = time.monotonic()
    geometry = None
    while True:
        try:
            socket, plug, plug_rect, panel_id, bar = speaker_geometry(pid, xid)
        except (subprocess.SubprocessError, RuntimeError) as exc:
            raise RuntimeError(f"Cannot validate speaker pid={pid} socket={xid} after "
                               f"{time.monotonic() - started:.1f}s: {exc}; last={geometry}") from exc
        elapsed = time.monotonic() - started
        first = geometry is None
        geometry = (f"pid={pid} socket={xid} bounds={socket} plug={plug} plug_bounds={plug_rect} "
                    f"panel={panel_id} panel_bounds={bar} elapsed={elapsed:.1f}s")
        if first:
            print(f"PANEL_ALLOCATION_FIRST {geometry}", flush=True)
        if socket and plug_rect:
            # XEmbed clips the wrapper to its socket. Only accept a real
            # patch of the wrapper that the top panel can receive touches on.
            rectangles = (socket, plug_rect, bar, (0, 0, 1024, 768))
            left = max(r[0] for r in rectangles)
            top = max(r[1] for r in rectangles)
            width = min(r[0] + r[2] for r in rectangles) - left
            height = min(r[1] + r[3] for r in rectangles) - top
            if min(width, height) >= 12:
                target = left, top, width, height
                print(f"PANEL_X11_SOCKET {geometry} touch_bounds={target}", flush=True)
                return pid, target
        if elapsed >= ALLOCATION_WAIT:
            print(f"PANEL_ALLOCATION_TIMEOUT {geometry}", flush=True)
            raise RuntimeError(f"No touchable speaker allocation after {ALLOCATION_WAIT}s: {geometry}")
        time.sleep(min(2.0, ALLOCATION_WAIT - elapsed))


def speaker_button():
    observer_pid = os.environ.get("Y700_PANEL_WRAPPER_PID")
    observer_socket = os.environ.get("Y700_PANEL_SOCKET_XID")
    if observer_pid is not None or observer_socket is not None:
        if (not re.fullmatch(r"[1-9][0-9]*", observer_pid or "")
                or not re.fullmatch(r"(?:[1-9][0-9]*|0[xX][0-9A-Fa-f]+)", observer_socket or "")):
            raise RuntimeError(f"Invalid observer speaker pid={observer_pid!r} socket={observer_socket!r}")
        pid, socket_id = int(observer_pid), int(observer_socket, 0)
        if pid > 0x7fffffff or not 0 < socket_id <= 0xffffffff:
            raise RuntimeError(f"Out-of-range observer speaker pid={pid} socket={socket_id}")
        # The observer verified the wrapper UID, plugin ID, loaded library and
        # argv. The session user verifies its live XEmbed socket and owns all UI.
        return mapped_speaker(pid, socket_id)
    for proc in Path("/proc").glob("[0-9]*"):
        try:
            if proc.stat().st_uid != os.getuid():
                continue
            args = (proc / "cmdline").read_bytes().split(b"\0")
            module = next((i for i, arg in enumerate(args) if arg.endswith(b"/libpulseaudio-plugin.so")), None)
            if module is None or args[module + 1] != b"19":
                continue
            if b"DISPLAY=" + os.fsencode(os.environ["DISPLAY"]) not in (proc / "environ").read_bytes().split(b"\0"):
                continue
            if "/libpulseaudio-plugin.so" not in (proc / "maps").read_text():
                continue
            socket_id = int(args[module + 2])
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        return mapped_speaker(int(proc.name), socket_id)
    return None


def owner_menu(pid):
    # GTK popup menus are direct children of the X root and may be allocated
    # before being mapped. Filter by the real wrapper PID and mapped state.
    tree = run("xwininfo", "-root", "-children")
    for line in tree.splitlines():
        window = re.match(r"\s*(0x[\da-f]+)\b", line)
        size = re.search(r" (\d+)x(\d+)[+-]\d+[+-]\d+\s+", line)
        if not window or not size:
            continue
        width, height = map(int, size.groups())
        if not (100 < width < 1024 and 25 < height < 768):
            continue
        xid = window[1]
        props = run("xprop", "-id", xid, "_NET_WM_PID", "_NET_WM_WINDOW_TYPE")
        if not re.search(rf"_NET_WM_PID\(CARDINAL\) = {pid}\b", props):
            continue
        if not re.search(r"_NET_WM_WINDOW_TYPE_(?:POPUP_MENU|DROPDOWN_MENU|MENU)\b", props):
            continue
        rect = bounds(xid)
        if rect:
            margins = re.search(r"= (\d+), (\d+), (\d+), (\d+)", run("xprop", "-id", xid, "_GTK_FRAME_EXTENTS"))
            left, right, top, bottom = map(int, margins.groups()) if margins else (0, 0, 0, 0)
            x, y, width, height = rect
            return xid, (x + left, y + top, width - left - right, height - top - bottom)
    return None


def sink_info():
    props = run("wpctl", "inspect", DEFAULT)
    sink = re.search(r'\bnode.name = "([^"]+)"', props)
    if not sink or 'media.class = "Audio/Sink"' not in props:
        return None
    return sink[1]


def audio_state():
    value = run("wpctl", "get-volume", DEFAULT)
    match = re.fullmatch(r"Volume: (\d+(?:\.\d+)?)\s*(\[MUTED\])?", value)
    if not match:
        raise RuntimeError(f"Unrecognized default sink state: {value}")
    return match[1], bool(match[2])


def output_switch(menu):
    # In plugin 0.4.9 the first row is an output scale with a GtkSwitch
    # packed on the trailing side. Use the current GTK theme/scale sizes.
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk

    xid, (x, y, width, height) = menu
    switch = Gtk.Switch()
    switch.show()
    natural = switch.get_preferred_size()[1]
    scale = switch.get_scale_factor()
    if not (24 <= natural.width <= 100 and 10 <= natural.height <= 60 and 1 <= scale <= 3):
        raise RuntimeError("Unexpected GTK switch geometry")
    # GTK menu items have padding around the switch. Locate the first row's
    # center from the menu border. Keeping well inside the switch tolerates
    # normal theme gutters. Always check the real sink response afterwards.
    px = x + width - (natural.width // 2 + 8) * scale
    py = y + (natural.height // 2 + 8) * scale
    print(f"PANEL_OUTPUT_ROW menu={xid} bounds={x},{y},{width},{height} "
          f"gtk_switch={natural.width}x{natural.height} scale={scale}", flush=True)
    return px, py


def main():
    if os.getuid() == 0 or b"linux,dummy-virt" not in Path("/proc/device-tree/compatible").read_bytes().split(b"\0"):
        raise RuntimeError("Requires the ordinary account on the test VM desktop")
    root_info = run("xwininfo", "-root")
    if not (re.search(r"Width:\s+1024\b", root_info) and re.search(r"Height:\s+768\b", root_info)):
        raise RuntimeError("Expected the 1024x768 touch mapping")
    sink = wait_for(sink_info, "default sink")
    if sink != "auto_null":
        raise RuntimeError(f"Expected the VM's silent auto_null sink, found {sink}")
    pid, (x, y, width, height) = wait_for(speaker_button, "mapped top-bar PulseAudio wrapper")
    original = audio_state()
    print(f"PANEL_SPEAKER pid={pid} bounds={x},{y},{width},{height} sink={sink} "
          f"volume={original[0]} initial_mute={int(original[1])}", flush=True)
    if owner_menu(pid):
        raise RuntimeError("Unexpected existing audio popup")
    tap(x + width // 2, y + height // 2)
    menu = wait_for(lambda: owner_menu(pid), "speaker menu")
    pos = output_switch(menu)
    tap(*pos)
    try:
        wait_for(lambda: audio_state() == (original[0], not original[1]), "sink mute inversion", 14)
        print(f"PANEL_SINK_CHANGED mute={int(not original[1])} volume={original[0]}", flush=True)
    finally:
        if audio_state()[1] != original[1]:
            if not owner_menu(pid):
                tap(x + width // 2, y + height // 2)
            pos = output_switch(wait_for(lambda: owner_menu(pid), "speaker menu for restore"))
            # Avoid triggering GTK's double-click handling on a fast machine.
            time.sleep(0.6)
            tap(*pos)
            wait_for(lambda: audio_state() == original, "original sink state", 14)
    if owner_menu(pid):
        # Tapping outside dismisses this user's popup.
        tap(4, 740)
    if sink_info() != sink or audio_state() != original or owner_menu(pid):
        raise RuntimeError("Sink or desktop menu was not restored")
    print("PANEL_TOUCH_VOLUME_PASS input=type-b sink=auto_null changed=mute restored=1", flush=True)


if __name__ == "__main__":
    def timed_out(signum, frame):
        raise TimeoutError("Desktop volume test exceeded its wall-clock budget")
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(145 + ALLOCATION_WAIT)
    main()
