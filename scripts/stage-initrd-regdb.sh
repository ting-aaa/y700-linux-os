#!/usr/bin/env bash
# Both pinned board kernels use the upstream cfg80211 signing keys.
set -euo pipefail
source_dir=${1:?integrated Debian root}/usr/lib/firmware
destination=${2:?initramfs firmware directory}
test -d "$destination"

# File digests from wireless-regdb in config/debian-base.lock.json. The Debian
# and upstream data match in this release, but the detached signatures differ.
(
    cd "$source_dir"
    sha256sum --quiet -c <<'HASHES'
2fb33ca0074db573e05ef7dd50bb45b63c0ff98b7e852e1105ebad536fae8e6b  regulatory.db-upstream
c941c08f51c93e46722293b85631604c3740d86c3de0c75f79aef50d2e919179  regulatory.db.p7s-upstream
HASHES
)
for file in regulatory.db regulatory.db.p7s; do
    install -m644 "$source_dir/$file-upstream" "$destination/$file"
done
