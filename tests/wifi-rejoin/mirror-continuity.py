"""Verify repeated Debian downloads on a single TLS connection bound to the physical WLAN."""
import argparse
import hashlib
import http.client
import ipaddress
import json
from pathlib import Path
import re
import socket
import ssl
import subprocess
import time


HOST = "deb.debian.org"
RESOURCE = "/debian/pool/main/h/hello/hello_2.10-5_arm64.deb"
SIZE = 52660
DIGEST = "7a917c7f44fbd3373dff0f35a0b6bdf8ef564ff90579d8b130ff52fbf33fce1f"


def active_frequency(interface):
    lines = subprocess.check_output(["nmcli", "-t", "-f", "IN-USE,FREQ", "dev", "wifi", "list",
                                     "ifname", interface, "--rescan", "no"], text=True, timeout=4)
    match = re.search(r"^\*:(\d+) MHz$", lines, re.MULTILINE)
    return int(match[1]) if match else None


def run(family, seconds, require_roundtrip):
    endpoints = socket.getaddrinfo(HOST, 443, family, socket.SOCK_STREAM)
    address = endpoints[0][4]
    route, = json.loads(subprocess.check_output(["ip", "-j", "route", "get", address[0]]))
    interface = route["dev"]
    if not Path("/sys/class/net", interface, "phy80211").is_dir():
        raise RuntimeError("Debian mirror route does not use a wireless interface")
    source = route["prefsrc"]
    tls = ssl.create_default_context()
    changes = []
    count = 0
    longest_gap = 0
    with socket.socket(family, socket.SOCK_STREAM) as tcp:
        tcp.settimeout(15)
        tcp.bind((source, 0))
        tcp.connect(address)
        with tls.wrap_socket(tcp, server_hostname=HOST) as sock:
            if ipaddress.ip_address(sock.getsockname()[0]) != ipaddress.ip_address(source):
                raise RuntimeError("WLAN source mismatch")
            conn = http.client.HTTPConnection(HOST, port=443)
            conn.auto_open = False
            conn.sock = sock
            start = last = time.monotonic()
            while count == 0 or time.monotonic() - start < seconds:
                before = active_frequency(interface)
                conn.request("GET", RESOURCE, headers={"Accept-Encoding": "identity", "Connection": "keep-alive"})
                response = conn.getresponse()
                if response.status != 200 or response.getheader("Content-Length") != str(SIZE):
                    raise RuntimeError("Unexpected Debian response")
                body = response.read(SIZE + 1)
                if len(body) != SIZE or hashlib.sha256(body).hexdigest() != DIGEST:
                    raise RuntimeError("Debian response identity mismatch")
                if conn.sock is not sock:
                    raise RuntimeError("Peer ended the persistent connection")
                after = active_frequency(interface)
                now = time.monotonic()
                longest_gap = max(longest_gap, now - last)
                count += 1
                if after and before == after and (not changes or after != changes[-1]):
                    changes.append(after)
                    print(f"WLAN_HTTPS frequency_MHz={after} verified={count}", flush=True)
                last = now
                if not seconds or (require_roundtrip and len(changes) >= 3 and
                                   changes[0] == changes[-1] and any(4900 <= f < 5925 for f in changes)):
                    break
                time.sleep(1)
    steps = ["2.4" if 2400 <= f < 2500 else "5" if 4900 <= f < 5925 else "other" for f in changes]
    result = dict(ip_version=4 if family == socket.AF_INET else 6, downloads=count, payload_bytes=count * SIZE,
                  one_tls_socket=True, frequencies_MHz=changes, return_to_2ghz=steps == ["2.4", "5", "2.4"],
                  longest_gap_s=round(longest_gap, 3), elapsed_s=round(last-start, 3), sha256=DIGEST)
    print(json.dumps(result, sort_keys=True), flush=True)
    return not require_roundtrip or result["return_to_2ghz"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip-version", type=int, choices=[4, 6], required=True)
    parser.add_argument("--seconds", type=int, default=0)
    parser.add_argument("--require-roundtrip", action="store_true")
    args = parser.parse_args()
    if not 0 <= args.seconds <= 150:
        parser.error("seconds must be between 0 and 150")
    fam = socket.AF_INET if args.ip_version == 4 else socket.AF_INET6
    raise SystemExit(0 if run(fam, args.seconds, args.require_roundtrip) else 1)
