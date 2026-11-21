# Y700 二代 dev12.10 内置安装记录

2026-11-21 在一台国行 TB320FC（16 GiB 内存、512 GB 内置存储）完成安装。当前默认项 **Y700 dev12.10 (filesystem recovery)** 自动检查文件系统，随后进入通常的图形登录，沿用原来的 `y700` 账户和密码。安装介质通过 USB 传入。日常开机使用平板内置存储，关机后可以保留文件。[断电恢复与验证](POWER-LOSS-RECOVERY.md)

## 实机启动

| 环节 | 实测结果 |
| --- | --- |
| 首次启动 | systemd-boot 选择限一次的试启动项。板级内核挂载新版根和 EFI 文件系统，原账户进入内置屏上的 Xfce。Wi-Fi 自动连接，经原 USB 主机密钥验证的 SSH 可用。 |
| 默认启动 | 在同一次已确认的启动中晋升为默认项，随后正常重启。新的启动 ID、EFI 变量 `LoaderEntrySelected=y700-file-12-10.conf`、试启动参数消失及回退定时器停止，均已在平板核实。设备到达 LightDM 图形登录界面。 |
| 触屏登录界面 | 在第二次启动的 LightDM 会话中，Xorg 报告内置 DSI 屏正向竖屏 1600 × 2560。按 udev 触摸标签匹配真实输入节点后，读出的 XInput 触控矩阵为单位矩阵，与此显示方向一致。 |
| 系统身份 | 实机内核 notes、发行收据、Parole、专用 Iris 插件及全部 1,240 个 Debian 软件包的名称、版本、架构均通过核验。systemd 报告 0 个失败单元。 |
| 外设 | 内置屏原生模式 1600 × 2560；发现触摸输入、背光和 GPU 渲染节点。Wi-Fi 已连接，蓝牙控制器已上电。两颗扬声器功放均绑定驱动，校准服务成功，后置主摄、前摄和微距子设备均出现。系统启动的 SLPI 及其监听服务处于运行状态。 |

首次安装流程包含两次整机重启，后续的恢复入口又单独验证了限次启动和默认启动。完全断电再开机、外接蓝牙键鼠输入和这次安装后的人工试听仍待实测。初次外设枚举记录见 `out/dev12.10-installed/normal-acceptance.log`。恢复入口的最终检查见 `out/dev12.10-power-recovery/board-permanent-acceptance.log`。实机检查可以通过已有维护连接运行 `bash scripts/check-installed-desktop.sh`。[现场检查脚本](../scripts/check-installed-desktop.sh) · [既有硬件功能实测](STATUS.md)

## 数据及回退

新版使用原 Debian 分区中的独立 32 GiB ext4 文件和 1 GiB EFI 文件；启动时分别挂载为 `/` 和 `/boot`。安装完成后，新根约有 26 GiB 可用空间。Linux 原分区的其余空间继续由原文件系统管理。Android、分区表和 microSD 均保留。

安装时在平板内对 `/home/y700` 创建快照，连同属主、权限、ACL 和扩展属性迁入新版，并用快照逐项比对。账户密码、已有 Wi-Fi 配置、蓝牙信息、SSH 身份和本机传感器校准也已迁入。两个系统各有一份家目录；以后在新版修改的文件保存在新版里。[迁移脚本](../scripts/personalize-file-install.sh)

要临时使用原系统，在启动菜单选 **Debian 13 Xfce (Lenovo Y700)**。另一个入口 **Y700 dev12.10 (persistent files)** 使用同一新版桌面与同一份文件，沿用最初的干净挂载检查。要通过维护命令逐步恢复默认项，先执行第一条返回最初的 dev12.10 入口。若要进一步返回安装前的旧 Debian，再执行第二条，然后正常重启。

```bash
sudo /usr/local/sbin/y700-recovery-boot --recovery restore journal-20261121a \
  21b05d85897a5047834766a5ae1629203d6fad6fd43d0aa614c110b1f3bfa834
sudo /usr/local/sbin/y700-installed-boot restore dev1210-20261121a \
  1c5c6829f6349cfae5fcaac0e9844ac88dcc01ba18adf787a317aff2ad8d41bc
```

这台平板在安装前已把原 EFI 分区的全部 21 个文件归档至移动硬盘，解包后逐个核对 SHA-256。第二次重启后复核了 19 个原静态文件，含原内核、设备树、initrd、启动管理器和 Debian 菜单项。另两个文件分别是已更新的默认菜单配置和启动管理器更新的随机种子。原入口在实机菜单文件中核验过，自动回退在 ARM64 虚拟机验证过，本次未让平板实际切回旧系统。[启动事务与回退](../tests/installed-trial/README.md)

后续更新板级内核时须同步验证外层 EFI 菜单引用的内核、设备树及 initrd。系统挂载的内层 `/boot` 与固件实际读取的外层 EFI 是两个文件系统。[启动介质与版本校验](DEV12.10-IMAGE.md)
