# Diskless Y700 RAM boot

Use `RAM_TRIAL_VERSION=dev12.9` for the 1,240-package release with Parole preinstalled. The guest compares its media receipt to the repository lock and hashes its installed package inventory. It also exercises the desktop and temporary upper layer described below. [dev12.9 artifacts and results](../../docs/DEV12.9-VERIFICATION.md)

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
