# 在平板上更新 Debian 软件

在 Xfce 打开 **设置 → 软件更新**。平板会从配置好的 Debian 软件源刷新索引，再打开软件包更新程序。点击软件包可查看详情，勾选需要的项目后点击安装。Debian 的授权策略可能要求输入管理员密码。关闭窗口即可结束查看。[Debian 软件包更新程序](https://packages.debian.org/trixie/gnome-package-updater)

网络或授权错误会显示在窗口里，可以轻点 **重试**。平板已有索引时，还可选择 **查看已有列表**。该列表使用上次保存的仓库信息。Debian 软件源提供常规软件及安全更新，Y700 的板级内核和专属补丁随本项目的发行包交付。[Debian 软件维护说明](https://www.debian.org/doc/manuals/debian-handbook/sect.regular-upgrades.en.html)

## 实机和构建记录

参考平板的三个 trixie 软件源已配置，但首次测试时本地没有索引。Debian 原版 `gpk-update-viewer` 启动时请求已有更新列表。新增的 Xfce 设置入口先经 PackageKit 请求刷新，把 Debian 原版选择器用于后续交易。刷新和选择器均在普通账户中启动，系统通过原有 PackageKit、APT、polkit 和 PAM 处理软件源和授权。[Debian 源码](https://deb.debian.org/debian/pool/main/g/gnome-packagekit/) · [设置入口](../packaging/software-updates/y700-software-updates)

在内置 dev12.11 上，此功能新增六个包。安装前保留的 1,242 项全部匹配，安装后共 1,248 项，清单 SHA-256 为 `8a4aced66e2947b07082c4b9988358f01673d617ab642bf1152e1ea275b69646`。实机 APT 通过系统密钥验证了 trixie、trixie-updates、trixie-security 三个源，此次检查列出 35 个可更新的软件包。参考机只安装了更新工具本身。该次检查的日志位于 `out/software-updates/verified/`。

实机停在登录界面时，另开的普通账户私有 200% 桌面没有取得刷新授权。它显示错误并允许明确选择已有列表。系统原版更新程序随后显示了全部 35 个候选和 2 个分类行。将六个包真正卸载后，原 1,242 项库存逐项恢复。重新安装后复查了全部 1,248 项，设置入口的三个文件与保存的归档逐字节一致。

在 ARM64 虚拟机正常登录的主桌面中，同一设置入口成功刷新签名源并自动打开更新列表。另一次冷启动在 200% 缩放下完成了全触屏安装。普通桌面账户用 Type-B 模拟触屏选择测试包，MATE 授权窗口自动聚焦密码框，Onboard 随之展开。模拟触屏依次按下十个密码键和「授权」，系统 polkit/PAM 验证成功，PackageKit 的 APT 后端把该包从 1.0 更新至 2.0。回退后全套包库存逐项恢复。该用例使用隔离的本地签名软件源。[复现说明与收据](../tests/debian-desktop-updates/README.md)

可以在项目工作区执行以下命令重新取得相同的五个 Debian 归档，并构建本地设置包。构建时已独立核验 InRelease 签名、解压后的完整软件包索引和各归档的大小与 SHA-256。设置包 `0.1.0` 的两次构建摘要相同，为 `547ea83736f209c8175e30047eed1a57e8afbe481115e0bf3d166017c2d3b2ae`。[上游归档锁](../config/software-updates-debian.lock.json) · [构建脚本](../scripts/build-software-updates.sh)

```sh
uv run --no-project --python 3.13 python scripts/fetch-debian-inputs.py \
    --lock config/software-updates-debian.lock.json --cache out/software-updates-debian
bash scripts/build-software-updates.sh out/software-updates
```

已有 Debian 桌面可以直接通过 APT 用最新兼容依赖安装构建的本地包。先检查模拟安装清单，再决定是否安装。

```sh
sudo apt update
apt-get -s --no-install-recommends install ./y700-software-updates_0.1.0_all.deb
sudo apt install --no-install-recommends ./y700-software-updates_0.1.0_all.deb
```

参考机保留六个原始归档及安装清单。关闭更新窗口、等正在进行的包事务结束后，可运行 `sudo bash /var/lib/y700/updates/software-updates-0.1.0/rollback.sh`。脚本使用 dpkg 检查依赖，只移除这次安装记录中的软件包。单独通过 APT 安装的用户可用 `sudo apt remove y700-software-updates` 移除设置入口。
