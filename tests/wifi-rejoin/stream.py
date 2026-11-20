"""Keep one bidirectional TCP connection across two hwsim band changes."""
import hashlib
import os
from pathlib import Path
import socket
import struct
import sys
import time


ROOT = Path("/run/wifi-fixture/rejoin")
ADDRESS = ("192.0.2.1", 19500)
DATA = 4096


def read(sock, length):
    data = bytearray()
    while len(data) < length:
        block = sock.recv(length - len(data))
        if not block:
            raise EOFError("Test connection ended early")
        data.extend(block)
    return bytes(data)


def server():
    with socket.socket() as listener:
        listener.bind(ADDRESS)
        listener.listen(1)
        (ROOT / "listening").touch()
        sock, _ = listener.accept()
    with sock:  # The listener is already closed.
        n = 0
        while True:
            request = read(sock, DATA + 12)
            sequence, epoch = struct.unpack("!QI", request[:12])
            assert sequence == n
            reply = os.urandom(DATA)
            sock.sendall(reply + hashlib.sha256(request + reply).digest())
            if epoch == 3:
                return
            n += 1


def client(interface):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, os.fsencode(interface) + b"\0")
        sock.settimeout(80)
        sock.connect(ADDRESS)
        last = time.monotonic()
        max_gap = 0.0
        sequence = 0
        while True:
            epoch = int((ROOT / "epoch").read_text())
            request = struct.pack("!QI", sequence, epoch) + os.urandom(DATA)
            sock.sendall(request)
            reply = read(sock, DATA + 32)
            assert reply[DATA:] == hashlib.sha256(request + reply[:DATA]).digest()
            now = time.monotonic()
            max_gap = max(max_gap, now - last)
            (ROOT / "ack.tmp").write_text(f"{epoch} {sequence + 1} {max_gap:.3f}\n")
            (ROOT / "ack.tmp").replace(ROOT / "ack")
            if epoch == 3:
                return
            last = now
            sequence += 1
            time.sleep(.15)


if __name__ == "__main__":
    assert "y700.wifi_rejoin=3" in Path("/proc/cmdline").read_text().split()
    if sys.argv[1] == "server":
        server()
    else:
        client(sys.argv[1])
