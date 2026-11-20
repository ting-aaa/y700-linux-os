"""Allow e2fsck's low-deletion-time repair only for unused tombstones in the sealed parent."""

import re
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree


def problem_inodes(report, fixed):
    items = ElementTree.parse(report).getroot().findall("problem")
    if not items or any(p.get("code") not in ("0x010036", "0x010037") for p in items):
        raise ValueError("Unexpected ext4 problem class")
    if any(p.get("answer") != str(int(fixed)) or (p.get("fixed") == "1") != fixed for p in items):
        raise ValueError("Unexpected ext4 repair disposition")
    return {int(p.attrib["ino"]) for p in items if p.attrib["code"] == "0x010036"}


def deletion_time(image, inode):
    def debug(command):
        return subprocess.check_output(
            ["debugfs", "-R", f"{command} <{inode}>", image], text=True, stderr=subprocess.DEVNULL
        )

    if debug("testi").strip() != f"Inode {inode} is not in use":
        raise ValueError(f"Inode {inode} is allocated")
    info = debug("stat")
    if not re.search(r"^Links: 0\s+Blockcount: 0$", info, re.MULTILINE):
        raise ValueError(f"Inode {inode} still has links or blocks")
    timestamp = re.search(r"^ dtime: 0x([0-9a-f]+)", info, re.MULTILINE)
    if not timestamp:
        raise ValueError(f"Inode {inode} has no deletion time")
    return int(timestamp[1], 16)


if __name__ == "__main__":
    source, target, before, *after = map(Path, sys.argv[1:])
    inodes = problem_inodes(before, False)
    if after and problem_inodes(after[0], True) != inodes:
        raise ValueError("Repaired inode set differs from the read-only diagnosis")
    if not inodes:
        raise ValueError("Empty deletion-time diagnosis")
    for ino in inodes:
        original_time = deletion_time(source, ino)
        if not 0 < original_time < 86400:
            raise ValueError(f"Original inode {ino} was not deleted on the epoch date")
        observed = deletion_time(target, ino)
        if (after and observed < 86400) or (not after and observed != original_time):
            raise ValueError(f"Unexpected deletion time on copied inode {ino}")
    print(f"epoch_deleted_unallocated_inodes={len(inodes)}")
