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

After the owner authorizes one physical measurement and the PC has received READY, submit the token shown by that status query. The PC displays each filtered aggregate line as it arrives. After printing the terminal measurement code, the physical host client acknowledges the SHA-256 of every received data line including the terminal line. The receiver compares this value to its tmpfs receipt. A match schedules an orderly systemd reboot in five seconds and returns `AF1 RETURN acknowledged=1`. The PC then exits with the measurement code. A missing terminal line leaves the outcome unresolved.

```powershell
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py start --port COMn --token TOKEN
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py result --port COMn --token TOKEN
```

The service checks storage again before accepting START and consumes that boot's trial before opening the camera. After a lost connection, use `result` and the original token to retrieve and acknowledge the saved receipt. To save the output locally, pipe the host command to PowerShell `Tee-Object -FilePath .\ram-af-receipt.txt`.

On the PRC tablet the attachment enables an independent 12-minute timer in the RAM system's systemd manager. The timer starts after the USB carrier transfer, verification and switch to the new root. It requests an ordinary `systemctl reboot` even if the host never connects, the gadget setup fails, the sensor self-test fails or the host disconnects after measurement. The original firmware boot selection determines which OS starts next. START closes nine minutes after handover to keep at least three minutes for the 70-second measurement, sensor cleanup and retrieval. After either return path destroys the RAM overlay, only the rows already received on the PC survive. A kernel stall that prevents systemd from running or completing shutdown can still require the physical power button.

The following PC tests use the actual ARM64 client with synthetic input and private devices. The virtual port uses a Unix socket. The return tests add a separate VM-only init entry to exercise the physical timer installation on the emulator. The idle test shortens the deadline to 80 seconds in the VM overlay. The shipped PRC timer remains 12 minutes.

```sh
bash tests/ram-af-acm/run-qemu.sh "$sealed_dev1212_ram" "$new_attachment" "$new_emulator_log_dir"
AF_QA_DISCONNECT=1 bash tests/ram-af-acm/run-qemu.sh "$sealed_dev1212_ram" "$new_attachment" "$new_disconnect_log_dir"
AF_QA_RETURN=ack AF_QA_DISCONNECT=1 bash tests/ram-af-acm/run-qemu.sh "$sealed_dev1212_ram" "$new_attachment" "$new_confirmed_return_log_dir"
AF_QA_RETURN=deadline bash tests/ram-af-acm/run-qemu.sh "$sealed_dev1212_ram" "$new_attachment" "$new_idle_return_log_dir"
```

The acknowledged and idle ARM64 runs each reached `systemd-shutdown: Rebooting` and the kernel restart with no host kill. Shutdown reported two busy read-only RAM loop mounts before restart. Physical USB enumeration, autofocus and the firmware's selection of the daily Debian system on the following boot require a tablet run.
