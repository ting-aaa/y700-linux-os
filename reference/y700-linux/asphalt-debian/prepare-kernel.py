"""Apply the pinned Asphalt queue and derive the local PRC board configuration."""
import json
import re
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
repo = here.parent / "asphalt-upstream"
kernel = repo / "pkgs/linux-kernel"
board = kernel / "sm8475/asphalt"
source = Path(sys.argv[1]).resolve()
assert subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip() == "8dcb481fc2ce91794fd294630e06f15a52ec7513"
recipe = (kernel / "default.nix").read_text()
common = recipe.split("commonPatches = [", 1)[1].split("];", 1)[0]
family = recipe.split("qualcomm = [", 1)[1].split("];", 1)[0]
patches = [kernel / p for p in re.findall(r"\S+\.patch", common + family)]
patches.extend(board / p for p in re.findall(r"\S+\.patch", (board / "series.nix").read_text()))
for patch in patches:
    with patch.open("rb") as f:
        subprocess.run(["patch", "--fuzz=0", "--batch", "-p1"], cwd=source, stdin=f, check=True)
print(f"Applied {len(patches)} upstream patches.")

dts = source / "arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dts"
memory = here.parent / "vendor-build-20261025/runtime-fdt-memory-semantics-v1/memory.json"
ranges = json.loads(memory.read_text())["nodes"][0]["reg"]["ranges"]
banks = ", ".join("<" + " ".join(hex(n) for n in r["address_cells_raw"] + r["size_cells_raw"]) + ">" for r in ranges)
original = dts.read_text()
anchor = 'region_country = "ROW";'
assert original.count(anchor) == 1 and len(ranges) == 5
dts.write_text(original.replace(anchor, 'region_country = "PRC";') + f'''
/ {{
    /delete-node/ memory@a0000000;
    memory {{
        device_type = "memory";
        reg = {banks};
    }};
}};
''')
settings = json.loads(subprocess.check_output(["nix-instantiate", "--eval", "--strict", "--json", here / "board-config.nix"]))
base = (board / "kernel.config").read_text().splitlines()
def keep(line):
    key = re.match(r"(?:# )?CONFIG_(\w+)(?:=| is not set)", line)
    return not key or key[1] not in settings
(source / ".config").write_text("\n".join([line for line in base if keep(line)] + [
    f"# CONFIG_{key} is not set" if val == "n" else f"CONFIG_{key}={val}" for key, val in settings.items()
]) + "\n")
