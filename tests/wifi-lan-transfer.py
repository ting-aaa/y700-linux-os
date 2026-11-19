"""Measure verified TCP payloads over the tablet's associated WLAN, controlled over USB."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time


MIB = 1024 * 1024
BLOCK = 64 * 1024
ROUNDS = 3
COUNTERS = ("rx_bytes", "tx_bytes", "rx_errors", "tx_errors", "rx_dropped", "tx_dropped")


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.recv(count - len(result))
        if not part:
            raise EOFError("Peer closed the transfer early")
        result.extend(part)
    return bytes(result)


def expect(stream, marker):
    if read_exact(stream, len(marker)) != marker:
        raise ValueError("Peer did not acknowledge the expected transfer phase")


def send_payload(stream, size):
    block = os.urandom(BLOCK)
    digest = hashlib.sha256()
    for _ in range(size // BLOCK):
        digest.update(block)
    stream.sendall(digest.digest())
    expect(stream, b"G")
    for _ in range(size // BLOCK):
        stream.sendall(block)
    expect(stream, b"K")


def receive_payload(stream, size):
    expected = read_exact(stream, 32)
    digest = hashlib.sha256()
    remaining = size
    start = time.perf_counter()
    stream.sendall(b"G")
    while remaining:
        data = stream.recv(min(BLOCK, remaining))
        if not data:
            raise EOFError("Truncated payload")
        digest.update(data)
        remaining -= len(data)
    elapsed = time.perf_counter() - start
    if digest.digest() != expected:
        raise ValueError("Payload SHA-256 mismatch")
    stream.sendall(b"K")
    return round(size * 8 / elapsed / 1e6, 2)


def counters(interface):
    return {name: int((interface / "statistics" / name).read_text()) for name in COUNTERS}


def tablet(peer, size):
    import signal

    signal.alarm(240)
    route, = json.loads(subprocess.check_output(["ip", "-j", "-4", "route", "get", peer]))
    interface = Path("/sys/class/net") / route["dev"]
    if "gateway" in route or not (interface / "phy80211").is_dir():
        raise ValueError("The host must be on-link via the physical WLAN interface")
    driver = (interface / "device/driver").resolve(strict=True).name
    token = secrets.token_bytes(32)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.settimeout(20)
        listener.bind((route["prefsrc"], 0))
        listener.listen(1)
        print(json.dumps([*listener.getsockname(), token.hex()]), flush=True)
        stream, endpoint = listener.accept()
    with stream:
        stream.settimeout(15)
        if endpoint[0] != peer or not secrets.compare_digest(read_exact(stream, 32), token):
            raise ValueError("Client address or session token mismatch")
        before = counters(interface)
        received = []
        for _ in range(ROUNDS):
            received.append(receive_payload(stream, size))
            send_payload(stream, size)
        after = counters(interface)
    deltas = {name: after[name] - before[name] for name in COUNTERS}
    if min(deltas["rx_bytes"], deltas["tx_bytes"]) < ROUNDS * size:
        raise ValueError("Wireless byte counters do not cover the completed transfers")
    print(json.dumps({"driver": driver, "tablet_rx_Mbps": received, "wireless_delta": deltas}))


def host(peer, size_mib, control):
    # Validated IP and integer are the only interpolated remote command arguments.
    remote = ("runuser -u nobody -- env HOME=/tmp uv run --no-config --no-cache --offline "
              f"--no-project --python /usr/bin/python3 python -B - --tablet {peer} --mib {size_mib}")
    process = subprocess.Popen([*control, remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        with process.stdin:
            process.stdin.write(Path(__file__).read_bytes())
        with process.stdout:
            address, port, token = json.loads(process.stdout.readline())
            received = []
            with socket.create_connection((address, port), timeout=15, source_address=(peer, 0)) as stream:
                stream.sendall(bytes.fromhex(token))
                for _ in range(ROUNDS):
                    send_payload(stream, size_mib * MIB)
                    received.append(receive_payload(stream, size_mib * MIB))
            report = json.loads(process.stdout.readline())
        if process.wait(timeout=10):
            raise RuntimeError("Tablet verification failed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    report.update(tablet_tx_Mbps=received, MiB_per_transfer=size_mib, verified_transfers=2 * ROUNDS)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    location = parser.add_mutually_exclusive_group(required=True)
    location.add_argument("--host", type=ipaddress.IPv4Address, help="Host's on-link LAN IPv4 address")
    location.add_argument("--tablet", type=ipaddress.IPv4Address, help=argparse.SUPPRESS)
    parser.add_argument("--mib", type=int, choices=(1, 8, 16, 32), default=16)
    parser.add_argument("--control", nargs=argparse.REMAINDER, help="Host-key-checked USB SSH wrapper command")
    args = parser.parse_args()
    if args.tablet:
        tablet(str(args.tablet), args.mib * MIB)
    elif args.control:
        host(str(args.host), args.mib, args.control)
    else:
        parser.error("--host requires --control")
