# Authenticated Debian inputs and fresh package-base builder

The project now has an exact **962-package historical base lock** and a separately authenticated **30-package desktop repair lock**. These describe package inputs, not a bit-identical filesystem image, current security update coverage or board support.

## Provenance recovered and checked

The historical base's dpkg database contained 962 installed name/version/architecture tuples. The retained archives matched 957; apt, debian-archive-keyring, libapt-pkg7.0, login and sqv were missing. Their exact archives were retrieved from canonical Debian HTTPS repositories and verified against authenticated index hashes.

Retained public repository metadata from an earlier failed build made independent revalidation possible:

1. `gpgv` verified the original InRelease signatures against a separately installed Debian archive keyring (host package `2025.1ubuntu1`).
2. Every used uncompressed Packages index matched the signed Release SHA-256 and size.
3. All 962 requested package versions matched authenticated index entries, including each cached archive's length/hash. All 30 repair archives were also revalidated against their original signed indexes.

`config/debian-base.lock.json` and `config/desktop-repair-auth.lock.json` record repository/index hashes, dates, canonical archive URLs, versions, architectures, lengths and SHA-256. Keyring hash: `506b815cbb32d9b6066b4a2aa524071e071761e7e7f68c3ac74f3061ba852017`. The original acquisition filename list remains in `desktop-repair.lock.json`; renaming a byte-identical archive is allowed, while extra/missing packages or content changes are rejected.

**Freshness boundary:** base updates/security InRelease validity ended on 2026-10-30. Signatures remain useful for reproducing this historical snapshot, but do not make it a current secure release. A release candidate must refresh the snapshot and repeat acceptance with its exact versions. Runtime APT sources use normal signed Debian repositories; no globally disabled freshness/signature checks are installed.

## Rebuild on a Linux host

Prerequisites: mmdebstrap, dpkg tools, uv, root privileges and functioning ARM64 QEMU/binfmt support. A new root directory and repository directory are required. Build outputs and archives stay outside Git. Python always runs through uv.

```sh
uv run --python 3.13 --no-project python scripts/fetch-debian-inputs.py \
  --lock config/debian-base.lock.json --cache downloads/debian-base
uv run --python 3.13 --no-project python scripts/fetch-debian-inputs.py \
  --lock config/desktop-repair-auth.lock.json --cache downloads/desktop-repair

sudo /path/to/uv run --python 3.13 --no-project python scripts/build-debian-base.py \
  --lock config/debian-base.lock.json --cache downloads/debian-base \
  --repository /build/package-repository --root /build/fresh-base
sudo bash scripts/configure-debian-base.sh /build/fresh-base
bash scripts/build-platform.sh
sudo env UV_BIN=/path/to/uv bash scripts/integrate-rootfs.sh \
  /build/fresh-base downloads/desktop-repair out/packages/y700-platform_0.1.0~dev2_all.deb
sudo env UV_BIN=/path/to/uv bash tests/arm64-rootfs.sh /build/fresh-base
```

The downloader publishes an archive atomically only after checking length/hash, revalidates cached files, and refuses a mismatched existing file. Tested network retrieval covered the five missing base packages and all 30 repair packages; all 962 base artifacts were additionally revalidated in the independent local pool. Future availability of every canonical URL is not guaranteed: use a reviewed historical Debian mirror/snapshot while retaining the exact content hashes if an archive is retired. Do not silently choose another version.

The builder creates a local repository exclusively from verified locked archives, then uses mmdebstrap with exact versions. Its `trusted=yes` applies only to this generated local repository; it is not used for a remote source. An empty suite is necessary for this flat repository, and the `copy:` transport puts archives into the chroot cache. These details fixed two observed failed builds (no essential packages selected, then inaccessible file-mirror archives). The builder checks the resulting installed package tuples against the entire lock before writing a success marker and restores normal authenticated runtime APT sources.

The configuration stage adds a locked local account, locales, default services and the existing console password setup. It deliberately does not claim touch-only graphical enrollment. It clears the base machine ID; later SSH package installation and test activity still require final identity/log cleanup before distribution.

## Verified fresh build, 2026-11-18

The third clean build completed with mmdebstrap `1.5.7-3` in 864.6645 seconds under ARM64 QEMU user emulation. Its complete installed set matched all **962 locked package/version/architecture tuples** before configuration. No historical root filesystem was copied. Configuration then completed, and all 30 repair packages plus `y700-platform 0.1.0~dev2` installed successfully, producing 993 installed packages.

The fresh integrated root passed an empty dpkg audit, APT dependency checks, ARM64 SSH configuration/effective-policy checks, persistent host-key generation, systemd unit validation and an Onboard settings round-trip. Temporary maintenance credentials were removed. Runtime APT sources contain normal signed Debian HTTPS repositories, and the clock seed was not in the future. This establishes a fresh package-base build and userspace integration only; no board boot or graphical session was exercised.

## Revalidate original metadata

With matching public apt list files and a separately trusted keyring available locally:

```sh
uv run --python 3.13 --no-project python scripts/audit-debian-inputs.py \
  --root /build/source-base --cache /build/archive-cache --output /build/audit.json
uv run --python 3.13 --no-project python scripts/verify-debian-metadata.py \
  --audit /build/audit.json --lists /build/original-apt-lists \
  --keyring /usr/share/keyrings/debian-archive-keyring.gpg --output /build/authenticated.json
uv run --python 3.13 --no-project python tests/debian-metadata.py \
  --audit /build/audit.json --lists /build/original-apt-lists \
  --keyring /usr/share/keyrings/debian-archive-keyring.gpg
```

The audit returns nonzero and lists missing/conflicting archives. The signature verifier never invents missing evidence or equates a downloaded hash with authenticity. Negative tests changed a real signed Release and a real Packages index; both were rejected. Public CI checks source and small policy/package tests, not this large original-metadata integration test or a full base rebuild.

Remaining stages: pinned kernel/toolchain/DT/initramfs, provenance-reviewed board firmware, touch-only enrollment, per-install identity finalization, filesystem/EFI assembly, update/rollback/recovery and attended hardware acceptance. Neither the historical root nor the fresh package base is a stable image release.
