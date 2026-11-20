# Suspend and resume in the dev12.8 ARM64 desktop

The diskless test opens the normal dev12.8 LightDM/PAM session and uses `systemctl suspend` from a test service. The virtual board supplies a PL031 RTC at GIC SPI 2. A test-only module built from the matching kernel source binds this device after Xfce starts. The physical tablet has a Qualcomm PMK8350 RTC on SPMI. Its interrupt routing, regulator state, battery drain and recovery of each peripheral require a physical test. [QEMU ARM virt](https://github.com/qemu/qemu/blob/master/hw/arm/virt.c) · [Linux sleep states](https://docs.kernel.org/admin-guide/pm/sleep-states.html)

## Reproduce

Use the [dev12.8 RAM trial](DEV12.8-RAM-TRIAL.md) and its pinned virtual device tree on the Linux build host. `KERNEL_BUILD` must contain the configured 7.3.4-asphalt-prc tree, generated headers and module symbol versions. The run directory must be new.

```bash
KERNEL_BUILD="$kernel_tree" RAM_TRIAL_VERSION=dev12.8 RAM_TRIAL_SLEEP=1 \
    bash tests/ram-trial/run.sh "$ram_bundle" "$virt_dtb" "$new_log_dir"
```

The host verifies the sealed boot inputs before and after the guest runs. The guest reads the complete package inventory. After login it checks both Linux wake-alarm APIs before and after PL031 registration and waits for one hardware alarm with the guest fully awake. On each suspend cycle it reads the alarm interrupt count, checks the kernel's suspend counters and compares the original Xfce session process, process start time, session leader, session-bus owner and user file after resume. The desktop account also queries its original X server with `xrandr --current` and reads `org.xfce.ScreenSaver.GetActive` from its own session bus.

The kernel configuration omits `/sys/power/pm_wakeup_irq`. The guest captures the IRQ number passed to `pm_system_irq_wakeup()` using tracefs. It requires a match with the IRQ registered by the virtual RTC driver. The collector is scoped to this disposable ARM64 virtual machine. [Kernel trace-event documentation](https://docs.kernel.org/trace/kprobetrace.html)

## Results

The alias in the virtual device tree reserved `rtc1` for PL031. Its `hctosys` flag stayed zero and `/dev/rtc0` was absent. Initially the POSIX alarm clock query returned `EINVAL` and creating a POSIX alarm timer returned `EOPNOTSUPP`. Both succeeded once the RTC was registered. The awake timerfd expired once in both configurations. The separate four-second `rtcwake -m on` alarm then raised the virtual RTC interrupt count from zero to one.

In the first complete desktop run the two kernel suspend-entry to suspend-exit intervals were 9.555 and 9.538 seconds. The kernel attributed both wakes to PL031 IRQ 16. Each counter increased by one, suspend successes reached two, and the failure count stayed at zero. Both cycles returned to the same Xfce session on the same boot with the same ordinary user's file. The guest powered off normally and the host reverified the original boot files. The reduced local receipt is `out/dev12.8-sleep-guest/full-session.log` (SHA-256 `3586f7f6e6e42169f8b8e39014ed5ad73832e3d5ae45768f5c2c459ea694bfcd`).

The final desktop run added a fresh X11 request after each wake. The original account queried the same connected RandR output and screen geometry both times. Xfce reported its screensaver inactive before suspend and active after each wake. The two kernel entry-to-exit intervals were 8.658 and 14.271 seconds. The interrupt and session checks passed again, followed by a clean shutdown and matching input hashes. These checks establish a responsive virtual X server and the screensaver's advertised state. Password entry on a resumed physical panel remains open. The reduced local receipt is `out/dev12.8-sleep-guest/full-x11.log` (SHA-256 `0c7247ba0c6ef4119a2534af32ac0dcad7c73d99346b417fc383f3287c6c2b43`).

Earlier attempts identified requirements for the test fixture. Building the module with GCC for the Clang-built ARM64 kernel produced a misaligned ftrace patch site during module loading, so the module build uses the kernel's LLVM toolchain. Another run recorded a kernel suspend entry and exit, then its virtio serial report stopped during resume. The final fixture uses the separate PL011 console for the post-resume assertions. An intermediate X11 run passed inside the guest and shut down normally, but editing its running host script interrupted its final checksum step. An independent check matched every input to its pre-boot hash. The final X11 run above passed the complete entry point with the host script held fixed.
