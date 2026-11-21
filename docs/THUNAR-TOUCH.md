# 在触屏上管理文件

Thunar 图标视图现在可以轻点进入文件夹。要改名，按住文件或文件夹，松手后选择「重命名」。要新建文件夹，在空白处长按，松手后选择「创建文件夹」，即可用屏幕键盘输入名称。工具栏提供后退、前进和返回上一级目录。屏幕键盘的浮动按钮可以拖到一旁。

更新基于 Debian 13 的 Thunar 4.20.2。参考平板的内置 dev12.11 已安装触屏版。封存的 dev12.15 镜像使用 Debian 原版，安装后可加装下方的离线包。[Debian 软件包源代码](https://sources.debian.org/src/thunar/4.20.2-1%2Bdeb13u1/) · [Y700 触摸处理补丁](../packaging/thunar-touch/direct-touch.patch)

## 安装和回退

原版为 `4.20.2-1+deb13u1`，触屏版为 `4.20.2-1+deb13u1+y7001`。离线包 `out/thunar-touch/thunar-touch-y7001.tar` 包含两版 ARM64 软件包和校验文件，可搭配 dev12.15 发行镜像使用。在平板上解包后运行以下命令，然后重新打开文件管理器。

```sh
cd thunar-update
sha256sum --strict -c SHA256SUMS
sudo bash update-thunar-touch.sh install
sudo bash update-thunar-touch.sh check
```

在同一目录执行 `sudo bash update-thunar-touch.sh rollback` 可还原 Debian 原版。两次独立构建生成的触屏版包逐字节相同，SHA-256 为 `f0ecf50c5fbbd36acdeaab07efc3787bdef7be853fc06a4e94747b4aa67b9dee`。[构建配方](../packaging/thunar-touch/build.sh) · [更新工具](../scripts/update-thunar-touch.sh)

## 验证方法

开发用平板运行已安装的 Xorg、Xfwm、Onboard 和 Thunar。独立的 2560×1600 桌面使用 200% 缩放，在内存中的普通账户发送 XI2 触点。原版中，单击后状态栏显示选中了目标文件夹，长按没有出现改名菜单。更新测试还会读取临时目录，核对新建和改名的结果。这里的触点来自测试程序；实体手指的现场体验需另行确认。[板端复现](../tests/thunar-board/README.md)

安装后的平板两次轻点打开目录，后退、前进和返回上级各通过一次。长按空白处后用 Onboard 新建了 `hello`，长按该目录后改名为 `oh`。还实际回退、比对 1,248 个软件包，再次安装并重走完整流程。板端回退文件在 `/var/lib/y700/updates/thunar-touch-y7001/`。[板端收据](../tests/thunar-board/receipt.txt)

ARM64 虚拟机通过 Linux Type-B 输入和 libinput 检查了滑动与双指触摸。含 96 个文件夹的视图滚动后，触摸和鼠标命中了同一文件夹。在 100% 和 200% 缩放下，鼠标都保持单击选中、双击打开目录。[构建与输入回归](../tests/thunar-touch/README.md)
