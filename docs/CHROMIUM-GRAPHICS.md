# Chromium 图形设置

可选平台更新在 Xfce 的「设置管理器 → 硬件 → Chromium 图形」中加入「在 Chromium 中使用 GPU 加速」。每个账户初次使用时均关闭。勾选后完全退出 Chromium，再从原来的浏览器图标打开。要恢复软件渲染，清除勾选并同样重开。已有 Chromium 进程会接收新窗口请求，因此仅关闭当前标签页无法应用更改。

状态保存在该用户的 GSettings 键 `org.y700.chromium hardware-acceleration`。软件模式和无法读取键时沿用 `--disable-gpu`。硬件模式请求 ANGLE/Vulkan，普通窗口收到 `--use-gl=angle --use-angle=vulkan`。显式调用 `--headless` 时额外收到 `--enable-gpu`。此前配置或调用者已指定 `--disable-gpu`、`--use-angle` 或 `--use-gl` 时，硬件模式尊重这项选择。在浏览器中打开 `chrome://gpu` 可查看实际后端。

启动入口仍是发行版的 `chromium.desktop` 和 `/usr/bin/chromium`。更新的是原有 `y700-platform` 软件渲染配置，并新增设置界面、菜单和 schema。Debian 启动器继续读取同目录内的其他配置，包括 Y700 相机和浏览器扩展设置。

## 构建、安装与回退

在 Linux 构建机上运行以下命令，从 dev12.8 的封存平台包生成更新。dev12.11 使用同一个基础包。

```sh
bash scripts/build-chromium-graphics.sh \
  out/platform-dev12.8/y700-platform_0.1.0~dev12.8_all.deb out/chromium-graphics
```

将以下两个包和 `scripts/update-chromium-graphics.sh` 放在同一目录。可以用 `sha256sum` 核对文件。

| 文件 | SHA-256 |
| --- | --- |
| `y700-platform_0.1.0~dev12.8_all.deb` | `95b8e4419a40080e98b78dbfe63839476c20479714ffb7257cfb7bbafc927583` |
| `y700-platform_0.1.0~dev12.8+gpu1_all.deb` | `2b6dd72510cc0a63744127cd68149ec28f4241a6acca587263ddcc8e3357e97e` |
| `update-chromium-graphics.sh` | `3e8d6d9e877f734608d8d7398c52cf47b19cb4e17e10a157833abd803b47fcff` |

```sh
sudo bash update-chromium-graphics.sh install \
  y700-platform_0.1.0~dev12.8_all.deb y700-platform_0.1.0~dev12.8+gpu1_all.deb
```

将命令中的 `install` 改为 `rollback` 可恢复原平台包和全账户软件渲染策略。两种操作可重复执行，均检查包、当前版本及本功能的四个文件。目标路径存在本地更改时会停止。安装和回退由 dpkg 更新系统文件，个人对该键的选择留在用户会话中。重新安装后，该账户以前保存的选择会再次生效。

## 验证

`bash tests/chromium-graphics/policy.sh` 用临时 GLib 配置验证软件默认、硬件参数、显式覆盖和第二账户的默认值。ARM64 用户态验收使用以下命令。

```sh
sudo bash tests/chromium-graphics/run.sh DEV12.11_ROOT_EXT4 ORIGINAL_DEB UPDATED_DEB ARM64_QA_DIR
```

`ARM64_QA_DIR` 提供 `bin/{Xvfb,xdotool,uv}` 和 `lib/libxdo.so.3`。验收在封存根的临时可写叠层中运行真正的 dpkg、GLib、普通用户 dconf 和 200% 的中文 GTK 界面。从桌面项打开设置并点击复选框，核对每次选择、跨进程保存和另一账户的默认策略。测试执行发行版的完整浏览器启动脚本，仅在最终浏览器 ELF 位置记录其参数。两次安装及两次回退均成功，个人 Chromium 配置样本保持逐字节一致。GPU 渲染器和像素核验使用独立的[实机测量](DEV12.11-VERIFICATION.md)。
