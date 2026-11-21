# dev12.11 发行镜像和实机验证

2026-11-21，国行 Y700 二代（TB320FC_PRC，16 GiB / 512 GB）从内置 UFS 启动了独立安装的 Debian dev12.11。第二次限次启动确认了新根、图形登录界面、USB SSH、Wi-Fi 链路和原账户身份。普通用户通过 FD730 和 Turnip 完成了短时离屏渲染与像素回读。[镜像解包说明](DEV12.11-IMAGE.md)

## 发行文件

本地发行目录为 `out/dev12.11-board/`。归档大小为 1,416,427,520 字节。用随包的 `unpack.sh` 解包后，分别校验板级 U-Boot、启动分区和通用根文件系统。两次独立构建的 FAT 逐字节相同。实体设备树在 GT9768 主摄对焦马达描述之外启用 PMK8350 RTC，并为其分配 `rtc1`。[启动分区构建与设备树核验](CAMERA-SUPPLY-ESP.md)

| 文件 | SHA-256 |
| --- | --- |
| `y700-tb320fc-prc-debian-dev12.11.tar` | `217bb183be85bebe4508f28954fec2566fb29456e58468cdf53d493ceac25c8d` |
| `packages.tsv`（1,240 个已安装包） | `be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d` |
| `asphalt-prc-u-boot.img` | `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8` |
| `linux-boot.fat`（1 GiB） | `92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36` |
| `root.ext4`（6 GiB） | `33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3` |

## 电脑上的 ARM64 验证

完整发行文件经虚拟 U-Boot、systemd-boot、发行内核和 initrd 启动。运行中的 Debian 核对了 1,240 个软件包的名称、版本、架构，以及内核 notes 和相机版本收据。两次桌面启动都通过触屏首次注册和 PAM 登录 Xfce。第二次从正式桌面入口打开相机，在 1024 × 768 虚拟显示器上按 200% Qt 缩放测得窗口宽 492 像素、取消按钮高 96 像素，Type-B 触碰成功关闭窗口。Parole 随后以软件解码显示了 H.264 的三组预期色块。第一次运行中播放器已启动，但画面采样未捕获色块，原因未定位。第二次正常关机后复核了源镜像哈希。虚拟机使用自己的设备树；桌面本身在该分辨率下采用 100% 缩放。[EFI 桌面验收](../tests/combined-efi/README.md)

另一项测试在虚拟 GPT 上重建内置安装的两层文件系统，用生产内核和文件根 initrd 直接启动。新系统以读写方式挂载独立 32 GiB 根和 1 GiB EFI，进入 systemd。关机后读回了两个持久化标记，旧版两个镜像的哈希一致，两层 ext4 和 FAT 的只读检查均通过。另一次故意换入错误的 FAT，initrd 在开放持久根写入之前终止。外层 EFI 的独立固件测试验证了限次项消耗一次、下一次启动选择 dev12.10。[嵌套根启动与回退测试](../tests/installed-trial/README.md)

## 机主数据和两次实机试启动

原 dev12.10 的 32 GiB 根和 1 GiB EFI 均保留。安装程序为 dev12.11 创建了独立文件，新根 UUID 为 `c0e447e4-82db-59ee-91d6-0e1ec9d5f45e`，内层 EFI 为 `31EC-3084`。迁移校验覆盖机主主目录、账户与组、已存无线配置、蓝牙和 USB SSH 身份。原外层 EFI 的 29 个文件逐项校验通过；新增内核、设备树、initrd 和启动项后共 33 个文件。两份文件系统使用同一台平板既有的 U-Boot。[迁移实现](../scripts/personalize-file-install.sh) · [限次控制器](../scripts/arm-installed-trial.sh)

- 第一次试启动后，主机重新连入 dev12.10。只读挂载 dev12.11 根时发现新增了 Xorg、LightDM 和登录界面日志，说明新系统已进入图形登录阶段。此次未在期限内取得新系统的维护连接，未能直接记录触发回退的事件。
- 第二次试启动通过 USB SSH 读回 dev12.11 的新根 UUID，确认本次启动并停止四分钟回退定时器。平板位于 LightDM 登录界面，用户口令已配置，机主目录、机器、蓝牙和 SSH 公钥身份通过校验。Wi-Fi 链路已连接，蓝牙控制器已上电，系统枚举出触摸设备、DSI、背光、两个扬声器功放及三个相机子设备。这次检查停留在登录界面。[实机桌面检查](../scripts/check-installed-desktop.sh)

## 实机 GPU 与清醒状态闹钟

同一次限次启动中，普通用户两次运行 FD730 EGL/GLES 离屏测试。两次均在三个上下文提交 12 帧并核对 24,576 个像素，首次检查未出现新的内核 GPU 故障记录。Turnip 识别为 Adreno 730，完成四次 Vulkan 渲染和四次传输，回读并核对 8,192 个像素（32,768 字节）。测量期间 GPU 的运行时挂起时间累计增加 694 毫秒；这组负载持续数秒。浏览器加速与长时间 GPU 稳定性需要各自的工作负载验证。[GPU 测试实现](../tests/gpu-resume/)

同一系统识别 `rtc-pm8xxx` 驱动的 `rtc1`，`hctosys=0`。平板保持清醒时设置四秒闹钟，约 4.09 秒收到一次 RTC 中断，测试结束后恢复了原先已关闭的闹钟状态。[RTC 测试](../tests/rtc-alias/)

电脑上的原始记录分布在 `out/dev12.11-efi-verified/`、`out/dev12.11-nested-verified/` 和 `out/dev12.11-installed-boot/`。实机第二轮桌面检查 `desktop-trial.log` 的 SHA-256 为 `56e6d62913180cfbb5b6407c53f326e3d6b4896c433df046851eb1186c5c3750`，GPU 与 RTC 记录 `trial-render-rtc.log` 的 SHA-256 为 `f8868ffb80995d466af2382e064613cb7ff8e21b5bd95ded77b21f73a68fdec7`。
