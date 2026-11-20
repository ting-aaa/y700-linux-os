# Y700 二代 Debian microSD 测试包

`y700-test-card.img.zst` 包含整张卡的 GPT、EFI 启动分区和 Debian 根文件系统。`trial-entry.tar.gz` 包含现有内置 EFI 菜单需要的四个补充文件及其校验清单。通用测试卡保留首次设密和本机校准流程。已经使用自己平板的蓝牙地址生成过个性化镜像的用户，可以从该目录重新生成配套测试卡。

## 在电脑上验证并解包

准备 Bash、GNU coreutils、tar 和 zstd。在 Linux 文件系统上的一个新目录中执行。下例把 `bundle` 设为测试包所在的绝对路径，需要约 8 GiB 可用空间。

```bash
set -eu
bundle=/path/to/dev12.5-sd-trial
(cd "$bundle" && sha256sum --strict -c TRANSPORT-SHA256SUMS)
zstd -d --sparse "$bundle/y700-test-card.img.zst" -o y700-test-card.img
sha256sum --strict -c "$bundle/SHA256SUMS"
mkdir trial-entry
tar -xzf "$bundle/trial-entry.tar.gz" -C trial-entry
(cd trial-entry && sha256sum --strict -c SHA256SUMS)
```

解包只生成电脑上的普通文件。`identity.txt` 和 `verify-physical-boot.sh` 用于随后核对平板实际从哪张卡启动，在独立的实机验证中应放在同一目录。`SOURCE-SHA256SUMS` 记录生成此卡时的原始 U-Boot、EFI 分区、Debian 根镜像和身份文件摘要。

## 从已个性化的镜像目录生成测试包

在产品源码目录运行。输入 `images` 为完整镜像的解包目录，包含 `root.ext4`、`linux-boot.fat` 和校验文件。三个输出路径都应尚未存在。生成的卡包含该机的蓝牙地址，单独保存在本地。

```bash
bash scripts/build-test-card.sh "$images" "$work/card"
bash scripts/build-trial-entry.sh --bounded-return "$work/card" "$work/entry"
bash scripts/export-board-image.sh --card-only "$images" "$work/export" "$work/card" "$work/entry"
```
