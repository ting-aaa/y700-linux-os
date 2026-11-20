# Xfce 原生托盘的单击电源菜单

TB320FC_PRC 的 X11 桌面使用 Xfce 通知区域。电源管理器将电池图标嵌入已有面板。此构建让 GTK 的主激活动作打开该图标的电源菜单，用户可以从原有位置进入电源设置。

Debian 4.20.0-1 的后台程序只为托盘连接 `popup-menu` 和 `scroll-event`。上游 4.20 分支在提交 `727d8348` 也如此。Xfce 手册中可点击的 Power Manager Plugin 是需要加入面板的另一款组件。上游开发分支提交 `23752a49` 的后台程序已移除原来的 GtkStatusIcon 实现。[Debian 4.20.0-1 源码](https://sources.debian.org/src/xfce4-power-manager/4.20.0-1/src/xfpm-manager.c/) · [Xfce 4.20 分支](https://github.com/xfce-mirror/xfce4-power-manager/blob/727d83489987f273b9ac014bea5f50fbafe19271/src/xfpm-manager.c#L935-L942) · [开发分支对照](https://github.com/xfce-mirror/xfce4-power-manager/blob/23752a49e5ef8ed8864d9e711f63b4f30d42e426/src/xfpm-manager.c) · [面板插件说明](https://docs.xfce.org/xfce/xfce4-power-manager/panel-plugin)

板级修订 `4.20.0-1+y7001` 连接 GTK 的 `activate` 信号。主激活与原来的右键入口调用同一个菜单函数，滚动仍由原来的处理器接收。GTK 决定当前平台上哪些输入会产生主激活。托盘图标隐藏时同时解除新增的信号连接。[GTK 3 的 activate 信号](https://docs.gtk.org/gtk3/signal.StatusIcon.activate.html)

## 从 Debian 源包重建

在独立的 Debian 13 ARM64 构建环境中启用 trixie 的 `deb-src`，从仓库根目录执行以下命令。前两条 APT 命令需要管理员权限。源包下载和构建可使用普通账户。

```sh
sudo apt-get update
sudo apt-get build-dep --no-install-recommends xfce4-power-manager=4.20.0-1
mkdir -p out/power-manager-source
(cd out/power-manager-source && apt-get source --download-only xfce4-power-manager=4.20.0-1)
bash scripts/build-power-manager-touch.sh out/power-manager-source out/power-manager-touch
```

此次构建时，Debian trixie 的 `InRelease` 已用 Debian 归档密钥环通过 `gpgv` 校验。其中 `main/source/Sources.xz` 的 SHA-256 是 `6002f81f463a2d976d84b34170367cc16da2d60bd0ba9ab9d868d6e1c1a935d9`。构建脚本固定了该索引所列的三个源包文件的 SHA-256。脚本先核对哈希，再用 Debian 的规则生成 ARM64 包，并验证包的名称、版本、架构及数据依赖。[Debian 原始归档](https://deb.debian.org/debian/pool/main/x/xfce4-power-manager/)

部署只需本地的 `xfce4-power-manager_4.20.0-1+y7001_arm64.deb` 与 Debian 原版 `xfce4-power-manager-data (= 4.20.0-1)`。板级包保留对该数据版本的精确依赖。恢复时可将 ARM64 主包降回 `4.20.0-1`。

## 构建及交互实测

三个离线 ARM64 构建根分别从源包开始编译，经 `cmp` 比对得到相同的 129,112 字节归档。第三轮还在输出目录预放了首轮的包，验证重复执行能正常结束。包的 SHA-256 为 `b4fe51dcac6b90de809f12814e8495952b286e3526e77cc758111d5d2dae5df4`，其中 `/usr/bin/xfce4-power-manager` 的 SHA-256 为 `bdae8fa01f32676e3095ab73ed492132fb94c0bc27fc9962e3d9fb929c281366`。用 `readelf` 确认其为 AArch64，逐项比对原版包的 Depends、Recommends、安装路径及权限均相同。归档与核验记录位于 `out/power-manager-touch/`。

PC 上的私有 ARM64 Debian 会话运行真实的 `xfce4-panel`、`xfce4-power-manager` 和 Xvfb。测试从实际嵌入面板的图标开始，用 X11 输入事件点击或按键。库存版在 1024×768 上单击图标没有菜单，右击图标后可从菜单打开电源设置。在 2560×1600、GTK 200% 下，板级包的图标为 44×44 物理像素。以下三种操作都弹出同一个电源管理器进程所属的 352×218 菜单，并能选中最后一行打开电源设置窗口。

- 单击图标。
- 右击图标。
- 图标获得焦点后按回车。

用户选择隐藏图标后，重新启动电源管理器仍保持隐藏，再开启可重新显示。原版与候选的会话记录分别为 `out/upower/arm64-tray-settings.log` 和 `out/upower/arm64-tray-candidate-final.log`。测试覆盖了 X11 的主激活和键盘路径，实机面板上的手指点按、滚动调节实际亮度和整机挂起仍需各自的硬件验证。
