"""Build a reproducible offline Parole add-on from the authenticated Debian archives."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import tarfile
import tempfile
from urllib.error import URLError


def add(archive, name, stream, size, mode=0o644):
    info = tarfile.TarInfo("y700-video-player/" + name)
    info.size, info.mode = size, mode
    archive.addfile(info, stream)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("cache", type=Path)
    cli.add_argument("output", type=Path)
    cli.add_argument("--fetch", action="store_true", help="fetch missing archives from Debian or its dated snapshot")
    args = cli.parse_args()
    here = Path(__file__).resolve().parent
    lock_bytes = (here / "debian.lock.json").read_bytes()
    lock = json.loads(lock_bytes)
    if args.fetch:
        args.cache.mkdir(parents=True, exist_ok=True)
        fetch = runpy.run_path(str(here.parents[1] / "scripts/fetch-debian-inputs.py"))["fetch"]

        def acquire(package):
            try:
                return fetch(package, args.cache)
            except (URLError, TimeoutError):
                snapshot = "https://snapshot.debian.org/archive/debian/20260913T000000Z/"
                return fetch({**package, "uri": snapshot + package["repository_path"]}, args.cache)

        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(acquire, lock["packages"]))
    with tempfile.NamedTemporaryFile(dir=args.output.parent) as scratch:
        with gzip.GzipFile(filename="", mode="wb", fileobj=scratch, compresslevel=1, mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w|") as archive:
                sums = []
                packages = []
                for p in lock["packages"]:
                    sha = p["sha256"]
                    name = "packages/" + Path(p["repository_path"]).name
                    with (args.cache / (sha + ".deb")).open("rb") as source:
                        if hashlib.file_digest(source, "sha256").hexdigest() != sha or os.fstat(source.fileno()).st_size != p["size"]:
                            raise ValueError("Archive differs from signed index: " + p["package"])
                        source.seek(0)
                        add(archive, name, source, p["size"])
                    sums.append(f"{sha}  {name}\n")
                    packages.append("\t".join(p[k] for k in ("package", "version", "architecture")) + "\n")
                files = {"SHA256SUMS": "".join(sums).encode(), "additions.tsv": "".join(packages).encode(),
                         "debian.lock.json": lock_bytes, "install.sh": (here / "install.sh").read_bytes()}
                for name, data in files.items():
                    add(archive, name, io.BytesIO(data), len(data), 0o755 if name == "install.sh" else 0o644)
        scratch.flush()
        os.fchmod(scratch.fileno(), 0o644)
        os.link(scratch.name, args.output)
    print(f"Bundled {len(packages)} official Debian packages in {args.output}")


if __name__ == "__main__":
    main()
