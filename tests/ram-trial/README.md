# Diskless Y700 RAM boot

Use `RAM_TRIAL_VERSION=dev12.10` for the 1,240-package image with Parole `4.18.2-1+y7002`. The guest verifies its installed package inventory, the installed Parole package files, the current media receipts and the original dev12.9 receipt before it exercises first login and the temporary desktop. [dev12.10 image guide](../../docs/DEV12.10-IMAGE.md)

Use `RAM_TRIAL_VERSION=dev12.9` for the earlier 1,240-package release with Debian Parole. The guest compares its media receipt to the repository lock and hashes its installed package inventory. It also exercises the desktop and temporary upper layer described below. [dev12.9 artifacts and results](../../docs/DEV12.9-VERIFICATION.md)

Run on a Linux PC with an ARM64 QEMU system emulator, an AArch64 cross compiler, uv, `dtc` tooling and room to run a 9 GiB guest. Provide the sealed RAM trial directory and the same virtual board DT used by the combined EFI fixture.

```sh
bash tests/ram-trial/run.sh "$sealed_ram_trial" "$virt_dtb" "$new_log_dir"
```

The default verifies the 1,112-package dev12.5 desktop. Set `RAM_TRIAL_VERSION=dev12.6` for the sealed 1,115-package dev12.6 root, including in the EFI-first fixture below. The host and guest both check the inventory selected by the caller. The dev12.6 host check requires zero active swap at startup. [dev12.6 build and evidence](../../docs/DEV12.6-RAM-TRIAL.md)

Use `RAM_TRIAL_VERSION=dev12.8` for the 1,124-package root with Blueman y7002 and opt-in adaptive brightness. The observer checks the two package locks and zero active swap. After PAM login the ordinary user writes a canary under their home directory. The observer verifies its contents only exist on the tmpfs upper layer and leaves it there until power-off. A second independent run with the same bundle checks that the account is locked again and that the previous file is absent. [dev12.8 instructions](../../docs/DEV12.8-RAM-TRIAL.md)

The host verifies the input manifest and the exact candidate kernel before and after the run. It copies the virtual DT and adjusts only its RAM size, keeping the original 1024×768 simple-framebuffer at `0xbe000000`. QEMU directly boots the sealed kernel and its unchanged production initrd without disks or a NIC. After the production RAM init switches to systemd, a temporary unit accepts the small observer and touchscreen program over private virtio serial. All QA changes live inside this disposable guest.

The observer proves the overlay root uses the read-only ext4 inside the initrd's in-memory SquashFS carrier and confines writes to a tmpfs upper layer. It records the live initrd bounds, available RAM and the absence of disk-backed swap. The test uses Type-B contacts to reject a password mismatch, perform real first enrollment and log in through the rendered Arctica keyboard. It checks that the resulting ordinary LightDM PAM session owns the active local seat0 Xfce desktop and requests normal power-off. The synthetic password stays in the host process's memory and the guest's transient account state.

To test the handover from the tablet's baseline kernel on the PC, use the EFI-first fixture. It requires the AArch64 EDK II firmware from Ubuntu's `qemu-efi-aarch64` package version `2025.11-3ubuntu7.3` (the file hash is pinned by the wrapper). The emulated Cortex-A72 exposes GICv3 and ITS. The guest boots without a disk. Before switching, the fixture checks that all three kernel load segments avoid the interrupt controller's live tables. The run also checks the identity of each kernel, the device tree's kexec marker and the ordinary desktop session.

```sh
RAM_TRIAL_BASELINE_KERNEL="$baseline_kernel" bash tests/ram-handover/efi-first.sh \
    "$aavmf_code" "$sealed_ram_trial" "$virt_dtb" "$new_log_dir"
```

Tool overrides are `QEMU_SYSTEM_AARCH64`, `QEMU_DATA`, `AARCH64_CC` and `UV_BIN`. The fixture uses the virtual board; a successful result covers the diskless ARM64 kernel and Debian desktop path in QEMU.
## dev12.12 RAM desktop with onboard storage disabled

On a Linux build PC, start with the unmodified dev12.12 release's `images` directory and a new output path. The builder verifies the 6 GiB ext4 and 1 GiB EFI file, extracts the default dual-refresh kernel and firmware initrd, and derives the diagnostic PRC device tree from the release tree. It changes the UFS and microSD host statuses to `disabled` and verifies the rest of the canonical tree byte-for-byte. The final initrd includes a SquashFS carrier containing the intact ext4.

```bash
bash scripts/build-ram-trial.sh --dev12.12 "$images" "$ram_bundle"
(cd "$ram_bundle" && sha256sum --strict -c SHA256SUMS)
sudo bash tests/ram-trial/check-storage-guard.sh "$ram_bundle"
RAM_TRIAL_VERSION=dev12.12 bash tests/ram-trial/run.sh "$ram_bundle" "$virt_dtb" "$new_log_dir"
```

The ARM64 VM uses the exact release kernel and RAM initrd, a virtual device tree, no disks and no NIC. The guest checks the 1,240-package inventory, the running kernel notes, the absence of a boot mount and disk-backed swap, two read-only loops and a tmpfs upper layer. It exercises first enrollment, LightDM/PAM and an ordinary Xfce desktop. The storage guard test runs the packaged check in an isolated filesystem with simulated PRC device-tree statuses. Disabled controllers pass. A missing status, an enabled controller or an enumerated UFS/SD disk or partition triggers the power-off path.

On the physical PRC board the RAM init requires the supplied storage-disabled tree. If early setup fails, it requests power-off and then halt. Board-level RAM entry, USB recovery and camera operation require separate physical verification. An existing EFI system that boots a file-backed Debian root uses persistent storage. The Android recovery menu depends on the contents of its recovery partition. This build creates host files for a dedicated RAM boot.

The sealed `SHA256SUMS` digest is `2cdddecb410b4aa3d9b63b229fc8df5fc8de61b00ed3a209a34c633d82adb453`. The 1,363,224,164-byte initrd has SHA-256 `02d1b27418805d79a813763f9e3001e24768f4dd4360d55e37b93e7c152721b2` and the diagnostic board tree has SHA-256 `8ad76f844d20ebb57f7ebcaad91c61e0484f139a1e9fdfccec02ba198c02cf82`.

The sealed root installs the USB and SSH maintenance units. They require `/etc/y700/maintenance.env` and `/etc/y700/maintenance-sshd.conf`. These files, the enrolled public key, the SSH host key and a USB serial getty are absent from the fresh image. The VM witness communicates over a virtual serial port. A physical diagnostic boot needs a separate volatile reporting channel so the PC can verify the running kernel, device tree and RAM mounts before starting a hardware test. [Maintenance configuration generator](../../scripts/provision-maintenance.py)

### Receiving the sealed root over USB

The early initrd accepts the 1,351,581,696-byte SquashFS over a dedicated USB ACM endpoint after the bootloader starts Linux. Both the early receiver and the Debian RAM init check the PRC storage-disabled device tree. The receiver verifies the exact byte count and SHA-256 before it hands the file to the Debian RAM init. The optional camera attachment runs in the temporary root and reports numerical results over a second ACM endpoint.

```bash
bash scripts/build-ram-receiver.sh "$images" "$ram_bundle" "$new_receiver_dir" "$af_addon" "$af_addon_sha256"
bash tests/ram-trial/check-receiver.sh "$new_receiver_dir" "$receiver_manifest_sha256" "$new_log_dir"
```

The VM exercises both stages with the real release kernel and sealed root. Its sensor input is synthetic. On the running PRC tablet, the existing maintenance ACM carried this same SquashFS into tmpfs in **93.578 seconds** on the Windows host. The tablet checked SHA-256 `ce527192a32b47eff9a5f41682e058db88f8ef4bb9421afc737655783fb0229a` before cleanup. Physical enumeration by the early initrd and actual lens movement are separate checks.

The November 21 return-enabled diagnostic bundle has a 13,802,084-byte initrd and manifest SHA-256 `0e52f171ce43862488272c8bc8bc2f610792ad46a678c153c03e32d3dcfd4f61`. Its attachment SHA-256 is `f5b6dde26b72677d9f45a0dfa391368c91e88d61bc78a26b2c103a0440159840`. In one cold VM boot the receiver accepted the full payload, Debian mounted the two read-only loops, and the host retrieved the synthetic autofocus result after disconnecting. Separate runs verified the guest-initiated reboot after receipt acknowledgement and the fallback reboot without a connected host. Run these large ARM64 guests one at a time on a 16 GiB WSL instance. During one concurrent run the guest logged CPU soft lockups and refused to start the measurement after its self-test failed. The same bundle passed on an exclusive rerun.

After the bootloader has handed control to Linux, run the sender from the PC. It selects the receiver by VID, PID and USB serial, verifies the local file and waits for the tablet to confirm the digest. The camera endpoint becomes available after the RAM desktop starts. [U-Boot staging](../uboot-ram-stage/README.md) · [Camera diagnostic and host commands](../ram-af-acm/README.md)

```powershell
uv run --offline --python 3.13 tests/ram-trial/send-carrier.py out/dev12.12-ram-receiver/carrier.squashfs --usb
```
