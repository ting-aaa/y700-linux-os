# Y700 Linux OS

为联想拯救者 Y700 二代（2023，**TB320FC / TB320FC_PRC，SM8475**）开发可日常使用的原生 Linux 桌面系统。

目标是完整桌面发行版的体验：触摸和屏幕键盘、可靠网络、硬件图形加速、传感器与旋转、音频与蓝牙、休眠与充电，以及可维护的更新、回滚和恢复。当前以 Debian 13 ARM64 为用户空间，基于 Asphalt 板级支持推进。

**当前状态：开发基线，尚非产品级发行版；没有对公众发布可直接刷机的稳定镜像。** 此仓库承接一台国行 16 GiB / 512 GB 设备的前期实机验证，不代表其他容量、区域底包或 Y700 其他代际兼容。

## 已确认的基线

截至 2026-11-18，测试机已从内置 UFS 启动 Debian 13.7、Xfce 4.20，内核为 `7.3.4-asphalt-prc`。

- 内置显示、竖屏触摸和左转横屏后的触摸坐标已由用户实测。
- USB ACM/NCM 与经主机密钥校验的 SSH 维护通道可用。
- 手机热点、DNS、连续 HTTPS 请求与 Chromium 网页访问已验证。
- 屏幕键盘可输入；桌面补齐终端、网络菜单、权限代理和自动校时。
- GPU 出现过 GMU/Adreno 卡死。目前关闭窗口合成并让 Chromium 使用软件绘制，**不算硬件加速验收**。

完整区分已验证、临时缓解和未知项，见 [硬件与系统状态](docs/STATUS.md) 和 [脱敏实机基线](docs/BASELINE.md)。

11 月 19 日，实机通过 PipeWire 完成了内置扬声器播放，BlueZ 启用了 WCN6855，三颗摄像头各完成两轮全分辨率 RAW 采集，并向相机应用交付了彩色预览帧。临时自动登录验证了横屏桌面、屏幕键盘显隐和缩放设置入口。另一次启动 Xorg 时，原始内核出现 Adreno 卡死。GPU 候选内核随后分别通过 30 分钟 OpenGL 和 Vulkan 实机负载，平板已回到原内核及常规登录界面。[外设实测](docs/PERIPHERALS.md) · [摄像头与传感器](docs/CAMERA-SENSORS.md)

## 在平板桌面上操作

- **首次开机**　组合开发镜像的本地账户名为 `y700`。首次开机在屏幕键盘上输入两遍新密码，随后在图形登录界面使用同一密码进入 Xfce。已在同一份 ARM64 镜像里走通全程，平板内置屏的实际触点和方向仍待验证。[首次设密](docs/FIRSTBOOT-TOUCH.md) · [图形登录](docs/WARM-GREETER.md)
- **调整缩放**　dev9 在单独使用原生分辨率内屏时，为新 Xfce 用户默认选择 200%。已有用户明确选择的比例继续生效。「设置 → 平板显示缩放」可切换 100% 或 200%，部分应用需重新打开。[桌面与应用缩放](docs/PLATFORM-BUILD.md) · [浏览器手势](docs/TOUCH-GESTURES.md)
- **连接外接屏时的触控**　dev10 会在桌面尺寸改变时重新对齐内屏触控。ARM64 双屏测试中，同一个触点在旧版落到了右侧外屏的第 2,112 像素，修复后落在内屏的第 1,056 像素。拔除外屏后也能自动恢复。真实 USB-C 显示器的输出和触点仍待验证。[双屏触控验证](tests/display-touch-topology/README.md)
- **输入中文和切换桌面语言**　点面板的输入法图标，选择「Chinese – Intelligent Pinyin」。点入文本框后用屏幕键盘拼写，点候选词前的编号上屏。若拼音仍在编辑，再点一次编号，空格也可选中当前候选。在 Chromium 里切换输入法后，如键盘收起，点一下其他控件再点回输入框即可。用「设置 → Display language」选择简体中文或英语，下次登录生效。完整镜像在 ARM64 EFI 测试中先后登录了英文和中文桌面。[中文输入实测](docs/CHINESE-INPUT.md)
- **锁定屏幕方向**　「设置 → 平板屏幕旋转」可保存当前用户的偏好，默认锁定当前方向。实机在一次 5.018 秒的传感器 DSP 启停中读到了加速度、角速度、磁场、环境光、接近、罗盘和保护套霍尔。四个方向的自动旋转、触点对齐和开合盖响应仍待实测。[七通道读数](docs/SSC-TRIAL.md#seven-channel-physical-survey) · [桌面旋转](docs/CAMERA-SENSORS.md#xfce-screen-rotation)
- **保留本机传感器校准**　SSC 0.1.1 首次初始化时，从这台平板的内部 UFS 只读导入出厂校准。本机实测合并得到 375 组配置，重复初始化保留了已有状态。通用镜像随附板级默认值，每台平板在本地完成导入。[校准来源与验证](docs/SSC-CALIBRATION.md)
- **选择 Wi-Fi**　点面板上的网络图标，展开「Available networks」（可用网络）。实机普通用户的菜单里显示了当前网络和另外 6 个可用网络。「Network Connections」（网络连接）列出 2 个已保存配置。WPA3 密码输错时，可以打开「设置 → 高级网络配置」，编辑已保存连接的 Wi-Fi 安全密码并保存。独立 ARM64 测试中原连接随后取得了 DHCP 地址。[选网验证](docs/WIFI-CHOOSER.md)
- **添加蓝牙键鼠**　将外设置于配对模式，再打开 Blueman 管理器选择设备。键盘要求输入配对码时，在键盘上键入平板显示的六位数字。Blueman y7001 已修复输完最后一位时界面报错的问题。实机已识别无线键鼠报告，隔离桌面验证了码值显示及确认按钮。低功耗和经典蓝牙的键鼠输入与重连通过了原生 ARM64 虚拟设备测试，实际配件仍待上手验证。[实机无线](docs/BLUETOOTH-HID-RADIO.md) · [配对界面](docs/BLUEMAN-PAIRING.md) · [输入与重连](docs/BLUETOOTH-VIRTUAL.md)
- **打开相机**　安装可选的「Y700 相机」后，从 Xfce 的图形菜单打开。安装 PipeWire 相机插件后，应用还可以单独选择后置主摄、前摄和微距。实机登录界面的普通 PipeWire 会话从每个镜头都收到了 12 帧 640×480 RGBA 图像。内屏预览画质、触控授权和实际拍照仍待验收。[相机应用](docs/QCAM.md) · [PipeWire 相机与应用授权](docs/CAMERA-PIPEWIRE.md)

最新国行 KMS 开发镜像使用 Debian 13 ARM64、dev10 平板组件、qcam y7002、Blueman y7001 和中英文输入组件，包含 1,112 个软件包。组合镜像集成首次设密屏幕键盘、三摄 PipeWire 接口、Chromium 摄像头授权、SSC 0.1.1 本机校准导入，以及已分别完成 30 分钟 OpenGL 和 Vulkan 实机测试的 Adreno 候选内核。解包时可用同一台平板的原厂 Android 属性预配蓝牙地址。现有平板已单独升级桌面、相机、蓝牙应用及中文输入组件，整个新镜像仍待上板启动。[镜像组成与校验值](docs/BOARD-IMAGE.md#dev10-touch-mapping) · [屏幕键盘验证](docs/PLATFORM-BUILD.md) · [蓝牙地址准备](docs/PERIPHERALS.md#prepare-a-fresh-installation)

## 仓库内容

| 路径 | 用途 |
| --- | --- |
| `src/session/` | 在测试机验证过的 X11 显示与触摸同步程序 |
| `src/usb/` | 测试机使用的 USB 串口与 NCM 维护服务；不含任何访问密钥 |
| `config/` | 桌面包清单及 Chromium 软件绘制规避配置 |
| `reference/y700-linux/` | 前期内核、U-Boot、EFI、根文件系统构建配方的来源快照 |
| `docs/PRODUCT.md` | 产品范围、阶段与发布验收条件 |
| `docs/BUILD.md` | 当前构建入口与尚未闭合的依赖 |
| `docs/PROVENANCE.md` | 固定上游、许可证、资料来源及公开边界 |
| `scripts/check-public-tree.py` | 对 Git 待跟踪文件进行基础公开内容检查与语法检查 |

`reference/` 保留开发来源，**不是已经在新仓库完成的可复现构建流水线**。部分流程依赖独立获取的上游工具、固件或本机提取的设备树；旧根镜像配方尚未整合后续所有实机修复。先完成 [构建迁移](docs/BUILD.md)，不要将这些配方当作一键安装器。

## 开发

11 月 18 日的产品开发已新增 [桌面集成包与 ARM64 隔离验证](docs/PLATFORM-BUILD.md)、[GPU 故障假设表](docs/GPU-INVESTIGATION.md) 和 [硬件／传感器来源映射](docs/HARDWARE-MAP.md)。[962 个包的基础系统](docs/DEBIAN-SNAPSHOT.md) 已从经签名元数据验证的软件包全新构建，随后整合 30 个修复包与平台包，通过 ARM64 用户空间检查。该历史快照仍需刷新安全更新，完整启动镜像和新配置的实机验收尚未完成。

Python 使用 `uv` 管理。Windows 用于设备连接与仓库管理，Linux/WSL 用于 ARM64 构建。先阅读 [AGENTS.md](AGENTS.md)、[状态表](docs/STATUS.md) 和 [产品计划](docs/PRODUCT.md)。

[候选镜像 03](docs/BOARD-IMAGE.md) 已在电脑上从 EFI 启动到 systemd，核对了实际挂载的根分区和全部 993 个软件包。独立测试卡和临时 EFI 入口已通过双盘模拟。候选镜像仍须在 TB320FC_PRC 实机启动并验证能回到原系统。

```sh
uv run --python 3.13 --no-project python scripts/check-public-tree.py
```

静态检查不证明内核可启动或设备功能可用。公开仓库不包含私人备份、账号/密码/密钥、原始设备日志、唯一设备标识或原厂固件镜像。后续发布仍须逐项审计来源与再分发条件。

本项目与 Lenovo 无官方隶属关系。项目自有代码采用 MIT；上游内核、U-Boot、Debian 软件包及外部固件保留各自许可证，见 [第三方说明](THIRD_PARTY_NOTICES.md)。
