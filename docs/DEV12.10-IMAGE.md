# Y700 二代 Debian dev12.10 开发镜像

此版本面向国行联想 Y700 二代（TB320FC_PRC）。Debian 13 ARM64 根镜像预装 Xfce 触屏桌面、Parole `4.18.2-1+y7002` 和供该播放器使用的 Iris 解码插件。在文件管理器中点开 MP4 或 WebM 即可播放。播放器针对 200% 显示缩放加大了播放按钮和进度条的触控区域，并修复了拖动进度条时重复请求跳转的问题。[播放器修复与实机证据](VIDEO-CODEC-BOARD.md)

## 在电脑上解包

把发行目录中的 TAR、`packages.tsv` 和 `SHA256SUMS` 放在一起。在有 GNU tar、zstd、coreutils 和 Bash 的 Linux 电脑上准备至少 9 GiB 可用空间，运行以下命令。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.10.tar
cd y700-tb320fc-prc-debian-dev12.10
bash unpack.sh ../dev12.10-images
(cd ../dev12.10-images && sha256sum --strict -c SHA256SUMS)
```

输出包含板级 U-Boot、EFI 分区、6 GiB 的 ext4 根镜像和身份清单。通用镜像的首次登录通过屏幕键盘为 `y700` 账户设置密码。蓝牙控制器地址和传感器校准来自每台平板自己的原厂数据。[首次登录](FIRSTBOOT-TOUCH.md) · [按设备准备蓝牙和传感器数据](DEV12.6-IMAGE.md)

## 制作内存试用包

在项目源码目录下，将 `images` 指向上一步解出的镜像目录，选择一个新的输出目录。内存版使用同一个根文件系统、板级内核和设备树，临时改动随试用结束丢弃。

```bash
bash scripts/build-ram-trial.sh --dev12.10 "$images" dev12.10-ram-trial
(cd dev12.10-ram-trial && sha256sum --strict -c SHA256SUMS)
```

在现有平板上通过 USB 试用镜像内的软件时，平板沿用当前运行的内核。验证新内核在物理平板上独立启动，需要另做一次整机启动测试。[内存试用原理](DEV12.8-RAM-TRIAL.md)

## 从 dev12.9 重建

在支持运行 ARM64 Debian 程序的 Linux 主机上，将 `base` 指向解出的 dev12.9 镜像目录，`update` 指向已校验的 y7002 播放器更新归档。`new_root` 和 `output` 使用尚未创建的输出目录。根构建会验证输入，更新软件包账本，检查更新后的二进制文件，并封存文件系统。打包器独立检查根镜像内容。[dev12.9 基底](DEV12.9-IMAGE.md) · [更新归档校验信息](../config/video-player-update.lock.json)

```bash
sudo env UV_BIN="$(command -v uv)" bash scripts/update-sealed-root.sh \
    video-player-update "$base/root.ext4" "$update" "$new_root"
root_sha=$(sudo cut -d' ' -f1 "$new_root/SHA256SUMS")
sudo bash scripts/package-board-image.sh dev12.10 "$new_root/root.ext4" "$root_sha" \
    "$base/linux-boot.fat" 495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 \
    "$base/asphalt-prc-u-boot.img" "$output"
```

镜像包含 1,240 项已安装软件包。按软件包名、版本、架构排序后的清单 SHA-256 为 `ffb8818f1fd41efb3b7c7a14782abd62b37bf5dd687cfaa923d3419d785f51c3`。专用插件仅由 Parole 的启动器加载，其他应用继续使用 Debian 提供的系统插件。
