# Attended first SLPI trial

`trial-ssc.sh` defaults to read-only preflight. It targets the original `7.3.4-asphalt-prc` kernel and the PRC Y700 device tree. An offline SLPI, a running ADSP, inactive SSC services and a board firmware directory without SLPI firmware are required. Plan the first start when the owner can operate the tablet. The owner can also explicitly authorize a remote start while accepting that recovery may later require local intervention. Wait for one of those decisions before issuing `--trial`. Keep the usual USB recovery route available.

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

PID 1 registers one transient coordinator and its cleanup before the trial stages any data. The coordinator validates the archive SHA-256, every file-backed SLPI segment length and the live device-tree carveout. It builds a read-only temporary view of the existing board firmware directory with the SLPI metadata and split files added. The original files remain on disk. The listener starts from a separate transient unit and waits for `/dev/fastrpc-sdsp`. Its Android configuration and writable registry aliases are inside a temporary root. Receipt-verified calibration is copied in, leaving the original state available for later tests.

The worker requests a single start and seeks one real accelerometer sample. It watches the journal and state during device discovery and sampling, then closes the listener and releases its own SLPI power reference. The trial leaves the kernel firmware search setting and service enablement untouched. PID 1 owns cleanup across a lost SSH connection or a terminated coordinator. The temporary firmware bind is removed by identity, and the transient runtime directory holds no durable calibration changes.

```sh
journalctl -b -u y700-ssc-first-trial.service -u y700-ssc-first-trial-listener.service
bash /path/to/trial-ssc.sh
```

The first `SSC first fault` entry comes from the matching SLPI, ADSP or sensor-domain kernel messages after the captured journal cursor. Check the listener journal alongside it. The worker checks for an offline baseline before it arms and again immediately before requesting start. A concurrent start can race that final check. A successful sysfs call grants the trial one power reference, and releasing it can leave SLPI running if another owner still holds a reference. An unconfirmed sysfs write or failed stop leaves a warning in the journal. Identify ownership and restore the baseline before repeating the experiment.

A Qualcomm firmware fault can interrupt the kernel or USB transport. A postmarketOS-era SDM845 report records repeated `sensor_process` watchdog resets on a Pocophone F1 and a reported hang on a OnePlus 6 during SLPI bring-up. Those are different devices and firmware. PID 1 cleanup depends on Linux continuing to run. The kernel's existing remoteproc recovery can run independently, and a hang can require local recovery. This trial covers initial startup and a sample. Suspend, resume and repeated physical cycles are separate tests. [SDM845 failure report](https://gitlab.com/sdm845-mainline/linux/-/issues/28) · [Qualcomm PAS and remoteproc stop](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/remoteproc/qcom_q6v5_pas.c?h=v7.3.4)

## Host checks

`bash tests/trial-ssc.sh` exercises read-only dispatch, duplicate protection, external references, failed and interrupted sysfs writes, and endpoint identity checks using local files. Its test doubles issue no sysfs operations. Passive checks on the physical tablet passed the board and baseline checks, resolved `uv` at `/usr/local/bin/uv`, and verified the private package, calibrated state and live carveout. Physical SLPI start and sampling remain pending.
