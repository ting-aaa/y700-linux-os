"""Observe displayed keyboard codes through X11 and AT-SPI on the private test buses."""
import os
import re
import secrets
import subprocess
import tempfile
import time

from pairing import (
    AGENT, AGENT_IFACE, BLUEZ, MOCK_IFACE, Atspi, Gdk, Gio, GLib, application,
    await_value, call, emit, matching_label, owner, registered, require, showing_nodes, system_agent,
)


def windows(pid):
    result = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", str(pid),
                             "--name", "^Bluetooth$"], capture_output=True, text=True, timeout=4)
    require(result.returncode in (0, 1), "x11-window-search-failed")
    return result.stdout.split()


def stable(predicate, error):
    await_value(predicate, error)
    until = time.monotonic() + .6
    while time.monotonic() < until:
        require(predicate(), error)
        time.sleep(.05)


def main():
    require(os.geteuid() != 0 and os.environ["DBUS_SYSTEM_BUS_ADDRESS"].startswith(
        "unix:path=/run/blueman-pairing/"), "isolated-ordinary-session-required")
    Atspi.init()
    Atspi.set_timeout(2500, 2500)
    require(Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2, "scale-mismatch")
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
    await_value(lambda: owner(bus, BLUEZ), "mock-missing")
    call(bus, BLUEZ, "/", "org.bluez.Mock", "AddAdapter", GLib.Variant("(ss)", ("hci0", "Fixture")))
    keyboards = [
        call(bus, BLUEZ, "/", "org.bluez.Mock", "AddDevice", GLib.Variant(
            "(sss)", ("hci0", f"02:00:00:00:00:{index:02x}", f"Fixture keyboard {index}")))[0]
        for index in (1, 2)
    ]
    first, second = keyboards
    old = os.environ["BLUEMAN_EXPECTED_VERSION"] == "2.4.4-1+y7001"
    codes = secrets.SystemRandom().sample(range(100000), 5)
    with tempfile.TemporaryFile() as log, subprocess.Popen(
        ["blueman-applet"], stdout=subprocess.DEVNULL, stderr=log,
    ) as applet:
        try:
            await_value(lambda: registered(bus), "agent-not-registered", seconds=40)
            agent = await_value(lambda: system_agent(bus, applet.pid), "agent-not-exported")

            def invoke(member, arguments=None):
                require(call(bus, agent, AGENT, AGENT_IFACE, member, arguments) == (), "agent-reply")

            def passkey_labels():
                return [node for node in showing_nodes(application(applet.pid))
                        if node.get_role() == Atspi.Role.LABEL
                        and (node.get_name() or "").startswith("Pairing passkey for")]

            def display(device, code, entered):
                invoke("DisplayPasskey", GLib.Variant("(ouq)", (device, code, entered)))
                await_value(lambda: windows(applet.pid) and len(passkey_labels()) == 1
                            and matching_label(applet.pid, code),
                            "one-matching-dialog-required")

            def property_change(device, key, value):
                call(bus, BLUEZ, device, MOCK_IFACE, "UpdateProperties", GLib.Variant(
                    "(sa{sv})", ("org.bluez.Device1", {key: GLib.Variant("b", value)})))

            def cleared(code):
                stable(lambda: not passkey_labels() and not matching_label(applet.pid, code),
                       "previous-passkey-still-visible")

            for entered in range(7):
                display(first, codes[0], entered)
                require(len(windows(applet.pid)) == 1, "extra-window-during-six-updates")
            emit("PASSKEY_UI initial_plus_six_updates=7 single_matching_window_each=1")
            invoke("Cancel")
            cleared(codes[0])
            display(second, codes[1], 0)
            property_change(first, "Paired", True)
            if old:
                cleared(codes[1])
            else:
                stable(lambda: len(passkey_labels()) == 1 and matching_label(applet.pid, codes[1]),
                       "unrelated-device-property-closed-new-prompt")
            emit(f"PASSKEY_AFTER_CANCEL old_device_event_closed_next_prompt={int(old)}")
            invoke("Cancel")
            cleared(codes[1])

            for entered in range(7):
                display(second, codes[2], entered)
            property_change(second, "Paired", True)
            cleared(codes[2])
            emit("PASSKEY_PAIRED window_and_label_cleared=1")

            property_change(first, "Connected", True)
            display(first, codes[3], 0)
            property_change(first, "Connected", False)
            cleared(codes[3])
            emit("PASSKEY_DISCONNECTED window_and_label_cleared=1")

            display(second, codes[4], 0)
            invoke("Release")
            cleared(codes[4])
            xml = call(bus, agent, AGENT, "org.freedesktop.DBus.Introspectable", "Introspect")[0]
            require(AGENT_IFACE not in xml, "released-agent-still-exported")
            # A late state transition after the agent is retired must be harmless.
            property_change(second, "Connected", False)
            await_value(lambda: application(applet.pid) is not None, "applet-exited")
            time.sleep(.4)
            # Only record exception counts, never copy applet output or display codes.
            data = os.pread(log.fileno(), os.fstat(log.fileno()).st_size, 0)
            traces = data.split(b"Traceback (most recent call last):")[1:]
            agent_traces = [trace for trace in traces if b'/blueman/main/applet/BluezAgent.py"' in trace]
            errors = sum(b"KeyError:" in trace and b"in _on_device_property_changed" in trace
                         for trace in agent_traces)
            for trace in traces:
                if trace not in agent_traces:
                    frames = re.findall(rb'^  File ".*/([\w-]+\.py)", line \d+, in (\w+)', trace, re.M)
                    if frames:
                        emit("APPLET_OTHER_TRACE " + ".".join(part.decode() for part in frames[-1]))
            require(errors > 0 if old else not agent_traces, "unexpected-pairing-agent-tracebacks")
            emit(f"PASSKEY_RELEASE agent_unexported=1 passkey_labels=0 callback_key_errors={errors} "
                 f"agent_tracebacks={len(agent_traces)}")
            emit("PASSKEY_LIFETIME_CONTROL_REPRODUCED" if old else "PASSKEY_LIFETIME_PASS")
        finally:
            applet.terminate()
            try:
                applet.wait(timeout=4)
            except subprocess.TimeoutExpired:
                applet.kill()


if __name__ == "__main__":
    main()
