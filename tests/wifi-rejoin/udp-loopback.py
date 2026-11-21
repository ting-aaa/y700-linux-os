"""Run both UDP peers as separate processes on loopback."""
import contextlib
import ctypes
import importlib.util
import io
import ipaddress
import json
from pathlib import Path
import runpy
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("udp_peer", here / "udp-peer.py")
udp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(udp)
lan = SimpleNamespace(**runpy.run_path(str(here.parent / "wifi-lan-transfer.py")))
bands = [2437, 2437, 5220, 5220, 2437, 2437]


def peers(version):
    if version == 4:
        return ipaddress.ip_address("127.0.0.1"), ipaddress.ip_address("127.0.0.2"), ipaddress.ip_network("127.0.0.0/8")
    return ipaddress.ip_address("::1"), ipaddress.ip_address("::1"), ipaddress.ip_network("::1/128")


def bad_challenges(sock, data):
    # Each goes only to the same connected loopback endpoint. A bad MAC,
    # a stale authenticated challenge, and a reflected direction must fail.
    if bad_challenges.previous is not None:
        sock.send(bad_challenges.previous)
    bad_challenges.previous = data
    sock.send(data[:5] + (b"T" if data[5:6] == b"W" else b"W") + data[6:])
    return int(sock.send(data[:-1] + bytes([data[-1] ^ 1])) == len(data))


def tablet_fixture(version, direction):
    local, simulated_tablet, _ = peers(version)
    frequencies = iter(mhz for mhz in bands for _ in range(2))
    bad_challenges.previous = None
    send = bad_challenges if direction == "tablet-loss" else udp.send_probe
    with patch.object(udp, "send_probe", send):
        device = "lo" if sys.platform.startswith("linux") else None
        udp.peer_loop(lan, local, simulated_tablet, 0, len(bands), lambda: next(frequencies), lambda: "REACHABLE",
                      sys.stdin.buffer, sys.stdout.buffer, device=device, same_host=version == 6)


def run(version, direction, index):
    local, peer, network = peers(version)
    worker = subprocess.Popen([sys.executable, "-B", __file__, "--peer", str(version), direction],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    bad_challenges.previous = None
    send = bad_challenges if direction == "host-loss" else udp.send_probe
    try:
        out = io.StringIO()
        neighbor = udp.windows_neighbor if sys.platform == "win32" else (
            lambda peer, _: udp.linux_neighbor(peer, Path("/sys/class/net/lo")))
        with patch.object(udp, "send_probe", send), contextlib.redirect_stdout(out):
            report = udp.host_loop(lan, local, index, network, len(bands), worker.stdout, worker.stdin,
                                   same_host=True, neighbor=neighbor)
        assert worker.wait(timeout=3) == 0
    finally:
        if worker.poll() is None:
            worker.kill()
        worker.wait()
    segments = report["segments"]
    assert [s["mhz"] for s in segments] == [2437, 5220, 2437]
    assert [s["rounds"] for s in segments] == [2, 2, 2]
    assert sum(s["windows_sent"] for s in segments) == len(bands) - 2
    assert sum(s["tablet_sent"] for s in segments) == len(bands)
    w = sum(s["windows_received"] for s in segments)
    t = sum(s["tablet_received"] for s in segments)
    assert w == (0 if direction == "tablet-loss" else len(bands))
    assert t == (0 if direction == "host-loss" else len(bands) - 2)
    assert segments[0]["tablet_only_rounds"] == 2
    assert segments[0]["tablet_only_received"] == (0 if direction == "tablet-loss" else 2)
    assert all(sum(s["windows_neighbor"].values()) == s["rounds"] for s in segments)
    assert all("UNKNOWN" not in s["windows_neighbor"] for s in segments)
    assert str(local) not in out.getvalue() and str(peer) not in out.getvalue()
    print(f"UDP_LOOPBACK ip_version={version} mode={direction} windows_received={w} tablet_received={t} "
          "synthetic_band_segments=3 native_peer_neighbor=1 private_endpoint_output=0")


def wrong_endpoint():
    local, _, network = peers(4)
    ready = io.BytesIO((json.dumps(["192.0.2.44", 32001, "00" * 32]) + "\n").encode())
    sink = io.BytesIO()
    try:
        udp.host_loop(lan, local, 1, network, 6, ready, sink, same_host=True)
    except udp.ProbeError:
        assert not sink.getvalue()
    else:
        raise AssertionError("Off-link endpoint accepted")


def scoped_wlan_prefix(address, index):
    assert sys.platform == "win32"
    scoped = ipaddress.IPv6Address(address)
    assert scoped.is_link_local and scoped.scope_id == str(index)
    local = ipaddress.IPv6Address(scoped.packed)
    assert local in udp.windows_subnet(local, index)
    try:
        udp.windows_subnet(local, 0)
    except udp.ProbeError:
        pass
    else:
        raise AssertionError("Unassigned interface accepted")
    print("WINDOWS_WLAN_IPV6 scoped_source_validated=1 wrong_ifindex_refused=1 datagrams_sent=0")


if __name__ == "__main__":
    if sys.argv[1] == "--peer":
        tablet_fixture(int(sys.argv[2]), sys.argv[3])
    elif sys.argv[1] == "--check-wlan-prefix":
        scoped_wlan_prefix(sys.argv[2], int(sys.argv[3]))
    else:
        assert ctypes.sizeof(udp.NeighborRow) == 88 and udp.NeighborRow.state.offset == 76
        wrong_endpoint()
        run(int(sys.argv[1]), sys.argv[2], int(sys.argv[3]))
