# Y700 传感器服务的启动、升级和回滚

已封存的 dev12.4 镜像含 `y700-ssc-runtime 0.1.1`。该版本安装了 CN350 传感器栈，但 SDSP 设备出现时，udev 仅请求桌面代理。代理又要求已有运行中的监听服务，因而可能停在依赖失败。0.1.2 补全了这个设备事件。0.1.3 在设备快速移除后立即重现时，也能恢复监听器和代理。维护者可在新的离线镜像中使用更新后的十一包输入。已有 dev12.4 用户可只更新一个包。[镜像输入](../config/ssc.lock.json) · [运行服务](../src/sensors/ssc/y700-ssc.service)

## 从板端固件到桌面

正常 Debian 启动所用的 EFI 设备树将 `remoteproc@2400000` 标为 `okay`，指定 `qcom/sm8475/lenovo/tb320fc/slpi.mdt`。其 FastRPC 节点的域标签是 `sdsp`，保护域为 `msm/slpi/sensor_pd`。镜像的普通 initrd 将根切换到 Debian，未提前装载 PAS 模块。Linux 7.3.4 的 `qcom,sm8450-slpi-pas` 匹配启用自动启动的驱动配置。内核根据探测结果加载固件，FastRPC 在 RPMsg 通道上注册 misc 设备。rootfs 上安装正确固件很重要，已错过固件的旧系统不会因为更新这个用户空间包而重新探测 SLPI。[Linux 的 SLPI 匹配](https://github.com/gregkh/linux/blob/v7.3.4/drivers/remoteproc/qcom_q6v5_pas.c#L1794) · [同板 SDSP 配置](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/modules/devices/asphalt/sensors.nix)

0.1.3 在 `/dev/fastrpc-sdsp` 出现时用 udev 激活 `y700-ssc-device.target`。设备活动期间，该目标要求监听器 `y700-ssc.service` 持续运行。如果设备快速重现，PID 1 可以先完成旧的停止作业，再重新启动监听器。监听器在自己的命名空间使用现有或首次建立的板级注册表，启动 `sdsprpcd sensorspd`。代理的 `ExecStartPre` 等到 `ssccli` 取得加速度读数，才向系统总线发布 `net.hadess.SensorProxy`。Xfce 在活动且解锁的本地会话内按用户的自动旋转设置订阅该代理。自动旋转默认锁定，安装包不修改这一设置。[同板参考实现](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/modules/mobile/ssc-sensors.nix#L79-L109) · [用户会话](../src/sensors/rotation_session.py) · [首次校准](SSC-CALIBRATION.md)

## 已有 dev12.4 离线升级

在电脑上，更新包位于 `out/ssc-device-0.1.3-offline/`，回滚包位于 `out/ssc-calibrated-offline/`。将下面两个 ARM64 归档放入平板上的同一个目录。已安装 dev12.4 完整 SSC 层时，依赖已齐。先校验归档并记录更新前的服务状态，再用 dpkg 安装。没有 SDSP 节点时可正常完成安装。

```sh
sha256sum -c <<'SHA256'
2d717ae8b0090b986423f8fd398b675d125af6087a5a9827385527c98ccd479b  y700-ssc-runtime_0.1.3_arm64.deb
ffaaf6288b81582c0f35d76ae4d19e760028761b4fd7b6e48a26230fa237cecb  y700-ssc-runtime_0.1.1_arm64.deb
SHA256
```

两行都显示 `OK` 后执行以下命令。第一条命令可返回 `inactive`。

```sh
systemctl is-active y700-ssc.service iio-sensor-proxy.service
sudo dpkg -i ./y700-ssc-runtime_0.1.3_arm64.deb
dpkg-query -W y700-ssc-runtime
```

如果节点在升级前就已存在，安装脚本会申请启动监听器。运行中的实例继续使用同一进程。手工维护时可先停止设备目标和监听器。安装脚本尊重 Debian 的 `policy-rc.d` 和服务 mask，并在离线构建或 chroot 中跳过现场启动。systemd 只在设备首次变为活动时执行 udev 指定的依赖，这也是已有节点需要单独处理的原因。[安装脚本](../src/sensors/ssc/postinst) · [systemd.device](https://www.freedesktop.org/software/systemd/man/latest/systemd.device.html#SYSTEMD_WANTS=)

设备出现后可用以下只读命令核对运行链。节点缺席时两个服务处于非活动状态符合默认设置。

```sh
udevadm info --query=property --name=/dev/fastrpc-sdsp
systemctl is-active y700-ssc.service iio-sensor-proxy.service
busctl --system --auto-start=no get-property net.hadess.SensorProxy \
    /net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer
```

## 回滚至随镜像交付的 0.1.1

若本机之前单独升级过 0.1.2，也可用 `out/ssc-device-offline/y700-ssc-runtime_0.1.2_arm64.deb` 恢复到该版本。其 SHA-256 为 `ceb15ee63163b9f1700a7720d654229b22ba476464b1716c8a48618df0aad0ac`。以下命令给出回到原镜像 0.1.1 的路径。

若记录的升级前状态是两个服务均未运行，可在回滚前执行 `sudo systemctl stop y700-ssc-device.target y700-ssc.service`。0.1.3 会随之停止依赖它的代理。如果升级前监听器已由管理员启动，则保留其运行状态。安装旧归档后刷新 PID 1 和 udev。

```sh
sudo dpkg -i ./y700-ssc-runtime_0.1.1_arm64.deb
sudo systemctl daemon-reload
sudo udevadm control --reload
dpkg-query -W y700-ssc-runtime
systemctl is-active y700-ssc.service iio-sensor-proxy.service
```

这两个版本共用 `/var/lib/y700-ssc`。升级与回滚均保留该目录。

## 验证范围

ARM64 QEMU 运行已封存 dev12.4 的内核和 Debian systemd、udev、代理。0.1.3 在三种场景中收到三种桌面传感器能力：设备先于 PID 1 存在、系统启动后才出现、在 0.1.1 已发现设备时升级。移除设备后代理和监听器依次停止，再出现时两者均恢复。快速连续移除、重加成功恢复，受测的 0.1.2 在相同操作后停留在非活动状态。升级遇到拒绝策略或服务 mask 时跳过启动，重复安装保留原监听实例。遮罩监听器后再次插入设备，两个服务的 PID 均为零。向下安装原 0.1.1 后，注册表版本文件保持原校验值，新设备到来恢复旧版本的手动启动行为。[测试方法](../tests/ssc-lifecycle/)

此回归以 QEMU misc 设备和通过 Linux QRTR 发送数据的传感器模拟程序代替物理 DSP。板上曾实测七个传感器通道。在 0.1.2 的单次受限实机试验中，普通桌面用户通过系统代理读到平放朝上、17.7435 lux 和远离状态，随后释放加速度、光照和接近订阅。平放时屏幕方向报告为 `undefined`。实机在 SDSP 缺席时从 0.1.2 升级到 0.1.3，核对了归档和服务文件；升级前后 SLPI 都为 offline、ADSP 都在运行，内核启动和停止计数仍各为原有的一次。完整镜像的板端冷启动、休眠恢复和实机转动时的方向映射尚待验证。[物理传感器记录](CAMERA-SENSORS.md#physical-ssc-qualification)
