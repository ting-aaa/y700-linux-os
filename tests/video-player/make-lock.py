"""Resolve the optional Debian player against the sealed dpkg status and authenticate all archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("status", "lists", "keyring", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    verifier = runpy.run_path(str(repo / "scripts/verify-debian-metadata.py"))
    records = verifier["paragraphs"](args.status)
    base = sorted((p["Package"], p["Version"], p["Architecture"]) for p in records
                  if p.get("Status") == "install ok installed")
    rows = "".join("\t".join(row) + "\n" for row in base).encode()
    base_sha = hashlib.sha256(rows).hexdigest()
    expected = json.loads((repo / "config/power-desktop-debian-auth.lock.json").read_text())
    if (base_sha != "a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84"
            or verifier["sha256"](args.keyring) != expected["keyring_sha256"]):
        raise ValueError("Expected the sealed dev12.8 package set and pinned Debian keyring")
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        (work / "sources.list").write_text("deb [arch=arm64] https://deb.debian.org/debian trixie main\n")
        (work / "empty").mkdir()
        options = {"APT::Architecture": "arm64", "APT::Architectures": "arm64",
                   "Dir::State::status": args.status.resolve(), "Dir::State::lists": args.lists.resolve(),
                   "Dir::Etc::sourcelist": work / "sources.list", "Dir::Etc::sourceparts": work / "empty",
                   "Dir::Etc::preferences": "/dev/null", "Dir::Etc::preferencesparts": work / "empty",
                   "Dir::Cache::pkgcache": "", "Dir::Cache::srcpkgcache": ""}
        cmd = ["apt-get", "-s", "--no-install-recommends", "--no-remove"]
        for key, value in options.items():
            cmd.extend(["-o", f"{key}={value}"])
        result = subprocess.check_output(cmd + ["install", "parole", "gstreamer1.0-plugins-bad"],
                                         env={**os.environ, "LC_ALL": "C"}, text=True)
    if not re.search(r"^0 upgraded, 116 newly installed, 0 to remove", result, re.M):
        raise ValueError("Unexpected APT transaction: " + result)
    additions = re.findall(r"^Inst ([^ ]+) \(([^ ]+) .*?\[([^]]+)\]\)$", result, re.M)
    if len(set(additions)) != 116 or set(additions) & set(base):
        raise ValueError("Unexpected package selection")
    audit = dict(conflicting=[], installed_count=116, packages=[],
                 missing=[dict(package=p, version=v, architecture=a) for p, v, a in additions])
    lock = verifier["verify"](audit, args.lists, args.keyring)
    if lock["metadata"] != expected["metadata"] or lock["unmatched"] or lock["authenticated_count"] != 116:
        raise ValueError("Expected all packages in the pinned Debian trixie signed index")
    result_rows = "".join("\t".join(row) + "\n" for row in sorted(base + additions)).encode()
    lock["base_package_sha256"] = base_sha
    lock["result_package_sha256"] = hashlib.sha256(result_rows).hexdigest()
    with args.output.open("x") as stream:
        json.dump(lock, stream, indent=2)
        stream.write("\n")
    print(f"Authenticated {len(additions)} additions against {len(base)} baseline packages.")


if __name__ == "__main__":
    main()
