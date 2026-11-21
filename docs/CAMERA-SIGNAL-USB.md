# dev12.13 diskless rear-camera signal receiver

One boot can run either a matched HI1339 RAW/RGB measurement or the original autofocus trial. The host selects the measurement after reading the current boot token and completing the configuration check. The signal option warms up for 24 frames and measures the next matched frame. The sensor stays in automatic exposure. The normal AF request and its original score-pair library remain available through `start`. Both choices consume the same single run. [Signal measurements and interpretation](CAMERA-SIGNAL.md) · [Original AF protocol](../tests/ram-af-acm/README.md)

## Build and identify the receiver

On the development PC, the prepared directory is `/var/tmp/y700-camera-signal-receivers/dev12.13` in the Ubuntu WSL distribution. The Windows path is `\\wsl.localhost\Ubuntu\var\tmp\y700-camera-signal-receivers\dev12.13`. Source and destination must share a filesystem because the builder hard-links four immutable files. The additional permanent data comprise the new 13,904,484-byte initrd and its 387-byte manifest. A second build against the public copy of the sealed receiver produced the same hashes.

| File | SHA-256 |
| --- | --- |
| Parent dev12.13 receiver manifest | `c7e5c6a5cfc795c25bd54940b8f4f1fea0e457cafb02f6e17ca3dc6914fc608f` |
| Matched-signal receiver manifest | `8e66df7f74fcc357bcf4035f5145d26d1c4c076352689664e27bdaa9665b9405` |
| Matched-signal initrd | `390515364426533b56385c2e058ea551c952c1892839158adf3d68db026db236` |
| Shared 1,353,732,096-byte carrier | `1e8d32f9db603ff91c13b4666e78ce2d8af3355cf7e8fa2426339b4e13743ef2` |
| Signal probe | `9c86901edec6bd8f4052c62a94b994bf25d439eb0ae3ded5be9b823712442df8` |

```sh
sudo bash tests/ram-af-acm/signal-attachment.sh "$sealed_dev1213_receiver" \
    out/camera-signal/y700-af-measure-signal "$new_receiver"
```

The builder verifies every parent file and the exact last newc member before applying two small changes to its service and board wrapper. It includes the old AF executable, diagnostic library, return units, package ledger guard and original board init. The signal client uses the release CPU ISP. The original sealed receiver continues to build from its existing instructions. [Builder](../tests/ram-af-acm/signal-attachment.sh) · [Dev12.13 parent](DEV12.13-VERIFICATION.md)

## One authorized boot

Use the existing staged RAM boot procedure with the receiver directory and its new manifest pin. On Windows the host-only check reads all five files and reports `host_verified=5 first_stage_files=3 first_stage_bytes=53436027`. The U-Boot entry point accepts the same directory and pin. Once the receiver requests the carrier, pass its existing `carrier.squashfs` to the standard sender. [RAM staging and USB carrier procedure](../tests/ram-trial/README.md)

```powershell
$receiver = '\\wsl.localhost\Ubuntu\var\tmp\y700-camera-signal-receivers\dev12.13'
$pin = '8e66df7f74fcc357bcf4035f5145d26d1c4c076352689664e27bdaa9665b9405'
uv run --offline --no-project python -B scripts/uboot-ram-stage.py check $receiver $pin
```

For an authorized physical run, the first command below waits for the identified U-Boot console during the normal restart. The second supplies the verified carrier once the Linux receiver has enumerated. A lab already using the read-only ESP kernel/prefix optimization can retain its verified ESP PARTUUID and flags for the first command. [Staging command and console handover](../tests/uboot-ram-stage/README.md)

```powershell
uv run --no-project --with pyserial==3.5 python scripts/uboot-ram-stage.py boot $receiver $pin --wait-seconds 120 --exit-efi-menu
uv run --no-project --with pyserial==3.5 python tests/ram-trial/send-carrier.py "$receiver/carrier.squashfs" --usb
```

Use the newly enumerated Debian diagnostic ACM port. Substitute the returned READY token in both commands. The configuration result checks the restricted allocator and the suspended sensor. Each boot has its own token.

```powershell
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py status --port COMn
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py check-config --port COMn --token TOKEN
uv run --no-project --with pyserial==3.5 python tests/ram-af-acm/host.py signal --port COMn --token TOKEN
```

The host checks the complete same-frame receipt, sensor suspension and removal of the private DMA-BUF alias before acknowledging success. The guest then schedules a normal reboot after five seconds. If USB disconnects during measurement, reconnect to the same boot, read `status`, then use `signal-result` with the matching DONE token. That command replays the saved receipt and acknowledges it. A failed or incomplete measurement is represented by a bounded failure record and nonzero end code. A partial transfer receives no acknowledgement. The independent twelve-minute return timer remains armed throughout. [Host](../tests/ram-af-acm/host.py) · [Receipt schema](../tests/ram-af-acm/signal_receipt.py)

The board probe checks matching frame sequence and timestamp inside the process before emitting an aggregate pair. The wire allowlist accepts seven fixed channel rows plus frame metadata, completion and cleanup. Apart from those values, it drops all driver output. Measurements and the replay file live in RAM. The inherited checks verify disabled UFS and SD, read-only carrier/root loop devices, the RAM overlay and zero swap. This derived receiver has not yet measured a physical RAW/RGB pair.

## Reproduce the PC checks

Run the unit tests under `uv`. They exercise the physical receipt format, rejected fields, interrupted transfers, malformed cleanup and the acknowledgement digest. For the cold boots, use the ARM64 QEMU and host `uv` paths described in the receiver tests, with 8 GiB guest memory available. Each command takes a new log directory. The test wrapper removes its temporary QA initrd. The common receiver, carrier and production board initrd stay in place.

```sh
uv run --offline --no-project python -B tests/ram-af-acm/test-signal-receipt.py
uv run --offline --no-project python -B tests/ram-af-acm/test-receipt.py
pin=8e66df7f74fcc357bcf4035f5145d26d1c4c076352689664e27bdaa9665b9405
AF_QA_SIGNAL=ack bash tests/ram-trial/check-receiver.sh "$new_receiver" "$pin" "$new_ack_logs"
AF_QA_SIGNAL=deadline bash tests/ram-trial/check-receiver.sh "$new_receiver" "$pin" "$new_deadline_logs"
AF_QA_ALLOCATOR=1 bash tests/ram-trial/check-receiver.sh "$new_receiver" "$pin" "$new_legacy_logs"
```

The two signal runs enable the return units on QEMU's dummy machine in a temporary initrd. The deadline run shortens its independent return timer to 80 seconds. The virtual signal producer emits a labelled artificial pair after the actual ARM64 probe completes its camera-free self-test. Protocol validation covers transfer, receipt replay and guest reboot. [Released CPU ISP replay with synthetic Bayer input](CAMERA-SIGNAL.md#pc-replay)

Three ARM64 cold boots passed. One recovered all seven signal channels after disconnect, rejected a second capture and a wrong acknowledgement, then rebooted normally on the correct acknowledgement. Another rebooted on the independent deadline while the host was offline. The third passed the original AF configuration, start, disconnect and result replay. Both receiver manifests were rechecked afterwards. The four shared files had the same inodes as the parent and the two new files consumed 13,910,016 allocated bytes. The reduced logs are in `out/camera-signal-usb/`. Their `evidence.sha256` manifest has SHA-256 `435e93ff549e62d61a1fe68f2361dfacf378a805619b183ab20cbd8e67f992fd`.
