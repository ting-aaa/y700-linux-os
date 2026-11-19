# Per-tablet sensor calibration

Android keeps the sensor DSP's writable registry on the tablet's internal `persist` partition. The Linux board package supplies version-7 defaults for the TB320FC_PRC. The importer combines those defaults with the calibration groups stored on the individual tablet. The Linux listener binds `/var/lib/y700-ssc` to both `/persist/sensors` and `/mnt/vendor/persist/sensors` in its service namespace. It reads the group files under `registry/registry/` and the version marker under `registry/sns_reg_version`. [Native service](../src/sensors/ssc/y700-ssc.service) · [Pinned upstream registry generation](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/mobile/ssc-registry/generate.py)

## First start on the tablet

With the 0.1.1 runtime and the CN350 seed installed, the listener's first start attempts to import the tablet's calibration automatically. If the source is unavailable, the service initializes its writable registry from the board defaults. Subsequent starts keep the existing state, including learned values. [First-start logic](../src/sensors/ssc/seed)

For a manual import into fresh state, run the installed helper as root. It uses Debian's Python 3 and `debugfs` from `e2fsprogs`.

```sh
/usr/libexec/y700-ssc/import-calibration import-live
```

The command locates the `persist` partition on the tablet's internal UFS controller and opens it read-only. It checks the board, region, block device identity, partition size and registry version. A read-write mounted source is rejected. It publishes the composed registry under the listener's first-start lock. The private receipt `registry/.y700-factory-calibration.json` records the number and combined digest of the imported groups, outside the DSP's group directory. [Import utility](../scripts/import-ssc-calibration.py)

For an isolated trial, add `--state /run/y700-ssc-trial`. The trial listener must bind that directory to both Android paths. Use a private Linux filesystem owned by the calling account. Keep generated state on the tablet or in that tablet's private provisioning area.

When a writable registry already exists, the command retains it. Repeating the same import after the DSP has learned new values also retains them. To compare factory calibration with existing state, prepare a separate state directory and keep the original available for rollback.

## Prepare from the same tablet's verified backup

The Linux build host can prepare or inspect a private state directory from the owner’s original partition capture. The inputs are the backup's two verification manifests, its `partitions/persist.img`, and the genuine seed from the board package. The backup command checks the model, CN350 firmware identity, matching manifest device identifiers and the four source, staging and local image hashes before reading the sensor groups. Provide the actual backup root. Keep its path separate from the output.

```sh
uv run --no-project --python 3.13 python scripts/import-ssc-calibration.py stage-backup \
    --backup "$tablet_backup" --seed "$board_seed" --state "$private_parent/ssc-state"
```

The importer selects named physical calibration groups, including biases, correction matrices, proximity and optical calibration, and persisted gyro/magnetometer calibration tables. The board's other driver, bus and logical-sensor settings come from the Linux seed. JSON scalar values are retained, and the `owner`, `type`, `ver` and `data` keys are ordered for the SSC streaming parser. Group counts describe saved records. A device capture can include unused chip alternatives, default values and learned values from earlier Android use.

On this unit, the backed-up registry had 377 JSON groups and one empty Android marker. The import selected 124 calibration groups, including 46 groups additional to the 329 Linux defaults. Importing the live tablet's internal partition into a temporary state during the physical trial also yielded 375 JSON groups. Live motion, orientation and accuracy require separate tests. See [SSC hardware qualification](CAMERA-SENSORS.md#physical-ssc-qualification).
