# dev12.7 蓝牙配对界面更新

已经解包通用 dev12.7 镜像的用户，可以在 Linux 电脑上应用 32.3 MiB 差分。新镜像使用 `blueman 2.4.4-1+y7002`，用于修正配对输入框和键盘配对码通知的生命周期。1,124 个软件包中只有 Blueman 版本发生变化。启动时使用原 dev12.7 的 U-Boot 和 EFI 分区。[dev12.7 通用镜像](DEV12.7-IMAGE.md) · [配对界面与测试](BLUEMAN-PAIRING.md)

| 内容 | SHA-256 |
| --- | --- |
| 通用 dev12.7 的 `root.ext4` | `dd885eb7bc88e3fb87b0567ff7f382afbe079363910d6f0fd5b4bb41935e220a` |
| `out/dev12.7-blueman/blueman-update.qcow2`（33,882,112 字节） | `71c8f57d1e35114068dedd9d7b516f0a4fe2e679499c4c0a0d647d9113175624` |
| 重建的 `updated.ext4`（6,442,450,944 字节） | `869745fbe9e9eacb2eb981731b2b8bc6ad162756282a2244f297063a7f79a5a4` |
| 已安装包名、版本、架构排序清单 | `685d01f30932a5dd7df5ccbf99c66f3908e29c5cdeda2b7abe91d727f9c09511` |
| `blueman_2.4.4-1+y7002_arm64.deb`（1,050,192 字节） | `4fbb2eb45426a10620e75943f359715adec921fdc71e5d976f807f3295756367` |

## 从差分重建

在 Linux 上准备 qemu-utils、coreutils、e2fsprogs 和至少 6 GiB 空间。下面的命令使用普通用户权限，两个输入路径请替换为本机的实际位置。

```bash
(
  set -eu
  umask 077
  base=$(realpath -e /path/to/generic-dev12.7/root.ext4)
  delta=$(realpath -e /path/to/out/dev12.7-blueman)
  work=$(mktemp -d "$PWD/blueman-root.XXXXXXXX")
  cd "$work"
  cp "$delta/blueman-update.qcow2" .
  echo '71c8f57d1e35114068dedd9d7b516f0a4fe2e679499c4c0a0d647d9113175624  blueman-update.qcow2' | sha256sum --strict -c -
  ln -s "$base" root.ext4
  echo 'dd885eb7bc88e3fb87b0567ff7f382afbe079363910d6f0fd5b4bb41935e220a  root.ext4' | sha256sum --strict -c -
  qemu-img check -f qcow2 blueman-update.qcow2
  qemu-img convert -f qcow2 -O raw blueman-update.qcow2 updated.ext4
  echo '869745fbe9e9eacb2eb981731b2b8bc6ad162756282a2244f297063a7f79a5a4  updated.ext4' | sha256sum --strict -c -
  e2fsck -fn updated.ext4
  printf '%s/updated.ext4\n' "$PWD"
)
```

## 从 Debian 包构建

在可运行 ARM64 Debian 程序的 Linux 构建机上，可以用以下命令由同一基底制作更新。原始 Debian 包的摘要来自发行版的签名索引；本地补丁和构建出的 ARM64 包由仓库的构建脚本与归档锁关联。构建程序在私有网络、PID 和挂载命名空间内修改副本，对比原始和最终的包清单，检查 APT 依赖、dpkg 状态、Blueman 文件、配对数据目录和 ext4。重新运行 dpkg 会生成新的文件系统时间戳。[构建脚本](../scripts/build-blueman-passkey.sh) · [归档锁](../config/blueman.lock.json)

```bash
sudo env UV_BIN="$(command -v uv)" bash scripts/build-power-root.sh --blueman-update \
  /path/to/generic-dev12.7/root.ext4 out/blueman-passkey-lifetime /var/tmp/new-blueman-root
```

对旧镜像运行 `scripts/verify-image-packages.py` 时，dev12.6 和原 dev12.7 选择 `--sealed-blueman-y7001`；dev12.5 使用原来的 `--sealed-dev12-5 --qcam-lock tests/onboard-image/camera-qcam.lock.json`。更新镜像使用默认 Blueman 锁。三份旧镜像和更新镜像各自的完整清单均已在只读挂载下复核。

## 已验证的交付路径

普通用户从本地 dev12.7 TAR 解包，复制交付目录中的差分再重建 `updated.ext4`。逐字节比较与五阶段 `e2fsck -fn` 均通过。Blueman 的 `BluezAgent.py` 与锁定归档内的文件也逐字节对应，SHA-256 为 `ff0b74f998c7e4e063043fc7e79546e5bb38b46603fe2e6540a4c803e1d6230d`。

电脑上的 ARM64 QEMU 从 U-Boot/EFI 启动该根镜像，使用一次性写层。来宾检查 1,124 项清单与 Blueman 安装收据，使用虚拟 Type-B 触屏完成首次设密、登录界面的屏幕键盘输入和 PAM 认证。普通用户进入 Xfce 后，Onboard、顶栏音量插件、Xfce 电源管理器和 UPower 均通过检查，QEMU 正常关机。该启动测试中的虚拟机没有蓝牙射频设备。复测选择 `POWER_DESKTOP=1 BLUEMAN_UPDATE=1`。[EFI 测试](../tests/combined-efi/README.md)

本地收据位于 `out/dev12.7-blueman-verified/`，包括 `historical.log`、`changed.tsv`、`extraction.log` 和 `efi-boot.log`。
