# 为 dev12.10 根镜像预装 WPA3 密码重试更新

离线更新后的 ARM64 根镜像有 1,240 个已安装软件包。与原版 dev12.10 相比，`network-manager` 升至 `1.52.1-1+0y7001`，`wpasupplicant` 升至 `2:2.10-24+0y7001`。这两个项目构建的包以 Debian 13 源码为基础。四包归档同时提供按 Debian 签名索引校验的两个原版包。镜像内的全部已安装软件包元组摘要为 `2d180b436086b9015044bff4053c314de4b63bce4f5406baffcd1ebce79a67d8`。[更新与回退](WIFI-PASSWORD-RETRY.md) · [构建输入锁](../config/wifi-sae-update.lock.json)

## 从已封存的根镜像还原同一份副本

用 Linux 的 `xdelta3` 和 `sha256sum` 可以离线还原。准备从 dev12.10 完整归档解出的原版 `root.ext4`、5,515,075 字节的 `y700-dev12.10-wifi-root.vcdiff`，以及至少 6 GiB 空闲空间。以下命令在当前目录创建新的私有输出目录，打印路径后即可将其中的 `root.ext4` 用作预装了这两个包的通用构建输入。[原版解包步骤](DEV12.10-IMAGE.md)

```bash
set -euo pipefail
base=/path/to/dev12.10-images/root.ext4
delta=/path/to/y700-dev12.10-wifi-root.vcdiff
printf '%s  %s\n' \
  18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd "$base" \
  090fcf95244511bc731c13c1a325f25677504f78f0992557276fd82f8237bd6c "$delta" | sha256sum --strict -c -
dest=$(mktemp -d ./dev12.10-wifi.XXXXXXXX)
xdelta3 -d -s "$base" "$delta" "$dest/root.ext4"
printf '%s  %s\n' 0383703eac309a64e3febc286fa6c8d9fffb9c252745bb7b1647bde647a27ca0 \
  "$dest/root.ext4" | sha256sum --strict -c -
chmod 0444 "$dest/root.ext4"
printf '%s\n' "$dest/root.ext4"
```

开发机已解码完整差分并比对还原后 6,442,450,944 字节的 SHA-256。用只读挂载检查了机器标识为空、`y700` 账户锁定、没有机主网络配置、历史接入点、DHCP 租约、配对状态或 SSH 密钥。留存在根内的 `/var/lib/y700/build/wifi-sae-update.lock.json` 标记此次更新，独立验证器会拒绝收据被移除或更改的副本。既有板级试启与个性化脚本仍要求发布时的原始根摘要。

## 从已校验的软件包重新构建

在能运行 ARM64 Debian 程序的 Linux 主机上，将 `base` 指向原版封存根，`archive` 指向项目的四包 TAR，`new_root` 指向 Linux 文件系统中尚不存在的目录。构建程序会校验父镜像、TAR、四个包的哈希和候选包元数据，在隔离的副本中安装两个候选包，随后核对 dpkg 文件、依赖、全部继承收据、ARM64 软件包账本及文件系统。四包归档的 SHA-256 为 `bcea67e60aff2dcfa4f6354bef419610b602150da9db442d4089b3d5bb6eb18d`。[构建脚本](../scripts/update-sealed-root.sh)

```bash
sudo env UV_BIN="$(command -v uv)" bash scripts/update-sealed-root.sh \
  wifi-sae-update "$base" "$archive" "$new_root"
sudo cat "$new_root/inventory.log" "$new_root/identity-check.log" "$new_root/SHA256SUMS"
```

每次从包重建时 ext4 挂载时间和 dpkg 安装时间可能不同。该路径核对固定的软件包清单和载荷，每次产生的文件系统有各自的 SHA-256。
