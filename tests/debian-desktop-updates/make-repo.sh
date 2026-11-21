#!/bin/bash
# Make one disposable, signed APT update for a disconnected guest.
set -euo pipefail
export LC_ALL=C
scratch=$1
payload=$2
pkg=y700-qa-updater
mkdir "$scratch/key"; chmod 700 "$scratch/key"
export GNUPGHOME=$scratch/key
trap 'gpgconf --kill gpg-agent 2>/dev/null || :' EXIT
repo=$payload/repo
dist=$repo/dists/trixie
index=main/binary-arm64/Packages
mkdir -p "$repo/pool" "$dist/main/binary-arm64" "$scratch/pkg/DEBIAN" "$scratch/pkg/usr/share/$pkg"
for ver in 1.0 2.0; do
    cat > "$scratch/pkg/DEBIAN/control" <<CTRL
Package: $pkg
Architecture: all
Version: $ver
Section: misc
Priority: optional
Maintainer: QA <qa@invalid.example>
Description: Y700 synthetic update marker
CTRL
    echo "$ver" > "$scratch/pkg/usr/share/$pkg/version"
    dpkg-deb --root-owner-group --build "$scratch/pkg" "$scratch/$pkg.deb" >/dev/null
    if [[ $ver == 1.0 ]]; then mv "$scratch/$pkg.deb" "$payload/baseline.deb"
    else mv "$scratch/$pkg.deb" "$repo/pool/$pkg.deb"; fi
done
file=pool/$pkg.deb
(
    cd "$repo"
    dpkg-deb -f "$file"
    echo "Filename: $file"
    echo "Size: $(stat -c %s "$file")"
    echo "SHA256: $(sha256sum "$file" | cut -d' ' -f1)"
    echo
) > "$dist/$index"
(
    cd "$dist"
    printf 'Origin: Y700QATest\nLabel: Y700QATest\nSuite: stable\nCodename: trixie\nDate: %s\nArchitectures: arm64\nComponents: main\nSHA256:\n %s %s %s\n' \
        "$(date -Ru)" "$(sha256sum "$index" | cut -d' ' -f1)" "$(stat -c %s "$index")" "$index"
) > "$dist/Release"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-generate-key 'Y700 disposable repository <qa@invalid.example>' rsa2048 sign 0
gpg --batch --quiet --export > "$payload/fixture-keyring.gpg"
gpg --batch --quiet --yes --clearsign -o "$dist/InRelease" "$dist/Release"
gpgv --keyring "$payload/fixture-keyring.gpg" "$dist/InRelease" >/dev/null
