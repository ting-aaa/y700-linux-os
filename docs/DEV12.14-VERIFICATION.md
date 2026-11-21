# dev12.14 全新安装与浏览器相机验证

dev12.14 将已在参考机日用桌面验证的 `y700-camera-pipewire` 从 `1.4.2-1+y700.4` 升到 `1.4.2-1+y700.5`。首次安装时，电脑直接从 dev12.13 封存包和 dev12.14 增量包生成完整安装镜像。已有系统仍可使用小型 Debian 离线更新包。[安装说明](DEV12.14-IMAGE.md) · [参考机更新与运行时检查](BROWSER-CAMERA-UPDATE.md)

| 文件 | 字节数 | SHA-256 |
|---|---:|---|
| dev12.13 完整 TAR | 1,451,878,400 | `60fc1e12b2ad707270bf722d90e72e32c030ae377a50a37130ecd4336aac1fb6` |
| dev12.14 增量 TAR | 501,760 | `e2d7eb03e5db24dbfe71dc195a864f864ec30ffb2ca6cf525b70ab1b63487b87` |
| 增量包中的 VCDIFF | 434,960 | `4f6407ff6fbed3884f7c38b69d8be93139b862029dd6c6e12a07b898e62c13ce` |
| 还原的 `root.ext4` | 6,442,450,944 | `32896d21a07a1c9529db3d007df788bb8ddcf4e5b6b0782527737ac7af1a3259` |
| 软件包清单 `packages.tsv` | 40,399 | `a652f024df73eb7386043cf11fa3fde1a1eb81a9f78a572c7bce808b0f1979fb` |

小包位于 `out/dev12.14-board/`。实际用同版发布入口将两份 TAR 解到空目录后，核验了全部三个原始文件及身份说明。生成的 EFI 分区 SHA-256 为 `cdd0e35bf0d0cd859f521bf74fafa594388ea3093c33ea81c189da56cb3dea0d`，U-Boot 为 `f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8`。整包保留原有启动链与备用内核。

另一名普通 Linux 用户从两份 TAR 解包，在仅该用户可读的临时文件中传入合成蓝牙地址。个性化后通过了 ext4 检查、重新校验和地址回读，保留了通用镜像摘要。错误的父包和已经存在的目标目录均被拒绝。测试结束后清除了两套临时工作目录，证据见 `out/dev12.14-verified/ordinary-unpack.txt` 与 `scratch-cleanup.txt`。

## 首次开机与登录

ARM64 虚拟 U-Boot 通过最终包恢复的 EFI 和根启动。Type-B 触屏首次输入两次不同的密码后，账户仍处于锁定状态；第二次输入一致后，LightDM 接受屏幕键盘输入，通过 PAM 进入普通用户的 Xfce 会话。该登录会话启动了发行版 Chromium，实际渲染进程启用了 seccomp 和 NoNewPrivs。顶栏快捷设置、相机选择器和本地 H.264 播放也完成桌面检查。此 EFI 桌面使用虚拟帧缓冲；摄像头视频方向由下一节的 DSI-1 测试测量。[EFI 试验入口](../tests/combined-efi/README.md)

## 独立复核

重新只读挂载从最终发布包恢复的新旧根，在两边独立查询 dpkg 状态。1,241 项已安装软件包中有 1,240 项名称、版本和架构完全相同。另行比对了 24 个继承的构建锁、账户密码数据库和首次设密服务。通用机的机器身份为空；包内没有参考平板的配对、网络、SSH 密钥或单机校准。新包的七个普通文件分别核对 SHA-256、属主与权限。安装副本完成了 `dpkg --verify`、`dpkg --audit`、`apt-get check` 和卸载后的 `e2fsck -fn`。[只读核验](../tests/browser-camera-root/check.sh) · [七文件与包清单锁](../config/browser-camera-desktop.lock.json)

ARM64 浏览器测试从 dev12.14 根启动，在 RAM 中接入带不对称色标的虚拟主摄和前摄。普通账户使用发行版 Chromium、WirePlumber、PipeWire 和两层相机权限。运行中的 WirePlumber 映射了发行根上 SHA-256 为 `a7eab16363e28fd191944dd75e2aa6b37e0520ba2c05a47699b800ac83ae28d0` 的 SPA 插件。主摄和前摄各自保持同一个 WebRTC 轨道，在模拟内屏左右旋转时分别读取八帧 640 × 480 视频，四项网页和 X11 窗口读数均与标靶吻合。渲染进程使用独立 PID 命名空间，seccomp 为 2，NoNewPrivs 为 1。收据见 `out/dev12.14-verified/browser.txt`。[Chromium 试验与复现入口](../tests/camera-browser-orientation/README.md)

## 重建

解包器面向普通用户；从原 Debian 包重新制作根时，构建主机须能在隔离的挂载和网络命名空间中执行 ARM64 Debian 用户态。将经锁定的 56,448 字节 .5 包放入 `$debs`，其 SHA-256 为 `73cfdd2a0b1dad67f02aef3efbbb54b9129fb6a918bddc33b0574a08cd343cfc`。

```sh
sudo env UV_BIN="$(command -v uv)" bash scripts/update-sealed-root.sh \
    browser-camera-desktop "$dev1213_root" "$debs" "$new_result_directory"
sudo env UV_BIN="$(command -v uv)" bash tests/browser-camera-root/check.sh \
    "$dev1213_root" "$published_dev1214_root"
bash scripts/package-browser-camera-release.sh \
    "$dev1213_tar" "$dev1213_root" "$published_dev1214_root" "$new_release_directory"
```

从 Debian 包重做文件系统会产生新的 ext4 与 dpkg 时间戳。要复原表中每个字节，使用发布的 VCDIFF。组包脚本校验原始两份根，编码后重新解出并哈希整个 6 GiB 数据流，再制作具有固定属主、权限、顺序和时间戳的 TAR。复验资料在 `out/dev12.14-verified/`。本轮均在电脑上运行；实体平板开机进入 dev12.14、各网站自身的镜像偏好和真实拍摄方向仍需分别验证。
