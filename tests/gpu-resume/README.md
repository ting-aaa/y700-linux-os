# Offscreen GPU check across system sleep

The probe creates three independent OpenGL ES 3 contexts on the MSM render node. Each context draws four frames into a 64 × 32 integer framebuffer. The fragment shader fetches a coordinate-shifted texel, combines channels with integer multiplication, addition and XOR, and writes four bytes per pixel. A CPU reference checks every byte. EGL binds no window or display surface. [Surfaceless EGL contexts](https://registry.khronos.org/EGL/extensions/KHR/EGL_KHR_surfaceless_context.txt)

Hardware mode requires the FD730 renderer string and an increase in that process's MSM GPU elapsed-time or cycle counter for each context. Duplicate DRM file descriptors are grouped by client ID on the selected render node. The pinned kernel increments these counters in `retire_submit()`. This measures work retired for that client even if the desktop also has an active GPU client. [DRM client usage](https://docs.kernel.org/gpu/drm-usage-stats.html) · [Kernel MSM accounting](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/msm/msm_gpu.c)

## Build and check on a PC

```sh
bash tests/gpu-resume/build.sh "$DEBIAN_ARM64_SDK" "$NEW_ELF"
sudo bash tests/gpu-resume/software-control.sh "$GENERIC_DEV12_10_ROOT" "$NEW_ELF" "$NEW_RESULTS"
```

On the sealed dev12.10 root (`18e75eff…`), the AArch64 executable ran under QEMU user emulation as UID 65534 in a private filesystem namespace. Mesa llvmpipe (LLVM 19.1.7) produced the expected 24,576 pixels across all 12 frames. The default mode refused that environment because it had no render node. The two builds of the probe matched SHA-256 `c41738743f9780296d7a59d86b649ab44190f49c1685fed9e3319c2e2500a280`. The local receipts are in `out/gpu-offscreen/debian-control/`.

## Board use

Place the binary in a directory that the ordinary y700 account can traverse. Run the checks around a separately managed sleep using one private results directory. Supply a fresh path for each pair.

```sh
sudo bash check.sh before /var/tmp/y700-gpu-cycle-01 /run/y700-gpu-tools/gpu-offscreen.arm64
# After the separate system suspend and wake
sudo bash check.sh after /var/tmp/y700-gpu-cycle-01 /run/y700-gpu-tools/gpu-offscreen.arm64
```

The wrapper reads the kernel journal as root and launches the bounded render process as UID 1000 with its ordinary groups and an empty display environment. A hardware receipt includes three positive MSM accounting deltas. The second pass also requires the same boot ID and executable hash, paired suspend-entry/exit records, and at least 100 ms growth in the difference between Linux boot time and monotonic time. Both stages report new GPU, GMU or display fault matches. The wrapper never initiates sleep. A successful pair covers these rendering operations and the observed sleep interval. Display scanout, Vulkan, long-running stability and which platform power rails actually switched off require separate evidence.

## Offscreen Vulkan graphics queue

The Vulkan 1.2 probe uses a 64 × 32 optimal-tiled RGBA8 integer color attachment. Each of four graphics-queue submissions clears the framebuffer at render-pass load, clears a moving interior rectangle, and copies the image to a buffer. A transfer-to-host barrier, a three-second fence wait and mapped-memory invalidation precede each CPU check of all four channels. This exercises render-pass attachment writes, image layout transitions, transfers and synchronized host readback. Shader drawing, compute dispatch and window presentation require their own tests. [Attachment clears](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdClearAttachments.html) · [Image-to-buffer copies](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdCopyImageToBuffer.html) · [Host visibility](https://docs.vulkan.org/refpages/latest/refpages/source/vkInvalidateMappedMemoryRanges.html)

Build with Debian ARM64 `libvulkan-dev` and `libvulkan1` extracted in the SDK. The verified build used package version `1.4.309.0-1` and GCC 15.2.0. The two builds produced SHA-256 `11e97a2a06219df3374af797fc563fcd43f0b5ef3c10c1b4a9b7eb5c73f68540`. In the sealed dev12.11 image (root SHA-256 `33ce23e8…`), UID 65534 with the lavapipe ICD passed all 8,192 pixels. Hardware mode rejected the same software device. The logs are in `out/gpu-offscreen/vulkan-dev12.11-control/`.

```sh
bash tests/gpu-resume/vulkan-build.sh "$DEBIAN_ARM64_SDK" "$NEW_ELF"
sudo bash tests/gpu-resume/software-control.sh --vulkan-dev12.11 "$GENERIC_DEV12_11_ROOT" "$NEW_ELF" "$NEW_RESULTS"
```

Run as the ordinary desktop user on each side of a separately managed sleep and retain both outputs. Hardware mode requires the integrated device named `Turnip Adreno (TM) 730` and driver ID `VK_DRIVER_ID_MESA_TURNIP`.

```sh
timeout -k 2 20 env VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.json \
    MESA_SHADER_CACHE_DISABLE=true /run/y700-gpu-tools/vulkan-offscreen.arm64
```
