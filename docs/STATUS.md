# Hardware and system status

Evidence through 2026-11-19 covers one TB320FC_PRC with 16 GiB RAM, 512 GB storage and the CN350 Android firmware. This is a pre-alpha development system.

| Area | Evidence / current status | Remaining acceptance |
| --- | --- | --- |
| Native boot/UFS | Physical Debian boot, expanded root filesystem, EFI chain; B slot successful/bootable confirmed | Repeated cold starts, recovery and update rollback |
| Display | Native 1600×2560 panel and Xfce desktop work. The PRC kernel exposed `ktz8866-backlight` with maximum 2047 and observed value 102 | Visible brightness changes, refresh modes, power transitions, external display |
| Touch | Portrait and left-rotated 2560×1600 manually confirmed; X11 mapping helper running | Other rotations, relogin/reboot persistence, suspend/resume, multitouch gestures |
| Wi-Fi | The saved Wi-Fi profile automatically activated and reached connected state in all three most recent physical boots. The current Wi-Fi interface returned all six gateway probes. Earlier tests confirmed DHCP, DNS, HTTPS and Chromium browsing | Touch-operated network selection, roaming, rejoin after loss of signal or suspend, longer stability and measured throughput |
| USB maintenance | ACM/NCM enumeration and key-authenticated SSH verified | Portable host setup, per-install credentials/identity, reconnect/resume coverage |
| Desktop basics | Temporary LightDM autologin started the real Xfce session. Onboard showed and hid over D-Bus. The tablet scale control opened on the 2560×1600 left-rotated screen | Touch-only enrollment and password login, finger interaction with applications, localization/IME and accessibility |
| Chromium | User confirmed websites with software rendering | Hardware acceleration without GPU faults, browser workload regression coverage |
| GPU | The original kernel hung in Xorg's FD730 glamor path. On separate tablet boots, the GMU queue-fix kernel completed 1,800.26 seconds of FD730 OpenGL and 1,800.20 seconds of Turnip Vulkan. The Vulkan run retained 870 submissions and 4,640 vblank samples, with a median of 120.005 Hz. The combined image selects that kernel | Browser, sensor and suspend interactions on the combined install, plus video acceleration and thermal evidence |
| Accelerometer/gyro | Dev7 installed on the tablet. Xfce has a per-user rotation lock and a SensorProxy client. The physical baseline reports SLPI offline and has no sensor provider | Enumerate real sensors, confirm axis and calibration, check all four orientations and touch alignment |
| Audio/microphone | Two-second playback completed on the real ALSA PCM and via the signed-in user's PipeWire default speaker sink with CS35L45 protection | Audible output from each side, microphone capture, everyday volume and suspend/resume |
| Bluetooth | The dev6 service verified the original WCN6855 address. Two independent BLE broadcasts delivered fresh 16-byte test payloads between tablet and computer, one in each direction | Actual keyboard and mouse pairing, key, pointer and scroll events, reconnect and resume |
| Battery/charging/thermals | Linux `qcom-battmgr-bat` reported Full and 100% with USB attached | Charging/discharging transitions, measurement accuracy, thermal policy, idle drain and sustained load |
| Suspend/wake/poweroff | No product acceptance | Repeated cycles, wake sources, USB/Wi-Fi/audio/touch recovery |
| Cameras | All three sensors delivered full-resolution RAW frames twice as `y700`, CPU RGB as the unprivileged active seat owner, and live Qt application viewfinder frames offscreen | Visible panel preview, finger-operated switching, still-image quality and desktop/browser access. [Per-camera evidence](CAMERA-SENSORS.md) |
| Video codecs/external I/O | No product acceptance | Hardware decode/encode, external displays and both USB interfaces |
| Updates/security/recovery | Experimental install plus local backups | Reproducible build, authenticated updates, rollback, credential provisioning and proven recovery |

The desktop keeps the current orientation by default. Platform dev7 lets the user opt in to automatic rotation in Settings. The GTK panel passed 100% and 200% scale tests in an ARM64 X11 fixture. The session client recovered from sensor removal, proxy replacement and screen locking on isolated D-Bus services. Physical portrait and left-landscape touch evidence comes from manual rotations. [Sensor integration and physical limits](CAMERA-SENSORS.md#xfce-screen-rotation)

No claim of complete hardware support, maximum performance, all-day battery life, production readiness or universal Y700 compatibility is made.

Candidate 03 now boots to systemd in the PC EFI tests. The trial entry and test card exercise the same kernel, initramfs and root in a two-disk simulation. The device currently runs the previous baseline. See the [candidate receipts and attended trial](BOARD-IMAGE.md).

The installed platform package progressed from dev2 on November 18 to dev7 on November 19. The dev6 to dev7 upgrade preserved the boot and the running LightDM, SSH and Bluetooth service invocations. A new USB SSH connection confirmed the ordinary greeter and the signed-out user's default rotation lock. The scale launcher follows external scale changes, and the Bluetooth helper checks the adapter again after asynchronous address installation. The private camera runtime and optional qcam were tested as separate packages on the existing tablet installation. [Platform updates](PLATFORM-BUILD.md) · [Current peripheral evidence](PERIPHERALS.md)

The [authenticated Debian snapshot stage](DEBIAN-SNAPSHOT.md) builds a 963-package ARM64 base including Debian's global ALSA UCM configuration. The base, 30 repair packages and platform dev5 produced the 994-package image tested under EFI/QEMU. The combined dev6 development build includes 1,050 packages, both touch keyboards, all three camera helpers, the private sensor firmware and the GPU queue fix. Physical image acceptance and refreshing the historical security snapshot remain open. [Image receipt](BOARD-IMAGE.md#combined-tablet-development-image)

The newer 1,069-package KMS image adds qcam and its 17 Debian dependencies plus a DRM enrollment package. Its ARM64 EFI boot matched the selected kernel, package list and live framebuffer-off setting. The camera streams, Bluetooth radio and earlier OpenGL/Vulkan results come from the existing physical installation. [KMS image and hashes](BOARD-IMAGE.md#kms-touchscreen-build)
