# Repaired desktop integration milestone

This builds an experimental Debian integration package and applies it to a **disposable ARM64 root directory on a Linux build host**. It does not deploy to a tablet, produce a bootable release, or finalize credentials. Do not install this development package over the currently working tablet.

## Package build and checks

```sh
bash scripts/build-platform.sh
bash tests/platform-package.sh
uv run --python 3.13 --no-project python -m unittest discover -s tests -v
```

Requirements: Bash, GNU coreutils, findutils, dpkg-deb, xz and uv. The package is architecture-independent shell/configuration; its dependencies are resolved in the ARM64 candidate. Repeated builds with the same `SOURCE_DATE_EPOCH` are compared byte-for-byte. This only establishes determinism of this package on the tested builder.

The package includes X11 touch alignment, Onboard/Xfce defaults, the temporary Chromium/compositor workaround, a USB ACM/NCM service and a dedicated SSH service. No maintainer script starts or enables a service. `y700-onboard.desktop` has its own name to avoid replacing Debian's Onboard-owned autostart file. The session defaults are applied once per user; touch alignment still starts if settings initialization fails.

The USB descriptor class and function combination follow the repaired prototype. Serial and locally administered MAC addresses are generated separately per installation. Host recognition of those new identities is **not physically tested**. The current tablet continues using its existing tested maintenance service.

## Locked repair archives and offline integration

`config/desktop-repair.lock.json` records the 30 archives used by the deployed repair, including exact name, version, architecture, length and SHA-256. These were originally obtained from verified Debian repository metadata. Obtain matching versions from authenticated Debian repositories/archive services; the lock verifies bytes but does not replace signature verification. Do not silently substitute newer versions or treat the lock as the entire base distribution lock.

```sh
uv run --python 3.13 --no-project python scripts/repair-inputs.py verify /build/repair-debs config/desktop-repair.lock.json
# /build/candidate must be a new, private copy of the declared base rootfs.
touch /build/candidate/.y700-disposable-build-root
sudo env UV_BIN=/path/to/uv bash scripts/integrate-rootfs.sh \
  /build/candidate /build/repair-debs out/packages/y700-platform_0.1.0~dev1_all.deb
sudo env UV_BIN=/path/to/uv bash tests/arm64-rootfs.sh /build/candidate
```

The Linux host needs working ARM64 binfmt/QEMU user emulation, mount namespaces and root privileges. Set `UV_PYTHON` to an available uv-managed version (3.12 and 3.13 were used in development). Integration mounts proc and read-only sys in a private mount namespace; package service starts are denied. It audits dpkg/APT, disables the historical USB services, masks distribution SSH service/socket activation, and enables the dedicated product units offline. It records the installed package inventory inside the candidate. Existing Xfce compositing configuration is disabled before a candidate desktop can start.

The runtime check generates a temporary client key/overlay, runs ARM64 `sshd -t/-T`, validates the effective listener, allowed user and authentication policy, and confirms persistent per-install host-key generation. It removes its test credentials afterward. It does not start a listener or USB gadget. ARM64 gsettings round-trip and systemd unit parsing are also checked; QEMU user emulation does not test board boot or the kernel.

Timesyncd is enabled and its early-boot clock seed is advanced to the package build epoch if older; a newer seed is preserved. Actual clock accuracy still requires successful NTP. See the [verification receipt](VALIDATION-20261118.md) and [pending attended tests](ATTENDED-TESTS.md).

## Private installation identity

```sh
uv run --python 3.13 --no-project python scripts/provision-maintenance.py \
  --output /build/private-overlay --device-cidr 192.0.2.1/24 \
  --host-address 192.0.2.2 --user y700 --public-key /private/client.pub
```

The documentation addresses above are examples. Choose a dedicated USB subnet that does not conflict with host routes. Output must be new and stays private. Only an ED25519 **public** key is accepted. The intended user must already exist. SSH is key-only, denies root, restricts the host address and disables forwarding; it uses its own configuration instead of inheriting permissive distribution drop-ins. Its host key is generated at first service start and must be authenticated and pinned before connecting. Generating this overlay is not proof of a successful login or a recovery route.

## Remaining build/release gates

| Input or behavior | Current boundary |
| --- | --- |
| Debian base root | Existing local experimental base reused; full signed snapshot/package closure and root content lock still needed |
| Kernel/DT/initramfs | Historical pinned recipe; no new kernel/image rebuilt by this milestone |
| Board firmware | Local provenance retained; missing sensor firmware and redistribution review remain |
| Boot-success marking | Existing board lifecycle is not modified by this package; no new slot-success writer is introduced |
| First-boot UX | Historical console password setup remains; touch-only graphical enrollment/login is not implemented |
| Image identity finalization | Remove build host keys, machine ID, cached credentials and private logs; provision a new user/identity before any distribution |
| Saved rotation | Current left rotation was physically accepted; package follows chosen Xfce rotation and does not force a direction |
| Runtime | New login/cold boot, Onboard auto-show, newly provisioned USB identity and actual SSH authentication require attended tests |

In particular, the candidate directory still contains historical base state and build-generated files. It is private test material, **not a distributable image**. The old `reference/` image packager remains historical and must not be used to bypass these gates.
