"""Request camera access and run a consumer on the portal's PipeWire connection.

Run inside the target graphical session with its normal D-Bus permissions.
Use -- before the optional consumer command. It receives Y700_CAMERA_PORTAL_FD.
"""
import argparse
import os
import secrets
import socket
import subprocess
import sys
import time

from gi.repository import Gio, GLib


PORTAL = "org.freedesktop.portal.Desktop"
DESKTOP_PATH = "/org/freedesktop/portal/desktop"
CAMERA = "org.freedesktop.portal.Camera"
REQUEST = "org.freedesktop.portal.Request"


def call(bus, path, interface, method, parameters, result_type):
    return bus.call_sync(PORTAL, path, interface, method, parameters, GLib.VariantType.new(result_type),
                         Gio.DBusCallFlags.NONE, 10000, None)


def wait_for_camera(bus, timeout):
    deadline = time.monotonic() + timeout
    while True:
        present, = call(bus, DESKTOP_PATH, "org.freedesktop.DBus.Properties", "Get",
                        GLib.Variant("(ss)", (CAMERA, "IsCameraPresent")), "(v)").unpack()
        if present:
            print("IsCameraPresent=yes", flush=True)
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("The camera portal reports no video source")
        time.sleep(0.2)


def request_access(bus, timeout):
    token = "y700_" + secrets.token_hex(8)
    loop = GLib.MainLoop()
    responses = {}
    request_path = None

    def response(_bus, _sender, path, _interface, _signal, body):
        responses[path] = body.unpack()[0]
        if path == request_path:
            loop.quit()

    def expired():
        loop.quit()
        return GLib.SOURCE_REMOVE

    # Subscribe before requesting. A native application can receive an
    # immediate response, before it has had a chance to inspect the handle.
    subscription = bus.signal_subscribe(PORTAL, REQUEST, "Response", None, None,
                                        Gio.DBusSignalFlags.NONE, response)
    try:
        options = {"handle_token": GLib.Variant("s", token)}
        request_path, = call(bus, DESKTOP_PATH, CAMERA, "AccessCamera",
                             GLib.Variant("(a{sv})", (options,)), "(o)").unpack()
        if request_path not in responses:
            timer = GLib.timeout_source_new_seconds(timeout)
            timer.set_callback(lambda *_: expired())
            timer.attach(loop.get_context())
            try:
                loop.run()
            finally:
                timer.destroy()
        if request_path not in responses:
            call(bus, request_path, REQUEST, "Close", None, "()")
            raise RuntimeError("Camera access request timed out")
        result = responses[request_path]
        print(f"AccessCamera.response={result}", flush=True)
        if result != 0:
            raise RuntimeError("The camera portal did not grant access")
    finally:
        bus.signal_unsubscribe(subscription)


def run(args):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    wait_for_camera(bus, args.timeout)
    request_access(bus, args.timeout)
    reply, descriptors = bus.call_with_unix_fd_list_sync(
        PORTAL, DESKTOP_PATH, CAMERA, "OpenPipeWireRemote", GLib.Variant("(a{sv})", ({},)),
        GLib.VariantType.new("(h)"), Gio.DBusCallFlags.NONE, 10000, None, None)
    index, = reply.unpack()
    if descriptors is None or not 0 <= index < descriptors.get_length():
        raise RuntimeError("Portal returned an invalid file descriptor index")
    with socket.socket(fileno=descriptors.get(index)) as remote:
        if remote.family != socket.AF_UNIX or remote.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != socket.SOCK_STREAM:
            raise RuntimeError("The returned descriptor is not a Unix stream socket")
        remote.getpeername()
        print("OpenPipeWireRemote=connected-unix-stream", flush=True)
        if not args.command:
            return 0
        fd = remote.fileno()
        return subprocess.run(args.command, env={**os.environ, "Y700_CAMERA_PORTAL_FD": str(fd)},
                              pass_fds=(fd,), check=False).returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=30, choices=range(1, 301), metavar="SECONDS")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    try:
        sys.exit(run(args))
    except (GLib.Error, OSError, RuntimeError) as exc:
        sys.exit(f"Camera portal: {exc}")
