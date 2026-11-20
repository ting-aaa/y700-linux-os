# 拯救者 Y700 二代 Debian 平板镜像 dev12.6

本地开发包适用于国行联想 TB320FC_PRC。在 Linux 电脑上，普通用户可以从一个 TAR 解出板级 U-Boot、EFI 启动分区和完整的 Debian 13 ARM64 根文件系统。归档包含开机所需的三个镜像，解包无需联网或另行下载旧版本。

dev12.6 包含 1,115 个已安装软件包。Xfce 顶栏的账户菜单提供锁屏入口，解锁对话框内置 Onboard 触屏键盘。启用自动旋转时，桌面客户端会在锁屏期间释放加速度计，解锁后再读取当前方向。相机选择器区分后置主摄、前摄和微距。通用镜像保留首次设置账户密码的流程，蓝牙地址、设备配对和出厂校准按设备单独准备。

## 在电脑上校验和解包

将 `y700-tb320fc-prc-debian-dev12.6.tar` 和随附的 `SHA256SUMS` 放入同一目录，准备 Bash、GNU coreutils、GNU tar 和 zstd。以普通账户在至少还有 9 GiB 空闲空间的 Linux 文件系统内运行下列命令。归档目录和最后的镜像目录均使用新路径。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.6.tar
cd y700-tb320fc-prc-debian-dev12.6
bash unpack.sh --verify
bash unpack.sh ../dev12.6-images
(cd ../dev12.6-images && sha256sum --strict -c SHA256SUMS)
```

| 解包产物 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `asphalt-prc-u-boot.img`，国行板级 U-Boot | 41,406,464 | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |
| `linux-boot.fat`，沿用 dev12.5 的 Debian EFI 分区，包含内核、设备树和 initramfs | 1,073,741,824 | `495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6` |
| `root.ext4`，dev12.6 通用根文件系统 | 6,442,450,944 | `74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd` |

`identity.txt` 记录根分区 UUID、镜像标识和包清单摘要。按包名、版本和架构排序的完整清单摘要为 `a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98`。随包的平台版本为 `0.1.0~dev12.6`，相机应用版本为 `0.7.2-1~bpo13+1.y7004`，Xfce 锁屏组件版本为 `4.18.4-1`。这些解包命令的终点是电脑上的镜像文件。整套镜像在平板上冷启动、用手指完成首次设置以及实体蓝牙键鼠输入仍待实测。

## 可选：为一台平板配置原厂蓝牙地址

在权限仅限自己的 Linux 目录中保存该机的原厂 Android 属性记录。另备 uv、Python 3 和 e2fsprogs。以下命令从展开的归档目录运行，`/private/` 替换为自己的私有目录。

```bash
umask 077
uv run --offline --no-project --python /usr/bin/python3 python prepare-bluetooth-identity.py \
  --getprop /private/this-tablet-getprop.txt --output /private/this-tablet-address
bash unpack.sh --bluetooth-address /private/this-tablet-address ../dev12.6-personal
(cd ../dev12.6-personal && sha256sum --strict -c SHA256SUMS)
```

个性化目录的 `root.ext4` 包含该机地址。`SHA256SUMS` 对应个性化结果，`UNPERSONALIZED-SHA256SUMS` 保留通用镜像校验值。

## 从三个原始文件重新打包

在项目仓库根目录准备 Bash、GNU coreutils、GNU tar、zstd、dpkg-query、e2fsprogs、util-linux 和 dosfstools。将三个输入路径替换为上表对应的文件，并选择一个尚未创建的输出目录。固定 TAR 时间戳为 2026-11-20 00:00 UTC。

```bash
SOURCE_DATE_EPOCH=1795132800 bash scripts/package-board-image.sh dev12.6 \
  /path/to/root.ext4 74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd \
  /path/to/linux-boot.fat 495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 \
  /path/to/asphalt-prc-u-boot.img /path/to/new-output
```
