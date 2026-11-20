# 蓝牙键盘配对码何时消失

蓝牙键盘配对时，BlueZ 的 `DisplayPasskey` 先显示六位码，随后报告键盘已经输入的位数。全部六位输入完毕时，用户仍可看到完整的码，直到配对完成、断开或取消。Blueman 板级版本 `2.4.4-1+y7002` 将设备状态监听与这一次显示绑定。[BlueZ Agent1 接口](https://github.com/bluez/bluez/blob/5.82/doc/org.bluez.Agent.rst) · [此前的末位修复](BLUEMAN-PAIRING.md)

在旧版 `y7001` 中，输入进度每更新一次就新增一次设备监听。取消会关闭当时的窗口，但旧监听仍可收到状态变化。测试中，取消第一把模拟键盘的配对并开始显示第二把的码后，第一把键盘迟到的 `Paired=true` 关闭了第二把的窗口。同一设备正常配对完成也会让重复回调尝试移除已经移除的监听。两版在正常键入六位的七次画面中，都只显示一个有匹配码的窗口。

改动在替换或关闭显示时断开其设备监听。首次显示、后续更新和旧式 PIN 显示共用这段逻辑，取消、完成、断开以及代理退出都经过相同的清理路径。候选包还包含确认比较码为零和并发请求输入框的修复。[显示生命周期补丁](../packaging/blueman/display-passkey-lifetime.patch) · [输入和确认补丁](../packaging/blueman/agent-entry.patch)

## 构建和验证

使用已通过 Debian 签名索引校验的 `blueman_2.4.4-1_arm64.deb`，在 Linux 上运行以下命令。默认构建当前的 `y7002`。第三个参数指定 `y7001` 可重建旧包。[构建脚本](../scripts/build-blueman-passkey.sh)

```sh
mkdir -p out/blueman-passkey-lifetime
bash scripts/build-blueman-passkey.sh "$DEBIAN_BLUEMAN" out/blueman-passkey-lifetime y7002
```

两次构建均得到 1,050,192 字节的 `blueman_2.4.4-1+y7002_arm64.deb`，SHA-256 为 `4fbb2eb45426a10620e75943f359715adec921fdc71e5d976f807f3295756367`。与 Debian 原包相比，仅包版本、文件校验清单及 `BluezAgent.py` 有变化。单独重建的 `y7001` 与原留存归档逐字节相同。

PC 上的隔离 ARM64 测试使用只读 dev12.6 根镜像、私有系统与会话 D-Bus、模拟的 BlueZ 服务和真实的 Blueman applet。Xvfb 提供 2560×1600 的显示，GTK 缩放为 200%。测试通过 X11 窗口和 AT-SPI 可见标签核对显示的码。输入的码仅在临时测试进程中使用。所需工具为 ARM64 Xvfb、xdotool、libxdo3、Debian 的 `python3-dbusmock_0.38.1-1_all.deb` 和 ARM64 uv。[测试入口](../tests/blueman-passkey-lifetime/run.sh)

```sh
sudo bash tests/blueman-passkey-lifetime/run.sh "$DEV126_EXT4" "$X11_DEBS" "$DBUSMOCK_DEB" "$ARM64_UV"
sudo bash tests/blueman-passkey-lifetime/run.sh "$DEV126_EXT4" "$X11_DEBS" "$DBUSMOCK_DEB" "$ARM64_UV" \
    out/blueman-passkey-lifetime/blueman_2.4.4-1+y7002_arm64.deb \
    4fbb2eb45426a10620e75943f359715adec921fdc71e5d976f807f3295756367
```

候选包安装到一次性写入层后，通过了 `dpkg -V blueman` 和 `dpkg --audit`。取消后收到旧设备状态时，候选版继续显示新键盘的码。当前设备配对完成或断开后，码从界面消失。`Release` 后，代理从 D-Bus 注销，界面没有可见的配对码。整轮测试中，旧版配对代理记录了 22 次设备回调异常，新版为零。测试单独记录了来自其他桌面插件的异常。旧版与候选回归收据位于 `out/blueman-passkey-lifetime/{control,candidate}.log`。这组测试覆盖 GTK 回退对话框。实物键盘的空中配对、键入和重连仍需在实机验收。
