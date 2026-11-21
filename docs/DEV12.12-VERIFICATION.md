# dev12.12 开发镜像验证

本版将已在国行 TB320FC_PRC 实机上分别验证的桌面更新和双刷新率内核装入同一套通用镜像。参考机为 16 GiB / 512 GB 型号，日常桌面使用内置 dev12.11。[镜像使用说明](DEV12.12-IMAGE.md) · [实机电源键唤醒与自动旋转](DEV12.11-VERIFICATION.md#实体电源键解锁与旋转)

## 发行包与来源

在 Linux 或 WSL 使用随包的 `unpack.sh` 可以重建下表中的三个普通文件。TAR 大小为 1,449,779,200 字节。已从实际归档解包，对解压后的全部字节校验 SHA-256。

| 文件 | SHA-256 |
| --- | --- |
| `y700-tb320fc-prc-debian-dev12.12.tar` | `f3aece9924f3c6cf7ff9eeae2aca9714d05dd69aef3ba2f99d67a899f37a6c16` |
| `packages.tsv`（1,240 个软件包） | `ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047` |
| `asphalt-prc-u-boot.img` | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |
| `linux-boot.fat`（1 GiB） | `1f6d75c17b5f38ff69d57e13c671bd0c1cbccf0c74cf1ea3f79e2011445ed091` |
| `root.ext4`（6 GiB） | `5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3` |

从封存的 dev12.11 根离线升级。软件包清单中仅 `y700-platform` 变更为 `0.1.0~dev12.8+gpu1.2`。升级后的 38 个包文件、22 份继承的软件包锁、首次设密状态及通用身份均已核对。根文件系统通过只读 ext4 检查；EFI 分区两次独立构建逐字节一致。[桌面更新锁](../config/platform-desktop-update.lock.json) · [根镜像升级程序](../scripts/update-sealed-root.sh)

默认内核支持 60 和 120 Hz，备用项保留 dev12.11 原 120 Hz 内核。两项使用相同的设备树、initrd 和通用根。默认内核在本机上临时启动时做过两轮刷新率往返，60 Hz 测得 60.000 Hz。机主已实测手指拖动亮度、恢复亮度、电源键唤醒后的密码解锁及自动旋转。[刷新率与社区驱动来源](PANEL-REFRESH.md) · [实屏亮度](BRIGHTNESS.md)

底层显示驱动源自 dianqk 的 Asphalt 移植，包含 TB320FC 面板、背光及 SM8475 DSI PHY 支持。本项目在此基础上将国行面板的 60 Hz 时序接入 DRM。EFI 菜单使用 Boot Loader Specification 的 Type #1 文件分别指定内核、设备树及启动参数。[上游板级补丁](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0002-asphalt-display.patch) · [启动菜单规范](https://uapi-group.org/specifications/specs/boot_loader_specification/)

## 从归档启动桌面

从最终 TAR 解出的根与 EFI 经过虚拟 U-Boot 和 systemd-boot 启动。首次启动时先输入两次不一致的密码，账户仍锁定；两次一致后，通过屏幕键盘登录普通账户。虚拟机完整关机后启动新进程，复用同一个临时磁盘，系统跳过注册并接受原密码。两次启动的 ID 不同，均登录 Xfce、正常关机，最后复核输入镜像哈希。

两次均核对了 1,240 个软件包。从 Xfce 桌面入口按 200% 缩放打开亮度和图形设置，通过虚拟 Type-B 触屏将 Chromium 选项从关切到开，再切回关。随后用触屏关闭相机镜头选择器，由 Parole 显示 H.264 样片的三组预期色块。虚拟板使用自己的设备树，视频通过软件解码。收据 `out/dev12.12-board-verified/desktop.txt` 的 SHA-256 为 `bc1b32781a0cf0b1b8ba52626c58c76417dc97c8b3230462ca54787c6a7270bc`。[启动和桌面验收](../tests/combined-efi/README.md)

## 平板上的新版桌面

从此发行包将压缩根经 USB 流入板端 RAM，解压后在板端逐字节核对了完整 6 GiB 根镜像和安装清单。在实机 ARM64 CPU 上，用只读新根及独立的临时写入层启动普通账户的 Xfce、窗口管理器、面板和屏幕键盘。私有显示为 2560 × 1600，缩放 200%。

从桌面菜单打开亮度时，滑杆范围为 5–100%，尺寸为 377 × 56 逻辑像素。测试隔离了真实背光，窗口正确显示不可调。Chromium 复选框为 396 × 64 逻辑像素；普通账户开启加速、关闭窗口、重新打开后仍为开启，再触发可关闭。测试结束后比对了原启动、桌面、锁定、背光、SLPI、交换区和挂载状态，临时 RAM 文件与循环设备已释放。板上运行的内核来自日常的 dev12.11。精简收据为 `out/dev12.12-root/physical-ram-settings.log`，SHA-256 为 `f95352cd7db2b399e04e7ec8a1f28b09796ffe88ead02c44043f4e2b2c84979d`。

## microSD 试用包

测试机的 U-Boot 从内置 EFI 读内核；待 Linux 接管后才从卡槽挂载系统。电脑上的 `out/dev12.12-sd/` 含整卡镜像、两个内置菜单项所需的六个文件和实机校验脚本。请将整个目录视为一套。桌面的校准与蓝牙身份需按设备准备。[microSD 使用说明](../packaging/sd-trial/dev12.12.zh_CN.md) · [设备专属配置](DEV12.12-PER-UNIT.md)

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| `y700-test-card.img.zst` | 1,406,228,013 | `7c59a1843e2f07e7768e22e507e0d97ccc75a857bd4af683d16ac38392f412a5` |
| `y700-test-card.img`（解压后） | 7,519,338,496 | `630506ffdc329e327d40c7f7af83216562590d602e4ec1e1b0cbb4d39bc96631` |
| `trial-entry.tar.gz`（内置 EFI 补充件） | 43,681,267 | `5eace98fee5d57420a77e39473ac0268831ec8f527b98508940b87c0b8602d81` |

同一组输入两次生成了相同的整卡文件。制卡时为卡的 EFI 分区分配 FAT 序列号 `12DC-1212`，在卡根的 `fstab` 使用该序列号挂载 `/boot`，使用 GPT 标签 `y700-test-root` 指定根。启动时另核对同卡父设备、本版发行标识及桌面收据。这样同时插有相同通用 ext4 UUID 的内置盘时，两种内核都能定位到各自应使用的分区。[制卡程序](../scripts/build-test-card.sh) · [SD 启动检查](../src/boot/dev12.12-sd-init.patch)

两次双盘 ARM64 测试分别从模拟内置 EFI 选择普通和 120 Hz 兼容菜单项。内置盘使用 4096 字节扇区、卡使用 512 字节扇区，两者含相同的 ext4 UUID。两个内核的运行标识分别吻合，均从卡挂载根分区 `/dev/vdb2` 和 EFI 分区 `/dev/vdb1`，启动 systemd，核对 1,240 个包后正常关机。另三次测试使用同一根 UUID 的旧发行卡、FAT 序列号错误的卡以及空卡槽，试验入口均拒绝启动，自动重启后进入内置默认系统。测试机实际卡槽的冷启动仍待验证。[双盘测试](../tests/board-image-vm.sh) · [缺卡和错卡返回测试](../tests/sd-trial-return/run.sh)
