# Provenance and public-data boundary

## Fixed inputs

| Component | Source / identity |
| --- | --- |
| Asphalt recipes and board work | [dianqk/nixos-android-devices](https://github.com/dianqk/nixos-android-devices/tree/8dcb481fc2ce91794fd294630e06f15a52ec7513), commit `8dcb481fc2ce91794fd294630e06f15a52ec7513` |
| Experimental kernel base | Linux 7.3.4; source archive SHA-256 `b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f`; upstream recipe supplies the source reference |
| Bootloader base | U-Boot v2026.10 through the pinned Asphalt recipe; 22 patches in the earlier build |
| Kernel adaptation | 53 upstream patches in the earlier build; PRC identifiers and measured five-bank memory layout; local version `-asphalt-prc` |
| Userspace | Debian 13 ARM64, Xfce 4.20; physical repaired system reported Debian 13.7 |
| Audio topology source | linux-msm/audioreach-topology commit `993a17dcb672357998a463a73f120064d6c74f4f` |

These are source/build identities from local records. They do not mean the new public checkout has already produced an equivalent candidate. The upstream ROW device and the local PRC device are distinct validation contexts.

`docs/import-manifest.json` records hashes of allowlisted imported source files before and after public-path normalization. It lists repository-relative paths, not private host locations. `reference/` is a snapshot, not an upstream fork with its full history.

## Publication policy

Publish source, non-personal board facts, version pins, reduced failure signatures, reviewed patches and test procedures. Keep device-specific captures, user/app backups, Wi-Fi profiles, private/public access keys, unique host fingerprints, unique serials and raw system logs local. Raw firmware and stock images are not distributed here; describe lawful acquisition and verify licenses before future releases.

Git exclusions are defense in depth, not an audit. Inspect the exact staged tree, check large/binary files and secret patterns, and preserve third-party notices before pushing. A scanner's success is not proof of licensing or privacy completeness.
