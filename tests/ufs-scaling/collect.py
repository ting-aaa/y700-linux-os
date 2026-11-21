"""Collect one numeric receipt from the PRC UFS observer and acknowledge it after saving."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import socket
import stat
import sys
import tempfile
import time
from contextlib import closing


BEGIN = b"UFS1 BEGIN"
RETURN = b"UFS1 RETURN"
MAX_LINE = 384
MAX_RECEIPT = 4096
DEADLINE = 160


class InvalidReceipt(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidReceipt(message)


def numbers(line, label, count):
    fields = line.split(b" ")
    require(fields[:2] == [b"UFS1", label] and len(fields) == count + 2, "Invalid receipt fields")
    require(all(re.fullmatch(rb"-1|0|[1-9][0-9]{0,18}", item) for item in fields[2:]),
            "Noncanonical numeric field")
    values = list(map(int, fields[2:]))
    require(all(n < 2**63 for n in values), "Integer out of range")
    return values


def validate(lines, variant, virtual):
    require(4 <= len(lines) <= 8 and lines[0] == BEGIN, "Incomplete receipt")
    v, vm, guard, identity, reads, error = numbers(lines[1], b"META", 6)
    require((v, vm) == (variant, virtual), "Receipt environment mismatch")
    require(guard in (0, 1) and identity in (0, 1) and 0 <= reads <= 2 and 0 <= error <= 7,
            "Invalid guard, identity, read count or result")
    lower, upper, supported_low, supported_high = numbers(lines[2], b"RANGE", 4)
    for low, high in ((lower, upper), (supported_low, supported_high)):
        require(low < 0 or high < 0 or low <= high, "Invalid frequency range")
    phases = lines[3:-1]
    require(guard >= identity and (not reads or (identity and len(phases) >= 2 * reads)),
            "Read count is inconsistent with the guards and completed phases")
    if error == 0:
        require((guard, identity, reads, len(phases)) == (1, 1, 2, 4), "Incomplete successful read")
    initial_counters = None
    for i, phase in enumerate(phases):
        fields = numbers(phase, b"PHASE", 14)
        index, runtime, link = fields[:3]
        require(index == i and -1 <= runtime <= 4 and -1 <= link <= 4, "Invalid phase or power state")
        if index in (0, 2):
            require(fields[-1] == -1, "Unexpected latency in idle phase")
        elif error == 0:
            require(fields[-1] >= 0, "Missing direct-read timing")
        if index == 0:
            initial_counters = fields[9:13]
        elif index == 3 and error == 0:
            require(initial_counters == fields[9:13], "Error counters changed during a reported success")
    digest = hashlib.sha256(b"".join(line + b"\n" for line in lines[1:-1])).hexdigest().encode()
    require(lines[-1] == b"UFS1 END " + digest, "Receipt digest mismatch")
    return digest, error


def saved_bytes(path):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    require(stat.S_ISREG(metadata.st_mode) and 0 < metadata.st_size <= MAX_RECEIPT,
            "Existing receipt path is not a bounded regular file")
    with path.open("rb") as stream:
        data = stream.read(MAX_RECEIPT + 1)
    require(len(data) == metadata.st_size, "Existing receipt changed while reading")
    return data


def publish(path, data):
    # The unique sibling is fsynced before linking. An interrupted write never
    # exposes a partial final file, and concurrent collectors cannot overwrite it.
    f = tempfile.NamedTemporaryFile(dir=path.parent, prefix=".ufs-receipt-", delete=False)
    temp = Path(f.name)
    try:
        with f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.link(temp, path)
        except FileExistsError:
            pass
        require(saved_bytes(path) == data, "Stored receipt differs from this run")
        if os.name == "posix":
            handle = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(handle)
            finally:
                os.close(handle)
    finally:
        temp.unlink(missing_ok=True)


class Channel:
    def __init__(self, device, is_socket):
        self.device = device
        self.is_socket = is_socket
        self.buffer = bytearray()

    def close(self):
        self.device.close()

    def send(self, command):
        line = command + b"\n"
        if self.is_socket:
            self.device.sendall(line)
        elif self.device.write(line) != len(line):
            raise ConnectionError("Short USB write")

    def line(self, until):
        while time.monotonic() < until:
            pos = self.buffer.find(b"\n")
            if pos >= 0:
                require(pos <= MAX_LINE, "Oversized protocol line")
                value = bytes(self.buffer[:pos]).removesuffix(b"\r")
                del self.buffer[:pos + 1]
                return value
            require(len(self.buffer) <= MAX_LINE, "Unterminated protocol line")
            if self.is_socket:
                try:
                    data = self.device.recv(512)
                except socket.timeout:
                    continue
                if not data:
                    raise ConnectionError("VM observer disconnected")
            else:
                data = self.device.read(max(1, min(512, self.device.in_waiting)))
            self.buffer.extend(data)
        raise TimeoutError("Observer response timeout")


def connect(port, vm_socket):
    if vm_socket is not None:
        sock = socket.socket(socket.AF_UNIX)
        try:
            sock.settimeout(0.3)
            sock.connect(vm_socket)
        except BaseException:
            sock.close()
            raise
        return Channel(sock, True)
    import serial
    from serial.tools import list_ports

    match = [p for p in list_ports.comports() if p.device == port]
    if not match:
        raise ConnectionError("Waiting for the named USB observer")
    require(len(match) == 1 and (match[0].vid, match[0].pid, match[0].serial_number)
            == (0x18D1, 0x4E11, "Y700_UFS_OBSERVER"), "Named USB port has a different identity")
    return Channel(serial.Serial(port, 115200, timeout=0.3, write_timeout=1), False)


def hello(channel, expected, deadline):
    # Discard a bounded interrupted response while waiting for a fresh STATUS.
    channel.send(b"UFS1 STATUS")
    for _ in range(16):
        line = channel.line(min(deadline, time.monotonic() + 2))
        if line.startswith(b"UFS1 READY "):
            require(line == expected, "Observer variant or transport mismatch")
            return
    raise InvalidReceipt("No valid observer handshake")


def collect(opener, variant, virtual, path, *, resume=False, deadline=None):
    deadline = time.monotonic() + DEADLINE if deadline is None else deadline
    expected = f"UFS1 READY {variant} {virtual}".encode()
    existing = saved_bytes(path)
    if existing is not None:
        require(existing.endswith(b"\n") and b"\r" not in existing, "Invalid stored framing")
        validate(existing[:-1].split(b"\n"), variant, virtual)
    replay = existing is not None or resume
    saved = existing is not None
    while time.monotonic() < deadline:
        try:
            with closing(opener()) as channel:
                hello(channel, expected, deadline)
                command = "RESULT" if replay else "READ"
                # Even a failed send may have reached PID 1. Never start another
                # measurement when the same port is opened again.
                replay = True
                channel.send(f"UFS1 {command} {variant}".encode())
                line = channel.line(min(deadline, time.monotonic() + 40))
                if line == expected:
                    raise ConnectionError("Awaiting cached receipt")
                require(line == BEGIN, "Missing receipt header")
                lines = [line]
                while len(lines) < 8:
                    line = channel.line(min(deadline, time.monotonic() + 4))
                    lines.append(line)
                    if line.startswith(b"UFS1 END "):
                        break
                digest, error = validate(lines, variant, virtual)
                data = b"".join(line + b"\n" for line in lines)
                # Repeat the durability check even when resuming a prior file.
                # A storage exception is terminal and prevents the ACK.
                try:
                    publish(path, data)
                except OSError as exc:
                    raise InvalidReceipt("Could not persist receipt") from exc
                saved = True
                channel.send(b"UFS1 ACK " + digest)
                require(channel.line(min(deadline, time.monotonic() + 4)) == RETURN,
                        "Return was not acknowledged")
                return error
        except OSError:
            time.sleep(min(0.3, max(0, deadline - time.monotonic())))
    state = "Receipt saved, return not confirmed" if saved else "No verified receipt"
    raise TimeoutError(state + " before the observer deadline")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    link = cli.add_mutually_exclusive_group(required=True)
    link.add_argument("--port", help="Exact serial port for the identified USB observer")
    link.add_argument("--vm-socket", help="QEMU UNIX socket for org.y700.ufs")
    cli.add_argument("--variant", type=int, choices=(0, 1), required=True, help="0 stock, 1 candidate")
    cli.add_argument("--output", required=True, type=Path, help="Receipt path in an existing directory")
    cli.add_argument("--resume", action="store_true", help="Only fetch an already started measurement")
    args = cli.parse_args()
    if not args.output.parent.is_dir():
        cli.error("Receipt directory does not exist")
    try:
        error = collect(lambda: connect(args.port, args.vm_socket), args.variant,
                        int(args.vm_socket is not None), args.output, resume=args.resume)
    except (OSError, InvalidReceipt) as exc:
        cli.exit(2, f"{exc}\n")
    print(f"UFS_HOST receipt_saved=1 return_acknowledged=1 observer_error={error}", flush=True)
    return int(error != 0)


if __name__ == "__main__":
    sys.exit(main())
