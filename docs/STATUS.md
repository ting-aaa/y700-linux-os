# Hardware and system status

Baseline date: 2026-11-18. Scope: one TB320FC_PRC, 16 GiB RAM, 512 GB storage, original CN350 firmware background. Product status: pre-alpha development.

| Area | Evidence / current status | Remaining acceptance |
| --- | --- | --- |
| Native boot/UFS | Physical Debian boot, expanded root filesystem, EFI chain; B slot successful/bootable confirmed | Repeated cold starts, recovery and update rollback |
| Display | Native 1600×2560 panel and Xfce desktop work | Brightness, refresh modes, power transitions, external display |
| Touch | Portrait and left-rotated 2560×1600 manually confirmed; X11 mapping helper running | Other rotations, relogin/reboot persistence, suspend/resume, multitouch gestures |
| Wi-Fi | Real hotspot association, DHCP/DNS, 12 gateway probes without loss and 3 HTTPS successes; browser confirmed | GUI discovery issue, roaming, reconnect, longer stability and measured throughput |
| USB maintenance | ACM/NCM enumeration and key-authenticated SSH verified | Portable host setup, per-install credentials/identity, reconnect/resume coverage |
| Desktop basics | Terminal, Polkit agent, network applet, screen keyboard and time sync present | Unified touch UX, discoverable settings, notifications, localization/IME and accessibility |
| Chromium | User confirmed websites with software rendering | Hardware acceleration without GPU faults, browser workload regression coverage |
| GPU | GMU timeout / Adreno fault / hangcheck reproduced during desktop/browser use | Root cause, stable OpenGL/Vulkan, video acceleration, performance and thermal evidence |
| Accelerometer/gyro | Not accepted on Debian | Inventory actual sensors, driver/firmware interfaces, orientation service and calibration |
| Audio/microphone | Source/firmware recipe exists; current Debian operation not accepted | Playback, recording, routing, volume safety and suspend/resume |
| Bluetooth | Not accepted on current Debian | Discovery, pairing, keyboards/audio and reconnect/resume |
| Battery/charging/thermals | No product acceptance | Reporting, charging modes, thermal policy, idle drain and sustained load |
| Suspend/wake/poweroff | No product acceptance | Repeated cycles, wake sources, USB/Wi-Fi/audio/touch recovery |
| Cameras/video/external I/O | Unverified | Hardware inventory and explicit support or documented limitation |
| Updates/security/recovery | Experimental install plus local backups | Reproducible build, authenticated updates, rollback, credential provisioning and proven recovery |

The current display helper follows a display rotation chosen in Xfce; it is not accelerometer-based autorotation. Its autostart and saved landscape profile were configured but not re-tested across a new login/reboot in the baseline session.

PC development on 2026-11-18: the new platform package installs into a disposable ARM64 root and passes dependency, SSH configuration, unit and keyboard-setting checks. Sensor registry builds match across two runs; an opt-in observation-first X11 rotation bridge passes policy tests. None has been deployed to this tablet. Fresh read-only sensor inspection found SLPI offline and its firmware/SSC stack missing; exact IMU identity remains unconfirmed. See [platform build](PLATFORM-BUILD.md), [GPU investigation](GPU-INVESTIGATION.md) and [component map](HARDWARE-MAP.md).

No claim of complete hardware support, maximum performance, all-day battery life, production readiness or universal Y700 compatibility is made.

Candidate 03 now boots to systemd in the PC EFI tests. The trial entry and test card exercise the same kernel, initramfs and root in a two-disk simulation. The device currently runs the previous baseline. See the [candidate receipts and attended trial](BOARD-IMAGE.md).

The [authenticated Debian snapshot stage](DEBIAN-SNAPSHOT.md) now builds a fresh 962-package ARM64 base without copying the historical root. Integration with 30 repair packages and platform dev2 produced 993 packages and passed the same userspace checks. This historical snapshot requires a security refresh; kernel/image assembly and physical acceptance remain open.
