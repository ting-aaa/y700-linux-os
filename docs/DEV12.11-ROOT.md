# dev12.11 通用根文件系统

dev12.11 将后置主摄对焦运行时、qcam 和 PipeWire 相机后端集成到已预装 WPA3 密码重试更新的 dev12.10 根镜像。封存文件为 6,442,450,944 字节，SHA-256 为 `33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3`。软件包清单共有 1,240 项，完整元组 SHA-256 为 `be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d`。[相机运行时](../packaging/camera-autofocus/README.md) · [Wi-Fi 父镜像](WIFI-OFFLINE-ROOT.md)

| ARM64 软件包 | 安装版本 |
| --- | --- |
| `y700-camera-runtime` | `0.7.2-1~bpo13+1.y7002` |
| `y700-camera-qcam` | `0.7.2-1~bpo13+1.y7005` |
| `y700-camera-pipewire` | `1.4.2-1+y700.4` |

`/etc/os-release` 增加 `IMAGE_ID=y700-prc-debian` 和 `IMAGE_VERSION=dev12.11`。本地 dpkg diversion 将 Debian 自带的链接保存在 `/etc/os-release.debian`，仍指向 `/usr/lib/os-release`。通用介质的 ext4 UUID 仍为 `171a4adb-916b-4763-9e6f-722b4a99988f`。`/etc/y700/image-id` 使用对应的 `y700-prc-` 标识。

在具备 ARM64 Debian 执行环境的 Linux 构建机上，可用以下命令重建。父镜像 SHA-256 为 `0383703eac309a64e3febc286fa6c8d9fffb9c252745bb7b1647bde647a27ca0`。`camera_debs` 指向三个经校验的 Debian 包，`output` 必须是尚不存在的 Linux 目录。重新运行 dpkg 和 ext4 会产生新的文件系统时间戳，构建器逐项验证固定的软件载荷和库存。[精确软件包及所有载荷文件哈希](../config/camera-autofocus.lock.json)

```sh
sudo env UV_BIN="$(command -v uv)" bash scripts/update-sealed-root.sh \
  camera-autofocus "$wifi_root" "$camera_debs" "$output"
sudo cat "$output/SHA256SUMS" "$output/inventory.log" "$output/filesystem-check.log"
```

在已卸载并封存的根上再次只读检查，三包内 23 个普通文件和 4 个符号链接的内容、目标、权限和属主均匹配归档。21 个既有软件层收据保持原哈希，新增 `/var/lib/y700/build/camera-autofocus.lock.json`。ARM64 包账本 `packages.tsv` 的 SHA-256 为 `17473ab98cdf1190d573276bba00ceca7e0cee05688b8b496de37df8fc600d82`。五阶段 `e2fsck -fn` 通过；用户账户已锁定，首次触控建号服务及 LightDM 图形目标已就绪。设备身份、网络资料、SSH 密钥和本机校准留待个性化时导入。构建、首次启动配置和只读逐文件复核日志位于 `out/dev12.11-root/`。
## 从已安装的 dev12.10 迁移

在正在运行的 dev12.10 文件根上，以 root 读取已校验的两个普通文件，按以下顺序传入暂存程序。正常安装需要原有系统之外约 40 GiB，包含 7 GiB 封存种子、32 GiB 新根和 1 GiB 内层 ESP。迁移时退出普通用户的桌面会话，以便完整比对主目录快照。主目录的临时归档需要相应的可用内存。

```sh
cat "$generic_root" "$generic_esp" |
  bash scripts/stage-file-trial-images.sh --dev12.11 /run/initramfs/backing
bash scripts/personalize-file-install.sh --dev12.11 "$root_owned_trial_controller"
```

暂存目录为 `.dev12.11-input`。个人化程序从当前运行的系统迁移账户、主目录、USB 身份及设备设置，在隐含目录准备完成后，将新文件对原子发布到 `/run/initramfs/backing/var/lib/y700-trial/dev12.11/`。成功标记为 `dev12.11 personal files verified, USB identity retained`。准备途中可使用同一命令从封存种子重试。新根 UUID 为 `c0e447e4-82db-59ee-91d6-0e1ec9d5f45e`，新 ESP ID 为 `31EC-3084`。试启动控制器另行选择引导项。

两次独立的 ARM64 用户空间迁移使用普通文件组成的嵌套 ext4 和 FAT，验证了 32 GiB 新根、用户文件与硬链接、四分钟回退计时器、原安装身份及离线文件系统检查。短传输、指向旧根的符号链接以及试图覆盖已发布目录均被拒绝。最终源码实测记录位于 `out/dev12.11-install-preparation/migration-arm64.log`。[可复现夹具](../tests/installed-trial/dev1211-migration.sh)
