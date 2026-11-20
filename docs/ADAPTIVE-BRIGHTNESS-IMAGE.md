# Y700 二代 Debian dev12.8 开发镜像

本地完整归档面向国行 TB320FC_PRC。它包含板级 U-Boot、EFI 启动分区和 6 GiB 的 Debian 13 ARM64 根文件系统。dev12.8 带有可选的自动亮度，默认关闭。它继承 dev12.7 的电池指示、触屏设密、屏幕键盘以及更新后的 Blueman 配对界面。

## 在电脑上解包

准备 Linux、Bash、GNU tar、coreutils、zstd 和至少 9 GiB 可用空间。将 `out/dev12.8-board/` 中的 TAR 和 `SHA256SUMS` 放入同一目录，以普通用户运行以下命令。

```bash
set -e
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.8.tar
cd y700-tb320fc-prc-debian-dev12.8
bash unpack.sh ../dev12.8-images
(cd ../dev12.8-images && sha256sum --strict -c SHA256SUMS)
```

输出包含 `asphalt-prc-u-boot.img`、`linux-boot.fat`、`root.ext4` 和 `identity.txt`。本次交付的通用 `root.ext4` SHA-256 为 `2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511`。镜像使用锁定的初始账户和空机器 ID。第一次图形登录通过触屏设置密码。如果需要为目标平板准备蓝牙身份或传感器校准，使用该平板自己的资料。仓库内的 `docs/DEV12.6-IMAGE.md` 给出了设备专属配置步骤。

## 构建输入

封存基底是更新过 Blueman 的 dev12.7 根镜像，SHA-256 为 `869745fbe9e9eacb2eb981731b2b8bc6ad162756282a2244f297063a7f79a5a4`。在这份镜像的 1,124 项包清单中，将 `y700-platform` 从 `0.1.0~dev12.6` 更新至 `0.1.0~dev12.8` 后得到清单摘要 `a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84`。基底和新版本使用同一板级 U-Boot（`f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8`）及 EFI 分区（`495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6`）。[基底重建步骤](BLUEMAN-UPDATE.md) · [平台软件包归档锁](../config/platform.lock.json)

在可运行 ARM64 Debian 程序的 Linux 电脑上，从仓库根目录执行。用 `base` 指定解包出来的旧版 U-Boot/EFI 所在目录，`previous` 指向上面摘要的基底。目标输出目录须尚未存在。单独传入最终平台包所在目录，其中只放这一份 `.deb`。

```bash
set -eu
work=$(mktemp -d /var/tmp/y700-dev12.8.XXXXXXXX)
sudo env UV_BIN="$(command -v uv)" bash scripts/update-sealed-root.sh platform \
  "$previous" out/platform-dev12.8 "$work/root"
digest=$(sudo cut -d' ' -f1 "$work/root/SHA256SUMS")
sudo bash scripts/package-board-image.sh dev12.8 "$work/root/root.ext4" "$digest" \
  "$base/linux-boot.fat" 495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 \
  "$base/asphalt-prc-u-boot.img" "$work/standalone"
```

镜像的 `base/RAW-SHA256SUMS` 给出该批次三个原始镜像的摘要。重新运行 dpkg 会生成新的 ext4 时间戳；验证软件内容时使用归档锁、完整包清单和文件校验。

独立核对旧根文件系统时，`scripts/verify-image-packages.py` 对 dev12.5 继续使用 `--sealed-dev12-5 --qcam-lock tests/onboard-image/camera-qcam.lock.json`，对原 dev12.6 和 dev12.7 继续使用 `--sealed-blueman-y7001`。dev12.7 的 Blueman y7002 更新版使用 `--platform-version '0.1.0~dev12.6'`，dev12.8 使用当前默认版本。四个旧根的封存清单均通过复核，旧 dev12.7 TAR 从原始三份镜像再次打包后逐字节一致。

## 验证范围

ARM64 虚拟机测试使用发布根的只读基底和临时写层，在 `tests/combined-efi/run.sh` 上选择 `POWER_DESKTOP=1 BLUEMAN_UPDATE=1`。来宾核对平台包、安装收据和全部软件包，并从虚拟 Type-B 触屏进入普通用户的 Xfce 桌面。登录后检查该用户启动了自动亮度客户端且 `org.y700.tablet automatic-brightness` 保持 `false`。环境光照变化与真实屏幕亮度需要在配备传感器和背光的平板上测量。电脑端收据在 `out/dev12.8-board-verified/`。
