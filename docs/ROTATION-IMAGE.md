# Y700 二代 Debian dev12.6 根文件系统更新

国行 TB320FC_PRC 的本地更新位于 `out/dev12.6-rotation/`。普通用户可用其中的 `rotation-update.qcow2` 和通用 dev12.5 的 `root.ext4`，在 Linux 电脑上重建完整的 dev12.6 根文件系统。配套的 U-Boot 和 EFI 启动分区来自 dev12.5。若从完整 tar 开始，请先按通用方式解包，取得下表中的基底文件。[dev12.5 解包说明](DEV12.5-IMAGE.md)

| 文件或清单 | 大小或数量 | SHA-256 |
| --- | ---: | --- |
| 通用 dev12.5 `root.ext4` | 6,442,450,944 字节 | `041fcf2e04b5d05edbfa3147f442a019d2f260f6544b9182087bf911ff8e55b6` |
| dev12.6 `rotation-update.qcow2` | 96,206,848 字节 | `d9f4ce243d8971699d77d66be0ba0d1cb049dcfc846079c6a48769f6d7c1cf3c` |
| 重建后的 dev12.6 ext4 | 6,442,450,944 字节 | `74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd` |
| dev12.6 `packages.tsv` | 1,115 项 | `a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98` |

## 从差分重建

准备 `qemu-img`、GNU coreutils 和 e2fsprogs。在有至少 6 GiB 可用空间的 Linux 文件系统中运行下面的 Bash 命令，先将前两个路径换成自己的位置。新建的临时目录保留输出；`updated.ext4` 即可单独复制使用。

```bash
(
  set -euo pipefail
  umask 077
  sealed=$(realpath -e -- /path/to/generic-dev12.5/root.ext4)
  delta=$(realpath -e -- /path/to/out/dev12.6-rotation)
  work=$(mktemp -d -- "$PWD/dev12.6.XXXXXXXX")
  cp -- "$delta"/* "$work/"
  cd -- "$work"
  echo 'cff4ea1e28567619a34a364b0a79d2a7e79d8e57ab3989d7210236d105a43997  SHA256SUMS' | sha256sum --strict -c -
  sha256sum --strict -c SHA256SUMS
  printf '%s  %s\n' "$(cat backing-root.sha256)" "$sealed" | sha256sum --strict -c -
  ln -s -- "$sealed" root.ext4
  qemu-img check -f qcow2 rotation-update.qcow2
  qemu-img convert -f qcow2 -O raw rotation-update.qcow2 updated.ext4
  printf '%s  updated.ext4\n' "$(cat new-root.sha256)" | sha256sum --strict -c -
  e2fsck -fn updated.ext4
  printf '%s/updated.ext4\n' "$PWD"
)
```

## 软件变化和验证

| 软件包 | dev12.5 → dev12.6 |
| --- | --- |
| `y700-platform` | `0.1.0~dev12.5` → `0.1.0~dev12.6`，自动旋转同时跟踪 logind 和 Xfce 锁屏状态 |
| `y700-camera-qcam` | `0.7.2-1~bpo13+1.y7003` → `0.7.2-1~bpo13+1.y7004`，三摄选择器显示镜头用途 |
| `libxss1` | 新增 `1:1.2.3-1+b3` |
| `xfce4-screensaver` | 新增 `4.18.4-1` |
| `y700-touch-lock` | 新增 `0.1.0`，配置锁屏时的触屏密码输入 |

构建程序在隔离的网络、PID 和挂载命名空间内操作基底副本。它核验平台包及相机 18 个、锁屏 3 个归档的输入，验证 dpkg、APT 和完整包清单。相机的 17 个运行库在两个版本中相同。通用根保留锁定的首次登录账户、空机器 ID 和上游签名的 Wi-Fi 监管数据库选择；检查覆盖蓝牙地址与配对、Wi-Fi 连接配置、SSH 主机密钥和设备校准数据。应用各自的实测范围见[相机](QCAM.md)和[锁屏](SCREEN-LOCK.md)。

在电脑上，基底、更新副本和重建镜像均通过只读 ext4 检查。构建还用 `qemu-img compare` 和 `cmp` 分别核验差分扇区和重建字节。另一轮以普通用户从 Windows 交付目录复制差分，重新链接只读基底、转换并校验完整镜像。离线收据位于 `out/dev12.6-rotation-verified/{build,ordinary-reconstruction}.log`。

## 从已锁定的软件包重新制作

准备可运行 ARM64 Debian 程序的 Linux 主机、root 权限、uv、qemu-img、e2fsprogs 和至少 13 GiB 临时空间。示例从仓库根目录运行，最后一个参数须为 Linux 文件系统内的新目录。构建会保留 `delta/` 中的可搬移更新和 `verified/updated.ext4` 中的只读完整镜像。重新运行 dpkg 时会生成新的文件系统时间戳，上表的字节摘要对应已交付的这一份。[构建脚本](../scripts/build-dev12.6-root.sh)

```bash
sudo env UV_BIN="$(command -v uv)" bash scripts/build-dev12.6-root.sh \
  /path/to/generic-dev12.5/root.ext4 out/platform-dev12.6/y700-platform_0.1.0~dev12.6_all.deb \
  out/camera-qcam-y7003-offline out/camera-qcam-y7004 out/touch-lock/archives \
  /var/tmp/y700-build-dev12.6
```
