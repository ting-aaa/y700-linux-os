# /// script
# requires-python = ">=3.11"
# dependencies = ["pyserial==3.5"]
# ///
"""Send the exact dev12.12 sealed RAM carrier to the waiting USB or QEMU receiver."""
import argparse
import hashlib
import socket
import time
from contextlib import ExitStack
from pathlib import Path


SIZE = 1_351_581_696
DIGEST = "ce527192a32b47eff9a5f41682e058db88f8ef4bb9421afc737655783fb0229a"


def exchange(send, readline, payload):
    ready = f"Y700_RAM_INFO {SIZE} {DIGEST}".encode()
    for _ in range(15):
        send(b"INFO\n")
        if readline().strip() == ready:
            break
    else:
        raise RuntimeError("Receiver did not identify the expected carrier")
    send(f"BEGIN {DIGEST}\n".encode())
    for _ in range(16):
        line = readline().strip()
        if line == b"Y700_RAM_SEND":
            break
        if line != ready:
            raise RuntimeError("Receiver declined the transfer")
    else:
        raise RuntimeError("Transfer did not start")
    for chunk in iter(lambda: payload.read(1024 * 1024), b""):
        send(chunk)
    if readline().strip() != b"Y700_RAM_VERIFIED":
        raise RuntimeError("Missing receiver SHA-256 confirmation")
    send(b"CONTINUE\n")
    print(f"RAM_CARRIER bytes={SIZE} sha256={DIGEST} receiver_verified=1", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("carrier", type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--usb", action="store_true")
    mode.add_argument("--qemu-socket", type=Path)
    args = parser.parse_args()
    with ExitStack() as stack:
        payload = stack.enter_context(args.carrier.open("rb"))
        if args.carrier.stat().st_size != SIZE or hashlib.file_digest(payload, "sha256").hexdigest() != DIGEST:
            raise RuntimeError("Local carrier identity mismatch")
        payload.seek(0)
        if args.qemu_socket:
            sock = stack.enter_context(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM))
            sock.settimeout(90)
            sock.connect(str(args.qemu_socket))
            stream = stack.enter_context(sock.makefile("rb"))
            exchange(sock.sendall, lambda: stream.readline(180), payload)
            return
        import serial
        from serial.tools import list_ports
        deadline = time.monotonic() + 90
        while True:
            ports = [p for p in list_ports.comports() if (p.vid, p.pid) == (0x18D1, 0x4E11)
                     and p.serial_number == "Y700_RAM_RECEIVER"]
            if len(ports) == 1:
                break
            if len(ports) > 1 or time.monotonic() >= deadline:
                raise RuntimeError("Expected one Y700 RAM receiver USB serial port")
            time.sleep(.4)
        port = stack.enter_context(serial.Serial(ports[0].device, 115200, timeout=3, write_timeout=30))
        def write(data):
            if port.write(data) != len(data):
                raise RuntimeError("Short USB serial write")
            if len(data) > 1000:
                port.timeout = 90
        exchange(write, lambda: port.read_until(size=180), payload)


if __name__ == "__main__":
    main()
