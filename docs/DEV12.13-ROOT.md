# dev12.13 通用根文件系统

dev12.13 在封存的 dev12.12 Debian 13 ARM64 根上升级相机、蓝牙管理器和 IBus，新增 Xfce 触屏快捷设置。完整包数为 1,241。相机的实际安装文件 `/opt/y700-camera/bin/qcam` SHA-256 为 `2f0ac49c949273142cda696bb195d405add209c538e2fea7505a2bc87227af92`，与日用参考机的方向修复一致。[相机方向](CAMERA-ORIENTATION.md) · [快捷设置](QUICK-SETTINGS.md)

| 软件包 | dev12.12 | dev12.13 |
| --- | --- | --- |
| `y700-camera-qcam` | `0.7.2-1~bpo13+1.y7005` | `0.7.2-1~bpo13+1.y7008` |
| `blueman` | `2.4.4-1+y7002` | `2.4.4-1+y7003` |
| `ibus` | `1.5.32-2` | `1.5.32-2+0y7001` |
| `y700-quick-settings` | 新增 | `0.1.0` |

封存的 `root.ext4` 为 6,442,450,944 字节，SHA-256 为 `6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c`。ARM64 原生 `packages.tsv` SHA-256 为 `3d77058cde509e6f3256f332d4a2469d9448490ce6628001defdadd08711b5b8`。按软件包名、版本与架构排序的元组清单 SHA-256 为 `5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098`。[归档与载荷锁](../config/tablet-desktop.lock.json)

## 从 dev12.12 构建

在可执行 ARM64 用户态的 Linux 主机上运行。用 `$dev1212_root` 指定 SHA-256 为 `5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3` 的 dev12.12 根。将锁中四个精确的 Debian 包放入 `$debs`。输出目录 `$result` 由构建器创建，父目录需有至少 6 GiB 空闲空间。构建器校验输入根与归档并向稀疏副本写入。新构建的 ext4 和安装日志带有当次时间戳。

```sh
sudo env UV_BIN="$(command -v uv)" bash scripts/update-sealed-root.sh \
    tablet-desktop "$dev1212_root" "$debs" "$result"
sudo env UV_BIN="$(command -v uv)" bash tests/tablet-desktop-root/check.sh \
    "$dev1212_root" "$result"
```

输出目录包含根镜像、`SHA256SUMS`、`packages.tsv`、`tablet-desktop.lock.json` 及构建日志。镜像内的 `/var/lib/y700/build/` 保留 23 个旧锁，并记录本次四包的归档和文件哈希。构建器检查四包的 416 个普通文件和两个链接，以及登记的属主和权限。另运行 `dpkg --verify`、`dpkg --audit`、`apt-get check` 和卸载后的 `e2fsck -fn`。

只读复核重新挂载两个封存根，比较原有板级软件包和 `/opt`、`/usr/local` 中的载荷。21 个沿用的定制软件包及本地运行时共核对 866 个文件和链接。图形首启设密仍已启用，通用账户处于锁定状态，机器 ID 为空。设备网络、SSH 密钥、蓝牙身份及单机校准留待首次配置。还原旧相机可执行文件、去掉快捷设置的执行权限或改变启动链接目标，都会在一次性写层中被校验器拒绝。日志位于 `out/dev12.13-root/`。[独立只读验收](../tests/tablet-desktop-root/check.sh)

## 实板 RAM 桌面

从本次发行包提取的压缩根经 USB 传入实板 RAM，用时 55 秒。板上逐字节核对完整根和 1,241 项软件包后，以普通账户在独立 200% Xfce 会话中启动了桌面、窗口管理器、面板和屏幕键盘。「快捷设置」由桌面的 XDG 自动启动项拉起。发行版相机在虚拟三镜头后端打开，中文和英文界面都默认选中后置主摄，三项切换后取消。日用系统的席位、服务、背光、镜头电源、网络及存储状态在测试前后吻合。板端临时 RAM 文件、loop 和挂载命名空间均已释放。[复现与实机收据](../tests/tablet-desktop-ram/README.md)
