# Y700 实机硬件视频解码

TB320FC_PRC 的原 Debian 内核已经能通过 Qualcomm Iris 解码 8 位 H.264、HEVC 和 VP9。2026 年 11 月 21 日，普通桌面账户在实机解码 1920×1080 合成短片，三个格式各得到 24 帧，与电脑上独立软件解码的逐帧 SHA-256 完全相同。三个测试均走到片尾，视频处理器恢复 runtime suspend，原有座席、背光和服务实例保持一致。[内核与固件](VIDEO-CODEC-KERNEL.md)

| 容器及格式 | 实机播放路径 | 附加组件与验证 |
| --- | --- | --- |
| MP4 / H.264 High | GStreamer 1.26.2 的 `playbin` 自动选中 `v4l2h264dec` | 从已核对 Debian 签名索引的包中临时加载 H.264/H.265 解析器。384×256 和 1920×1080 各通过 24 帧。 |
| MP4 / HEVC Main | 同一 `playbin` 自动选中 `v4l2h265dec` | 两种分辨率各通过 24 帧。两份 1080p MP4 均含实际解出的 15 个 B 帧，比较包括呈现顺序。 |
| WebM / VP9 Profile 0 | GStreamer 使用 `v4l2vp9dec`。1080p 测试用 `uridecodebin` 选择解码器，并为其 CPU 接收端指定 mmap。 | Debian 原插件在低分辨率测试中丢掉首帧。试验进程加载修正插件后，两个分辨率均通过 24 帧。 |

测试进程只看得到 Iris 解码节点，不能读取相机、屏幕、麦克风或 GPU。原插件能直接解码已经按访问单元分好的 H.264 和 HEVC。普通 MP4 中的码流使用长度前缀，封存的桌面缺少相应的解析器。单独提供 Debian 的 `libgstvideoparsersbad.so` 与 `libgstcodecparsers-1.0.so.0` 后，`playbin` 按原配置完成 MP4 解码。`uridecodebin` 接简单的 CPU 转换器时默认协商出 DMA-BUF，指定解码器的 `capture-io-mode=mmap` 后也通过。桌面应用使用的 `playbin` 有自己的输出协商路径。[桌面软件栈](VIDEO-CODEC-USERSPACE.md) · [VP9 首帧及错误处理](VIDEO-VP9.md)

普通 H.264、HEVC 使用 Debian 原 V4L2 插件。VP9 修正只加载到试验进程。浏览器硬件加速、长时间播放、十位视频、功耗和硬件编码仍待单独验收。

## 在平板内存中试用桌面播放器

实机脚本通过 USB 将 dev12.8 和离线 Parole 安装包送入内存，校验封存的根文件系统，并在临时可写层安装 116 个 Debian 包。安装后的 1,240 项软件包清单与构建结果一致。普通桌面用户在独立的 2560×1600、200% 缩放 Xfce 显示中，从 Thunar 打开文件。程序核对选中的文件、Parole 进程实际打开的路径和三个不同的窗口色块组合。X11 输入和像素采样都限于虚拟显示。桌面会话使用私有 D-Bus 和网络，只能访问一个媒体设备，即实机 Iris 解码器。[离线播放器与包清单](VIDEO-PLAYER.md)

同一组三段 1080p 影片在只加载 VP9 首帧修正时也有连续画面。逐个检查播放器进程后发现，解析器传入了部分 BT.601 色彩信息，三个 Iris 实例都打开了解码节点，但拒绝了输入格式。Parole 随即通过软件解码。其中两段 MP4 的输入已经正确转换为字节流。第二版私有插件只在这个解码器已报告支持 BT.601 时，接纳实测的两种部分描述。独立的实机 `playbin` 测试将这三段影片各播到片尾，Iris 返回的 144 帧逐帧与 FFmpeg 软件参考相同。[播放器测试片与完整 BT.709 对照](VIDEO-PLAYER.md)

用第二版插件从 Thunar 再次打开同一批文件，三个 Parole 窗口均显示了红绿、绿蓝和蓝红三对色块。每个播放器进程自己的日志均记录了 10 个来自对应 Iris 解码器的输出缓冲，VP9 的首帧也已确认。播放器打开测试在看齐三次画面后结束。48 帧的逐帧比对使用上文单独的片尾测试。

组合试用包把播放器和修正安装到同一个 RAM 试用系统。通过默认桌面文件打开视频时，三个 Parole 进程都自行加载了专属插件，各自使用播放器缓存，三种格式均通过同样的画面和硬件缓冲检查。桌面测试环境没有设置插件路径。另一组具有完整 BT.709 标签的 1080p 对照视频，只加载较早的 VP9 首帧修正就通过了三种格式的硬解和窗口检查。[组合包与重建说明](VIDEO-PLAYER-INTEGRATION.md) · [色彩协商与首帧修正](VIDEO-VP9.md)

下方命令使用桌面测试的三段循环彩色视频。电脑端准备已固定哈希的 dev12.8 RAM 包和组合播放器归档。平板端的 `tablet_xvfb_usr` 指向已解包的 Debian ARM64 Xvfb 测试工具目录，其中包含 `bin/Xvfb`。试用结束后脚本核对原座席、启动、挂载和系统服务，并清除暂存目录。[实机播放器脚本](../tests/video-codec/run-parole-tablet.sh)

```bash
PAROLE_BUNDLE_SHA256=0abe5888335940419fe49d7ca2e03ca17a5f767aeb6b10d2c01de5b34081e64f \
    bash tests/video-codec/run-parole-tablet.sh "$usb_ssh" "$ram_bundle" "$combined_player_archive" \
    "$repeating_clips" "$tablet_xvfb_usr"
```

复测这些桌面文件的全部 48 帧时，可以用同一批压缩文件生成参考，并把生成的目录传给下文的 `run-tablet.sh`。三个模式分别是 `h264-playbin`、`hevc-playbin` 和 `vp9-playbin`。三者均通过 `IRIS_V4L2_PLUGIN` 和 `IRIS_V4L2_SHA256` 选择第二版插件，两种 MP4 另需解析器目录。

```bash
uv run --no-project --with imageio-ffmpeg==0.6.0 python \
    tests/video-codec/player-reference.py "$repeating_clips" "$new_reference_dir"
```

## 复测

电脑端需要 FFmpeg（含 libx264、libx265、libvpx）、uv 和 Linux。平板继续运行原 Debian，通过已固定主机密钥的 USB SSH 连接。生成器在新目录中创建无音频的动态图案、访问单元、标准容器和独立软件参考。通过条件同时包括真实 Iris 元素、解码结束、输出尺寸、每帧内容和原设备状态。完整操作不会修改平板的软件包。

```bash
uv run --no-project --python 3.13 python tests/video-codec/make-clips.py "$ffmpeg" "$new_clips" --full-hd
bash tests/video-codec/run-tablet.sh "$usb_ssh" "$gst_tools_arm64_deb" "$new_clips" h264-playbin "$parser_root"
bash tests/video-codec/run-tablet.sh "$usb_ssh" "$gst_tools_arm64_deb" "$new_clips" hevc-playbin "$parser_root"
IRIS_V4L2_PLUGIN="$vp9_plugin" IRIS_V4L2_SHA256="$vp9_sha256" \
    bash tests/video-codec/run-tablet.sh "$usb_ssh" "$gst_tools_arm64_deb" "$new_clips" vp9-auto
```

`gst_tools_arm64_deb` 是 Debian 的 `gstreamer1.0-tools_1.26.2-2_arm64.deb`，脚本校验归档后只在 RAM 使用其中的工具。解析器目录保留 Debian 的 `usr/lib/aarch64-linux-gnu/` 布局。两个库来自 `gstreamer1.0-plugins-bad` 和 `libgstreamer-plugins-bad1.0-0` 的 ARM64 版本 `1.26.2-3+deb13u3`，脚本会核对两个 ELF。已验证插件的重建命令及 SHA-256 见首帧说明。缩减的实机记录位于本工作树的 `out/iris-physical/`。[Debian 验证工具](https://packages.debian.org/trixie/arm64/gstreamer1.0-tools/download) · [插件构建与哈希](VIDEO-VP9.md)
