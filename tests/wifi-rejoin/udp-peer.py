"""Measure independent WLAN UDP delivery to the single peer authorized over USB."""
import argparse
import ctypes
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import runpy
import secrets
import shlex
import socket
import struct
import subprocess
import sys
import threading
import time
from types import SimpleNamespace


WINDOW = 0.55
MAX_ROUNDS = 90
STATES = ("UNREACHABLE", "INCOMPLETE", "PROBE", "DELAY", "STALE", "REACHABLE", "PERMANENT")
KNOWN = set(STATES) | {"FAILED", "NOARP", "NONE", "ABSENT", "UNKNOWN"}


class ProbeError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ProbeError(message)


def send_record(stream, value):
    stream.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    stream.flush()


def read_record(stream):
    line = stream.readline(512)
    require(line.endswith(b"\n"), "USB control record missing or too long")
    return json.loads(line)


def challenge(key, sender, index):
    header = b"Y7UD1" + sender + struct.pack("!H", index)
    return header + hmac.digest(key, header, hashlib.sha256)[:16]


def send_probe(sock, data):
    try:
        return int(sock.send(data) == len(data))
    except OSError:
        return 0


def receive_probe(sock, expected):
    deadline = time.monotonic() + WINDOW
    for _ in range(12):
        left = deadline - time.monotonic()
        if left <= 0:
            break
        sock.settimeout(left)
        try:
            data = sock.recv(64)
        except TimeoutError:
            break
        except OSError:
            return 0, 1
        if hmac.compare_digest(data, expected):
            return 1, 0
    return 0, 0


def linux_neighbor(peer, interface):
    try:
        data = subprocess.check_output(["ip", "-j", f"-{peer.version}", "neigh", "show", "to",
                                        str(peer), "dev", interface.name], stderr=subprocess.DEVNULL, timeout=1)
        rows = json.loads(data)
        if not rows:
            return "ABSENT"
        state, = rows[0]["state"]
        return state if len(rows) == 1 and state in KNOWN else "UNKNOWN"
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        return "UNKNOWN"


class NeighborRow(ctypes.Structure):
    # Windows SDK MIB_IPNET_ROW2. Only address, interface index and state are used.
    _fields_ = [("address", ctypes.c_ubyte * 28), ("index", ctypes.c_uint32), ("luid", ctypes.c_uint64),
                ("physical", ctypes.c_ubyte * 32), ("length", ctypes.c_uint32), ("state", ctypes.c_int32),
                ("flags", ctypes.c_ubyte), ("time", ctypes.c_uint32)]


def windows_neighbor(peer, index):
    row = NeighborRow()
    ipv4 = peer.version == 4
    addr = struct.pack("<HH", socket.AF_INET if ipv4 else socket.AF_INET6, 0)
    if ipv4:
        addr += peer.packed
    else:
        addr += bytes(4) + peer.packed + struct.pack("<I", index if peer.is_link_local else 0)
    ctypes.memmove(ctypes.addressof(row), addr, len(addr))
    row.index = index
    rc = ctypes.windll.iphlpapi.GetIpNetEntry2(ctypes.byref(row))
    if rc == 1168:  # ERROR_NOT_FOUND
        return "ABSENT"
    return STATES[row.state] if rc == 0 and 0 <= row.state < len(STATES) else "UNKNOWN"


def windows_subnet(local, index):
    # Read the assigned prefix on the requested physical 802.11 interface.
    code = """
    $ErrorActionPreference='Stop'
    $nic=@(Get-NetAdapter -Physical | Where-Object { $_.ifIndex -eq [int]$env:Y700_UDP_INDEX })
    if ($nic.Count -ne 1 -or $nic[0].InterfaceType -ne 71 -or $nic[0].Status -ne 'Up') {exit 2}
    $local=@(Get-NetIPAddress -InterfaceIndex $nic[0].ifIndex -IPAddress $env:Y700_UDP_LOCAL)
    if ($local.Count -ne 1) {exit 3}
    [int]$local[0].PrefixLength
    """
    r = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", code],
                       env={**os.environ, "Y700_UDP_INDEX": str(index), "Y700_UDP_LOCAL": str(local)},
                       capture_output=True, timeout=15)
    require(r.returncode == 0 and r.stdout.strip().isdigit(), "Expected the local address on the selected physical WLAN")
    return ipaddress.ip_network((local, int(r.stdout)), strict=False)


def endpoint(ip):
    return socket.socket(socket.AF_INET if ip.version == 4 else socket.AF_INET6, socket.SOCK_DGRAM)


def peer_loop(lan, peer, local, scope, rounds, frequency, neighbor, source, sink, *, device=None, same_host=False):
    key = secrets.token_bytes(32)
    with endpoint(local) as sock:
        if device:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, os.fsencode(device) + b"\0")
        sock.bind(lan.socket_address(local, 0, scope))
        port = sock.getsockname()[1]
        if not same_host:
            sock.connect(lan.socket_address(peer, port, scope))
        send_record(sink, [str(local), port, key.hex()])
        host_port = read_record(source)
        require(type(host_port) is int and 1024 <= host_port <= 65535 and (same_host or host_port == port),
                "Unexpected host UDP port")
        if same_host:
            sock.connect(lan.socket_address(peer, host_port, scope))
        for index in range(rounds):
            require(read_record(source) == ["round", index], "USB round mismatch")
            state, before = neighbor(), frequency()
            send_record(sink, ["armed", index])
            sent = send_probe(sock, challenge(key, b"T", index))
            received, error = receive_probe(sock, challenge(key, b"W", index))
            after = frequency()
            send_record(sink, [index, before, after, state, sent, received, error])


def tablet(lan, address, rounds):
    import signal
    require(6 <= rounds <= MAX_ROUNDS, "Invalid round limit")
    signal.alarm(25 + 2 * rounds)
    peer = ipaddress.ip_address(address)
    interface, local, scope = lan.wlan_route(peer)
    def band():
        try:
            return lan.frequency(interface, between_associations=True, timeout=1) or 0
        except (OSError, subprocess.SubprocessError, RuntimeError):
            return 0
    peer_loop(lan, peer, local, scope, rounds, band, lambda: linux_neighbor(peer, interface),
              sys.stdin.buffer, sys.stdout.buffer, device=interface.name)


def host_loop(lan, local, index, network, rounds, source, sink, *, same_host=False, neighbor=windows_neighbor):
    addr, port, token = read_record(source)
    peer, key = ipaddress.ip_address(addr), bytes.fromhex(token)
    require(peer.version == local.version and peer in network and not peer.is_multicast and not peer.is_unspecified
            and (same_host or peer != local) and 1024 <= port <= 65535 and len(key) == 32,
            "USB returned an invalid on-link endpoint")
    if peer.version == 4 and network.prefixlen < 31:
        require(peer not in (network.network_address, network.broadcast_address), "USB returned a non-host address")
    scope = index if local.version == 6 and local.is_link_local else 0
    segments = []
    with endpoint(local) as sock:
        if index:
            lan.windows_unicast_interface(sock, local.version, index)
        host_port = 0 if same_host and local == peer else port
        sock.bind(lan.socket_address(local, host_port, scope))
        sock.connect(lan.socket_address(peer, port, scope))
        send_record(sink, sock.getsockname()[1])
        print(f"WIFI_UDP_READY ip_version={peer.version} rounds={rounds}", flush=True)
        for index_round in range(rounds):
            start = time.monotonic()
            host_state = neighbor(peer, index)
            send_record(sink, ["round", index_round])
            require(read_record(source) == ["armed", index_round], "Missing USB round acknowledgement")
            enabled = index_round >= 2
            tx = send_probe(sock, challenge(key, b"W", index_round)) if enabled else 0
            rx, host_error = receive_probe(sock, challenge(key, b"T", index_round))
            seq, before, after, state, tablet_tx, tablet_rx, tablet_error = read_record(source)
            require(seq == index_round and all(type(f) is int and 0 <= f <= 7125 for f in (before, after))
                    and all(type(v) is int and v in (0, 1) for v in (tablet_tx, tablet_rx, tablet_error))
                    and state in KNOWN and host_state in KNOWN and not (tablet_rx and not tx)
                    and not (rx and not tablet_tx), "Inconsistent USB endpoint counts")
            mhz = before if before == after else 0
            if not segments or segments[-1]["mhz"] != mhz:
                segments.append(dict(mhz=mhz, rounds=0, windows_sent=0, tablet_received=0, tablet_sent=0,
                                     windows_received=0, windows_send_errors=0, tablet_send_errors=0,
                                     windows_receive_errors=0, tablet_receive_errors=0, tablet_only_rounds=0,
                                     tablet_only_received=0, windows_neighbor={}, tablet_neighbor={}))
                print(f"WIFI_UDP_BAND mhz={mhz} first_round={index_round+1}", flush=True)
            report = segments[-1]
            for field, value in (("rounds", 1), ("windows_sent", tx), ("tablet_received", tablet_rx),
                                 ("tablet_sent", tablet_tx), ("windows_received", rx),
                                 ("windows_send_errors", int(enabled) - tx), ("tablet_send_errors", 1 - tablet_tx),
                                 ("windows_receive_errors", host_error), ("tablet_receive_errors", tablet_error),
                                 ("tablet_only_rounds", int(not enabled)), ("tablet_only_received", rx if not enabled else 0)):
                report[field] += value
            for field, value in (("windows_neighbor", host_state), ("tablet_neighbor", state)):
                report[field][value] = report[field].get(value, 0) + 1
            # Emit cumulative segment counts even if the USB control later disconnects.
            print("WIFI_UDP_COUNTS " + json.dumps(report, sort_keys=True, separators=(",", ":")), flush=True)
            time.sleep(max(0, 1 - (time.monotonic() - start)))
    return {"ip_version": local.version, "rounds": rounds, "segments": segments}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=ipaddress.ip_address, help="Windows WLAN address")
    parser.add_argument("--windows-ifindex", required=True, type=int)
    parser.add_argument("--rounds", type=int, default=35)
    parser.add_argument("--tablet-uv", default="uv")
    parser.add_argument("--control", nargs=argparse.REMAINDER, required=True, help="Host-key-checked USB SSH wrapper")
    args = parser.parse_args()
    index, scoped = args.windows_ifindex, args.host
    local = ipaddress.ip_address(scoped.packed)
    require(sys.platform == "win32" and args.control and 0 < index <= 0xffffffff and 6 <= args.rounds <= MAX_ROUNDS,
            "Expected a Windows interface index, a USB control command and 6 to 90 rounds")
    require(not (local.is_unspecified or local.is_multicast or local.is_loopback)
            and not getattr(local, "ipv4_mapped", None), "Expected a unicast WLAN address")
    if local.version == 6 and scoped.scope_id:
        require(local.is_link_local and scoped.scope_id == str(index), "IPv6 scope and interface index differ")
    network = windows_subnet(local, index)
    common = Path(__file__).resolve().parents[1] / "wifi-lan-transfer.py"
    lan = SimpleNamespace(**runpy.run_path(str(common)))
    first, second = common.read_bytes(), Path(__file__).read_bytes()
    # Load both files in RAM. Leave stdin open for the existing trusted USB channel.
    init = ("import sys,types; a={'__name__':'wlan'}; b={'__name__':'udp_peer'}; "
            f"exec(sys.stdin.buffer.read({len(first)}),a); exec(sys.stdin.buffer.read({len(second)}),b); "
            f"b['tablet'](types.SimpleNamespace(**a),{str(local)!r},{args.rounds})")
    remote = (f"runuser -u nobody -- env HOME=/tmp {shlex.quote(args.tablet_uv)} run --no-config --no-cache "
              f"--offline --no-project --python /usr/bin/python3 python -B -c {shlex.quote(init)}")
    worker = subprocess.Popen([*args.control, remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)
    timer = threading.Timer(25 + args.rounds * 2, worker.kill)
    timer.start()
    try:
        worker.stdin.write(first + second)
        worker.stdin.flush()
        report = host_loop(lan, local, index, network, args.rounds, worker.stdout, worker.stdin)
        worker.stdin.close()
        require(worker.wait(timeout=5) == 0, "Tablet control did not finish normally")
        print("WIFI_UDP_DONE " + json.dumps(report, sort_keys=True, separators=(",", ":")))
    finally:
        timer.cancel()
        if worker.poll() is None:
            worker.kill()
        worker.wait(timeout=5)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(f"WIFI_UDP_FAILED {exc}") from None
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        # Addresses, peer-subprocess arguments and challenge material stay off receipts.
        raise SystemExit(f"WIFI_UDP_FAILED reason={type(exc).__name__}") from None
