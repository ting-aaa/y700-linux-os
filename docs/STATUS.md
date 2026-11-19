# Hardware and system status

Evidence through 2026-11-19 covers one TB320FC_PRC with 16 GiB RAM, 512 GB storage and the CN350 Android firmware. This is a pre-alpha development system.

| Area | Evidence / current status | Remaining acceptance |
| --- | --- | --- |
| Native boot/UFS | Physical Debian boot, expanded root filesystem, EFI chain; B slot successful/bootable confirmed | Repeated cold starts, recovery and update rollback |
| Display | Native 1600×2560 panel and Xfce desktop work. The PRC kernel exposed `ktz8866-backlight` with maximum 2047 and observed value 102 | Visible brightness changes, refresh modes, power transitions, external display |
| Touch | Portrait and left-rotated 2560×1600 manually confirmed; X11 mapping helper running | Other rotations, relogin/reboot persistence, suspend/resume, multitouch gestures |
| Wi-Fi | Real hotspot association, DHCP/DNS, 12 gateway probes without loss and 3 HTTPS successes; browser confirmed | GUI discovery issue, roaming, reconnect, longer stability and measured throughput |
| USB maintenance | ACM/NCM enumeration and key-authenticated SSH verified | Portable host setup, per-install credentials/identity, reconnect/resume coverage |
| Desktop basics | Temporary LightDM autologin started the real Xfce session. Onboard showed and hid over D-Bus. The tablet scale control opened on the 2560×1600 left-rotated screen | Touch-only enrollment and password login, finger interaction with applications, localization/IME and accessibility |
| Chromium | User confirmed websites with software rendering | Hardware acceleration without GPU faults, browser workload regression coverage |
| GPU | The original kernel hung in Xorg's FD730 glamor path. On separate tablet boots, the GMU queue-fix kernel completed 1,800.26 seconds of FD730 OpenGL and 1,800.20 seconds of Turnip Vulkan. The Vulkan run retained 870 submissions and 4,640 vblank samples, with a median of 120.005 Hz. The combined image selects that kernel | Browser, sensor and suspend interactions on the combined install, plus video acceleration and thermal evidence |
| Accelerometer/gyro | Not accepted on Debian | Inventory actual sensors, driver/firmware interfaces, orientation service and calibration |
| Audio/microphone | Two-second playback completed on the real ALSA PCM and via the signed-in user's PipeWire default speaker sink with CS35L45 protection | Audible output from each side, microphone capture, everyday volume and suspend/resume |
| Bluetooth | The dev6 package's enabled service verified the original WCN6855 address on the tablet. The powered controller received a random 16-byte payload over the air from the host computer's Bluetooth radio | Actual keyboard and mouse pairing, key, pointer and scroll events, reconnect and resume |
| Battery/charging/thermals | Linux `qcom-battmgr-bat` reported Full and 100% with USB attached | Charging/discharging transitions, measurement accuracy, thermal policy, idle drain and sustained load |
| Suspend/wake/poweroff | No product acceptance | Repeated cycles, wake sources, USB/Wi-Fi/audio/touch recovery |
| Cameras | All three sensors delivered full-resolution RAW frames twice as `y700`, CPU RGB as the unprivileged active seat owner, and live Qt application viewfinder frames offscreen | Visible panel preview, finger-operated switching, still-image quality and desktop/browser access. [Per-camera evidence](CAMERA-SENSORS.md) |
| Video codecs/external I/O | No product acceptance | Hardware decode/encode, external displays and both USB interfaces |
| Updates/security/recovery | Experimental install plus local backups | Reproducible build, authenticated updates, rollback, credential provisioning and proven recovery |

The current display helper follows a display rotation chosen in Xfce; it is not accelerometer-based autorotation. Its autostart and saved landscape profile were configured but not re-tested across a new login/reboot in the baseline session.

PC development on 2026-11-18: the platform package passed dependency, SSH configuration, unit and keyboard-setting checks in a disposable ARM64 root. Sensor registry builds matched across two runs; an opt-in X11 rotation bridge passed policy tests. Both sensor components remain PC-only. Read-only sensor inspection found SLPI offline and its firmware/SSC stack missing; exact IMU identity remains unconfirmed. See [platform build](PLATFORM-BUILD.md), [GPU investigation](GPU-INVESTIGATION.md) and [component map](HARDWARE-MAP.md).

No claim of complete hardware support, maximum performance, all-day battery life, production readiness or universal Y700 compatibility is made.

Candidate 03 now boots to systemd in the PC EFI tests. The trial entry and test card exercise the same kernel, initramfs and root in a two-disk simulation. The device currently runs the previous baseline. See the [candidate receipts and attended trial](BOARD-IMAGE.md).

The installed platform package progressed from dev2 on November 18 to dev6 on November 19. The dev5 to dev6 upgrade preserved the running login manager and the boot ID. The scale launcher follows external scale changes, and the Bluetooth helper checks the adapter again after asynchronous address installation. The private camera runtime and optional qcam were tested as separate packages on the existing tablet installation. [Original dev2 installation](PLATFORM-BUILD.md#connected-tablet-package-check-2026-11-18) · [Current peripheral evidence](PERIPHERALS.md)

The [authenticated Debian snapshot stage](DEBIAN-SNAPSHOT.md) builds a 963-package ARM64 base including Debian's global ALSA UCM configuration. The base, 30 repair packages and platform dev5 produced the 994-package image tested under EFI/QEMU. The combined dev6 development build includes 1,050 packages, both touch keyboards, all three camera helpers, the private sensor firmware and the GPU queue fix. Physical image acceptance and refreshing the historical security snapshot remain open. [Image receipt](BOARD-IMAGE.md#combined-tablet-development-image)
