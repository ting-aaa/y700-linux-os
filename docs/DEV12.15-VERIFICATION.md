# dev12.15 发行验收

国行 TB320FC_PRC 的新安装根在 dev12.14 的 1,241 项软件包上增加 7 项。原有软件包的名称、版本、架构均保留。新增数字 USB 音频包、软件更新入口以及 Debian 的 PackageKit、GTK 更新选择器和相关库。安装文件通过一个增量 TAR 直接引用 dev12.13 完整基包。[安装说明](DEV12.15-IMAGE.md) · [七包与文件清单](../config/native-desktop.lock.json)

| 校验项 | SHA-256 |
| --- | --- |
| dev12.13 完整基包 | `60fc1e12b2ad707270bf722d90e72e32c030ae377a50a37130ecd4336aac1fb6` |
| dev12.15 增量 TAR，4,423,680 字节 | `3f388bd8a85d35e405d484ef11605d5ef6c089999690bb8856eaa4c424d6e340` |
| 6 GiB 通用根 | `a985dcd0c71b46ddc6f8d0af4882f84746f65800535ac4f5c76978286264dc84` |
| EFI FAT | `cdd0e35bf0d0cd859f521bf74fafa594388ea3093c33ea81c189da56cb3dea0d` |
| 身份清单，含 `package_count=1248` | `d2bebac147001bb1d62d6ef9cc5e05faa0045861021a94aa60be4a39cc3b8163` |
| 1,248 项包名、版本与架构 | `8a4aced66e2947b07082c4b9988358f01673d617ab642bf1152e1ea275b69646` |
| 根内 ARM64 dpkg 安装清单 | `3caad1e7069f76ba4ceecb7cab46518d2649508b6c1159abb0babaaad4ad51d0` |

## 原生安装与通用身份

构建器从精确的 dev12.14 根创建工作副本，以实际发行内核 `0c92b63a…` 启动无网络的 ARM64 QEMU。包内的原始 `preinst` 从该内核读取 `/sys/kernel/notes`，摘要为 `c53a4297…`。原生 dpkg 安装并配置全部七个包，完成 `depmod`，可解析 `snd_usb_audio` 及其依赖。软件包文件校验、`apt-get check`、`dpkg --audit` 和卸载后的 `e2fsck -fn` 均通过。五个 Debian 输入分别与签名软件源的包索引核对。[原生安装构建器](../scripts/build-native-desktop-root.sh) · [Debian 输入来源](../config/software-updates-debian.lock.json) · [两个适用内核](USB-AUDIO.md)

独立读取前后两份根的 dpkg 数据库，确认完整继承 1,241 项，七项新增。25 个继承的构建清单逐一相同。通用根没有已登记的用户密码、机器 ID、保存的 Wi-Fi 或蓝牙配对、SSH 私钥、扬声器或传感器单机校准。首次设密单元及 LightDM 图形登录保持启用。[只读复核](../tests/browser-camera-root/check.sh)

构建主机以原调用方式重新生成了 dev12.14 的整个 TAR，逐字节比对通过。新增的 `--dev12.15` 入口从签封根内的 ARM64 包清单计算条目数，再把条目数和软件包摘要写入 dev12.15 的身份文件。读回值分别是 1,248 和表中对应摘要。

从正式增量 TAR 以普通 Linux 用户身份解包，U-Boot、EFI、根和身份文件的 SHA-256 均匹配。用于 EFI 启动试验的三个引导及系统映像与最终解包结果逐字节核对相同。收据见 `out/dev12.15-verified/{unpack.log,independent.log,efi-input-readback.log}`。EFI 保留基包的 `dev12.13` 菜单标题，默认 `debian.conf` 选双刷新率内核，`debian-120.conf` 选备用内核，两项都加载同一份板级 DT 和 initrd。系统版本以根中的 `IMAGE_VERSION=dev12.15` 为准。

## ARM64 EFI 首次设密和图形登录

虚拟 U-Boot 经真实 EFI 加载器启动发行内核，使用 QEMU 虚拟机的设备树和屏幕。运行中的根报告 1,248 项、上述清单摘要与锁定的 y700 账户。通过虚拟 Type-B 触屏输入两次不同密码后，账户仍锁定。输入两次相同密码后进入 LightDM，再用屏幕键盘通过 PAM 登录普通用户的 X11/Xfce 会话。本次输入密码仅用于虚拟机的临时写层。[EFI 桌面验收入口](../tests/combined-efi/README.md)

同一会话通过顶栏快捷设置、相机选择器、本地 H.264 播放和带沙箱的 Chromium 渲染进程检查。虚拟机关机退出后，再次核对启动输入的 SHA-256。收据为 `out/dev12.15-verified/desktop.log`。生成及检验过程使用的临时完整根、EFI 副本和测试工作区均已清理。可分发目录 `out/dev12.15-board/` 仅含增量 TAR、`packages.tsv` 和校验清单。

## 实机 RAM 桌面

参考平板保留日用 dev12.11 内核，37 秒经 USB 把封存根送入 RAM。板端解压并校验完整 6 GiB 根与 1,248 项账本，再将根只读挂载，以 tmpfs 承接临时写入。普通账户在隔离的 2560 × 1600、200% Xfce 桌面运行 xfwm4、面板、xfdesktop、Onboard 和顶栏快捷设置。打开随根安装的“软件更新”后，程序在隔离会话缺少 PackageKit 后端且缓存为空时显示错误与“重试”，隐藏旧列表入口，可以正常关闭。设备的活动席位、系统服务、网络和挂载状态在试验前后一致。实机本次验收覆盖新根用户空间；完整 EFI 启动与首次设密由上一节的虚拟机覆盖。实机收据为 `out/dev12.15-verified/physical-desktop-ram.log`。[图形软件更新](SOFTWARE-UPDATES.md)

## 复核与重新组包

解包命令复原每个已封存的字节。由七个 Debian 包重新构建时，dpkg 和 ext4 会生成新的时间戳。以下命令中，`$primary_kernel` 是从正式 EFI FAT 提取的默认内核文件，`$busybox` 为构建器指纹锁定的静态 AArch64 BusyBox，`$debs` 存放七个指定版本的软件包。新输出均须位于具有足够空间的 Linux 文件系统上。

```bash
sudo env UV_BIN="$(command -v uv)" bash scripts/build-native-desktop-root.sh \
    "$dev1214_root" "$primary_kernel" "$busybox" "$debs" "$new_build"
sudo env UV_BIN="$(command -v uv)" bash tests/browser-camera-root/check.sh \
    --dev12.15 "$dev1214_root" "$unpacked_dev1215_root"
bash scripts/package-browser-camera-release.sh --dev12.15 "$dev1213_tar" \
    "$dev1213_root" "$unpacked_dev1215_root" "$new_release"
```
