# Y700 的 WPA3 密码重试

在原版 dev12.10 的触屏网络菜单里，第一次输入错误的 WPA3 个人网络密码后，再点同一网络，有时不会出现密码框。原版的替代操作是打开「设置 → 高级网络配置」，编辑已保存网络的 Wi-Fi 安全设置。[原版复现与编辑器操作](WIFI-CHOOSER.md)

不同接入点对错误密码的响应不同。hostapd 2.11 会在拒绝 SAE 确认帧时返回状态 15，而 Debian 13 的 hostapd 2.10 在该处返回通用失败状态 1。更新后的平板无线客户端能把前者作为明确的失败事件交给 NetworkManager。状态 1 也可能由其他原因造成，重试时需要结合所选网络和用户操作判断。[hostap 上游对响应码的讨论](https://lists.infradead.org/pipermail/hostap/2022-October/040922.html) · [NetworkManager 上游处理](https://github.com/NetworkManager/NetworkManager/commit/bcb96a1b19dae7306be0b373f0cf76660499ac61)

## 开发包的安装和回退

适用基线为 dev12.10 的 Debian 13 ARM64，软件包原版分别为 `network-manager 1.52.1-1` 和 `wpasupplicant 2:2.10-24`。先在更新目录核对四个包的校验值和当前安装版本。两组包均随更新目录提供。

```sh
sha256sum --strict -c SHA256SUMS
dpkg-query -W network-manager wpasupplicant
```

当前版本匹配基线、四个文件校验全部通过后，可在本地终端安装这两个包。它们只包含客户端更改。更新系统无线服务时连接可能短暂中断。

```sh
sudo dpkg -i ./candidate/*.deb
sudo apt-get check
```

要回到上述基线，在同一目录执行以下命令。

```sh
sudo dpkg -i ./stock/*.deb
sudo apt-get check
```

如果平板已升级到比上述版本更新的 Debian 软件包，请保留新版本并重新核对适用范围。本地包使用 `+0y7001` 后缀，Debian 后续的 `+deb13u1` 版本在版本比较中优先。

## 验证与构建

ARM64 QEMU 从只读 dev12.10 根镜像启动，依次运行原版、候选和回滚后的 NetworkManager 与 wpa_supplicant。各阶段都核对了运行中的两个可执行文件、各自的 D-Bus 服务，以及普通用户读取两份 SAE 配置的结果。配置及其中随机生成的密钥始终逐字相同。安装后 1240 个软件包中仅两个目标版本变化，回滚后完整清单恢复，`dpkg --audit` 和 `apt-get check` 均通过。[原生测试程序](../tests/wifi-sae-update/run-qemu.sh)

另一台 ARM64 虚拟机使用两个 hwsim 无线设备、Debian hostapd 2.11 和普通用户 Xfce 的 nm-applet。输错密码后，客户端收到状态 15，NetworkManager 发出一次新凭证请求，菜单自动重新弹出密码框。更正后使用原配置 UUID，其他配置未变。接入点确认 SAE、管理帧保护已协商，客户端取得 DHCP 地址并通过指定无线接口 ping 通。此次使用 100% 缩放和 GTK 辅助输入。200% 屏幕键盘和真实无线电上的密码重输仍需独立验收。

在 Debian 13 ARM64 独立构建根内，取得 `wpa=2:2.10-24` 的三个 Debian 源文件，安装该源码包的构建依赖，再执行以下步骤。NetworkManager 使用独立的构建配方。两个本地包各经两次独立构建，分别得到相同的 SHA-256。把它们放到同一目录，两个按 Debian 签名索引校验的原版包放到另一个目录。[NetworkManager 构建说明](../packaging/wifi-sae-retry/README.md) · [SAE 错误码上游依据](https://lists.infradead.org/pipermail/hostap/2025-October/043817.html)

```sh
JOBS=4 bash packaging/wifi-sae-supplicant/build.sh "$WPA_SOURCES" "$CANDIDATE_DEBS"
bash scripts/package-wifi-sae-update.sh "$CANDIDATE_DEBS" "$STOCK_DEBS" new-update new-update.tar
```

归档包含 `update/candidate/`、`update/stock/`、四份包的 `update/SHA256SUMS` 和本说明。要重做原生测试，请设置 `QEMU`、`QEMU_DATA`、`KERNEL_IMAGE` 和 `ARM64_BUSYBOX`，运行 `bash tests/wifi-sae-update/run-qemu.sh ROOT_EXT4 new-update NEW_LOG`。测试内核与根镜像会先按固定的 SHA-256 校验。
