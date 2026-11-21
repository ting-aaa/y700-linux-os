"""Exercise the physical host's receipt calculation on an in-memory serial transcript."""
import hashlib

from host import check_config, result


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

config = ["AF_CONFIG_RESOURCE path=/dev/udmabuf stat_rc=0 char=1 open_rdwr_rc=0",
          "AF_CONFIG_ONLY result=pass allocated=0 started=0 queued=0 af_triggered=0 pixels_read=0",
          "AF_CLEANUP mode=--check-rear-config rear=suspended sensor_active_ms_delta=0 exit=0",
          "AF_ALLOCATOR cleanup=1 original_unchanged=1", "AF1 CONFIG_END rc=0"]
wire = SerialTranscript(config)
assert check_config(wire, token) == 0 and wire.commands == ["CONFIG " + token]
for missing in range(len(config) - 1):
    try:
        check_config(SerialTranscript(config[:missing] + config[missing + 1:]), token)
    except RuntimeError:
        pass
    else:
        raise AssertionError(f"Incomplete physical configuration receipt accepted at row {missing}")
failure = ["AF_ERROR reason=no_cpu_rgb_mode", "AF1 CONFIG_END rc=1"]
assert check_config(SerialTranscript(failure), token) == 1
print("RAM_AF_CONFIG_RECEIPT complete=1 omissions_refused=4 retained_failure=1")
