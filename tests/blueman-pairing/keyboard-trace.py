"""Reduce actual password-entry, SMP and HCI events without exposing a passkey."""
from collections import Counter
from pathlib import Path
import struct

folder = Path("/run/cold-bond")
methods = [line.split() for line in (folder / "agent-methods").read_text().splitlines()]
assert any(row[-3:] == ["/org/bluez/agent/blueman", "org.bluez.Agent1", "DisplayPasskey"] for row in methods)
assert sum(row[-3:] == ["/org/bluez/agent", "org.bluez.Agent1", "RequestPasskey"] for row in methods) == 1
assert not any(row[-1:] == ["RequestConfirmation"] for row in methods)
trace = memoryview((folder / "trace").read_bytes())
header = struct.Struct(">IIIIQ")
assert trace[:16] == struct.pack(">8sII", b"btsnoop\0", 1, 2001)
offset = 16
messages = Counter()
capabilities = {}
while offset < len(trace):
    length, saved, flags, drops, _ = header.unpack_from(trace, offset)
    offset += header.size
    assert length == saved and drops == 0 and offset + saved <= len(trace)
    data = trace[offset:offset + saved]
    offset += saved
    adapter, direction = divmod(flags, 0x10000)
    if adapter or direction not in (4, 5) or len(data) < 9 or data[6:8] != b"\x06\x00":
        continue
    command = data[8]
    messages[direction, command] += 1
    if command in (1, 2):
        assert data[11] & 0x08  # Secure Connections
        capabilities[command] = data[9]
assert capabilities == {1: 2, 2: 4}, "expected a KeyboardOnly initiator and KeyboardDisplay responder"
assert messages[5, 1] == messages[4, 2] == 1, "unexpected extra pairing"
for direction in (4, 5):
    assert messages[direction, 3] == messages[direction, 4] == 20, "incomplete passkey rounds"
    assert messages[direction, 13] == 1, "missing DHKey check"
decoded = (folder / "decoded").read_text()
assert "Authenticated key from P-256" in decoded and "Enabled with AES-CCM" in decoded
print("REAL_PASSKEY dispatch=DisplayPasskey+RequestPasskey paired_once=1 "
      "smp_rounds=20 keyboard_only=1 authenticated_p256=1 aes_ccm=1", flush=True)
