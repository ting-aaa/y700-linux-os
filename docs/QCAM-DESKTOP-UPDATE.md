# 相机桌面更新

打开 Xfce 的「Y700 相机」时，`y7007` 预选后置主摄。点「确定」开始预览，也可以先换前摄或微距。预览中点工具栏上的镜头名称，会从当前镜头开始选。后置主摄扫描时若刚好已经合焦，随后到达的取消请求会保留相机返回的合焦或失败结果。

## 平板上的验证

国行 dev12.11 的旧版本在中英文界面都默认选中微距。通过同一桌面入口打开新版后，两个界面都预选主摄。普通账户在 200% 私有显示中依次切换三个选项，型号标签分别对应 HI1339、S5K4H7 和 SC202CS。点取消后退出。测试前后三颗传感器均挂起，累计运行时间没有增加。[板端选择器测试](../tests/qcam-photo/board-chooser.py)

实机的 libcamera 仅向后置 HI1339 提供单次对焦与取消控件。前摄和微距为固定焦距。对焦按钮的状态变化已使用合成请求测试；后摄合焦后的实际清晰度还需对静止目标测量。[对焦驱动与运行时检查](CAMERA-FOCUS-PROBE.md) · [清晰度测量方法](../tests/camera-autofocus/optical.md)

在 ARM64 虚拟机中，同一相机进程按「主摄 → 前摄 → 微距 → 主摄」切换，四次快门均保存了预期图案和尺寸的 JPEG，且拍后预览继续。首轮曾在 Debian 的虚拟摄像头组件内退出，修正测试库后完整通过。平板的相机库使用真实传感器的 simple 管线，未编入该虚拟组件。实机同次预览内的镜头切换仍待验证。[虚拟摄像头与快门验证](../tests/qcam-photo/README.md)

## 安装与回退

参考平板的内置 dev12.11 已从 `y7005` 更新到 `y7007`。核对全部 1,240 项软件包，只有 `y700-camera-qcam` 变化。板端启动 ID 以及 SSH、LightDM 和蓝牙服务实例在安装前后一致。系统检查返回 `core_failures=0`。两版软件包和回退脚本保存在平板的 `/var/lib/y700/updates/qcam-y7007/`。

dev12.12 发行镜像内含 `y7005`。本次更新单独分发，适用于已经装有该版本的 dev12.11 或 dev12.12。发布目录 `out/dev12.12-qcam-update/` 中的 `y700-qcam-y7007-offline.tar` 包含两个 ARM64 软件包、更新脚本和校验清单。归档大小为 245,760 字节，SHA-256 为 `e582e3335242c54bdb08e5bde6f71524d19374caf5b8d1c75b17db95e2230964`。脚本内置两个包的 SHA-256，并核对安装后的可执行文件。解包后可在同一目录离线安装，需要回退时再执行第二条命令。

```sh
sudo bash update-qcam-focus.sh install
sudo bash update-qcam-focus.sh rollback
```

两次独立构建生成相同的 115,428 字节新包。开发者可在准备好的 Debian 13 ARM64 构建环境中，以 `--qcam-rear-main` 构建新版、以 `--qcam-autofocus` 构建回退版。写时复制的 dev12.12 中，安装后只有相机应用的版本变化，回退恢复了原有的 1,240 项软件包清单。重装、解包后中断及配置失败后继续执行均已验证。[构建程序](../scripts/build-camera-backport.sh) · [软件包与文件摘要](../config/qcam-focus-result.lock.json) · [更新脚本](../scripts/update-qcam-focus.sh)
