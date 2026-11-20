# TB320FC PRC video codec in the dev12.8 kernel

The sealed Debian kernel, board DTB and root image already contain the SM8475 video driver, the board wiring and the exact CN350 video firmware. The PC verification below checks all three against the retained Android artifacts. It establishes the inputs to firmware startup. Frame delivery, display and application selection require runtime evidence. The project tracks tablet results in [STATUS](STATUS.md).

## From Android VIDC to Linux Iris

The retained CN350 Android tree enables `/soc/qcom,vidc@aa00000` with the Waipio Iris2 vendor binding, firmware name `vpu20_4v` and PAS ID 9. Android's vendor media configuration lists Codec2 components such as `c2.qti.avc.decoder`. The Debian board tree enables `/soc@0/video-codec@aa00000`. Its `qcom,sm8450-venus` compatible selects the Iris driver's `sm8450_data` in the patched 7.3.4 kernel. The deployed kernel's embedded configuration sets `VIDEO_QCOM_IRIS`, `QCOM_SCM`, `QCOM_MDT_LOADER` and `ARM_SMMU_QCOM` to built-in. The SM8450 Iris match is supplied by Asphalt patch 0007. [Project source pins](../upstream.lock.json) · [Asphalt SM8450 integration and original contributors](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0007-sm8450-iris-video.patch) · [Upstream Linux 7.3 Iris match table](https://github.com/torvalds/linux/blob/v7.3/drivers/media/platform/qcom/iris/iris_probe.c)

| Resource | Retained CN350 Android and sealed PRC Debian DTBs |
| --- | --- |
| Video register window and interrupt | `0x0aa00000`, length `0xf0000`, GIC SPI 174, level high |
| Firmware reservation | Both codec phandles resolve to the `no-map` range `0x85700000–0x85dfffff` (7 MiB) |
| Ordinary I/O | Nonsecure stream IDs `0x2180` and `0x2187`, each with mask `0x400` |
| Encoder's protected internal buffer | Secure non-pixel stream ID `0x2184`, mask `0x400`, VMID 11. Debian exposes it as the codec's `secure-arp` child |

The Debian node also names the interface, core and codec clocks, the `venus`, `vcodec0`, `mx` and `mmcx` power domains, two interconnect paths and bus/core resets. The driver uses VPU2 operations, four pixel-processing pipes and the HFI Gen2 descriptor. The `firmware_desc_gen1` field holds this platform's only descriptor, whose `firmware_data` explicitly points to `iris_hfi_gen2_data`. [Board patch series](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/series.nix)

## Firmware and ownership

The CN350 `vendor.img` file `/firmware/vpu20_4v.mbn` and the sealed Debian file `/usr/lib/firmware/qcom/sm8475/lenovo/tb320fc/vpu20_4v.mbn` match byte for byte. The community firmware set identifies ROW ZUI 17.0.339 as its source. Its corresponding file has the same digest. [Community firmware provenance](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/asphalt/firmware-source.nix) · [Board-specific installation path](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/asphalt/firmware.nix)

| Blob property | Offline result |
| --- | --- |
| Size and SHA-256 | 2,024,040 bytes, `d96846cf4b000142e1e3f5bb03a54368bb9a45cb1804d4f798990dc946a210fb` |
| Generation | Embedded `QC_IMAGE_VERSION_STRING` begins with `video-firmware.2.4-` |
| Memory required | Little-endian ELF32 with 20 program headers. Fourteen loadable, nonempty MDT segments span exactly `0x700000` bytes after 4 KiB alignment, filling the DT reservation |

The driver registers the decoder and encoder during probe. On the first open, `iris_open()` resumes the device and calls `iris_core_init()`. This can power the VPU, load the MDT, request secure-world authentication/reset for PAS 9, configure video memory protection and wait for the firmware's HFI response. Even a program that opens the device only to query capabilities can reach that sequence. The offline comparison does not perform authentication. [Iris firmware loader](https://github.com/torvalds/linux/blob/v7.3/drivers/media/platform/qcom/iris/iris_firmware.c) · [Qualcomm MDT sizing](https://github.com/torvalds/linux/blob/v7.3/drivers/soc/qcom/mdt_loader.c)

For ordinary encoding with this firmware, the board patches supply a per-buffer decoded picture buffer and a protected internal ARP allocation. The driver allocates zeroed pages, cleans the CPU mapping, transfers ownership from HLOS to CP_NON_PIXEL through SCM, and maps the secure SMMU domain. Release requires successful unmap/synchronization and return of ownership before page reuse. A failed path can retain the pages until reboot. Decode and encode therefore exercise different resources. [Protected-buffer driver](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0025-iris-secure-arp.patch) · [Secure SMMU support](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0024-qcom-smmu-secure-arp.patch)

## Userspace interface

Both nodes implement V4L2 streaming memory-to-memory with multi-planar queue types. These are the four-character format codes in the pinned driver's enumeration tables. OUTPUT means data supplied by the application, CAPTURE means data returned to it. The stateful decoder signals source changes. The client must handle CAPTURE negotiation, visible crop, allocated stride and the final drain. [Linux stateful decoder interface](https://docs.kernel.org/userspace-api/media/v4l/dev-decoder.html)

| Kernel device name | OUTPUT | CAPTURE |
| --- | --- | --- |
| `qcom-iris-decoder` | `H264`, `HEVC`, `VP90` | `NV12`, `Q08C`, `P010`, `Q10C` |
| `qcom-iris-encoder` | `NV12`, `Q08C` | `H264`, `HEVC` |

The peer Asphalt project reports 180-second 8-bit H.264/HEVC decode and short 720p/1080p H.264/HEVC encodes. Its direct V4L2 diagnostic uses a device-patched FFmpeg, including NV12 stride handling, P010 support and encoder draining. A useful Debian comparison uses a finite local synthetic clip, forces the hardware backend, then compares frame count and visible per-frame samples against software decoding. New VPU/SMMU errors, missing pictures or a silent software fallback invalidate a hardware pass. [Peer hardware results](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/docs/asphalt/hardware.md) · [Diagnostic FFmpeg recipe](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/asphalt/ffmpeg.nix)

The sealed Debian inventory includes Chromium 156, GStreamer 1.26 with the good plugins, and v4l-utils 1.30.1. It lacks the `ffmpeg`, `libavcodec61`, `libva2` and `vainfo` packages. A direct stateful V4L2 client can test the codec independently of Chromium. For applications using VA-API, Asphalt separately packages an optional Qualcomm bridge at commit `0980a1decf26`, plus its presentation, discovery and encode patches. This path also needs permission to access the appropriate video, DRM render and DMA heap devices. Browser acceleration needs an application-level decode test that identifies the selected backend. [Asphalt video stack](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/docs/video.md) · [VA-API bridge recipe](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/libva-v4l2/default.nix)

## Reproduce the offline check

Use the original private files on a Linux host with Python 3.11+, `uv`, `debugfs` and `fdtget`. The script accepts ordinary image files, checks their full hashes, reads the kernel's embedded configuration, resolves both device trees and reads the two firmware files into host memory. It requires neither a mount nor a device connection. The repository stores the verification code and digest. [Offline verifier](../tests/video-kernel.py)

```sh
uv run --offline --no-project --python /usr/bin/python3 python tests/video-kernel.py \
    out/dev12.8-ram-trial/kernel.efi out/dev12.8-ram-trial/board.dtb \
    "$CN350_RUNTIME_DTB" "$CN350_VENDOR_EXT4" "$DEV12_8_ROOT_EXT4"
```

The complete local run produced `out/video-kernel/verification.log`, SHA-256 `68c9ed3da60d3fff0f08476981f7b3f5c695524caff6db1a17df605d83aa34be`. Negative checks rejected a swapped Android/Linux DTB at the identity check and a synthetic secure VMID of 12 at the binding check.
