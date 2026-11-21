# Offline Thunar update

The archive holds the original Debian ARM64 Thunar package, the Y700 version and one updater. The source patch and its native Debian build recipe are in `source/` inside the archive. Keep the extracted directory available for rollback. The intended starting point is Debian `thunar` and `thunar-data` at `4.20.2-1+deb13u1`. The update changes the file manager executable. Other installed packages may differ from the development image.

```sh
sha256sum -c thunar-touch-y7001.tar.sha256
tar -xf thunar-touch-y7001.tar
cd thunar-update
sha256sum -c SHA256SUMS
sudo bash update-thunar-touch.sh install
sudo bash update-thunar-touch.sh check
```

`check` reports which of the two supported builds is installed and checks the program and its compatibility symlink. After closing existing Thunar processes, the next process loads the updated executable. The updater leaves the active desktop and personal settings alone. To go back, run `sudo bash update-thunar-touch.sh rollback` in the same directory. To repair the currently installed revision, use `reinstall`. An interrupted transaction can be resumed with `install` or reversed with `rollback`.

The updater holds the normal package-manager frontend lock while checking versions and running dpkg. It rejects a different Thunar revision or mismatched thunar-data. Debian's subsequent `+deb13u2` sorts after the local `+deb13u1+y7001`, so an ordinary later Debian security update can supersede the repair. Neither package contains conffiles. Their desktop data, Debian maintainer scripts and symlink targets are identical.

## Reproduce the archive and lifecycle check

```sh
bash scripts/package-thunar-touch-update.sh "$DEBS" "$OUT/thunar-touch-y7001.tar"
uv run --offline --no-project --python /usr/bin/python3 python tests/thunar-touch-update/compare.py \
  "$DEBS/thunar_4.20.2-1+deb13u1_arm64.deb" "$DEBS/thunar_4.20.2-1+deb13u1+y7001_arm64.deb"
sudo bash tests/thunar-touch-update/check.sh "$SEALED_DEV12_13_ROOT" "$OUT/thunar-touch-y7001.tar"
```

The PC test runs genuine ARM64 dpkg through binfmt in a private, network-isolated mount namespace. The sealed ext4 image is read-only with journal loading disabled. All package operations and QA settings go into a temporary overlay. Tests cover a busy apt/dpkg frontend lock, corrupted archives, repeated install/check/rollback without dpkg writes, an altered program repaired by explicit reinstall, interruption after unpack in both directions, and rejection of a later security revision. The 1,241 installed package tuples are checked after upgrade and rollback. User and system file-manager XML are compared byte for byte. [Touch interaction tests](../thunar-touch/)
