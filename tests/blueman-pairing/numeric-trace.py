"""Check the four HID notifications landed on the desktop's encrypted connection."""
from pathlib import Path
import struct
import sys

assert sys.argv[1:] in ([], ["--two-connections"])
connections = 2 if sys.argv[1:] else 1
trace = memoryview(Path("/run/cold-bond/trace").read_bytes())
assert trace[:16] == struct.pack(">8sII", b"btsnoop\0", 1, 2001)
record = struct.Struct(">IIIIQ")
offset = 16
encrypted = set()
reports = []
epochs = []
expected = [bytes([1]), bytes([0]), bytes([1, 7, 253, 1]), bytes(4)]
pdus = 0
while offset < len(trace):
    length, captured, flags, drops, _ = record.unpack_from(trace, offset)
    offset += record.size
    assert length == captured and not drops and offset + captured <= len(trace)
    data = trace[offset:offset + captured]
    offset += captured
    adapter, kind = divmod(flags, 0x10000)
    if adapter != 0:
        continue
    if kind == 3 and len(data) >= 6 and data[0] in (0x08, 0x05) and data[2] == 0:
        handle = int.from_bytes(data[3:5], "little")
        if data[0] == 0x08 and data[5]:
            encrypted.add(handle)
        else:
            encrypted.discard(handle)
            if reports:
                assert all(report[0] == handle for report in reports)
                epochs.append(reports)
                reports = []
    # ACL RX on the desktop, fixed ATT channel. BlueZ can batch several
    # {attribute handle, length, value} tuples in one notification (0x23).
    if kind != 5 or len(data) < 11 or data[6:8] != b"\x04\x00" or data[8] not in (0x1b, 0x23):
        continue
    handle = int.from_bytes(data[:2], "little") & 0x0fff
    tuples = []
    if data[8] == 0x1b:
        tuples.append((bytes(data[9:11]), bytes(data[11:])))
    else:
        pos = 9
        while pos < len(data):
            assert pos + 4 <= len(data)
            size = int.from_bytes(data[pos + 2:pos + 4], "little")
            assert pos + 4 + size <= len(data)
            tuples.append((bytes(data[pos:pos + 2]), bytes(data[pos + 4:pos + 4 + size])))
            pos += 4 + size
    matches = [(handle, attribute, value) for attribute, value in tuples if value in expected]
    if matches:
        assert handle in encrypted, "HID notification on an unencrypted link"
        reports.extend(matches)
        pdus += 1

if reports:
    epochs.append(reports)
assert len(epochs) == connections, "unexpected number of input-producing connections"
for reports in epochs:
    assert [r[2] for r in reports] == expected, "missing or extra HID reports on desktop ACL RX"
    assert len({r[0] for r in reports}) == 1
    assert reports[0][1] == reports[1][1] != reports[2][1] == reports[3][1]
if connections == 1:
    print(f"HCI_HOG_INPUT reports=4 att_pdus={pdus} handles=2 same_encrypted_connection=1", flush=True)
else:
    print(f"HCI_HOG_INPUT reports=8 att_pdus={pdus} handles_per_connection=2 encrypted_connections=2", flush=True)
