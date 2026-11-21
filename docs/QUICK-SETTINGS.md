# 平板快捷设置

在 Xfce 顶栏点快捷设置图标，或从这个图标向下拖动。也可以从应用菜单的设置分类打开「快捷设置」。亮度、音量、静音、蓝牙电源和自动旋转都在同一个面板内。点关闭、按 Esc 或切换到其他窗口即可收起。锁屏时会收起面板。

亮度滑杆的范围为 5–100%，由本次图形会话通过 logind 控制内屏背光。音量和静音跟随 WirePlumber 当前的默认输出。蓝牙修改 BlueZ 适配器的电源状态。有多个适配器时，面板根据设备树识别平板自带的 WCN6855。自动旋转与「平板屏幕旋转」共享账户偏好。面板打开期间会同步其他应用修改的状态。可在原有蓝牙管理器里配对键鼠。

## 安装与移除

在产品目录构建 Debian 包。已发布的基础镜像可通过同一包添加快捷面板。

```sh
bash scripts/build-quick-settings.sh out/quick-settings
sudo apt install ./out/quick-settings/y700-quick-settings_0.1.0_all.deb
```

登录 Xfce 后会自动启动托盘。要在当前会话中立即使用，打开应用菜单中的「快捷设置」。在当前桌面终端执行以下命令可退出并移除它。

```sh
y700-quick-settings --quit
sudo apt remove y700-quick-settings
```

[桌面组件](../packaging/quick-settings/panel.py) · [设备控制](../packaging/quick-settings/devices.py) · [ARM64 直接触屏测试](../tests/quick-settings/run.sh)

## 国行参考平板

日用 dev12.11 已安装 `y700-quick-settings 0.1.0`，软件包清单从 1,240 项增至 1,241 项。原桌面会话的 Xfce 顶栏已创建 44 × 44 物理像素的托盘图标，内屏为 2560 × 1600。用同一账户在独立显示上操作最终包，内屏背光从 102 调到 122 后恢复，默认输出从 34% 调到 33% 后恢复，静音和所有声道读数也回到原值。真实 WCN6855 蓝牙电源切换并恢复，原绑定保留。旋转开关在隔离的账户设置后端往返测试。机主此前已确认这台平板能随姿态自动旋转。

在平板上另起一套 200% 缩放的 Xfce 会话，用 XTest 从托盘中心轻点打开，点击两次旋转开关，按 Esc 关闭，再从图标向下拖动 36 个逻辑像素打开并按 Esc 关闭。设备安装与测试日志分别位于 `out/quick-settings/physical-install.log`、`physical-panel-final.log` 和 `physical-xtest.log`。这次实板操作使用了自动输入，新图标的人手触摸体验仍待确认。

## 复现直接触摸测试

在 ARM64 QEMU 中启动只读的 dev12.12 根文件系统及临时写层，安装正式包。Xorg、libinput、Xfce 托盘与 GTK 在 1600 × 2560 竖屏、200% 缩放下运行。测试通过 Linux Type-B 触点向下拖开顶栏图标，操作全部控件并核对外部状态同步，随后轻点图标重新打开、检查锁定状态抑制打开，并卸载软件包。虚拟机用测试服务响应背光、蓝牙和音量请求，用私有账户偏好保存旋转状态。

```sh
bash tests/quick-settings/run.sh "$ROOT_EXT4" "$KERNEL_EFI" "$ARM64_BUSYBOX" \
    "$ARM64_XORG_DUMMY_DEB" "$ARM64_UV" out/quick-settings/y700-quick-settings_0.1.0_all.deb
```

脚本使用现有的显示与触摸测试环境。为上述六个位置参数传入对应的本地文件。成功日志包含 `QUICK_SETTINGS controls=4 mute=1 sync=1 tap=1 drag=1 lock=1`、`QUICK_PACKAGE_rollback=pass` 和 `TOPOLOGY_GUEST_EXIT=0`。本次运行日志位于 `out/quick-settings/qa.log`。正式包 SHA-256 为 `4fcf573c0d0c561689f8d2978e34a29b9c8ba78acfc09b1fba0ad14e93892250`。
