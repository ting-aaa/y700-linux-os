"""Exercise the physical host's receipt calculation on an in-memory serial transcript."""
import hashlib

from host import result


class SerialTranscript:
    def __init__(self, rows):
        self.rows = iter(rows)
        self.commands = []

    def line(self):
        return next(self.rows)

    def send(self, line):
        self.commands.append(line)


token = "0" * 32
data = ["AF_RESULT verdict=inconclusive", "AF_CLEANUP mode=--rear-af rear=suspended exit=2",
        "AF1 END rc=2"]
digest = hashlib.sha256(("\n".join(data) + "\n").encode("ascii")).hexdigest()
wire = SerialTranscript([f"AF1 RUNNING {token} virtual=0", *data, "AF1 RETURN acknowledged=1"])
assert result(wire, token, False, True, acknowledge=True) == 2
assert wire.commands == ["START " + token, f"ACK {token} {digest}"]
print("RAM_AF_HOST_RECEIPT direct_start=1 nonzero_rc=2 complete_sha256=1")
