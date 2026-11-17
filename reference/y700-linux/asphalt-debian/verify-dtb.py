"""Compare the compiled DTB with this tablet's captured runtime memory map."""
import json
import subprocess
import sys
from pathlib import Path

dtb = Path(sys.argv[1])
evidence = Path(__file__).resolve().parent.parent / "vendor-build-20261025/runtime-fdt-memory-semantics-v1"
def fdt(*args):
    return subprocess.check_output(["fdtget", *args[:2], dtb, *args[2:]], text=True).split()

def cells(path, key):
    return [int(word, 16) for word in fdt("-t", "x", path, key)]

expected = json.loads((evidence / "memory.json").read_text())["nodes"][0]["reg"]["ranges"]
assert cells("/memory", "reg") == [x for r in expected for x in r["address_cells_raw"] + r["size_cells_raw"]]
assert fdt("-t", "s", "/", "region_country") == ["PRC"]
assert cells("/", "qcom,msm-id") == [531, 65536]
assert cells("/", "qcom,board-id") == [65544, 0]
nodes = subprocess.check_output(["fdtget", "-l", dtb, "/reserved-memory"], text=True).split()
intervals = []
for name in nodes:
    full = "/reserved-memory/" + name
    props = subprocess.check_output(["fdtget", "-p", dtb, full], text=True).split()
    if "reg" not in props or ("status" in props and fdt("-t", "s", full, "status") not in (["ok"], ["okay"])):
        continue
    data = cells(full, "reg")
    for i in range(0, len(data), 4):
        hi, lo, shi, slo = data[i:i+4]
        start = hi << 32 | lo
        intervals.append((start, start + (shi << 32 | slo)))
stock = json.loads((evidence / "reserved-memory-compact.json").read_text())["rows"]
count = 0
for row in stock:
    for region in row["fixed_reg"] or []:
        start, end = int(region["address_hex"], 16), int(region["end_exclusive_hex"], 16)
        assert any(a <= start and end <= b for a,b in intervals), (row["path"], hex(start), hex(end))
        count += 1
print(f"Verified PRC identifiers, {len(expected)} RAM banks, {count} fixed reservation ranges.")
