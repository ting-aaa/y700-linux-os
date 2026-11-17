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

11 月 18 日的产品开发已新增 [桌面集成包与 ARM64 隔离验证](docs/PLATFORM-BUILD.md)、[GPU 故障假设表](docs/GPU-INVESTIGATION.md) 和 [硬件／传感器来源映射](docs/HARDWARE-MAP.md)。平台包已可构建，30 个修复包有独立哈希锁；这仍不等于完整镜像可复现或新配置通过实机验收。

Python 使用 `uv` 管理。Windows 用于设备连接与仓库管理，Linux/WSL 用于 ARM64 构建。先阅读 [AGENTS.md](AGENTS.md)、[状态表](docs/STATUS.md) 和 [产品计划](docs/PRODUCT.md)。

```sh
uv run --python 3.13 --no-project python scripts/check-public-tree.py
```

静态检查不证明内核可启动或设备功能可用。公开仓库不包含私人备份、账号/密码/密钥、原始设备日志、唯一设备标识或原厂固件镜像。后续发布仍须逐项审计来源与再分发条件。

本项目与 Lenovo 无官方隶属关系。项目自有代码采用 MIT；上游内核、U-Boot、Debian 软件包及外部固件保留各自许可证，见 [第三方说明](THIRD_PARTY_NOTICES.md)。
