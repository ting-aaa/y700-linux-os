# Rear autofocus receipt over USB ACM

The [dev12.13 matched-signal receiver](../../docs/CAMERA-SIGNAL-USB.md) also accepts a one-shot `signal` command for paired RAW/RGB measurements through the same protected session.

This private RAM diagnostic attachment exposes one serial interface. It sends aggregate measurements from the pinned optical client. An ordinary user runs the client through the existing board runner with a private network, read-only system and hidden home directories. The attachment contains no login credentials.

## Compare the two focus scores on the same frames

The second physical RAM trial reached 419 preview frames. Its terminal diagnostic counted 18 accepted samples over nine coarse controls and reported `flat-contrast`. That attachment recorded only the terminal counters. The third attachment adds paired measurements of the production sampling grid and a dense reference over the center of the same 640 × 480 frame. The production score continues to control the scan. The reference processes only accepted pairs inside the private diagnostic process. [Second physical trial](../../docs/CAMERA-FOCUS-PROBE.md#diskless-rear-autofocus-on-22-november)

```sh
bash tests/ram-af-acm/build-allocator.sh --score-pairs out/dev12.12-ram-receiver-allocator \
    out/camera-af-score-pairs/libcamera.so.0.7 out/dev12.12-ram-receiver-scores
uv run --offline --no-project python -B tests/ram-af-acm/test-score-trace.py \
    --library-log out/camera-af-score-pairs/pairs-after.log
```

The v3 receiver manifest SHA-256 is `4b7aeab70eb27cf3a8ba943fa2f2a9ae8546aae36fe7ff5960a99e7732fe1065`. The 13,810,788-byte initrd is `2c83d73077dd1ab12aa3ccd4f1cbbead3f0845720b45ef0230cb2075ac48b02f`. The builder requires the sealed v2 receiver, pins the new library, and reuses its original kernel, board tree, command line and 1,351,581,696-byte carrier. The status, configuration, one-shot start, result retrieval and reboot protocol are shared.

After a separately initiated trial, run the following command on the host with the saved `start` or `result` output. The parser checks point order, sample counts, the terminal diagnostic, cleanup and the end receipt. A missing or duplicate point fails the comparison. Values use one million units per normalized score. Each point gives the mean and absolute within-pair difference for each method. Images and lens codes stay off the serial channel.

```sh
uv run --offline --no-project python -B tests/ram-af-acm/score_trace.py "$receipt"
```

The coarse summary gives the rounded maximum minus 25,000 ppm and the rounded maximum minus 1.12 times the rounded minimum. Up to 1.06 ppm of rounding uncertainty applies to the relative margin. The scan's original terminal reason uses internal, unrounded production scores. Compare the span with within-pair variability and with the reference span before interpreting the response. The scores alone do not measure mechanical lens travel.

A deterministic synthetic image gave nine identical production means of 33,900 ppm while the reference spanned 33,966–137,323 ppm on the same pairs. The unchanged production scan ended with `flat-contrast`. This fixture exercises the trace and its interpretation. A physical v3 measurement requires its own receipt.

## Diskless dev12.12 with a private software-ISP allocator

The original diskless tablet boot reached the ACM self-test. Its rear-camera check returned `no_cpu_rgb_mode` before streaming. A separate comparison on the daily tablet reproduced the raw-only selection for the unprivileged account. Giving only the transient measurement process read/write access to the real `/dev/udmabuf` yielded 640 × 480 ABGR8888 with a 2,560-byte stride. The configure-only client allocated zero buffers, read zero pixels and left the rear sensor suspended with zero additional active time. The local comparison is in `out/camera-optical-qa/physical-private-config-v2.log`.

Build the new USB receiver beside the original, on the same filesystem. Four hard links reuse the boot kernel, diskless board tree, command line and 1,351,581,696-byte immutable carrier. The builder verifies the old attachment at the end of the initial ramdisk and replaces that member. Each resulting directory has its own manifest.

```sh
bash tests/ram-af-acm/build-allocator.sh out/dev12.12-ram-receiver \
    out/ram-af-acm-return out/camera-optical-config/y700-af-measure-config \
    out/camera-af-settling/libcamera.so.0.7 out/dev12.12-ram-receiver-allocator
```

| File | SHA-256 |
| --- | --- |
| Receiver `SHA256SUMS` | `e06431c4839c40d93afaf8ffbe3467d337782607e1de5434136abae76166fb90` |
| Small `initrd`, 13,809,252 bytes | `e434556372b01949ebdd43ef703f0c7c908fcbf1e05d75a8a8c4c92a5ed23666` |
| `attachment/af-acm.cpio` | `bf4325938126dda719c41dd78bb58c0190e40fb602df5db2127b06d7427af249` |

After an authorized physical boot of this attachment, obtain the token and request the configure-only receipt. The host checks the sensor cleanup, all five zero activity counters, allocator access and private-node cleanup. The guest keeps that receipt for a retry. A successful configuration allows a separate, explicitly requested one-shot optical run.

```powershell
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py status --port COMn
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py check-config --port COMn --token TOKEN
```

The service rechecks both disabled controllers, the absence of physical block devices and swap, and the read-only carrier with tmpfs changes before granting allocator access. It checks the live device number against sysfs, creates a private `0600` node beneath a root-owned `0700` directory on devtmpfs, and bind-mounts only that node into the ordinary user's transient unit. Cleanup removes the alias and checks the original node's inode, owner, group, permissions and device number. CONFIG closes after 500 seconds from handover. The existing independent reboot timer and START window still apply.

To exercise the split boot, allocator and serial protocol on a PC, use an ARM64 QEMU installation and an available 8 GiB guest allocation. The VM has the release kernel's real udmabuf device. It tests access denial, private access, refusal of a substituted device, cleanup and receipt replay. Optical data in this VM come from the synthetic self-test. Use the v3 output directory and its manifest hash above to repeat the same boot check for that attachment.

```sh
AF_QA_ALLOCATOR=1 bash tests/ram-trial/check-receiver.sh \
    out/dev12.12-ram-receiver-allocator \
    e06431c4839c40d93afaf8ffbe3467d337782607e1de5434136abae76166fb90 "$new_vm_log_dir"
uv run --offline --no-project python -B tests/ram-af-acm/test-receipt.py
```

## Original attachment and shared return protocol

Run the original builder from a Git checkout that contains `9b3b6a18435b4d93d281f14ed0bf81a45c2e7664`. It uses the historical scripts and the original client and library to reproduce the first attachment.

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

The acknowledged and idle ARM64 runs each reached `systemd-shutdown: Rebooting` and the kernel restart with no host kill. Shutdown reported two busy read-only RAM loop mounts before restart. On the tablet the original attachment returned its camera configuration failure via USB and the next boot reached daily dev12.11. Receipts are in `out/camera-optical-qa/physical-cold-af.log` and `physical-cold-daily-return.log`.
