"""Copy the target udev and blockdev ELF dependencies from the sealed ARM64 root."""
from pathlib import Path
import re
import shutil
import subprocess
import sys

root, dest = map(Path, sys.argv[1:])
lib = Path("usr/lib/aarch64-linux-gnu")
pending = [Path("usr/bin/udevadm"), Path("usr/sbin/blockdev"), Path("lib/ld-linux-aarch64.so.1")]
seen = set()
while pending:
    path = pending.pop()
    if path in seen:
        continue
    seen.add(path)
    src, target = root / path, dest / path
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, target)
    dynamic = subprocess.check_output(["readelf", "-dW", src], text=True)
    for so in re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic):
        for folder in (lib, lib / "systemd"):
            if (root / folder / so).is_file():
                pending.append(folder / so)
                break
        else:
            raise RuntimeError(f"Unable to locate {so} from {path}")
