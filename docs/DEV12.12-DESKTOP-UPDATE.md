# dev12.12 桌面离线更新

此归档可一次更新已有 Y700 Debian 桌面的三个应用。相机首次打开时预选后置主摄，蓝牙管理器改善触屏布局和连接错误详情，中文输入法修复部分情况下需要点两次候选词的问题。归档同时带有三个旧版 ARM64 软件包，安装后请保留解包目录，以便离线回退。[相机更新](QCAM-DESKTOP-UPDATE.md) · [蓝牙管理器](BLUEMAN-PAIRING.md) · [中文触屏输入](CHINESE-INPUT.md)

相机方向修复包从表内的 y7007 继续升级到 y7008。顶栏快捷设置为单独安装包，两者均已用于日用平板。[相机方向](CAMERA-ORIENTATION.md) · [快捷设置](QUICK-SETTINGS.md)

| Debian 包 | 原版 | 更新后 |
| --- | --- | --- |
| `y700-camera-qcam` | `0.7.2-1~bpo13+1.y7005` | `0.7.2-1~bpo13+1.y7007` |
| `blueman` | `2.4.4-1+y7002` | `2.4.4-1+y7003` |
| `ibus` | `1.5.32-2` | `1.5.32-2+0y7001` |

## 安装、检查和回退

将 `y700-dev12.12-desktop-update.tar` 放入空目录，先核对下列 SHA-256，再解包。归档大小为 3,594,240 字节。

```sh
echo 'd684a33b0a7cdfa420ba99c303eb0f1609f458871d543695a1405fa61ec69195  y700-dev12.12-desktop-update.tar' | sha256sum --strict -c - &&
  tar -xf y700-dev12.12-desktop-update.tar &&
  sudo bash desktop-update/update.sh install &&
  sudo bash desktop-update/update.sh check
```

`check` 显示 `state=updated` 表示三个新版均已配置，主要程序文件已比对，APT 依赖检查通过。相机下次打开即使用新版；退出再登录自己的 Xfce 会话可加载新的蓝牙管理器和 IBus 面板。需要恢复表中三个原版时，在同一目录运行以下命令。

```sh
sudo bash desktop-update/update.sh rollback
sudo bash desktop-update/update.sh check
```

回退后应显示 `state=original`。如果先前仅更新过其中一个应用，或 dpkg 解包后中断，选择期望的最终状态，再次运行 `install` 或 `rollback` 即可。三个包已经达到期望状态时显示 `transaction=0`。脚本验证六个归档、三个已安装版本及其关键文件，使用 dpkg 保留本地 conffile。若发现 Debian IBus 维护脚本会删除的旧文件 `/etc/xdg/autostart/ibus.desktop`，程序会在安装前退出，待管理员保存并移开该文件。另行安装的软件可保留，安装入口按这三个包的版本和实际 Debian 依赖判定兼容性。

## 重建和验证

在 Linux 上，从三个已发布归档可重建相同的 TAR。在支持执行 ARM64 程序的主机上，`check.sh` 使用只读的通用 dev12.12 根镜像与一次性写层测试完整更新流程。[组包脚本](../scripts/package-desktop-update.sh) · [更新脚本](../scripts/update-desktop-packages.sh) · [测试程序](../tests/desktop-update/check.sh)

```sh
mkdir -p out/dev12.12-desktop-update
bash scripts/package-desktop-update.sh \
  out/dev12.12-qcam-update/y700-qcam-y7007-offline.tar \
  out/dev12.12-bt-desktop/y700-blueman-manager-y7003-offline.tar \
  out/chinese-input-touch/y700-ibus-tray-offline.tar \
  out/dev12.12-desktop-update/y700-dev12.12-desktop-update.tar
sudo bash tests/desktop-update/check.sh /path/to/dev12.12/root.ext4 \
  out/dev12.12-desktop-update/y700-dev12.12-desktop-update.tar
```

通用镜像的 SHA-256 为 `5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3`。测试按包名、版本和架构核对全部 1,240 项。原版和回退后的清单摘要均为 `ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047`，更新后为 `073a8831c0a7aa8cda470b59208cbfb258f546cd5e39cd36a792367959fb7430`。完整测试记录位于 `out/dev12.12-desktop-update/arm64-combined-lifecycle.log`。

两次重复操作均未写入 dpkg 状态或日志。分别在升级、回退的解包阶段停下，重新运行后都恢复了目标清单。修改过的 Blueman 配置文件逐字节保留。额外安装一个本地包得到 1,241 项时，升级和回退同样通过，额外的软件包一直保留。测试结束后复核原始镜像摘要一致，测试日志 SHA-256 为 `a61937c54ccf540100d57772e3e9c8f98f96a0e6191eb222bc6406141abd3d78`。
