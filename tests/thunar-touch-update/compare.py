"""Compare both native Debian archives, including symlinks and file permissions."""
import hashlib
import io
import re
import subprocess
import sys
import tarfile


def members(option, archive):
    data = subprocess.check_output(["dpkg-deb", option, archive])
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as tar:
        files = {}
        for info in tar:
            path = info.name
            if path in files:
                raise ValueError(f"duplicate archive member {path}")
            content = tar.extractfile(info).read() if info.isfile() else None
            files[path] = (info.type, info.mode, info.uid, info.gid, info.linkname, content)
        return files


def different(old, new):
    if old.keys() != new.keys():
        raise ValueError("archive paths changed")
    for path in old:
        if old[path][:-1] != new[path][:-1]:
            raise ValueError(f"file metadata changed: {path}")
    return {path for path in old if old[path][-1] != new[path][-1]}


def main():
    old, new = sys.argv[1:]
    stock, candidate = (members("--fsys-tarfile", archive) for archive in (old, new))
    binary = "./usr/bin/thunar"
    if different(stock, candidate) != {binary}:
        raise ValueError("expected one different executable")
    if stock["./usr/bin/Thunar"][4] != "thunar":
        raise ValueError("unexpected compatibility symlink")
    old_metadata, new_metadata = (members("--ctrl-tarfile", archive) for archive in (old, new))
    if different(old_metadata, new_metadata) != {"./control", "./md5sums"}:
        raise ValueError("unexpected control file change")

    old_binary, new_binary = stock[binary][-1], candidate[binary][-1]
    control = old_metadata["./control"][-1]
    version = b"Version: 4.20.2-1+deb13u1\n"
    expected = control.replace(version, version[:-1] + b"+y7001\n", 1)
    size = re.search(rb"^Installed-Size: (\d+)$", expected, re.MULTILINE)
    old_kib, new_kib = (int((len(data) + 1023) // 1024) for data in (old_binary, new_binary))
    expected = expected.replace(size[0], b"Installed-Size: %d" % (int(size[1]) + new_kib - old_kib), 1)
    if expected != new_metadata["./control"][-1]:
        raise ValueError("control file differs outside Version and calculated Installed-Size")

    old_sum = hashlib.md5(old_binary).hexdigest().encode() + b"  usr/bin/thunar\n"
    new_sum = hashlib.md5(new_binary).hexdigest().encode() + b"  usr/bin/thunar\n"
    if old_metadata["./md5sums"][-1].replace(old_sum, new_sum, 1) != new_metadata["./md5sums"][-1]:
        raise ValueError("unexpected changes to Debian's md5sums")
    print(f"THUNAR_PAIR_OK changed_payloads=1 payload_names={len(stock)} changed_paths=/usr/bin/thunar "
          f"conffiles={int('./conffiles' in old_metadata)} new_binary_sha256={hashlib.sha256(new_binary).hexdigest()}")


if __name__ == "__main__":
    main()
