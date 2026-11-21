# 数字 USB 耳麦与麦克风

国行 Y700 二代的 dev12.13 原始内核启用了 USB 主机，构建配置中 `CONFIG_SND_USB_AUDIO` 关闭。数字 USB Audio Class 耳麦有自己的 ADC，接入时应当枚举独立 USB 声卡。可选包 `y700-usb-audio-modules` 追加 Linux ALSA 驱动和三个依赖，使用 Debian 自带的 WirePlumber 和 PipeWire。适用于带数字声卡的 USB-C 麦克风、耳麦或带 ADC 的转接器。[Linux USB 音频配置](https://github.com/torvalds/linux/blob/master/sound/usb/Kconfig)

原厂 CN350 设备树还描述了两路模拟 USB-C 音频开关（0x42、0x43）和 WCD 的 MBHC 耳麦检测。无源模拟转接器、内置 AMIC 仍依赖板载 WCD。可在原厂内核取得的具体 codec variant 和共享 BOB 电压容许范围仍待核实。社区的 asphalt USB/audio 补丁处理板级 USB 端口与扬声器路由。[板载麦克风调查](MICROPHONE.md) · [原始社区补丁](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0008-asphalt-usb-audio.patch)

## 安装与回退

本地文件 `out/usb-audio/release/y700-usb-audio-modules_7.3.4-1_arm64.deb` 共 211,648 字节。安装脚本通过 `/sys/kernel/notes` 限定下面两个实际启动过的内核，并检查每个模块名和已有文件归属。预期内核版本均为 `7.3.4-asphalt-prc`。

| 内核 | EFI 文件 SHA-256 | 运行时 notes SHA-256 |
| --- | --- | --- |
| dev12.13 常规 | `0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60` | `c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063` |
| dev12.13 120 Hz、既有日用 dev12.11 | `b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625` | `35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6` |

在存放软件包的目录运行。无 USB 音频外设时也可以验证模块加载与卸载。接入数字耳麦后可在桌面音量控制的输入设备列表选择该麦克风。

```sh
deb=y700-usb-audio-modules_7.3.4-1_arm64.deb
printf '%s  %s\n' 87450f08290edab544d0ac104f4b5475cc17212bb8a1d6342b711bb60c03ab8d "$deb" | sha256sum --strict -c -
sudo dpkg -i "./$deb"
dpkg -V y700-usb-audio-modules
sudo modprobe snd-usb-audio
test -d /sys/module/snd_usb_audio
cat /proc/asound/cards
```

回退时先关闭使用 USB 音频的应用并拔下数字耳麦，再执行下列命令。由 dpkg 删除本包文件并重新索引模块。无须重启或重载桌面音频服务。

```sh
for name in snd_usb_audio snd_usbmidi_lib snd_rawmidi snd_hwdep; do
    if [ -d "/sys/module/$name" ]; then sudo rmmod "$name" || exit 1; fi
done
sudo dpkg --purge y700-usb-audio-modules
```

软件包库存新增一行 `y700-usb-audio-modules 7.3.4-1 arm64`。dev12.13 的 1,241 项摘要 `5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098` 变为 1,242 项 `fb6dcd2c9f7aec2a970ae9f1a8768c0effdf610871ba72ffa313079df3aea94b`。日用 .11 对应的 .14 桌面包组合 `a652f024df73eb7386043cf11fa3fde1a1eb81a9f78a572c7bce808b0f1979fb` 新摘要为 `bdace256c575450952627840971d910231b0b6426f5e799310a93c98ca14ab27`。完整库存供核对，安装条件仅涉及内核与本包文件。

## 重建与验收

用现有已准备好的 ARM64 PRC 内核树运行。构建器核对原 Image、配置、vmlinux.o 和导出符号摘要，在独立上层编译。目标模块为 `snd-usb-audio`、`snd-usbmidi-lib`、`snd-hwdep` 和 `snd-rawmidi`。原内核已导出相应的媒体控制器分配符号。普通构建和加入测试用 VHCI 后的独立构建生成相同的 Debian 软件包。

```sh
sudo bash scripts/build-usb-audio-modules.sh "$prepared_kernel" "$new_output" --test-vhci
git clone https://github.com/jabezwinston/usbip-python.git "$new_peer_checkout"
bash tests/usb-audio/run.sh "$kernel_efi" "$dev1213_root_ext4" "$arm64_busybox" "$arm64_uv" \
    "$new_output" "$new_peer_checkout" "$new_log"
```

测试从已固定的外设源码提交导出 UAC1 设备描述符，在无网络与硬件透传的 AArch64 QEMU 中使用 Linux VHCI。虚拟耳麦生成 48 kHz、16 位、440 Hz 的单声道信号。普通用户分别通过 ALSA 和 PipeWire-Pulse 的独立 USB 输入节点校验 48,000 个样本，另检测播放节点。数据只在内存中处理。断开后设备节点消失。虚拟控制器以即时完成方式验证字节流，USB 实物、板端角色切换、实时音质与长期稳定性须用实际配件测量。[虚拟 UAC 实现](https://github.com/jabezwinston/usbip-python/blob/34d6fac0eb369e4a6238b4719036ab39743a9a93/usbip/classes/device/uac.py) · [ARM64 测试入口](../tests/usb-audio/run.sh)

两份正式板内核的完整回执在 `out/usb-audio/verified-primary.log`（SHA-256 `337d1c56bf3438a9c26554851efd4f1ccd09fbdf128bc16191a3fa350bdb8373`）与 `verified-compat.log`（`3966fd70d853d73749fb752824f4d11bf4e7f0c429205f0c8ad9ef7954c3f3e5`）。每份均验证原始系统只枚举 USB 设备、未知内核和无主文件被拒绝、无配件加载时零 PCM、接入后 udev 自动加载、普通用户经两种 API 得到 440 Hz（幅值 8000、240/840 Hz 对照均为 0）、拔下并卸载后库存摘要还原。早期虚拟对端曾发生 ALSA 读超时；最终对端预计算周期、限制应用读取周期，并以两次串行启动完成核验。此处尚无实体 USB 声卡及板上插拔的结果。

## 日用 dev12.11 板端安装

国行参考平板已验证无外设安装、加载、卸载、清除和重装。执行时停在 LightDM 登录界面。通过 USB SSH 核对 120 Hz 内核 notes、两层 ext4 和原库存，四个模块均从本软件包的路径加载。板载 LenovoY700 的两个播放 PCM 始终空闲，采集 PCM 始终为零。两只扬声器共八项混音设置相同，PipeWire 的 ALSA 输出节点、音频进程和四项系统服务均保持原状。全程未录音、播放或改变 USB 角色。

第一次清除恢复原 1,241 项和原摘要。随后发现单独执行 `modprobe -r snd-usb-audio` 会留下 `snd-rawmidi`，守卫已自动恢复原状。逐模块卸载后，最终重装留下 1,242 项，四个驱动文件已通过 dpkg 校验，模块在无配件时全部卸载，APT 依赖检查通过。精简证据见 [板端回执](../tests/usb-audio/physical-dev12.11.txt)；实际数字耳麦热插与传输仍待实物验证。

这台平板已在 `/var/lib/y700/updates/usb-audio-7.3.4-1/` 保留正式 .deb 和离线回退。下列命令校验本包内容、归属和运行内核，逐一移除已加载的本包模块，然后仅清除这个包。其他应用可以独立升级。

```sh
sudo bash /var/lib/y700/updates/usb-audio-7.3.4-1/rollback.sh
```
