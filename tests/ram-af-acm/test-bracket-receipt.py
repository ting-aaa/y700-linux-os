"""Exercise the numeric filter and the acknowledgement for a four-exposure bracket."""
from contextlib import redirect_stdout
from hashlib import sha256
from io import StringIO

import bracket_receipt as protocol
import host


def capture(fn, *args):
    with redirect_stdout(StringIO()) as out:
        rc = fn(*args)
    return rc, out.getvalue().splitlines()


_, virtual = capture(protocol.synthetic)
cleanup = "AF_CLEANUP mode=--rear-bracket rear=suspended sensor_active_ms_delta=4500 exit=0"
physical = [*virtual[:-1], cleanup, protocol.signal.ALLOC]
assert protocol.complete(physical, False) and protocol.complete(virtual, True)
assert not protocol.complete(physical, True) and not protocol.complete(virtual, False)
assert capture(protocol.filter_output, ["private driver output", *physical], False) == (0, physical)
for i, change in [(0, ("target_gain=1", "target_gain=2")), (10, ("time_us=32000", "time_us=2000")),
                  (19, ("8.0000", "1.0000")), (19, ("sequence=22", "sequence=15")),
                  (28, ("sequence=29", "sequence=8")), (4, ("site=Gb", "site=R")),
                  (37, ("suspended", "active"))]:
    bad = physical.copy()
    bad[i] = bad[i].replace(*change)
    assert bad != physical and not protocol.complete(bad, False)
    rc, rows = capture(protocol.filter_output, bad, False)
    assert rc == 1 and len(rows) == 1 and protocol.is_failure(rows[0])
for bad in [physical[1:], physical[:-1], [*physical, physical[-1]],
            [*physical, "SIGNAL_IMAGE private"], [*physical[:18], *physical[27:]]]:
    rc, rows = capture(protocol.filter_output, bad, False)
    assert rc == 1 and len(rows) == 1 and protocol.is_failure(rows[0])
failed = capture(protocol.filter_output, [*physical[:9], "AF_ERROR reason=bracket_applied_timeout",
                                          cleanup[:-1] + "1", protocol.signal.ALLOC], False)
assert failed == (1, ["BRACKET_FAILURE code=6 complete_pairs=1 rear_suspended=1 allocator_clean=1"])


class Wire:
    def __init__(self, rows):
        self.rows = iter(rows)
        self.sent = []

    def line(self):
        return next(self.rows)

    def send(self, row):
        self.sent.append(row)


token = "3" * 32
for rows, rc in [(physical, 0), (failed[1], 1)]:
    end = f"AF1 END rc={rc}"
    channel = Wire([f"AF1 RUNNING {token} virtual=0", *rows, end, "AF1 RETURN acknowledged=1"])
    with redirect_stdout(StringIO()):
        assert host.result(channel, token, False, True, acknowledge=True, bracket=True) == rc
    digest = sha256(("\n".join([*rows, end]) + "\n").encode()).hexdigest()
    assert channel.sent == [f"BRACKET {token}", f"ACK {token} {digest}"]
for rows in [physical[:-1], virtual, failed[1], [*physical, "private output"]]:
    channel = Wire([*rows, "AF1 END rc=0"])
    try:
        with redirect_stdout(StringIO()):
            host.result(channel, token, False, False, acknowledge=True, bracket=True)
    except RuntimeError:
        pass
    else:
        raise AssertionError("unexpected acknowledgement")
    assert channel.sent == [f"RESULT {token}"]
print("BRACKET_RECEIPT steps=4 applied_values=1 increasing_sequence=1 privacy=1 cleanup=1 failure_reason=1 ack=1")
