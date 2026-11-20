"""Compare the Linux control points with the unmodified CN350 framework resources."""
import argparse
import ast
from hashlib import file_digest
from pathlib import Path
import re
import subprocess


def array(dump, name):
    match = re.search(r"(?m)^\s*resource 0x[0-9a-f]+ array/" + re.escape(name)
                      + r"\n\s+\(\) \(array\) size=(\d+)\s+\[([\d,\s]+)\]", dump)
    if not match:
        raise ValueError(f"Missing default integer array {name}")
    values = [int(value.strip()) for value in match[2].split(",")]
    if len(values) != int(match[1]):
        raise ValueError(f"Incomplete array {name}")
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("aapt2")
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()
    with args.apk.open("rb") as apk:
        digest = file_digest(apk, "sha256").hexdigest()
    if digest != "7bbc28d55706334ec4487d5f5ad90ccc45aab37de35a3864b8194024f20e4416":
        raise SystemExit("Expected the CN350 framework-res.apk")
    dump = subprocess.check_output([args.aapt2, "dump", "resources", args.apk], encoding="utf-8")
    lux = [0, *array(dump, "config_autoBrightnessLevels")]
    targets = array(dump, "config_autoBrightnessDisplayValuesNits")
    request = dict(zip(array(dump, "config_screenBrightnessNits"),
                       array(dump, "config_screenBrightnessBacklight"), strict=True))
    curve = tuple((l, request[nits]) for l, nits in zip(lux, targets, strict=True))
    daemon = Path(__file__).resolve().parents[2] / "packaging/root/usr/libexec/y700-ambient-backlight"
    actual, = (ast.literal_eval(stmt.value) for stmt in ast.parse(daemon.read_text()).body
               if isinstance(stmt, ast.Assign) and isinstance(stmt.targets[0], ast.Name)
               and stmt.targets[0].id == "CURVE")
    if curve != actual:
        raise SystemExit(f"Factory {curve} differs from packaged policy {actual}")
    print(f"CN350 verification passed for {len(curve)} lux/backlight points: {curve}")


if __name__ == "__main__":
    main()
