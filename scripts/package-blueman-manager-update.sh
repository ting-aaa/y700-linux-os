#!/bin/bash
# Write the checked updater, manifest and both native packages to an offline TAR.
set -euo pipefail
export LC_ALL=C
umask 022
[[ $# == 2 ]] || { echo 'Usage: package-blueman-manager-update.sh DEBS ARCHIVE.tar' >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
debs=$(realpath -e "$1")
output=$(realpath -m "$2")
[[ -d $debs && -d ${output%/*} && ! -L $2 ]]
work=$(mktemp -d "${output%/*}/.blueman-bundle.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
cd "$work"
mkdir blueman-update
cd blueman-update
install -m755 "$repo/scripts/update-blueman-manager.sh" .
install -m644 "$repo/config/blueman-manager-update.lock.json" .
"${UV_BIN:-uv}" run --offline --no-project --python "${BUILD_PYTHON:-/usr/bin/python3}" python - "$debs" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys

lock = json.loads(Path("blueman-manager-update.lock.json").read_text())
for item in [*lock["packages"], lock["rollback"]]:
    name = f'{item["package"]}_{item["version"]}_{item["architecture"]}.deb'
    source = Path(sys.argv[1], name)
    if source.is_symlink() or not source.is_file():
        raise SystemExit(f"Missing package: {name}")
    target = Path(name)
    shutil.copyfile(source, target)
    with target.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if target.stat().st_size != item["size"] or digest != item["sha256"]:
        raise SystemExit(f"Unexpected package: {name}")
PY
sha256sum -- *.deb *.json *.sh > SHA256SUMS
cd ..
# DrvFS and ext4 can present different mode bits for exactly the same source.
options=(--format=ustar --mtime=@1795219200 --owner=0 --group=0 --numeric-owner)
tar "${options[@]}" --no-recursion --mode=0755 -cf bundle.tar blueman-update
tar "${options[@]}" --mode=0644 -rf bundle.tar blueman-update/SHA256SUMS blueman-update/*.json blueman-update/*.deb
tar "${options[@]}" --mode=0755 -rf bundle.tar blueman-update/*.sh
if [[ -e $output ]]; then cmp -- bundle.tar "$output"; else ln -- bundle.tar "$output"; fi
(cd "${output%/*}" && sha256sum -- "${output##*/}") >bundle.sha256
[[ ! -L $output.sha256 ]]
if [[ -e $output.sha256 ]]; then cmp -- bundle.sha256 "$output.sha256"; else ln -- bundle.sha256 "$output.sha256"; fi
cat bundle.sha256
