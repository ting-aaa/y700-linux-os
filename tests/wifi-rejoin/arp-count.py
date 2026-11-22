"""Count only conventional IPv4 ARP for the tablet/Windows and tablet/gateway pairs."""
import argparse
from collections import Counter
import ctypes
import ipaddress
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import time


class Instruction(ctypes.Structure):
    _fields_ = [("code", ctypes.c_ushort), ("yes", ctypes.c_ubyte),
                ("no", ctypes.c_ubyte), ("value", ctypes.c_uint32)]


class Program(ctypes.Structure):
    _fields_ = [("length", ctypes.c_ushort), ("instructions", ctypes.POINTER(Instruction))]


def attach(sock, local, peer, gateway):
    # Ethernet, no VLAN tag. Require IPv4 over Ethernet ARP, valid opcode, and both
    # endpoints before delivering even the 42-byte header to the application.
    rows = [
        ("eth", 0x28, 12), ("arp", 0x15, 0x0806, "types", "drop"),
        ("types", 0x20, 14), ("ipv4", 0x15, 0x00010800, "lens", "drop"),
        ("lens", 0x28, 18), ("size", 0x15, 0x0604, "op", "drop"),
        ("op", 0x28, 20), ("req", 0x15, 1, "src", "reply"), ("reply", 0x15, 2, "src", "drop"),
        ("src", 0x20, 28), ("out", 0x15, int(local), "target", "incoming"),
        ("incoming", 0x20, 38), ("to_us", 0x15, int(local), "sender", "drop"),
        ("sender", 0x20, 28), ("peer_in", 0x15, int(peer), "keep", "gw_in"),
        ("gw_in", 0x15, int(gateway), "keep", "drop"),
        ("target", 0x20, 38), ("peer_out", 0x15, int(peer), "keep", "gw_out"),
        ("gw_out", 0x15, int(gateway), "keep", "drop"),
        ("keep", 0x06, 42), ("drop", 0x06, 0),
    ]
    offsets = {row[0]: i for i, row in enumerate(rows)}
    instructions = []
    for i, (_, code, value, *targets) in enumerate(rows):
        yes, no = [offsets[t] - i - 1 for t in targets] if targets else (0, 0)
        instructions.append(Instruction(code, yes, no, value))
    vector = (Instruction * len(rows))(*instructions)
    program = Program(len(rows), vector)
    sock.setsockopt(socket.SOL_SOCKET, 26, bytes(program))  # SO_ATTACH_FILTER
    sock.setsockopt(socket.SOL_SOCKET, 44, 1)  # SO_LOCK_FILTER


def route(*args):
    return json.loads(subprocess.check_output(["ip", "-4", "-j", "route", *args], timeout=2))


def mhz(iface):
    raw = subprocess.check_output(["wpa_cli", "-i", iface, "status"], timeout=2)
    fields = dict(line.split(b"=", 1) for line in raw.splitlines() if b"=" in line)
    return int(fields.get(b"freq", 0)) if fields.get(b"wpa_state") == b"COMPLETED" else 0


def run(peer, seconds):
    target, = route("get", str(peer))
    iface = target["dev"]
    if "gateway" in target or not (Path("/sys/class/net") / iface / "phy80211").is_dir():
        raise ValueError("Expected a directly connected physical WLAN peer")
    local = ipaddress.IPv4Address(target["prefsrc"])
    default, = route("show", "default", "dev", iface)
    gateway = ipaddress.IPv4Address(default["gateway"])
    if len({local, gateway, peer}) != 3:
        raise ValueError("Three distinct endpoints required")
    # Protocol zero disables delivery until the locked filter is bound to one interface.
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, 0) as sock:
        attach(sock, local, peer, gateway)
        sock.bind((iface, 3))  # ETH_P_ALL also receives Linux PACKET_OUTGOING indications.
        sock.setblocking(False)
        print("WIFI_ARP_READY filter_locked=1 promiscuous=0", flush=True)
        deadline = time.monotonic() + seconds
        counts = Counter()
        previous = mhz(iface)
        while time.monotonic() < deadline:
            tick = time.monotonic() + 1
            # One normal interface-bound gateway echo gives a control independently of
            # the existing peer UDP test. Never invalidate the ARP cache to force a hit.
            with subprocess.Popen(["ping", "-4", "-n", "-I", iface, "-c1", "-W1", str(gateway)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as echo:
                while True:
                    left = tick - time.monotonic()
                    if left <= 0 or not select.select([sock], [], [], left)[0]:
                        break
                    pkt, addr = sock.recvfrom(42)
                    outgoing = addr[2] == socket.PACKET_OUTGOING
                    src, dst = pkt[28:32], pkt[38:42]
                    if (outgoing and src != local.packed) or (not outgoing and dst != local.packed):
                        counts["direction_mismatch"] += 1
                        continue
                    remote = dst if outgoing else src
                    side = "peer" if remote == peer.packed else "gateway"
                    op = "request" if pkt[20:22] == b"\0\1" else "reply"
                    counts[f"{side}_{'out' if outgoing else 'in'}_{op}"] += 1
                counts["gateway_pings"] += 1
                counts["gateway_replies"] += int(echo.wait(timeout=2) == 0)
            now = mhz(iface)
            observed, dropped = struct.unpack("II", sock.getsockopt(263, 6, 8))  # PACKET_STATISTICS
            counts["socket_packets"] += observed
            counts["socket_drops"] += dropped
            print("WIFI_ARP " + json.dumps(dict(mhz=now if now == previous else 0, **counts),
                                          separators=(",", ":"), sort_keys=True), flush=True)
            previous = now
            counts.clear()


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("peer", type=ipaddress.IPv4Address)
    p.add_argument("--seconds", type=int, choices=range(8, 91), default=60)
    args = p.parse_args()
    signal.alarm(args.seconds + 15)
    try:
        run(args.peer, args.seconds)
    except (OSError, ValueError, subprocess.SubprocessError, KeyError) as exc:
        raise SystemExit(f"WIFI_ARP_FAILED reason={type(exc).__name__}") from None
