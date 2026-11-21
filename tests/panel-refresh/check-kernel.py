"""Check the built-in ARM64 mode table against the original linked kernel."""
from pathlib import Path
import re
import struct
import subprocess
import sys


def read_table(path):
    symbols = subprocess.check_output(["llvm-readelf", "-sW", path], text=True)
    records = [line.split() for line in symbols.splitlines() if line.endswith(" y700_modes")]
    assert len(records) == 1 and records[0][3:5] == ["OBJECT", "LOCAL"]
    _, address, size, _, _, _, index, _ = records[0]
    sections = subprocess.check_output(["llvm-readelf", "-SW", path], text=True)
    section = re.search(rf"^\s*\[\s*{index}\]\s+\.rodata\s+PROGBITS\s+([0-9a-f]+)\s+([0-9a-f]+)",
                        sections, re.MULTILINE | re.IGNORECASE)
    assert section
    base, offset = (int(value, 16) for value in section.groups())
    with path.open("rb") as binary:
        binary.seek(offset + int(address, 16) - base)
        return binary.read(int(size))


def check(original, candidate, image):
    first = read_table(original)
    table = read_table(candidate)
    assert len(first) == 120 and len(table) == 2 * len(first) and table[:len(first)] == first
    assert image.read_bytes().count(table) == 1, "linked modes absent or ambiguous in the EFI Image"
    for index, (rate, front) in enumerate(((120, 30), (60, 2880))):
        values = struct.unpack_from("<I10H", table, index * len(first))
        clock, width, hs, he, ht, skew, height, vs, ve, vt, scan = values
        assert (clock, width, hs, he, ht, skew) == (691524, 1600, 1874, 1914, 2022, 0)
        assert (height, vs - height, ve - vs, vt - ve, scan) == (2560, front, 4, 256, 0)
        assert clock * 1000 == rate * ht * vt
        print(f"PANEL_TIMING mode={rate}Hz table_index={index} vfp={front} total={ht}x{vt} clock={clock}kHz")
    assert table[24:len(first)] == table[len(first) + 24:]
    print("PANEL_MODE_TABLE original_first_unchanged=1 efi_contains_both=1")


if __name__ == "__main__":
    check(*(Path(arg) for arg in sys.argv[1:]))
