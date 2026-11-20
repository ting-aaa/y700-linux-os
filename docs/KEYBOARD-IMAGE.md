# Keyboard, camera and sensor update for the generic dev12.4 root

The offline ARM64 build upgrades four packages in the generic TB320FC_PRC Debian root. It retains the locked first-login account, empty machine ID and per-device Bluetooth and sensor provisioning. The package inventory contains 1,112 entries before and after. The build verifies the installed database against all current product locks and checks the Xfce keyboard-detection default as the ordinary desktop account. [Generic dev12.4 root](BOARD-IMAGE.md#dev124-native-xfce-volume-button-at-first-login) · [Onboard desktop tests](../tests/onboard-keyboard-presence/)

| Package | dev12.4 | Updated root |
| --- | --- | --- |
| `onboard` | `1.4.1-10` | `1.4.1-10+y7002` |
| `y700-platform` | `0.1.0~dev12.4` | `0.1.0~dev12.5` |
| `y700-camera-qcam` | `0.7.2-1~bpo13+1.y7002` | `0.7.2-1~bpo13+1.y7003` |
| `y700-ssc-runtime` | `0.1.1` | `0.1.3` |

The dev12.4 raw root SHA-256 is `9054df11e3a7d6cceacdfa6dffdb081c4a94428468ada09076c286c61ac17f30`. The updated inventory SHA-256 is `ae129edd690fcd72820e3c286c6010474a70cefea622d53f4fe88b53f94afb21`. Package configuration runs inside a Linux network namespace with service starts disabled. The local artifact and check files are in `out/onboard-image/`. An independent reconstruction used the copied QCOW2 and the sealed root, matched the raw checksum below and passed a read-only filesystem check. The candidate retains the parent’s boot artifacts. An attended boot and paired hardware input on this complete combination remain open. [Camera measurements](QCAM.md) · [Sensor service](SSC-SERVICE.md) · [Bluetooth radio measurements](BLUETOOTH-HID-RADIO.md)

| November 20 local artifact or check | Result |
| --- | --- |
| `keyboard-update.qcow2` | 57,147,392 bytes, SHA-256 `6169308d76225c507e699b2424a91557266a4d53b59ebe6a263b64fcdd80620a` |
| Reconstructed 6 GiB ext4 root | SHA-256 `ed41792877f6beac36248ae8a8314836400082d7ba22cdd55fa80085389e1410` |
| Inodes with historical deletion timestamps | 87, all unallocated in both the parent and child |
| Live tree before and after filesystem housekeeping | Identical SHA-256 `62a71ca74d9f9ae95df44523482697fbb62cc446eeb557279282ac98b8c0e189` |

## Reproduce the offline update

Use a Linux build filesystem with free space for a working 6 GiB raw image, ARM64 binfmt or a native ARM64 host, `uv`, `qemu-img`, `e2fsprogs`, GNU tar and root access for private loop mounts. Supply the unpacked generic dev12.4 `root.ext4` and the verified archive directories. The output directory must be new. [Offline integration runner](../tests/onboard-image/run.sh)

```sh
sudo env UV_BIN="$(command -v uv)" bash tests/onboard-image/run.sh \
  "$sealed_root" out/platform-dev12.5/y700-platform_0.1.0~dev12.5_all.deb \
  out/camera-qcam-y7003-offline out/ssc-device-0.1.3-offline out/onboard-offline \
  "$output"
```

The QCOW2 update names `root.ext4` in its own directory as its read-only backing data. From the output directory, verify the receipts and link the exact sealed root before reconstructing the new raw root. Extract to a new filename. The recorded filesystem digest covers this build, including its filesystem timestamps.

```sh
cd "$output"
sha256sum --strict -c SHA256SUMS
printf '%s  %s\n' "$(cat backing-root.sha256)" "$sealed_root" | sha256sum --strict -c -
ln -s -- "$(realpath -e -- "$sealed_root")" root.ext4
test ! -e updated.ext4 && test ! -L updated.ext4 &&
  qemu-img convert -f qcow2 -O raw keyboard-update.qcow2 updated.ext4
printf '%s  updated.ext4\n' "$(cat new-root.sha256)" | sha256sum --strict -c -
e2fsck -fn updated.ext4
```

## Filesystem verification at the current date

Earlier image builds deleted files within seconds of the Unix epoch. The corresponding inode numbers are free and retain those deletion timestamps in the sealed filesystem. Its recorded last mount and write were also in the first minute of 1970. Mounting a copy with a current clock made e2fsck 1.47.2 report old deletion times as possible orphan-list entries. A disposable mount and file-creation test reproduced this independently of dpkg. [e2fsck clock check](https://github.com/tytso/e2fsprogs/blob/v1.47.2/e2fsck/pass1.c#L1315-L1321) · [Deletion-time handling](https://github.com/tytso/e2fsprogs/blob/v1.47.2/e2fsck/pass1.c#L1392-L1418)

The build reads the e2fsck XML diagnosis and checks each affected inode in both images. Repair proceeds on the private child only when the original and copied inodes are unallocated, have zero links and data blocks, and carry identical epoch-date deletion timestamps. It enables preen for those two e2fsck problem codes, checks the resulting repair log, and compares the contents and metadata of the whole live tree before and after. A second read-only e2fsck runs with default settings. The build finally checks the QCOW2 structure, compares all reconstructed sectors with the staged filesystem, and verifies the original raw root hash. [Inode checks](../tests/onboard-image/check-deletions.py)

A further writable copy of the reconstructed update passed a current-clock mount, creation and removal of 3,072 files across 48 directories, unmount, and another default read-only filesystem check.
