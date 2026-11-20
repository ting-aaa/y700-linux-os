"""Measure verified TCP payloads over the tablet's associated WLAN, controlled over USB."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
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


def frequency(interface):
    if shutil.which("iw") is None:
        return None
    link = subprocess.check_output(["iw", "dev", interface.name, "link"], text=True)
    match = re.search(r"^\s*freq:\s*(\d+)(?:\.0+)?(?:\s|$)", link, re.MULTILINE)
    if not match:
        raise RuntimeError("No associated WLAN frequency")
    return int(match.group(1))


def socket_address(ip, port, scope):
    if ip.version == 4:
        return str(ip), port
    return str(ip), port, 0, scope


def tablet(peer, size):
    import signal

    signal.alarm(240)
    net = Path("/sys/class/net")
    command = ["ip", "-j", f"-{peer.version}", "route", "get", str(peer)]
    link_local = peer.version == 6 and peer.is_link_local
    if link_local:
        wireless = [path for path in net.iterdir() if (path / "phy80211").is_dir()
                    and (path / "operstate").read_text().strip() == "up"]
        if len(wireless) != 1:
            raise ValueError("Scoped IPv6 requires one active physical WLAN on the tablet")
        command.extend(["oif", wireless[0].name])
    route, = json.loads(subprocess.check_output(command))
    interface = net / route["dev"]
    if "gateway" in route or not (interface / "phy80211").is_dir():
        raise ValueError("The host must be on-link via the physical WLAN interface")
    driver = (interface / "device/driver").resolve(strict=True).name
    address = ipaddress.ip_address(route["prefsrc"])
    if address.version != peer.version or (link_local and not address.is_link_local):
        raise ValueError("Route selected an incompatible WLAN source address")
    scope = socket.if_nametoindex(interface.name) if link_local else 0
    token = secrets.token_bytes(32)
    with socket.socket(socket.AF_INET6 if peer.version == 6 else socket.AF_INET) as listener:
        listener.settimeout(20)
        listener.bind(socket_address(address, 0, scope))
        listener.listen(1)
        print(json.dumps([str(address), listener.getsockname()[1], token.hex()]), flush=True)
        stream, endpoint = listener.accept()
    with stream:
        stream.settimeout(15)
        if ipaddress.ip_address(endpoint[0]) != peer or (link_local and endpoint[3] != scope):
            raise ValueError("Unexpected client endpoint")
        if not secrets.compare_digest(read_exact(stream, 32), token):
            raise ValueError("Client address or session token mismatch")
        before = counters(interface)
        frequencies = [frequency(interface)]
        received = []
        for _ in range(ROUNDS):
            received.append(receive_payload(stream, size))
            send_payload(stream, size)
            frequencies.append(frequency(interface))
        after = counters(interface)
    deltas = {name: after[name] - before[name] for name in COUNTERS}
    if min(deltas["rx_bytes"], deltas["tx_bytes"]) < ROUNDS * size:
        raise ValueError("Wireless byte counters do not cover the completed transfers")
    print(json.dumps({"driver": driver, "ip_version": peer.version, "link_local": link_local,
                      "frequency_samples_MHz": frequencies,
                      "tablet_rx_Mbps": received, "wireless_delta": deltas}))


def host(peer, size_mib, control):
    # A link-local scope identifies an interface on this host only.
    scope = int(peer.scope_id) if peer.version == 6 and peer.scope_id else 0
    peer = ipaddress.ip_address(peer.packed)
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
            target = ipaddress.ip_address(address)
            if target.version != peer.version or (peer.version == 6 and target.is_link_local != peer.is_link_local):
                raise ValueError("USB control returned an incompatible WLAN endpoint")
            with socket.socket(socket.AF_INET6 if peer.version == 6 else socket.AF_INET) as stream:
                stream.settimeout(15)
                stream.bind(socket_address(peer, 0, scope))
                stream.connect(socket_address(target, port, scope))
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
    location.add_argument("--host", type=ipaddress.ip_address,
                          help="Host's on-link WLAN IP address (include %%ifindex for link-local IPv6)")
    location.add_argument("--tablet", type=ipaddress.ip_address, help=argparse.SUPPRESS)
    parser.add_argument("--mib", type=int, choices=(1, 8, 16, 32), default=16)
    parser.add_argument("--control", nargs=argparse.REMAINDER, help="Host-key-checked USB SSH wrapper command")
    args = parser.parse_args()
    address = args.tablet or args.host
    if address.is_multicast or address.is_unspecified or address.is_loopback:
        parser.error("A unicast WLAN address is required")
    if address.version == 6:
        zone = address.scope_id
        if args.host and address.is_link_local:
            if not zone or not zone.isascii() or not zone.isdecimal() or not 0 < int(zone) <= 0xffffffff:
                parser.error("Link-local --host requires a numeric WLAN interface index after %")
        elif zone is not None:
            parser.error("Only a link-local --host can include a zone")
    if args.tablet:
        tablet(args.tablet, args.mib * MIB)
    elif args.control:
        host(args.host, args.mib, args.control)
    else:
        parser.error("--host requires --control")
