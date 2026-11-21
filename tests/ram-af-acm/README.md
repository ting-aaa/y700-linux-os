# Rear autofocus receipt over USB ACM

This private RAM diagnostic attachment exposes one serial interface. It sends aggregate measurements from the pinned optical client. An ordinary user runs the client through the existing board runner with a private network, read-only system and hidden home directories. The attachment contains no login credentials.

```sh
bash tests/ram-af-acm/build.sh "$sealed_dev1212_ram" "$exposure_gated_arm64_elf" \
    "$diagnostic_libcamera_so" "$new_attachment"
(cd "$new_attachment" && sha256sum --strict -c SHA256SUMS)
cat "$sealed_dev1212_ram/initrd" "$new_attachment/af-acm.cpio" > "$new_combined_initrd"
```

Use the attachment's `cmdline.txt`, the sealed release kernel and the UFS/SD-disabled PRC tree. For a two-stage USB transfer, include the same newc member in the first initrd. Once the verified SquashFS carrier is at `/y700-root.squashfs`, release the staging gadget, restore the original early mount view, and execute `/y700-af-acm-init` with `y700.ram_af_acm=1` on the command line. The entry point installs the systemd service in the RAM overlay before switch-root. It preserves the original storage and shutdown checks. The source check requires the sealed RAM-bundle manifest `2cdddecb410b4aa3d9b63b229fc8df5fc8de61b00ed3a209a34c633d82adb453`.

The Windows host client requires pyserial 3.5. Select the COM port for the device whose USB serial number is `Y700_RAM_AF`. A status query runs no camera capture. The service verifies the release kernel, PRC identity, disabled storage controllers, absence of persistent drives and swap, and the read-only SquashFS/ext4 mounts and RAM upper layer. It checks that the synthetic self-test completes with the rear sensor suspended and no additional active sensor time. Only then does it return a READY line and the boot-specific token.

```powershell
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py status --port COMn
```

After the owner authorizes one physical measurement and the PC has received READY, submit the token shown by that status query. The PC displays each filtered aggregate line as it arrives and finishes with the measurement exit code. A missing terminal line leaves the outcome unresolved.

```powershell
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py start --port COMn --token TOKEN
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py result --port COMn --token TOKEN
```

The service checks storage again before accepting START and consumes that boot's trial before opening the camera. A completed receipt stays in tmpfs for retrieval through the same port. The service listens for up to 20 minutes, and the measurement running as the ordinary user has a 70-second runtime limit. A kernel stall may interrupt the receipt or prevent delivery. For repeatable PC tests, use the two commands below. The emulated port uses a Unix socket. Even a valid token on the virtual board can only invoke the ARM64 client's synthetic test with private devices.

```sh
bash tests/ram-af-acm/run-qemu.sh "$sealed_dev1212_ram" "$new_attachment" "$new_emulator_log_dir"
AF_QA_DISCONNECT=1 bash tests/ram-af-acm/run-qemu.sh "$sealed_dev1212_ram" "$new_attachment" "$new_disconnect_log_dir"
```
