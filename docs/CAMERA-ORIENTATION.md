# 相机预览与照片方向

国行 TB320FC 的内屏以 1600 × 2560 竖屏为原生方向。机主报告图像上下和左右同时颠倒时，内屏 `DSI-1` 的 RandR 状态为 `left`，桌面为 2560 × 1600 横屏。

在该次实机上，以普通用户向三个镜头请求 `Rotate0`，分别生成并验证彩色预览配置。诊断未获取相机、配置硬件、启动取景或读取任何一帧。三路均返回 `Rotate270`。CN350 出厂设备树的主摄、前摄和微距都标有 270° roll，两个后摄的 yaw 为 180°，前摄为 0°。Linux 端三个传感器节点各自提供 270° 安装角及前后位置。应用应使用协商之后的图像方向。[板级移植](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0016-asphalt-camera-wiring.patch) · [libcamera 的方向协商](https://docs.libcamera.org/master/public-api/classlibcamera_1_1CameraConfiguration.html) · [Android 前后摄及显示方向的约定](https://developer.android.com/media/camera/camera2/camera-preview)

| 用于核对的镜头 | Linux 位置 | 请求方向 | 实际方向 |
| --- | --- | --- | --- |
| HI1339 后置主摄 | 后方 | Rotate0 | Rotate270 |
| SC202CS 后置微距 | 后方 | Rotate0 | Rotate270 |
| S5K4H7 前摄 | 前方 | Rotate0 | Rotate270 |

后台探针从对应版本的 libcamera 公共头文件及生成的控件头文件编译，链接平板上原有的 `/opt/y700-camera/lib`。源码位于 [negotiated.cpp](../tests/camera-orientation/negotiated.cpp)。板端收据 `out/camera-optical-qa/physical-orientation-before.log` 的 SHA-256 为 `10f6c0465d2a1cadb528b7870ac3e2cf21646a11c41a9c984df9fe8132ca88f7`。

## 在日用系统中使用

`y700-camera-qcam` 修订版 `y7008` 根据当前镜头实际输出的方向、镜头位置和内屏 RandR 旋转，在 Qt 预览中绘制转正的画面。点击拍照时，同一变换应用到 JPEG 像素，普通照片查看器即可显示正确朝向。切换前后摄或旋转桌面后重新计算。这个更新适用于菜单「图形 → Y700 相机」的 Qt 预览。浏览器或会议应用有各自的摄像头显示路径。[实现与合成验收](../tests/qcam-photo/README.md)

修订版已安装到参考机的内置 dev12.11。安装当时对照全部 1,240 个包，仅 qcam 从 `y7007` 更新到 `y7008`，新程序 SHA-256 为 `2f0ac49c949273142cda696bb195d405add209c538e2fea7505a2bc87227af92`。关闭后重新打开应用即可使用。板端如需回到原版，可执行以下命令。

```sh
sudo bash /var/lib/y700/updates/qcam-orientation-y7008/update.sh rollback
```

装有日用版 `y7007` 的同型号设备可解开 `out/camera-qcam-orientation/y700-qcam-orientation-offline.tar`，进入 `qcam-orientation` 后用 `sudo bash update.sh install` 或 `rollback` 切换。归档同时含两版 Debian 包，SHA-256 为 `e0dda2f3d58a1bad5a6b3a3038ebc3b53b0c48bfe9bda3a03a11c9e88a5838ab`。[离线包构建器](../scripts/package-qcam-orientation.sh)

## 方向回归测试

在 ARM64 上以 100% 和 200% 缩放分别验证了 40 组方向组合。测试把带四色角标的帧送入实际 Qt 预览部件，同时用相机应用的照片写入路径生成 JPEG。每组均检查预览和解码后照片的四个角，覆盖协商方向带镜像标记的输入。对应收据为 `out/camera-qcam-orientation/raster.log`，SHA-256 为 `2977a0c58443b964560dfae806de6519b1c42b6078fc66aa1944b79af3a03886`。

在 dev12.12 的 ARM64 虚拟机上，三个模拟镜头使用参考机实际协商的 `Rotate270`。同一相机进程在四个内屏方向间切换，12 次预览和 12 张解码后的 JPEG 的四角顺序与宽高均符合预期。用同一幅标靶在 `left` 横屏比较，旧版保持原始后摄画面，新版把后置主摄和微距旋转 180°，前摄保持原角度。收据 `out/qcam-orientation-vm/verification.txt` 的 SHA-256 为 `5bc9a7ade014f86a7c44de32de3225cc2bed925b16478b90538c87bca77f811b`。[复现方法与各方向预期值](../tests/qcam-photo/orient-vm.md)

在参考机上，已安装的新版相机在 200% 缩放、中英文两种界面下都能选到后置主摄、前摄和微距，并能取消退出。此次菜单验证期间，三个传感器均保持挂起，活动时长增量为零。实景方向的最终确认由机主在日用桌面取景时完成。
