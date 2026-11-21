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

## 实机快进、回拖和暂停

在 TB320FC_PRC 的原内核上，通过 USB 把 dev12.9 传入运行内存，从独立 Xfce 桌面的 Thunar 打开 1920×1080 本地视频。200% 缩放下，测试程序点击真实 Parole 窗口的播放键、点击进度条前跳，再按住滑块向回拖动。每段测试片持续 16 秒，每 4 秒改变一次颜色，每 2 秒有一个关键帧。程序同时核对窗口像素、暂停时画面是否静止、恢复后的颜色和同一播放器进程新收到的硬件解码缓冲区。[测试片生成和校验](../tests/video-codec/seek-clips.py) · [窗口和解码器观测](../tests/video-codec/parole-transport.py)

| 8 位格式 | dev12.9 原播放器组合 | 更新后的平板内存试用 |
| --- | --- | --- |
| MP4 / H.264 | 快进、回拖、暂停、恢复均通过 | 四项通过，继续使用 Iris |
| MP4 / HEVC | 能开始播放，首次前跳后 10 秒内没有新画面 | 四项通过，继续使用 Iris |
| WebM / VP9 | 能开始播放，首次前跳后 10 秒内没有新画面 | 四项通过，继续使用 Iris |

进度条前跳到黄色、回拖到绿色，暂停保持绿色超过 4.4 秒，恢复后进入蓝色。播放键从 72×68 增至 96×96 设备像素，进度条从 852×68 调整为 708×96。测试使用独立显示会话中的指针，实体手指手感、浏览器、长片和音画同步还需分别验证。[HiDPI 播放控件](../packaging/parole-touch/README.md)

HEVC 和 VP9 在原组合上跳转后都触发了 V4L2 的 `SOURCE_CHANGE`。一次试验在同一文件描述上重建两个队列，HEVC 成功重新协商 NV12，但仍未返回新画面。播放器专用插件改为在这台 Iris 执行刷新跳转时释放旧队列并打开新的解码会话，保留输入格式。H.264 继续使用原有流程。此次区分依据是平板上三组受控对照，底层固件停滞的原因仍待定位。[Linux 有状态解码器接口](https://docs.kernel.org/userspace-api/media/v4l/dev-decoder.html) · [GStreamer 跳转语义](https://gstreamer.freedesktop.org/documentation/additional/design/seeking.html)

快速回拖还暴露了一个时序问题。前一次跳转刚启动压缩输入队列、尚在等待输出格式时，用户可能已经拖到了下一个位置。只检查输出画面队列是否就绪会漏掉这次跳转。修正以压缩输入队列已启用为条件。VP9 的详细记录中，三次重新打开会话后，硬件都返回了该位置的首个关键帧，随后返回下一帧。首个空缓冲区仍按保守规则报告，未放宽底层错误检查。[Iris 跳转修正](../tests/video-vp9/iris-seek.patch)

复验还捕捉到了另一处竞态。早期整包 `72a2f245…` 首轮通过，第二轮 HEVC 快速回拖时，下一次刷新恰好落在硬件输出缓冲池激活期间。这次刷新未能结束。修正后的解码器会中断刚刚激活的旧缓冲池。原版界面在同一台平板复测时，日志记录了这条中断路径，随后仍完成三轮往返、暂停和恢复。GStreamer 上游也处理过停止解码时新缓冲池激活造成的类似等待。[GStreamer 上游修复](https://github.com/GStreamer/gstreamer/commit/225d6b7e114b40066db3a3b0309b676b65f57526)

Parole `4.18.2-1+y7002` 在高 DPI 下让滑块和时间提示随手势移动，松开时向 GStreamer 发出一次跳转。这样即使拖过许多位置，也只需在最终位置重新解码。实机验收对每次手势同时检查解码器新输出、窗口实际颜色和跳转事件数。[播放控件补丁](../packaging/parole-touch/seek/scrub.patch)

VP9 的新会话还有一个恢复条件。实机曾在索引关键帧之前收到一包 44 字节的依赖帧，输出队列在关键帧到达前就开始等待格式并报错。最终插件在新开的 VP9 会话先跳过标为依赖帧的输入，从关键帧开始送入硬件。保留原版滑块进行快速回拖时，实机 14 次跳过前置依赖帧并从关键帧开解，三轮往返全部通过。[V4L2 恢复点定义](https://docs.kernel.org/userspace-api/media/v4l/dev-decoder.html#glossary)

触屏输入另在 ARM64 虚拟机中验证。虚拟多点触屏通过 Linux 输入设备和 Xorg libinput 将触摸按下、移动和抬起事件送入实际 Parole 窗口。一次点击跳到 13 秒。随后三次拖动各有八次位置更新，按住期间均未发出跳转，松手后各发出一次，目标分别为 5、13、5 秒。实际窗口依次显示黄、绿、黄、绿。平板上的测试覆盖真实 Iris 和播放器画面；实体屏幕手感仍需用户体验。

2026 年 11 月 21 日，最终离线升级包在平板的两次独立 RAM 会话中分别通过。每次从 1,240 个软件包的封存桌面安装，从 Thunar 分别打开三种格式，每种连续做三轮前跳和回拖，再暂停和恢复。两次共 36 个跳转手势，各产生一次 GStreamer 跳转，实际画面及硬解输出全数符合预期。两次退出后，原座席和服务均正常，解码器进入运行时挂起，新增挂载和循环设备均为零。

工作树内的归档为 `out/video-player-upgrade/y7002-keyframe/y700-dev12.9-player-update-arm64.tar.gz`，共 5,237,744 字节，SHA-256 为 `d9ee91f23a6b6177e770378203e8bd220b328134c6534ac798cfc1d86609ff04`。可在 `out/video-seek/verified-gestures.txt` 查看每次操作的结果，记录的 SHA-256 为 `3d995b5fa918bf3009a050c6b0db9112b76ef96ad1bf01a85cf41f6767e68c17`。

复测使用已校验的 dev12.9 RAM 包和配套离线升级包。在电脑的 Linux 环境运行以下命令，`update_sha256` 取自升级包的独立校验清单。完成后可在输出中查找每次动作的画面颜色和新硬解缓冲数。[升级包构建、安装与回退](../tests/video-player-upgrade/README.md)

```bash
uv run tests/video-codec/seek-clips.py "$new_seek_clips"
PAROLE_UPGRADE_ARCHIVE="$update_archive" PAROLE_UPGRADE_SHA256="$update_sha256" \
    bash tests/video-codec/run-parole-tablet.sh --transport "$usb_ssh" "$dev12_9_ram_bundle" \
    --preinstalled "$new_seek_clips" "$tablet_xvfb_usr"
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
