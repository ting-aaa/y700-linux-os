# Lenovo Legion Y700 Gen 2 (`TB320FC_PRC`) Full 9-Subsystem Hardware Verification & `dev13.0` Release Report

This report records the complete end-to-end physical hardware bring-up, objective automated measurements, clean-return verification, and unified `dev13.0` reproducible image packaging for the PRC Lenovo Legion Y700 Gen 2 (`TB320FC_PRC`, Qualcomm `SM8475`, Adreno 730, 16 GiB RAM / 512 GB UFS, stock Android CN350 background) performed on **2026-11-22**.

All evidence boundaries are kept strictly separate: **Source → Static / Build → ARM64 QEMU → Volatile Physical Trial (`hw-bringup-02`) → Packaged `dev13.0` Archive + QEMU Verification → Remaining Owner Hands-On Acceptance**. No raw logs, private keys, tokens, serial numbers, MAC/Bluetooth addresses, Wi-Fi SSIDs, `PARTUUID`s, or proprietary CN350 firmware blobs are included in this repository.

---

## 1. Unified Kernel & `dev13.0` Release Artifact Checksums

### Unified Full-Hardware Kernel Build (`hw-bringup-02`, `7.3.4-asphalt-prc`)

Built cleanly via [scripts/build-hw-bringup-kernel.sh](../scripts/build-hw-bringup-kernel.sh) in a private read-only OverlayFS mount over the pristine prepared Linux `7.3.4-asphalt-prc` tree (`vmlinux_abi_preserved=1`, 770 existing modules ABI-compatible, zero taint across all 15 new/updated modules in ARM64 QEMU).

| Artifact | SHA-256 |
| --- | --- |
| `kernel.efi` (`7.3.4-asphalt-prc`) | `c267245af7c92518510f8b39285b7c4b2981c04d3cd80baffe70c0dc37b81d7e` |
| `board.dtb` (unified full-hardware DT) | `5c568f3d379958a2f83376e4e9211d101f2334b4c1df4a2a6f1fefa5583b6866` |
| `board-diskless.dtb` (UFS/SD disabled) | `1b0842b060b25afa073e59ecad058e227d84af037aa561e86f290c9daa6030fc` |
| `notes` (`.notes` ELF build ID) | `6dc6eca53c5e1b184988e520d0e0ebca995c403667f1b7318fec6109ee7fbf95` |
| `Lenovo-Y700-tplg.bin` (AudioReach TX3 capture topology) | `aa6d0c1a904bafa20915528cae810ee08560d262f174c52465c386629e1b6422` |
| `drivers/input/misc/aw86927.ko` (170 Hz LRA) | `421022369162b7546c169a29c583ff259c00739806e8c107100325e9315d8a58` |
| `drivers/leds/flash/leds-qcom-flash.ko` | `e07b25ee23340079e4a4afe1817fd25dbeac7ff554fa1bef02a6d34b0a387afa` |
| `drivers/media/v4l2-core/v4l2-flash-led-class.ko` | `17b22738c706f9eb3a4cdf32b491a0989d1354748ebf22d18f8743b926031c97` |
| `drivers/soundwire/soundwire-qcom.ko` | `4c22f85e5e01255fd18b60c1abdd58873d6359b50d46a2456feb4b81aefa94f4` |
| `sound/soc/codecs/snd-soc-wcd938x.ko` | `505b45e8b2a4ceb10ee6b73653da30e7e3e6699f6a2efc54ad5aa8639b965eeb` |
| `sound/soc/codecs/snd-soc-wcd938x-sdw.ko` | `433fe5e398eb9da35dbaa302a7c404466c0d27806ef89cce77a14b9e589f9811` |
| `sound/soc/codecs/snd-soc-lpass-tx-macro.ko` | `ab9405969687e08f335a7e377d12bec5d993314af26a6b66c10d71c35a45f821` |
| `sound/soc/qcom/snd-soc-sc8280xp.ko` | `df114ca1c55e1ceb33ad50f803c94384646cdcc231124f7f73eb0d7c56b83e5d` |

### Packaged Standalone `dev13.0` Board Archive (Local Build, Generic First-Boot State)

Assembled cleanly via [scripts/build-dev13-image.sh](../scripts/build-dev13-image.sh) from the sealed `dev12.13` + `dev12.15` 1,248-package desktop base plus `hw-bringup-02` kernel, DTB, 15 modules, AudioReach TX3 topology, and fixed cold-boot ALSA UCM2, while preserving a fallback `dev12.15` EFI boot entry. Because the full board image contains device-extracted proprietary runtime firmware required to boot, the 1.4 GiB archive stays local (`out/dev13.0-board/`); all open-source patches, device-tree sources, UCM2 profiles, build scripts, and verification manifests are published on GitHub.

| Packaged Output | Size | SHA-256 |
| --- | ---: | --- |
| `y700-tb320fc-prc-debian-dev13.0.tar` | 1.4 GiB | `e65d0ecd532eecf9269a923a356339e7da9dc6240a8309e40a44d7bac39a191c` |
| `packages.tsv` (1,248 Debian 13 ARM64 packages) | 40 KiB | `8a4aced66e2947b07082c4b9988358f01673d617ab642bf1152e1ea275b69646` |
| `asphalt-prc-u-boot.img` | 41,406,464 B | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |
| `linux-boot.fat` (EFI FAT32, UUID `171A-4ADB`, `fsck.fat -n` clean) | 1,073,741,824 B | `c3df1c3d9b90dc031e8e0dd2f4eb6407e5d26269b64b426554f932f6f0dc9754` |
| `root.ext4` (ext4, UUID `171a4adb-916b-4763-9e6f-722b4a99988f`, `e2fsck -fn` clean) | 6,442,450,944 B | `b06fbfb68b8a11a9a71d7c71cf848c229270a129e9a749b49dbe3b4d11046ff2` |
| `identity.txt` (`image_version=dev13.0`, `fbdev_emulation=0`) | 326 B | `c88f9fd52a15af3ed022332714517f324fc05ad3cb287b8ac47499eb62c9bf1f` |

---

## 2. Complete 9-Subsystem Physical Hardware Verification Matrix

All measurements below were captured directly on the physical `TB320FC_PRC` tablet running `hw-bringup-02` in a volatile RAM-overlay trial (`boot_id=05c8e2d4-52c4-41b4-83d5-898e0d8c23b9`, `sda/ro=1`, `sda17/ro=1`) via [tests/hw-bringup/verify-all-9-subsystems.sh](../tests/hw-bringup/verify-all-9-subsystems.sh), with zero writes to internal UFS and verified clean return to daily `dev12.11`.

| # | Hardware Subsystem | Driver / Component | Physical Automated Measurement (`hw-bringup-02`) | Evidence Level | Remaining Owner Acceptance |
| --- | --- | --- | --- | --- | --- |
| 1 | **Display, Backlight & Adreno 730 GPU** | `msm_dpu`, `panel-novatek-nt36523`, `ktz8866-backlight`, Adreno 730 + GMU (`asphalt-hfi-match-queued-vote.patch`) | `DSI-1` connected (`1600x2560`, 118×190 mm); live X11 `xrandr` switched `120 Hz → 60 Hz → 120 Hz`; KTZ8866 stepped `429 → 449 → 429 / 2047`; OpenGL `freedreno` `FD730` `4.6` accelerated (`devfreq 220–862 MHz`, `GPU_HFI_ERRORS=0`); Turnip ICD present (`libvulkan_freedreno.so`). | **Physical Verified** | Visual check of 60/120 Hz fluidity, optical luminance in nits, sustained mixed load |
| 2 | **Touchscreen** | `novatek-nt36523n-spi` (`spi0.0`, `/dev/input/event5`) | Firmware `v0x1d`, PID `0x6066`, `16000×25600` 10-slot multitouch, `finger input ready`; cleanly re-initialized across live `120 ↔ 60 Hz` panel mode switches with zero SPI errors. | **Physical Verified** | Direct finger verification in right/inverted poses and multi-finger pinch/scroll on glass |
| 3 | **Wi-Fi** | Qualcomm `WCN6855` `ath11k_pci` (`wlp1s0`) | Associated & online (`wlp1s0:wifi:connected`), `6/6` gateway ICMP pings (`0%` loss, avg `16.5 ms`). Separate 2.4 GHz / 5 GHz ARP diagnosis (`tests/wifi-rejoin/arp-count.py`) confirmed tablet 2.4 GHz (`2437 MHz`) gateway ARP and `8/8` gateway ICMP pass 100%; cross-band L2 peer drop to a 5 GHz Windows host was isolated to AP cross-band policy and immediately recovered on returning to `5220 MHz`. | **Physical Verified** | Extended roaming stress and 6 GHz / hardware WPA3 AP testing |
| 4 | **Bluetooth** | Qualcomm `WCN6855` (`hci0`, QCA `BTFW.HSP.2.1.0`) | `UP RUNNING`, `Powered: yes`, `0` RX/TX errors; two 6-second live RF scans discovered **13–18 real nearby BLE/BR-EDR devices**. | **Physical Verified (RF + Scan)** | Real physical keyboard/mouse/headset pairing, HID input & A2DP audio |
| 5 | **Built-in Stereo Speakers** | Dual Cirrus Logic `CS35L45` (`7-0030`, `7-0031`, Protection DSP + factory calibration) | Enabled via production `alsaucm` (`Both factory records staged for the next Protection boot`); Left-only `1000 Hz` and Right-only `1500 Hz` playback independently verified acoustically by the tablet's dual internal mics with clear Left/Right stereo separation (`+60.9/+62.2 dB` Left, `+60.5/+58.1 dB` Right). | **Physical Verified (Acoustic)** | Subjective music/speech playback balance after cold boot of `dev13.0` |
| 6 | **Internal Dual Microphones** | `WCD9385` (`0x34b0=0x0a`) over SoundWire + `lpass-tx-macro` + AudioReach `TX_CODEC_DMA_TX_3` + PipeWire/WirePlumber UCM2 | **Major Breakthrough**: Fixed ASoC `"sleep"` pinctrl hard-reset bug ([asphalt-mic.dtsi](../config/kernel/asphalt-mic.dtsi)), TX SoundWire clock-rate bug (`0x3405=0x11` in `ADC_LP`, [asphalt-wcd938x-tx-clk-rate.patch](../config/kernel/asphalt-wcd938x-tx-clk-rate.patch)), and PipeWire cold-boot `SectionVerb` UCM2 probe bug ([HiFi-Mic.conf](../packaging/microphone/HiFi-Mic.conf)). `sdw:3` stayed `Attached` before, during, and after 5 s idle (`vreg_bob` untouched at `3.032 V`). Full-duplex `arecord` achieved `+60.9..+67.6 dB` SNR across idle reopen; unprivileged PipeWire `pw-record` on `alsa_input.platform-sound.HiFi__Mic__source` achieved `ch0_1k=258.8`, `ch1_1k=241.4` (`+68 dB`). Details: [MICROPHONE.md](MICROPHONE.md). | **Physical Verified (ALSA + PipeWire)** | Human voice recording clarity and post-suspend capture check |
| 7 | **Dual Vibration Motors (Haptics)** | Dual Awinic `AW86927` (`6-005a` Left `/dev/input/event3`, `8-005a` Right `/dev/input/event4`) | Both detected `chip_id=0x9270`, configured `8000 mV` (`vref=0x48`), loaded **141-sample `170.2 Hz` resonant LRA waveform** matching stock `f0_pre = 170.0 Hz` ([asphalt-aw86927-tb320fc.patch](../config/kernel/asphalt-aw86927-tb320fc.patch)). Acoustic 48 kHz measurement confirmed `+62.5/+65.9 dB` (`133.8 / 196.7`) for Left motor (`ch1` dominant) and `+68.5/+66.4 dB` (`266.6 / 209.0`) for Right motor (`ch0` dominant) vs `0.1` quiet baseline, with `AW86927_FAULTS=0`. Details: [HAPTICS.md](HAPTICS.md). | **Physical Verified (L/R Acoustic)** | Handheld tactile strength/sharpness confirmation |
| 8 | **3 Cameras, Rear AF VCM & Rear Flash LED** | `hi1339` (13 MP rear) + `gt9768` AF (`/dev/v4l-subdev30`), `s5k4h7` (8 MP front), `sc202cs` (2 MP macro), `PM8350C` `leds-qcom-flash` (`white:flash`) | `libcamera v0.7.2` enumerated all 3 cameras and captured 25 continuous frames each at ~30 fps (`7.64 MB`, `52.42 MB`, `31.88 MB` per frame). `gt9768` calibrated to TXD EEPROM range `360..605` and passed 6-point sweep (`360→420→480→540→605→480`) with exact readback. `white:flash` (`led-sources = <2>, <3>`, conservative `300 mA` torch / `1000 mA` flash) enabled at `64` and `128` with empty `flash_fault` (zero open/short/overcurrent) and measurable `hi1339` green-channel rise (`0.00 → 0.37`) even face-down on desk. Details: [CAMERA-FOCUS-FLASH.md](CAMERA-FOCUS-FLASH.md). | **Physical Verified (Streams + VCM + Zero-Fault Torch)** | Handheld camera photo sharpness, AF convergence on a bright target, and visual check of rear flash LED off the desk |
| 9 | **All Sensors (7 Native SLPI SSC Channels + `iio-sensor-proxy`) & Power/RTC** | `y700-ssc` (`sdsprpcd`), `iio-sensor-proxy`, `qcom-battmgr`, dual UCSI, `rtc-pm8xxx` (`/dev/rtc1`) | All **7 native SLPI SSC channels** delivered live readings on `hw-bringup-02`: **Accelerometer** (`5/5`, `x=-0.19, y=0.37, z=9.56 m/s²`), **Gyroscope** (`5/5`, `x=-0.0027, y=0.0062, z=-0.0043`), **Magnetometer** (`5/5`, `-61.8, -40.4, 70.9 μT`), **Ambient Light** (`5/5`, `5.39–5.67 Lux`), **Proximity** (`discovered`, `FAR`), **Compass/RotV** (`5/5`, `125.38°`), and **Hall (`BU52053NVX`)** (`discovered`, `FAR`). `monitor-sensor` confirmed `iio-sensor-proxy` live delivery (`Tilt: face-up`, `6.40 Lux`, `125.99°`). Bonus: `qcom-battmgr` (`100% Full`), dual UCSI USB-C ports active, `/dev/rtc1` (`rtc-pm8xxx`) active, thermal max `37.0 °C`. | **Physical Verified (All 7 Channels)** | Physical tilt in 4 directions (auto-rotate), cover proximity/light sensor, magnetic cover Hall `NEAR` trigger |

---

## 3. Permanent Daily `dev13.0` Installation & Owner Hands-On Acceptance (2026-11-22)

Following the volatile trial and ARM64 QEMU gates, the sealed `dev13.0` image was deployed permanently onto the reference `TB320FC_PRC` tablet as the default daily OS (`y700-file-13-0.conf`, expanded 32 GiB persistent `root.ext4`, user home/credentials migrated, earlier `dev12.11` preserved untouched on backing storage). During live cold-boot verification and hands-on owner testing, three additional real-world improvements were implemented and verified on the physical tablet:

1. **USB Maintenance Boot-Race Fix** ([src/usb/asphalt-usb-maintenance](../src/usb/asphalt-usb-maintenance), [packaging/root/usr/libexec/y700-usb-maintenance](../packaging/root/usr/libexec/y700-usb-maintenance)): Replaced `udevadm settle --timeout=10` (which could time out while the 15 newly enabled peripheral drivers probed concurrently at cold boot, delaying `ssh.service`) with a short non-fatal `udevadm settle --timeout=2 || true` followed by direct polling of `/sys/class/net/$iface/address`.
2. **Human Voice Microphone Gain Calibration** ([packaging/microphone/Mic.conf](../packaging/microphone/Mic.conf)): Raised the native `WCD9385` analog PGA (`ADC1/3 Volume` `6 → 18`, `+27 dB`) and `lpass-tx-macro` decimator gain (`TX_DEC2/5 Volume` `84 → 102`, `+18 dB`) in `ADC_NORMAL` mode to compensate for the absence of Android's QDSP6/ACDB post-gain stage. Live unprivileged PipeWire voice capture (`pw-record` → `pw-play`) moved from `-70 dBFS` RMS / `-55 dBFS` peak to **`-19.4 / -19.0 dBFS` RMS** and **`-2.4 / -0.1 dBFS` peak** across both channels (channel balance within `0.4 dB`), and the owner confirmed clear, natural voice playback.
3. **Orientation-Aware Stereo Speaker Routing** ([packaging/root/usr/libexec/y700-audio-orientation](../packaging/root/usr/libexec/y700-audio-orientation), [src/session/y700-display](../src/session/y700-display)): Verified that swapping `SPK1`/`SPK2` `DSP_RX1 Source` ↔ `DSP_RX2 Source` (`ASP_RX1` ↔ `ASP_RX2`) reverses physical Left/Right channels cleanly inside the `CS35L45` protection DSP with zero audio glitch (acoustic `ch0/ch1` ratio cleanly inverted `0.85 ↔ 1.29`) and persists across `pw-play` and idle cycles. Wired automatic orientation tracking into `y700-display` (`--rotate`, `--sync`, `--watch`) and a WirePlumber-ordered user service (`y700-audio-orientation.service`).

**Owner Hands-On Confirmation**: The owner tested and confirmed normal hands-on operation on permanent daily `dev13.0` across dual 170 Hz haptic motors, rear flash LED, stereo speakers (including orientation-aware L/R switching), dual internal microphones (live human voice record/playback), all 3 cameras + AF, display/touch, and sensors. Long-term multi-day battery/suspend soak testing remains ongoing in daily use.

---

## 4. Clean Return & ARM64 QEMU Verification Receipts

1. **Volatile Trial Clean Return (`hw-bringup-02` → daily `dev12.11`)**:
   - Returned cleanly to untouched daily `dev12.11` (`boot_id=3055fb7e-b04c-4e3b-b96c-3997020ba1d3`, `y700.hw_trial=none`), removed temporary staging directory `/run/initramfs/backing/y700-hw-bringup`, verified `/dev/loop0` (`rw`, `errors_count=0`), `/dev/sda17` (`rw`, `errors_count=0`), and all `1,248` installed packages intact.
2. **ARM64 QEMU Gate 1 — RAM-Overlay Boot (`tests/hw-bringup/qemu-verify.sh`)**:
   - `QEMU_OVERLAY_AND_RO_VERIFIED backing_unchanged=1 notes_match=1`, `QEMU_TAINT=0`.
3. **ARM64 QEMU Gate 2 — All-15-Modules Load/Unload (`tests/hw-bringup/qemu-insmod.sh`)**:
   - Loaded and unloaded `aw86927`, `v4l2-flash-led-class`, `leds-qcom-flash`, `soundwire-qcom`, `regmap-sdw`, all 5 `wcd938x` modules, all 4 `lpass-*` macro modules, and `snd-soc-sc8280xp` with `TAINT_AFTER_LOAD=0`, `TAINT_AFTER_UNLOAD=0`, `INSMOD_ALL_PASS=1`.
4. **ARM64 QEMU Gate 3 — Unpacked Standalone `dev13.0` Board Archive (`tests/hw-bringup/qemu-verify-dev13.sh`)**:
   - Verified `SHA256SUMS`, ran `unpack.sh --verify` and full `unpack.sh`, verified `fsck.fat -n`, `e2fsck -fn`, fallback `kernel-dev12.efi` + `debian-fallback.conf`, booted exact EFI `kernel.efi` against disposable `root.ext4`, verified `DEV13_NOTES=6dc6eca5...`, `IMAGE_VERSION=dev13.0`, `DEV13_HW_MANIFEST_OK=1`, `DEV13_UCM_VERB_OK=1`, `modprobe` across all 10 top-level hardware driver stacks, and `DEV13_TAINT=0` (`DEV13_STANDALONE_IMAGE_QEMU_VERIFIED=1`).

---

## 5. Reproducing Builds & Verification

```bash
# 1. Build unified full-hardware kernel + DTB + 15 loadable modules (as root on Linux/WSL)
sudo bash scripts/build-hw-bringup-kernel.sh "$PREPARED_LINUX_7_3_4" out/hw-bringup-02

# 2. Assemble standalone reproducible dev13.0 board archive from sealed dev12.13 + dev12.15
sudo bash scripts/build-dev13-image.sh \
    "$DEV1213_TAR" "$DEV1215_TAR" out/hw-bringup-02 "$TX3_TPLG" out/dev13.0-board

# 3. Verify unpacked dev13.0 archive in ARM64 QEMU
sudo bash tests/hw-bringup/qemu-verify-dev13.sh out/dev13.0-board

# 4. Run full 9-subsystem physical hardware verification suite on a booted Y700 tablet
sudo bash tests/hw-bringup/verify-all-9-subsystems.sh
```
