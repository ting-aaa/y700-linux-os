# Y700 二代 Debian dev12.14 全新安装

国行 TB320FC_PRC 的 dev12.14 在 Debian 13 / Xfce 桌面中预装了 `y700-camera-pipewire 1.4.2-1+y700.5`。网站请求相机时，系统会显示桌面授权和网站授权。允许后，Chromium 接收的画面会跟随内屏方向。顶栏快捷设置、触屏蓝牙管理、中文输入和首次设密桌面沿用 dev12.13。

## 在电脑上准备安装镜像

准备 dev12.13 的完整 TAR、dev12.14 的增量 TAR、随 dev12.14 提供的 `SHA256SUMS` 和 `packages.tsv`。Linux 或 WSL 需要 Bash、GNU tar、coreutils、util-linux、zstd 和 xdelta3。输出目录所在的 Linux 文件系统需有 18 GiB 可用空间。解包结束只留下最终三个映像、身份说明和校验清单。

```bash
sha256sum --strict -c SHA256SUMS
tar -xf y700-tb320fc-prc-debian-dev12.14.tar
bash y700-tb320fc-prc-debian-dev12.14/unpack.sh \
    y700-tb320fc-prc-debian-dev12.13.tar dev12.14-images
(cd dev12.14-images && sha256sum --strict -c SHA256SUMS)
```

开发机可以直接从项目的 `out/dev12.13-board/` 指定完整 TAR。解包器先校验基版 TAR，恢复 dev12.14 的 6 GiB 根，再核对 U-Boot、EFI、根和身份文件。生成的 `root.ext4` 在首次开机前已包含浏览器相机修复。可把这些文件交给现有 TB320FC_PRC 安装流程。以上命令只生成本地普通文件。

## 每台平板的身份与第一次登录

如已取得该平板原厂蓝牙地址的私密文件，可在同一条解包命令的 `unpack.sh` 后加入 `--bluetooth-address PRIVATE_FILE`。文件须由当前用户独占并设为 0600 或 0400。个性化额外需要 e2fsprogs。解包器校验地址并回读，保留通用根和个性化结果各自的摘要。扬声器与传感器校准沿用该机器自己的出厂数据。

第一次开机时用触屏设置本机密码，再登录 Xfce。默认 EFI 和备用 120 Hz 入口共用这套桌面。安装前请按现有机型的分区和恢复流程保存资料。保留原 dev12.13 TAR 可以随时重新解出该版通用安装文件。
