# Bounded SLPI trials

`trial-ssc.sh` defaults to read-only preflight. It targets the original `7.3.4-asphalt-prc` kernel and the PRC Y700 device tree. An offline SLPI, a running ADSP, inactive SSC services and a board firmware directory without SLPI firmware are required. Plan the first start when the owner can operate the tablet. The owner can also explicitly authorize a remote start while accepting that recovery may later require local intervention. Wait for one of those decisions before issuing `--trial`. Keep the usual USB recovery route available.

## First physical start

One authorized start on the test tablet brought SLPI online, bound the Qualcomm FastRPC RPMSG channel over GLINK and exposed `/dev/fastrpc-sdsp`. `sdsprpcd` then logged an internal domain-2 retry at 100 ms, opened the listener and read the board sensor configuration and private registry. This retry was inside the listener process. The kernel saw one SLPI power-on and one stop. The original coordinator reported no accepted accelerometer sample about 0.29 seconds after SLPI came up, while registry opens were still in progress. The original collector output and return code were lost during runtime cleanup, so the exact failure at the QMI or sensor layer is unknown. The controller released SLPI, ADSP stayed running and the original boot, USB SSH, service invocations and persistent firmware search path were verified. That authorization covered the recorded start only.

## Second physical start

On November 19, the owner authorized a second single activation of the same PRC tablet. The QRTR baseline contained no sensor service. Relative to the kernel power-up message, SLPI reported up after 273 ms, the protection domain reported UP after 318 ms, and the coordinator observed service 400, instance 1, after 573 ms. Debian's installed `ssccli` opened the accelerometer, returned 78 finite three-axis readings, disabled its subscription and exited successfully. The first vector was (−3.201345, 0.311545, 9.086595) m/s², with magnitude 9.6391 m/s². The trial included no calibration reference or orientation changes.

The kernel recorded one power-up and one stop 3.880 seconds apart. PID 1 finished cleanup. A fresh USB SSH connection verified the original boot and SSH, LightDM and Bluetooth service invocations, ADSP running, SLPI offline, no SDSP device and no temporary mounts. The persistent SLPI firmware path was absent. At that point the other sensor channels had not yet been sampled.

## Seven-channel physical survey

A third single activation on November 19 used the same PRC tablet, original kernel, private CN350 firmware and imported factory registry. The local sensor service appeared 498 ms after the power-up message. The native collectors accepted one reading from each channel. The six typed libssc clients each acknowledged discovery, subscription and close. The Hall listener accepted one report and rejected zero.

| Channel | First accepted measurement |
| --- | --- |
| Accelerometer | (−3.215710, 0.316334, 9.100960) m/s² |
| Gyroscope | (−0.002696, 0.006190, −0.004260) rad/s in SSC X, Y, Z order |
| Magnetometer | (−53.987873, −9.225600, 75.453781) µT |
| Ambient light | 109.714256 lux |
| Proximity | Far (`near_boolean=0`) |
| Fused compass | 115.178192° |
| Cover Hall | `FAR` |

The coordinator exited successfully. The kernel recorded one power-up and one stop, 5.018 seconds apart. A fresh USB SSH session verified the same boot and service invocations, running ADSP, offline SLPI, empty QRTR service-400 listing and zero temporary mounts. The gyro unit comes from the SSC stream specification. The collector retained the three original floats under the label `ssc_gyro_axis`. Accuracy against a reference, response to motion or light changes, near/far cover transitions, automatic desktop rotation and resume still require separate measurements. [Collector semantics and gyro protocol](../tests/ssc-sample.md) · [Hall events](SSC-HALL.md)

## Prepare and inspect

Place `trial-ssc.sh` and `trial-ssc-assets.py` together in a trusted root-owned location. Use the existing reviewed CN350 firmware archive without installing its SLPI files, and the private calibrated state directory prepared by the existing SSC importer. Keep the known baseline boot configuration. The tool expects the device's installed FastRPC listener, sensor data and `ssccli` from the established SSC package set. Put the trusted `uv` executable on the invoking root shell's `PATH`, including its installation directory if it lives under `/root`. The coordinator receives that absolute executable path and uses `/usr/bin/python3` with offline resolution.

```sh
bash /path/to/trial-ssc.sh
uv run --offline --no-project --python /usr/bin/python3 python -B \
  /path/to/trial-ssc-assets.py "$private_state"
```

The second command prints a digest over the calibration receipt, registry version and sorted group file names and contents. Review that digest locally. Keep the state and the archive private. If the source archive has permissive extraction modes, make a root-owned copy in a private staging directory with `install -m0600 "$source_archive" "$cn350_deb"`. Running preflight creates no unit, mount, or hardware request.

## Authorized trial

```sh
bash /path/to/trial-ssc.sh --trial "$cn350_deb" "$private_state" "$reviewed_state_sha256"
```

PID 1 registers one transient coordinator and its cleanup before the trial stages any data. The coordinator validates the archive SHA-256, every file-backed SLPI segment length and the live device-tree carveout. It builds a read-only temporary view of the existing board firmware directory with the SLPI metadata and split files added. The original files remain on disk. A separate transient unit waits for both the worker's recorded ownership and `/dev/fastrpc-sdsp` before launching the listener. Its Android configuration and writable registry aliases are inside a temporary root. Receipt-verified calibration is copied in, leaving the original state available for later tests.

Before that start, the worker asks the local QRTR nameservice for QMI service 400, confirms the end of its initial listing and requires that no matching endpoint exists. After one start it waits up to 12 seconds for a matching listing entry or registration notification. A FastRPC device node alone is insufficient. While waiting and sampling, it checks the kernel journal, both remoteproc states and the listener unit. Successful discovery permits a single `ssccli` accelerometer invocation, bounded by an eight-second process timeout. The journal prints its exact combined output and exit status and the first finite XYZ row if present. If PID 1 interrupts the worker before reaping the collector, cleanup prints the available output and `exit=unavailable`. A successful collector exit, finite row and healthy services are required for acceptance. Service registration and sample acceptance are separate milestones. [Linux QRTR nameservice](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/net/qrtr/ns.c?h=v7.3.4) · [libssc 0.4.4 QRTR discovery](https://sources.debian.org/src/libssc/0.4.4-2.1/src/libssc-client.c/)

Cleanup stops the listener, releases the owned SLPI power reference and removes the temporary firmware bind by identity. The trial uses the existing kernel firmware search setting and unit enablement. PID 1 retains cleanup responsibility across a lost SSH connection or a terminated coordinator. The runtime directory stores only temporary state.

```sh
journalctl -b -u y700-ssc-first-trial.service -o cat --no-pager
journalctl -b -u y700-ssc-first-trial.service -u y700-ssc-first-trial-listener.service
bash /path/to/trial-ssc.sh
```

The first `SSC first fault` entry comes from the matching SLPI, ADSP or sensor-domain kernel messages after the captured journal cursor. Check the listener journal alongside it. The worker checks for an offline baseline before it arms, and rechecks state and endpoint identity after opening the sysfs file for its one start request. An unrelated process can still request a start while the firmware bind is present. A successful sysfs call grants the trial one power reference, and releasing it can leave SLPI running if another owner still holds a reference. An unconfirmed sysfs write or failed stop leaves a warning in the journal. Identify ownership and restore the baseline before considering any separately authorized experiment.

A Qualcomm firmware fault can interrupt the kernel or USB transport. A postmarketOS-era SDM845 report records repeated `sensor_process` watchdog resets on a Pocophone F1 and a reported hang on a OnePlus 6 during SLPI bring-up. Those are different devices and firmware. PID 1 cleanup depends on Linux continuing to run. The kernel's existing remoteproc recovery can run independently, and a hang can require local recovery. This trial covers initial startup and a sample. Suspend, resume and repeated physical cycles are separate tests. [SDM845 failure report](https://gitlab.com/sdm845-mainline/linux/-/issues/28) · [Qualcomm PAS and remoteproc stop](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/remoteproc/qcom_q6v5_pas.c?h=v7.3.4)

## Optional seven-channel survey

For a separately authorized physical start, the same coordinator can collect one initial reading for each of accelerometer, gyroscope, magnetometer, light, proximity, fused compass and cover Hall. Use the survey command in place of the accelerometer trial for that activation. The worker stages private copies of the two ARM64 collectors and checks their exact hashes before mounting firmware or requesting power.

```sh
bash /path/to/trial-ssc.sh --survey "$cn350_deb" "$private_state" "$reviewed_state_sha256" \
    "$native_ssc_sample" "$native_ssc_hall"
```

| Collector | SHA-256 |
| --- | --- |
| `ssc-sample.arm64` | `ccb1de8f83004e9a9034ffa1e5bb92490b3da003c1383c9ffd5ae564a6eb9a49` |
| `ssc-hall.arm64` | `1f02ccf4c056e71c754e6749d1eb290b60899e7bfe621857b904cd299e25a2c2` |

The survey requires an initially empty QRTR service-400 listing. After starting SLPI it subscribes to service announcements, waits up to 13 seconds for a unique endpoint and keeps that subscription through the last collector. Each channel runs sequentially with a three-second sampling deadline and a six-second outer timeout, followed by up to one second for forced termination. The temporary listener has a 65-second runtime cap and the coordinator has a 75-second cap including preparation. The original accelerometer-only trial retains its 38-second runtime cap.

Read the coordinator journal for each `SSC survey-CHANNEL` block. It includes combined collector output and the process exit code. For the six typed channels, `SSC_RESULT` distinguishes discovery, subscription, valid data and close. For Hall, look for `Hall sensor measurement: NEAR` or `FAR` and its accepted/rejected counts. Exit 3 indicates a discovery or availability problem; exit 4 means the requested reading was missing. A healthy channel that returns an error leaves the subsequent checks enabled, and any incomplete result gives the overall survey a failing status. A lost or replaced QRTR endpoint, new matching kernel fault, missing SDSP device, stopped listener or unhealthy remote processor aborts the remaining checks. Cleanup journals partial output from an interrupted collector and marks unattempted channels `not run`. An interrupted process whose exit status could not be reaped reports `exit=unavailable`. [Typed collectors](../tests/ssc-sample.md) · [Hall reader](SSC-HALL.md)

The survey was exercised in a networkless Debian ARM64 guest with the real pinned libssc and a simulated QRTR service. It collected seven initial readings in one run. With magnetometer removed and an acknowledged light subscription producing no samples, it preserved exits 3 and 4 and still obtained proximity, compass and Hall data. With service 400 withdrawn during gyro collection, it stopped that collector and recorded the five remaining channels as unattempted. A file-backed host test separately injected a running-state fault. The physical survey above obtained the initial values on the tablet. Deliberate motion and cover changes remain pending.

## Host checks

`bash tests/trial-ssc.sh` exercises read-only dispatch, duplicate protection, external references, failed and interrupted sysfs writes and endpoint identity checks using local files. It also checks delayed and absent service registrations, finite-row validation, the original collector failure exit code and cleanup reporting after interruption. Its test doubles issue no sysfs operations. In the ARM64 QRTR guest, the nameservice gate rejected a missing or already-present service and admitted a delayed mock registration. The installed `ssccli 0.4.4` registered an SSC client, subscribed, emitted finite UTF-8 accelerometer rows and requested unsubscription. Reproduce with the existing native libssc test payload, placing the scripts in `/opt/ssc-test/scripts` and `/opt/ssc-test/tests`, and running `bash /opt/ssc-test/tests/trial-ssc.sh --qrtr-fixture`.

For the survey regression, also stage the two collectors as `ssc-sample.arm64` and `ssc-hall`, the Hall QRTR extension as `hall-mock.py` and its Hall sensor fixture alongside the gyroscope fixture in `ssc_server/data/`. Run `bash /opt/ssc-test/tests/trial-ssc.sh --survey-qrtr-fixture`. The guest rejects an existing SDSP node and requires the isolated fixture's kernel command line.
