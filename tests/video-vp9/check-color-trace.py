"""Pass the exact synthetic stream and kernel-probed caps from the Parole trace to the ARM64 test."""
import argparse
from pathlib import Path
import subprocess
import tarfile


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("trace", type=Path)
    args.add_argument("runner", nargs=argparse.REMAINDER, help="native test or qemu-aarch64 -L SYSROOT TEST")
    opts = args.parse_args()
    if not opts.runner:
        args.error("a test executable is required")
    found = set()
    with tarfile.open(opts.trace, "r:gz") as archive:
        for item in archive.getmembers():
            if not item.isfile() or not Path(item.name).match("media-*.log"):
                continue
            lines = archive.extractfile(item).read().decode().splitlines()
            for factory, media in (("v4l2h264dec", "video/x-h264"), ("v4l2h265dec", "video/x-h265"),
                                   ("v4l2vp9dec", "video/x-vp9")):
                queue = f"<{factory}0:sink> probed caps: "
                probed = [line.split(queue, 1)[1] for line in lines if queue in line]
                if not probed:
                    continue
                pad = "Pad capsfilter0:src caps:"
                stream = next(line.split(pad, 1)[1] for line in lines if pad + media in line)
                subprocess.run([*opts.runner, factory, probed[-1], stream], check=True)
                found.add(factory)
    if found != {"v4l2h264dec", "v4l2h265dec", "v4l2vp9dec"}:
        raise SystemExit(f"incomplete decoder trace: {sorted(found)}")


if __name__ == "__main__":
    main()
