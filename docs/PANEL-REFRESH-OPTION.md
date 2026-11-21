# dev12.11 的可选双刷新率启动项

启动菜单中的 **Y700 dev12.11 (60 / 120 Hz display)** 使用已测双刷新率内核。它和原来的 **Y700 dev12.11 (filesystem recovery)** 共用原 dev12.11 根、账户、initrd、设备树与启动参数。保留原启动项为默认时，每次需要双刷新率都要在启动菜单中选择新项。面板驱动仍将 120 Hz 列为首选。

登录 Xfce 后，可打开 **设置 → 显示**，选择 DSI 内屏的 **刷新率 → 60 Hz → 应用**。要切回可选择 120 Hz。若要在相同显示器组合下登录时自动应用，Xfce 的“高级”页支持保存并自动启用显示配置。dev12.11 封存根已包含 `xfce4-settings 4.20.1-1` 与 `/usr/bin/xfce4-display-settings`。机主账户的触屏选择及下次登录后能否重用其配置，仍待验证。[Xfce 显示设置](https://docs.xfce.org/xfce/xfce4-settings/display)

## 两个 EFI 文件

| 新增路径 | SHA-256 |
| --- | --- |
| `EFI/y700-display-12-11.efi` | `0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60` |
| `loader/entries/y700-display-12-11.conf` | `4e7bb647ba9421c6cdb5fa79119b9497d0e8540831eb24b8fcf868eb9009d662` |

普通启动项的标题与内核路径从正式启动项派生。其启动参数与正式版逐字相同。先前试验使用的 `y700.panel_probe`、试验编号、四分钟计时器和启动计数仅属于限次入口。默认回到原内核的时机是下次启动。选择新项后可以持续使用该次会话。[构建与增删工具](../scripts/panel-refresh-option.sh) · [systemd-boot 菜单](https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html)

## 构建、安装与撤销

在电脑上，以已验证的双速内核和完整的正式 dev12.11 入口目录构建。构建器校验正式四文件和新两文件的固定摘要。

```bash
bash scripts/panel-refresh-option.sh build "$kernel_efi" "$dev1211_entry" "$new_option_dir"
```

本地 `out/panel-refresh-option/display-option.tar` 同时提供操作脚本、两文件目录 `option` 和其清单。归档 SHA-256 为 `3685bfea931263bfe079f046250c3b8c6358a6732adb86ef478e0056f3f314b7`。核验归档并解到 root 的私有目录后，从该目录运行下列命令。`esp` 指向单独挂载的外层 `linux-boot` FAT（UUID `B6D4-FA81`）。工具要求正式 dev12.11 为 `loader.conf` 的默认项，且当前没有限次试验。它在写入内核并同步后才公布菜单项，移除时先删除菜单项并同步。

```bash
bash panel-refresh-option.sh add option "$esp"
# 稍后从原 dev12.11 启动，使用同一个归档撤销。
bash panel-refresh-option.sh remove option "$esp"
```

## 验证范围

真实 FAT 副本测试通过重复添加、重复移除、篡改拒绝和限次试验期间的拒绝。移除后原清单逐字节相同。ARM64 QEMU 从 U-Boot 进入真实 systemd-boot 菜单，用方向键选择新项，客体由 EFI 变量读回 `y700-display-12-11.conf` 并核对双速内核 notes。随后在同一块虚拟磁盘上等待菜单超时，读回原来的 `y700-file-12-11.conf` 和原内核 notes。两次均加载共享的正式 initrd，另附观察器和虚拟机 DT。[FAT 事务回归](../tests/panel-refresh/optional-menu.sh) · [ARM64 EFI 两次启动](../tests/panel-refresh/optional-firmware.sh)

实机已使用同一内核的限次入口完成两轮 120 → 60 → 120 Hz 的扫描测量。随后在国行平板的外层 EFI 安装了新的普通入口。实机复核确认上表两份新文件和原 32 份文件的摘要，默认项仍为正式 dev12.11。实机手动选择新菜单、Xfce 选择、重登录后的刷新率，以及 60 Hz 下的休眠与唤醒仍待验证。[面板时序及限次验证](PANEL-REFRESH.md)
