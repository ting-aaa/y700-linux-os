# Y700 二代 Debian dev12.9 开发镜像

dev12.9 面向国行 TB320FC_PRC。完整镜像含 Debian 13 ARM64、Xfce 触屏桌面、板级 U-Boot、EFI 启动分区和 6 GiB 根文件系统。1,240 项已安装软件包中包含 Parole 和解码依赖，系统另带供 Parole 使用的 Y700 专用 GStreamer 插件。从文件管理器打开本地 MP4 或 WebM 即可启动播放器。平台包版本为 `0.1.0~dev12.8`。[播放器和实机硬解](VIDEO-CODEC-BOARD.md)

## 解包

在有 tar、zstd、coreutils 和 Bash 的 Linux 电脑上使用普通账户，准备至少 9 GiB 可用空间。将 TAR、`packages.tsv` 与外层 `SHA256SUMS` 放在同一目录。以下命令只在电脑上生成普通文件。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.9.tar
cd y700-tb320fc-prc-debian-dev12.9
bash unpack.sh ../dev12.9-images
(cd ../dev12.9-images && sha256sum --strict -c SHA256SUMS)
```

输出包括 `asphalt-prc-u-boot.img`、`linux-boot.fat`、`root.ext4` 和 `identity.txt`。首次开机的本地账户为 `y700`，由用户通过屏幕键盘设置密码。根文件系统沿用该系列的 UUID，把两个同 UUID 的系统同时接入启动环境前，需要由启动配置明确指定目标。[首次设密](FIRSTBOOT-TOUCH.md) · [按设备准备蓝牙身份和传感器校准](DEV12.6-IMAGE.md)

本批次通用 `root.ext4` 的 SHA-256 是 `e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb`。可以从以上解包结果直接生成带只读根和临时写层的内存试用包。此命令在电脑上运行，`dev12.9-ram-trial` 需为新目录。

```bash
bash scripts/build-ram-trial.sh --dev12.9 "$images" dev12.9-ram-trial
(cd dev12.9-ram-trial && sha256sum --strict -c SHA256SUMS)
```

内存发行物中的内核和板级设备树提取自同一份 EFI 分区。使用项目的 ARM64 虚拟设备树时，可通过 `RAM_TRIAL_VERSION=dev12.9 bash tests/ram-trial/run.sh "$ram_bundle" "$virt_dtb" "$new_logs"` 进行无盘启动测试。平板沿用当前内核的隔离桌面试用与独立内核启动是两项不同验证。[内存试用设计](DEV12.8-RAM-TRIAL.md)

## 构建

基底是 dev12.8 的封存通用根，SHA-256 为 `2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511`。新版使用相同的板级启动文件，增加 116 个 Debian 软件包并安装专用启动器。已安装包清单的 SHA-256 为 `89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d`。媒体文件锁还包含桌面入口、插件、上游许可证及 Debian 原文件的摘要。[基底镜像](ADAPTIVE-BRIGHTNESS-IMAGE.md) · [播放器归档的构建与校验](VIDEO-PLAYER-INTEGRATION.md) · [媒体文件锁](../config/video-player.lock.json)

在能运行 ARM64 Debian 程序的 Linux 主机上，用 `base` 指向解包的 dev12.8 镜像目录，`media` 指向通过校验的播放器归档。`new_root` 和 `output` 是尚未创建的 Linux 输出目录。根镜像构建需要 root 权限。打包使用 e2fsprogs、dosfstools、jq、zstd、dpkg、coreutils 和 GNU tar，并独立核对软件包清单、镜像内的媒体文件、锁定账户和文件系统。

```bash
sudo env UV_BIN="$(command -v uv)" bash scripts/update-sealed-root.sh \
    video-player "$base/root.ext4" "$media" "$new_root"
root_sha=$(sudo cut -d' ' -f1 "$new_root/SHA256SUMS")
sudo bash scripts/package-board-image.sh dev12.9 "$new_root/root.ext4" "$root_sha" \
    "$base/linux-boot.fat" 495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 \
    "$base/asphalt-prc-u-boot.img" "$output"
```
