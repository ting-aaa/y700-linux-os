"""Read the RAM health receipt, or explicitly start one run for the previously observed token."""
import argparse
import hashlib
import re
import socket
import time


class Channel:
    def __init__(self, port, vm_socket):
        self.buffer = bytearray()
        self.sock = None
        self.serial = None
        if vm_socket:
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.settimeout(1)
            self.sock.connect(vm_socket)
        else:
            import serial
            from serial.tools import list_ports
            matches = [dev for dev in list_ports.comports()
                       if dev.device == port and (dev.vid, dev.pid) == (0x18d1, 0x4e11)
                       and dev.serial_number == "Y700_RAM_AF"]
            if len(matches) != 1:
                raise RuntimeError("Selected port does not identify the Y700 RAM autofocus gadget")
            self.serial = serial.Serial(port, baudrate=115200, timeout=1, write_timeout=5)

    def send(self, message):
        data = message.encode("ascii") + b"\n"
        if self.sock:
            self.sock.sendall(data)
        else:
            self.serial.write(data)

    def line(self):
        while b"\n" not in self.buffer:
            try:
                data = self.sock.recv(1024) if self.sock else self.serial.read_until(b"\n", 700)
            except socket.timeout:
                return None
            if not data:
                if self.sock:
                    raise EOFError("VM diagnostic channel closed")
                return None
            self.buffer.extend(data)
            if len(self.buffer) > 2048 and b"\n" not in self.buffer:
                raise ValueError("Oversized diagnostic response")
        row, _, remaining = self.buffer.partition(b"\n")
        self.buffer = bytearray(remaining)
        if len(row) > 700:
            raise ValueError("Oversized diagnostic response")
        return row.decode("ascii").rstrip("\r")

    def close(self):
        (self.sock or self.serial).close()


def status(channel, virtual):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            channel.send("STATUS")
        except socket.timeout:
            if not virtual:
                raise
            continue  # The guest has not opened its virtio port yet.
        row = channel.line()
        if row and re.fullmatch(r"AF1 BLOCKED [0-9a-f]{32} storage=none swap=none root=ram "
                                + f"selftest=failed virtual={int(virtual)}", row):
            raise RuntimeError("RAM storage guard passed, camera self-test failed")
        if row and (m := re.fullmatch(r"AF1 (READY|DONE) ([0-9a-f]{32}) storage=none swap=none root=ram "
                                      + f"selftest=pass virtual={int(virtual)}", row)):
            print(row, flush=True)
            return m.groups()
    raise TimeoutError("No verified health and self-test receipt")


def result(channel, token, virtual, start, acknowledge=False):
    if start:
        channel.send("START " + token)
    else:
        channel.send("RESULT " + token)
    running = not start
    digest = hashlib.sha256()
    deadline = time.monotonic() + 100
    while time.monotonic() < deadline:
        row = channel.line()
        if row is None:
            continue
        if row == f"AF1 RUNNING {token} virtual={int(virtual)}":
            running = True
        elif row.startswith(("AF1 READY ", "AF1 DONE ")):
            continue  # A previously sent STATUS may still have a response in flight.
        elif running and re.fullmatch(r"AF1 END rc=\d{1,3}", row):
            digest.update((row + "\n").encode("ascii"))
            print(row, flush=True)
            if acknowledge:
                channel.send(f"ACK {token} {digest.hexdigest()}")
                ack_deadline = time.monotonic() + 8
                while time.monotonic() < ack_deadline:
                    reply = channel.line()
                    if reply is None:
                        continue
                    if reply != "AF1 RETURN acknowledged=1":
                        raise RuntimeError("Receipt confirmation failed; reconnect and retrieve RESULT")
                    print(reply, flush=True)
                    break
                else:
                    raise TimeoutError("Return confirmation missing; independent RAM timer remains armed")
            return int(row.split("=")[1])
        elif not (running and re.fullmatch(r"AF_(PREVIEW|SCAN|EXPOSURE|RESULT|ERROR|DIAG|CLEANUP|TEST)"
                                          r"( [a-z_]+=[A-Za-z0-9_./:+-]+)+", row)):
            raise RuntimeError("Unexpected diagnostic response")
        else:
            digest.update((row + "\n").encode("ascii"))
        print(row, flush=True)
    raise TimeoutError("No terminal measurement receipt")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "start", "result"])
    transport = parser.add_mutually_exclusive_group(required=True)
    transport.add_argument("--port")
    transport.add_argument("--vm-socket")
    parser.add_argument("--token")
    args = parser.parse_args()
    link = Channel(args.port, args.vm_socket)
    try:
        state, token = status(link, bool(args.vm_socket))
        if args.action == "start":
            if state != "READY" or args.token != token:
                raise SystemExit("Start requires a matching READY token from this boot")
            raise SystemExit(result(link, token, bool(args.vm_socket), True, acknowledge=not args.vm_socket))
        if args.action == "result":
            if state != "DONE" or args.token != token:
                raise SystemExit("Retrieval requires a matching DONE token from this boot")
            raise SystemExit(result(link, token, bool(args.vm_socket), False, acknowledge=not args.vm_socket))
    finally:
        link.close()
