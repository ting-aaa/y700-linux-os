# qcam photo QA

With the tablet photo patch applied to the libcamera 0.7.2 source, run the store test on Linux with a C++20 compiler, `pkg-config`, Qt6 Core and Gui development packages, and the Qt6 JPEG plugin.

```sh
bash tests/qcam-photo/run.sh "$patched_libcamera"
```

The test creates a new Pictures directory, decodes every JPEG from five sequential and eight concurrent saves, and checks that earlier files remain unchanged. A 512-byte process file limit forces a real write error. The fixture observes file creation as well as the final directory listing and checks that saving works again after restoring the limit.

For the shutter test, use the Y700 ARM64 kernel, a disposable dev12.4-or-later root with the Qt desktop packages, the reviewed Y700 qcam archive, a static ARM64 BusyBox and ARM64 uv. Put the exact `libcamera0.7` 0.7.2-1 runtime closure from signed Debian Sid and Trixie APT metadata in a separate directory. Versions and checksums are listed in [virtual-runtime.sha256](virtual-runtime.sha256). The X11 archive directory must contain ARM64 `xvfb`, `xdotool` and `libxdo3`.

```sh
fixture=$(realpath tests/qcam-photo)
(cd "$virtual_runtime_debs" && sha256sum --strict -c "$fixture/virtual-runtime.sha256")
bash tests/qcam-photo/run-virtual-qemu.sh \
  "$root_qcow2" "$kernel_image" "$qcam_deb" "$virtual_runtime_debs" "$x11_debs" \
  "$arm64_busybox" "$arm64_uv"
```

The runner boots an offline guest with the root and backing chain read-only. The packaged app ELF opens a synthetic colour-bar camera using the test-only library. The verifier locates the actual Qt shutter at 200%, sends one X11 pointer click, then independently decodes exactly one 800×600 JPEG and checks all eight bars. It deletes the test photo and confirms preview continues. The run uses virtual hardware and no device passthrough.
