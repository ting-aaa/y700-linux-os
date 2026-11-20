# SDSP device activation on Debian ARM64

Run this test with a sealed dev12.4 root containing y700-ssc-runtime 0.1.1. It boots the board kernel with the Debian system manager, udev and system bus. A tmpfs overlay holds the package transaction and all generated state. QEMU opens the underlying root read-only. The test expects an ARM64 kernel build tree, a Linux build host with ARM64 binfmt, and the inputs used by the [SSC desktop test](../ssc-desktop/).

```sh
bash tests/ssc-lifecycle/run.sh ROOT_IMAGE qcow2 KERNEL_BUILD libssc_0.4.4.orig.tar.gz \
    ARM64_BUILD_ROOT ARM64_STATIC_BUSYBOX ARM64_UV y700-ssc-runtime_0.1.3_arm64.deb y700-ssc-runtime_0.1.1_arm64.deb
```

Use `raw` in place of `qcow2` for an ext4 file. Set `QEMU_BIN` and `QEMU_DATA_DIR` when using a private QEMU build. The script expects three `SSC_LIFECYCLE_PASS` lines, one for each independently booted guest.

- **Upgrade.** The simulated misc device appears under 0.1.1. The guest confirms that its udev wants omit the listener. It installs the newer Debian archive with a denying `policy-rc.d`, repeats while the listener is masked, then explicitly removes the test mask and runs normal package configuration. It checks that a further package configuration preserves the running listener's invocation ID. After the hotplug checks it downgrades to the sealed 0.1.1 archive, checks the registry version marker and confirms that another device arrival leaves the listener inactive.
- **Coldplug.** The newer package is configured offline. The SDSP device already exists when PID 1 starts udev. The guest checks listener startup, registry initialization and the proxy's three D-Bus capabilities.
- **Late arrival.** The newer package starts on a guest with no SDSP device. The guest verifies that no job is waiting for the device and inserts the test module. Each mode checks that removal stops the listener and proxy, that reappearance restores them and that a closely spaced remove/add recovers. The late case also inserts the device with a masked listener and measures the PIDs and masked-unit messages.

The mock misc device intentionally rejects FastRPC ioctls. The test replaces only the listener's main executable with the pinned libssc QRTR sensor simulator. The packaged systemd relationships, seed command, mounts, sample readiness check, proxy executable and udev rules run normally. PAS firmware boot, Hexagon execution, physical sensor values and suspend/resume require the tablet.
