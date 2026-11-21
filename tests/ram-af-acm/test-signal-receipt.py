"""Check the signal allowlist, failed-run acknowledgements and legacy host behavior."""

from contextlib import redirect_stdout
from hashlib import sha256
from io import StringIO
from unittest.mock import patch

import host
import signal_receipt as receipt


def output(function, *args):
    stream = StringIO()
    with redirect_stdout(stream):
        rc = function(*args)
    return rc, stream.getvalue().splitlines()


_, virtual = output(receipt.synthetic)
physical = virtual[:-1] + ["AF_CLEANUP mode=--rear-signal rear=suspended sensor_active_ms_delta=923 exit=0", receipt.ALLOC]
assert receipt.complete(virtual, True) and receipt.complete(physical, False)
assert not receipt.complete(virtual, False) and not receipt.complete(physical, True)
noise = ["WARNING raw row: 10 20 30", "/private/path", "AF_DIAG untrusted=DROP", "WARN " + "x" * 700]
assert output(receipt.filter_output, noise + physical, False) == (0, physical)
for bad in [
    physical[:-1], physical[1:], [*physical[:3], *physical[2:]], [*physical[:5], *physical[6:]],
    [physical[0].replace("1784", "0"), *physical[1:]],
    [physical[0], physical[1].replace("803.0000", "1024.0000"), *physical[2:]],
    [*physical[:6], physical[6].replace("near_white=0.0000", "near_white=1.9000"), *physical[7:]],
    [*physical, "SIGNAL_IMAGE bytes=0123456789"], [*physical, "SIGNAL_RAW " + "x" * 241],
    [*physical[:-2], "AF_CLEANUP mode=--rear-signal rear=active sensor_active_ms_delta=923 exit=0", receipt.ALLOC],
]:
    assert output(receipt.filter_output, bad, False) == (1, [receipt.FAIL])


class Wire:
    def __init__(self, rows):
        self.rows = iter(rows)
        self.sent = []

    def line(self):
        return next(self.rows)

    def send(self, row):
        self.sent.append(row)


token = "7" * 32
for rows, rc in [(physical, 0), ([receipt.FAIL], 1)]:
    end = f"AF1 END rc={rc}"
    wire = Wire([f"AF1 RUNNING {token} virtual=0", *rows, end, "AF1 RETURN acknowledged=1"])
    with redirect_stdout(StringIO()):
        assert host.result(wire, token, False, True, acknowledge=True, signal=True) == rc
    digest = sha256(("\n".join([*rows, end]) + "\n").encode("ascii")).hexdigest()
    assert wire.sent == [f"SIGNAL {token}", f"ACK {token} {digest}"]
for rows in [physical[:-1], [receipt.FAIL], virtual, ["raw=1,2,3"]]:
    wire = Wire([*rows, "AF1 END rc=0"])
    try:
        with redirect_stdout(StringIO()):
            host.result(wire, token, False, False, acknowledge=True, signal=True)
    except RuntimeError:
        pass
    else:
        raise AssertionError("host accepted incomplete, virtual or private receipt")
    assert wire.sent == [f"RESULT {token}"]
with patch.object(host.time, "monotonic", side_effect=[0, 101]):
    wire = Wire([])
    try:
        host.result(wire, token, False, False, acknowledge=True, signal=True)
    except TimeoutError:
        pass
    else:
        raise AssertionError("host accepted a timed out result")
    assert wire.sent == [f"RESULT {token}"]
print("SIGNAL_RECEIPT physical=1 synthetic=1 privacy=1 missing_cleanup_refused=1 incomplete_ack_refused=1 timeout=1")
