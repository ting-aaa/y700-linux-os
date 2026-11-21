# Load the staged capture modules

Build the module directory with [build-microphone-modules.sh](../../../scripts/build-microphone-modules.sh). Extract the **shipped** ARM64 kernel from `/EFI/debian/kernel.efi` on the original dev12.9 boot FAT. The SHA-256 of the FAT used for this test was `495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6`.

```sh
mcopy -i "$esp" ::/EFI/debian/kernel.efi ./shipped-kernel.efi
bash tests/microphone/modules/run.sh ./shipped-kernel.efi "$root_ext4" \
    "$module_build" "$arm64_static_busybox" ./shipped-load
bash tests/microphone/modules/run.sh --build-base "$kernel_build/arch/arm64/boot/Image" \
    "$root_ext4" "$module_build" "$arm64_static_busybox" ./build-base-load
```

Both inputs report `7.3.4-asphalt-prc`. The runner verifies the host input bytes and the guest's running kernel notes independently.

| Kernel | Image SHA-256 | Running `/sys/kernel/notes` SHA-256 |
| --- | --- | --- |
| Shipped on dev12.9 EFI | `4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1` | `c9fbc259802dfc4570c14df56043d37f1c08e9769341de3d7cde08f9be6f1564` |
| Prepared module build base | `9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db` | `2e6b047aba528bfdea5549b9aae9af362a9af055bb630a650bcdd7c654ec9066` |

The shipped kernel adds the Adreno HFI queued-vote acknowledgement fix, patch SHA-256 `3a30e92a15e858e2238ded2e3cf7e12e462f503be2e50cef967fc87bd9f730fe`. Applying the patch to a fresh copy of the base HFI source reproduced the shipped tree's HFI source. The retained builds had identical configurations, release strings and exported vmlinux symbol tables. [Kernel build recipe](../../../scripts/build-gmu-fix-kernel.sh) · [Shipped kernel manifest](../../../config/gmu-queue-kernel.sha256)

The runner independently pins both the raw candidate ELF manifest (`643fcd01ad5b928ff99648b11189640f1cb551d9ac2dae5395623cd95aaae933`) and the sealed compressed staging tree's manifest (`ccadea506a41b8883fc7d689d8c7e764129f4b3b520bf6a283321166e13a47e6`). In each QEMU guest, Debian's kmod 34.2-2 opened the staged compressed files. All 12 candidate modules and both original CS35L45 modules coexisted in the kernel. Every running module's GNU build ID matched the one extracted from its input ELF. The observer unloaded all 14 in holder order, then repeated the load and unload. Both rounds on each kernel produced zero new warnings and left the kernel taint mask at zero. The kernel configuration disables module signing and symbol version CRCs. The test used the ordinary kernel loader. Local receipts are `out/microphone/modules/{shipped-pinned,build-base-pinned}/receipt.log` and `out/microphone/modules/kernel-comparison.log`.

The virtual board provides module registration and lifetime coverage. Physical power sequencing, driver binding to TB320FC components, probe and microphone data still require board-specific evidence.
