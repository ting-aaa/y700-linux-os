# dev12.12 新安装后的本机校准与蓝牙身份

适用于国行 TB320FC_PRC。扬声器和传感器可以从这台平板保留的内置 UFS `persist` 分区恢复。蓝牙需要这台平板原来的 Android 适配器地址，建议在切换系统前保存。以下检查均可在本机完成，无须上传校准记录或地址。[镜像版本与校验值](DEV12.12-VERIFICATION.md)

| 项目 | dev12.12 已预装 | 本机数据何时就位 |
| --- | --- | --- |
| 扬声器 | 两颗 CS35L45 的 Protection 固件、ALSA HiFi 配置、已启用的校准服务 | 每次启动读取 `persist` 内 `/audio/spk_{1,2}_{cal_r,f0,ambient}`，在 `/run/y700-speaker-calibration/factory` 暂存两路记录 |
| 传感器 | `y700-ssc-cn350-firmware 17.0.350-1`、`y700-ssc-runtime 0.1.3`、v7 板级默认注册表（329 项） | 首次启动传感器监听器且状态为空时，从 `persist` 内 `/sensors/registry` 导入本机工厂组，保存到 `/var/lib/y700-ssc/registry` |
| 蓝牙 | BlueZ、WCN6855 身份配置工具及已启用的启动单元 | 为这台平板单独准备 `/etc/y700/bluetooth-address`；控制器报告缺少公开地址时，服务在 BlueZ 启动前设置 |

## 扬声器

安装后在平板上运行以下命令。第一条只读验证本机出厂记录，两路均须通过范围检查。第二、三条检查本次启动的准备状态和暂存文件，无须打开声音。

```sh
sudo /usr/libexec/y700-speaker-calibration check-live
systemctl is-active y700-speaker-calibration.service
sudo stat -c '%U:%G %a %s bytes' /run/y700-speaker-calibration/factory
```

预期为 `active` 和 `root:audio 640 32 bytes`。普通桌面打开扬声器路由时，HiFi 配置会装入校准。要核实两颗 DSP 确实选中各自的数值，可在本机原本就有声音播放时运行 `sudo /usr/libexec/y700-speaker-calibration verify-live`；空闲时返回 3，表示等待播放。若本机记录缺失，桌面保留较低的保护增益。[扬声器验证与故障定位](SPEAKERS.md)

## 传感器

自用镜像中已装 CN350 的 SLPI 固件、SDSP 文件和板级默认值。需要从源重建固件包时，已有构建器使用本地合法取得并经校验的 CN350 `modem.img`、`dsp.img` 及锁定版本的 Asphalt 源码。OEM 二进制的使用和再分发受其许可约束。[固件构建器](../scripts/build-ssc-firmware.py) · [包版本与来源](../config/ssc.lock.json)

新安装可在首次使用传感器前执行下列命令。导入器按 PRC 板型、内置 UFS 控制器和分区身份定位来源，只读打开 `persist`，再将经过筛选的工厂组写到 Linux 状态目录。这一步可以在传感器 DSP 离线时完成。

```sh
dpkg-query -W y700-ssc-cn350-firmware y700-ssc-runtime
sudo /usr/libexec/y700-ssc/import-calibration import-live
sudo test -s /var/lib/y700-ssc/registry/.y700-factory-calibration.json && echo '已找到本机导入收据'
```

如果首次启动时读不到工厂数据，监听器会取板级默认值。单有 `registry/` 目录不能证明工厂组已导入。已有相同收据时重复导入会保留学习值；已有其他状态时请保留原目录，并按校准指南用独立的 `--state` 目录核对。只有 `/dev/fastrpc-sdsp` 可用时才预期监听器运行，可用 `systemctl is-active y700-ssc.service iio-sensor-proxy.service` 检查。[校准与同机备份替代路径](SSC-CALIBRATION.md) · [服务生命周期](SSC-SERVICE.md)

## 蓝牙

在 Linux 电脑上进入发行 TAR 解出的目录，指定同一台平板上已授权 ADB 的 Android 序列号。若平板现在运行 Debian，可将 `--adb-serial "$ADB_SERIAL"` 换为 `--getprop "$PRIVATE_GETPROP"`，读取此前保存的本机属性文件。工具核对 TB320FC 的型号、设备名、联想地址和 Android 蓝牙服务地址；也支持从本机原始 `bt_config.conf` 的 `[Adapter]` 段取值。[Android 来源与交叉检查](PERIPHERALS.md#prepare-a-fresh-installation)

```sh
umask 077
private=$(mktemp -d "$HOME/y700-unit.XXXXXXXX")
uv run --no-project --python 3.13 python ./prepare-bluetooth-identity.py \
    --adb-serial "$ADB_SERIAL" --output "$private/bluetooth-address"
bash ./unpack.sh --bluetooth-address "$private/bluetooth-address" "$private/images"
(cd "$private/images" && sha256sum --strict -c SHA256SUMS)
```

个性化解包在新的根镜像写入属主 `root:root`、权限 `0600` 的地址文件，另存 `UNPERSONALIZED-SHA256SUMS` 以便核对通用版本。个性化根随地址文件一起私存。如果已经安装通用根，将上述准备好的单个地址文件通过自己的私有通道传到平板，在平板上将 `PRIVATE_FILE` 设为其路径，运行以下命令。已存在的地址文件会保留；地址不同则停止。

```sh
sudo bash -seu -- "$PRIVATE_FILE" <<'INSTALL'
dst=/etc/y700/bluetooth-address
if [[ -e $dst || -L $dst ]]; then
  [[ -f $dst && ! -L $dst && $(stat -c '%u:%a' "$dst") =~ ^0:(400|600)$ ]]
  cmp -s "$1" "$dst"
else
  tmp=$(mktemp /etc/y700/.bt-address.XXXXXXXX)
  trap 'rm -f -- "$tmp"' EXIT
  install -o root -g root -m 0600 -- "$1" "$tmp"
  ln -T -- "$tmp" "$dst"
fi
systemctl start y700-bluetooth-identity.service
INSTALL
```

在平板上用仓库的 `bash scripts/check-bluetooth-hid.sh` 可读回 BlueZ 的电源状态和地址是否非零，检查不会扫描或配对。若要验证**恰好是原地址**，以下命令适用于板载 WCN6855 为 `hci0` 的系统，成功只输出匹配结果。遇到已经有地址但比对不同的控制器，先复核同机来源。[控制器配置逻辑](../packaging/root/usr/libexec/y700-bluetooth-identity)

```sh
sudo bash -eu -c '
  grep -zFxq qcom,wcn6855-bt /sys/class/bluetooth/hci0/device/of_node/compatible
  addr=$(cat /etc/y700/bluetooth-address)
  actual=$(busctl --system --auto-start=no --timeout=2s call org.bluez /org/bluez/hci0 \
      org.freedesktop.DBus.Properties Get ss org.bluez.Adapter1 Address)
  [[ $actual == "v s \"${addr^^}\"" ]] && echo "本机蓝牙地址匹配"
'
```

## 验证范围

电脑只读检查了通用根 `5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3`。22 项合成测试覆盖双扬声器校准、ext4 工厂注册表和 Android 身份提取。随后用合成地址对完整 dev12.12 发行包进行了个性化解包，回读地址字节、属主和权限均正确，只有根镜像的校验值改变。本轮验证使用的输入均来自电脑。[扬声器测试](../tests/test_speaker_calibration.py) · [传感器测试](../tests/test_ssc_calibration.py) · [身份测试](../tests/test_bluetooth_provision.py)
