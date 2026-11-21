"""Measure verified TCP payloads over the tablet's associated WLAN, controlled over USB."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import time


MIB = 1024 * 1024
BLOCK = 64 * 1024
ROUNDS = 3
CHALLENGE = 4096
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


def frequency(interface, *, between_associations=False):
    if shutil.which("iw"):
        link = subprocess.check_output(["iw", "dev", interface.name, "link"], text=True)
        match = re.search(r"^\s*freq:\s*(\d+)(?:\.0+)?(?:\s|$)", link, re.MULTILINE)
    elif shutil.which("nmcli"):
        cells = subprocess.check_output(["nmcli", "-t", "-f", "IN-USE,FREQ", "device", "wifi",
                                         "list", "ifname", interface.name, "--rescan", "no"],
                                        text=True, env={**os.environ, "LC_ALL": "C"})
        match = re.search(r"^\*:(\d+) MHz$", cells, re.MULTILINE)
    else:
        return None
    if not match and between_associations:
        return None
    if not match:
        raise RuntimeError("No associated WLAN frequency")
    return int(match.group(1))


def socket_address(ip, port, scope):
    if ip.version == 4:
        return str(ip), port
    return str(ip), port, 0, scope


def reply_to_challenges(stream, interface):
    count = 0
    bands = []
    next_sample = 0
    while True:
        tag = read_exact(stream, 1)
        if tag == b"Z":
            return count, bands
        if tag != b"P" or read_exact(stream, 8) != count.to_bytes(8, "big"):
            raise ValueError("Out-of-order continuity probe")
        request = read_exact(stream, CHALLENGE)
        mhz = 0
        if time.monotonic() >= next_sample:
            mhz = frequency(interface, between_associations=True) or 0
            next_sample = time.monotonic() + 1
        response = os.urandom(CHALLENGE) + mhz.to_bytes(2, "big")
        stream.sendall(response + hashlib.sha256(request + response).digest())
        count += 1
        if mhz and (not bands or bands[-1]["MHz"] != mhz):
            bands.append({"MHz": mhz, "reply": count})


def run_challenges(stream, seconds):
    started = last = time.monotonic()
    count = 0
    longest = 0.0
    over_one = over_fifteen = 0
    bands = []
    while time.monotonic() - started < seconds:
        request = os.urandom(CHALLENGE)
        try:
            stream.sendall(b"P" + count.to_bytes(8, "big") + request)
            reply = read_exact(stream, CHALLENGE + 2 + 32)
        except (EOFError, OSError):
            print(json.dumps({"result": "incomplete", "verified_replies": count,
                              "bands_at_verified_replies": bands,
                              "since_last_reply_s": round(time.monotonic() - last, 3)}), flush=True)
            raise
        if reply[-32:] != hashlib.sha256(request + reply[:-32]).digest():
            raise ValueError("Continuity challenge digest mismatch")
        now = time.monotonic()
        gap = now - last
        longest = max(longest, gap)
        over_one += gap > 1
        over_fifteen += gap > 15
        last = now
        count += 1
        mhz = int.from_bytes(reply[CHALLENGE:CHALLENGE + 2], "big")
        if mhz and (not bands or bands[-1]["MHz"] != mhz):
            bands.append({"MHz": mhz, "reply": count})
            print(f"WIFI_STREAM_BAND reply={count} mhz={mhz}", flush=True)
        if count == 1 or count % 25 == 0:
            print(f"WIFI_STREAM elapsed_s={now-started:.3f} replies={count} longest_gap_s={longest:.3f}", flush=True)
        time.sleep(.15)
    stream.sendall(b"Z")
    return {"verified_replies": count, "bands_at_verified_replies": bands,
            "payload_bytes_each_way": count * CHALLENGE,
            "longest_reply_gap_s": round(longest, 3), "gaps_over_1s": over_one,
            "gaps_over_15s": over_fifteen, "elapsed_s": round(last - started, 3)}


def tablet(peer, size, stream_seconds):
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
        stream.settimeout(60 if stream_seconds else 15)
        if ipaddress.ip_address(endpoint[0]) != peer or (link_local and endpoint[3] != scope):
            raise ValueError("Unexpected client endpoint")
        if not secrets.compare_digest(read_exact(stream, 32), token):
            raise ValueError("Client address or session token mismatch")
        before = counters(interface)
        frequencies = [frequency(interface)]
        received = []
        if stream_seconds:
            replies, bands = reply_to_challenges(stream, interface)
            frequencies.append(frequency(interface))
            minimum = replies * CHALLENGE
        else:
            for _ in range(ROUNDS):
                received.append(receive_payload(stream, size))
                send_payload(stream, size)
                frequencies.append(frequency(interface))
            minimum = ROUNDS * size
        after = counters(interface)
    deltas = {name: after[name] - before[name] for name in COUNTERS}
    if min(deltas["rx_bytes"], deltas["tx_bytes"]) < minimum:
        raise ValueError("Wireless byte counters do not cover the completed transfers")
    report = {"driver": driver, "ip_version": peer.version, "link_local": link_local,
              "frequency_samples_MHz": frequencies, "wireless_delta": deltas}
    report.update({"tablet_replies": replies, "bands_at_verified_replies": bands}
                  if stream_seconds else {"tablet_rx_Mbps": received})
    print(json.dumps(report))


def host(peer, size_mib, control, tablet_uv, stream_seconds, windows_ifindex, require_both_bands):
    # A link-local scope identifies an interface on this host only.
    scope = int(peer.scope_id) if peer.version == 6 and peer.scope_id else 0
    peer = ipaddress.ip_address(peer.packed)
    remote = (f"runuser -u nobody -- env HOME=/tmp {shlex.quote(tablet_uv)} run --no-config --no-cache --offline "
              f"--no-project --python /usr/bin/python3 python -B - --tablet {peer} --mib {size_mib} "
              f"--stream-seconds {stream_seconds}")
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
                if windows_ifindex:
                    # WinSock UNICAST_IF (31) uses network byte order for IPv4 and host order for IPv6.
                    ipv4 = peer.version == 4
                    level = socket.IPPROTO_IP if ipv4 else socket.IPPROTO_IPV6
                    index = windows_ifindex.to_bytes(4, "big" if ipv4 else sys.byteorder)
                    stream.setsockopt(level, 31, index)
                stream.bind(socket_address(peer, 0, scope))
                stream.connect(socket_address(target, port, scope))
                stream.sendall(bytes.fromhex(token))
                if stream_seconds:
                    stream.settimeout(60)
                    continuity = run_challenges(stream, stream_seconds)
                else:
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
    if stream_seconds:
        if (report["tablet_replies"] != continuity["verified_replies"] or
                report["bands_at_verified_replies"] != continuity["bands_at_verified_replies"]):
            raise ValueError("Endpoints disagree on challenge count or frequency samples")
        report.update(continuity, connections=1)
        sampled = [b["MHz"] for b in continuity["bands_at_verified_replies"]]
        report["verified_2ghz_and_5ghz"] = (any(2400 <= mhz < 2500 for mhz in sampled)
                                           and any(4900 <= mhz < 5925 for mhz in sampled))
    else:
        report.update(tablet_tx_Mbps=received, MiB_per_transfer=size_mib, verified_transfers=2 * ROUNDS)
    print(json.dumps(report, sort_keys=True))
    if require_both_bands and not report["verified_2ghz_and_5ghz"]:
        raise SystemExit("The stream did not verify replies on both 2.4 GHz and 5 GHz")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    location = parser.add_mutually_exclusive_group(required=True)
    location.add_argument("--host", type=ipaddress.ip_address,
                          help="Host's on-link WLAN IP address (include %%ifindex for link-local IPv6)")
    location.add_argument("--tablet", type=ipaddress.ip_address, help=argparse.SUPPRESS)
    parser.add_argument("--mib", type=int, choices=(1, 8, 16, 32), default=16)
    parser.add_argument("--tablet-uv", default="uv", help="uv executable on the tablet, optionally staged in tmpfs")
    parser.add_argument("--stream-seconds", type=int, default=0,
                        help="Continuously verify one bidirectional TCP connection for up to 180 seconds")
    parser.add_argument("--windows-ifindex", type=int,
                        help="Use this Windows WLAN interface for outgoing test packets")
    parser.add_argument("--require-both-bands", action="store_true",
                        help="Require verified stream replies at both 2.4 GHz and 5 GHz")
    parser.add_argument("--control", nargs=argparse.REMAINDER, help="Host-key-checked USB SSH wrapper command")
    args = parser.parse_args()
    if not 0 <= args.stream_seconds <= 180:
        parser.error("--stream-seconds must be between 0 and 180")
    if args.require_both_bands and not (args.host and args.stream_seconds):
        parser.error("--require-both-bands requires a host continuity test")
    if args.windows_ifindex is not None and (sys.platform != "win32" or not args.host
                                              or not 0 < args.windows_ifindex <= 0xffffffff):
        parser.error("--windows-ifindex requires a Windows host and a positive interface index")
    address = args.tablet or args.host
    if address.is_multicast or address.is_unspecified or address.is_loopback:
        parser.error("A unicast WLAN address is required")
    if address.version == 6:
        zone = address.scope_id
        if args.host and address.is_link_local:
            if not zone or not zone.isascii() or not zone.isdecimal() or not 0 < int(zone) <= 0xffffffff:
                parser.error("Link-local --host requires a numeric WLAN interface index after %")
            if args.windows_ifindex is not None and int(zone) != args.windows_ifindex:
                parser.error("The link-local scope must match --windows-ifindex")
        elif zone is not None:
            parser.error("Only a link-local --host can include a zone")
    if args.tablet:
        tablet(args.tablet, args.mib * MIB, args.stream_seconds)
    elif args.control:
        host(args.host, args.mib, args.control, args.tablet_uv, args.stream_seconds, args.windows_ifindex,
             args.require_both_bands)
    else:
        parser.error("--host requires --control")
