"""Summarize one real PackageKit method, its flags and matching Finished result."""
from pathlib import Path
import re
import sys


def successful(member):
    lines = Path("/run/updater-transactions.log").read_text(errors="replace").splitlines()
    calls, finished = {}, {}
    for i, header in enumerate(lines):
        path = re.search(r"\bpath=([^; ]+)", header)
        if not path:
            continue
        path = path[1]
        if header.startswith("method call ") and header.endswith("member=" + member):
            value = lines[i+1].strip() if i + 1 < len(lines) else ""
            calls[path] = value
        if header.startswith("signal ") and header.endswith("member=Finished"):
            if i + 1 < len(lines):
                finished[path] = lines[i+1].strip()
    for path, flags in calls.items():
        if finished.get(path) != "uint32 1":
            continue
        if member == "RefreshCache" and flags == "boolean true":
            return True
        if member == "UpdatePackages" and flags.startswith("uint64 "):
            value = int(flags.split()[1])
            if value & 2 and not value & (4 | 8):  # ONLY_TRUSTED, actual install
                return True
    return False


if __name__ == "__main__":
    print(int(successful(sys.argv[1])))
