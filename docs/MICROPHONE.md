# TB320FC internal microphones

The dev12.9 ARM64 desktop can select a two-channel microphone when the candidate ALSA profile sees the matching capture PCM and mixer controls. On the PC, an ordinary application recorded independent synthetic channels while the speaker monitor carried a third tone. Two kernel fixes also passed an original-versus-patched ARM64 test. Physical capture on the tablet is still open. [Stereo driver verification](#stereo-driver-and-audioreach-verification) · [Application and duplex verification](../tests/microphone/virtual/README.md)

The physical Lenovo Y700 Gen 2 running `y700-platform 0.1.0~dev12.6` and `7.3.4-asphalt-prc` has **zero capture PCMs**. ALSA card `LenovoY700` exposes MultiMedia1 and MultiMedia2 playback. The board UCM profile lists only Speaker. Applications can encounter a speaker monitor source even on a system without a microphone PCM. Lenovo specifies two microphones for the Snapdragon 8+ Gen 1 TB320FC. [Lenovo product reference](https://psref.lenovo.com/syspool/Sys/PDF/Lenovo_Tablets/Legion_Tab/Legion_Tab_Spec.PDF) · [Shipping board UCM](../packaging/root/usr/share/alsa/ucm2/Lenovo-Y700/HiFi.conf)

## Factory capture path

The stock CN350 `sku_cape` resource manager selects a 48 kHz, 16-bit, two-channel backend named `CODEC_DMA-LPAIF_RXTX-TX-3` for both `PAL_DEVICE_IN_HANDSET_MIC` and `PAL_DEVICE_IN_SPEAKER_MIC`. The corresponding mixer paths `handset-mic` and `speaker-mic` both include `amic1` and `amic4`. The generic Android microphone characteristics file describes processed application channels. Its handset entry reports one processed microphone and its speaker entry reports two. The factory mixer and device tree identify the two underlying analog routes.

| Stock mixer path | Analog input | Source selected in TX macro | Factory SoundWire mapping | Factory mic bias |
| --- | --- | --- | --- | --- |
| AMIC1 | ADC1, TX0 in `ADC_LP` | DEC2, `SWR_MIC4`, TX_AIF1 | `SWRM_TX2_CH1` | MIC BIAS1, 2.7 V |
| AMIC4 | ADC3 `INP4`, `NO_HDR34`, TX2 in `ADC_LP` | DEC5, `SWR_MIC8`, TX_AIF1 | `SWRM_TX3_CH1` | MIC BIAS3, 2.7 V |

The merged stock board tree describes a split `qcom,wcd938x-codec` with RX peripheral register cells `<0xd 0x01170224>` on controller `0x03210000` and TX cells `<0xd 0x01170223>` on `0x033b0000`. The latter is a child of the VA macro in the Android tree. The stock TX macro is at `0x03220000`. The four separate SoundWire digital microphone nodes are disabled. The vendor codec identifier covers the WCD938x family. The exact 9380/9385 silicon variant remains unobserved on this tablet.

The codec reset pin is TLMM GPIO43, high in the factory active state and low in sleep. The factory DT supplies codec I/O, RX/TX and buck from PM8350 S10 at 1.8 V. The mic-bias regulator supply requests 3.296 V from PM8350C BOB. The four individual mic-bias outputs are configured for 2.7 V. The Qualcomm HDK uses 1.8 V for its mic-bias outputs and a different static TX port map. The Linux codec driver puts ADC1 on peripheral port 1 and ADC3 on peripheral port 2, both on bit 0. The Qualcomm SoundWire manager indexes `m_port_map` using that peripheral port. A board port needs to reconcile those entries with the stock capture profile’s selected manager ports 2 and 3. [SM8450 HDK wiring](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/qcom/sm8450-hdk.dts) · [WCD938x SoundWire ports](https://github.com/torvalds/linux/blob/master/sound/soc/codecs/wcd938x-sdw.c) · [Qualcomm controller port mapping](https://github.com/torvalds/linux/blob/master/drivers/soundwire/qcom.c)

| Local CN350 input | SHA-256 |
| --- | --- |
| Merged base DT plus stock overlay 14 | `7359763f57ceea931c6881581fa13c35198f0cb905116e00fdd20ec00cd181d5` |
| Saved Android running DT from this tablet | `bda4b80b9cb73e1b001cf22666890ad0139f0246e08a86d432a190d8e06ba4c6` |
| `sku_cape/resourcemanager_waipio_mtp.xml` | `18b8646e5447673d2823025c1633eab09580c452543a2256bff5811520853b5e` |
| `sku_cape/mixer_paths_waipio_mtp.xml` | `76b637235cddeda4e6b6551b0e251772bd8563e823bf897e1d076b66f40ce0c9` |
| `vendor/etc/microphone_characteristics.xml` | `78cabf57531f88bad165e5025949cc412c858041c4968beef30db0a5ec1c0d65` |

## Native Debian findings

The metadata-only probe reads the kernel’s ALSA inventory, SoundWire device list, active tree, configuration and the installed board profile hashes. The physical receipt at `out/microphone/physical-capability.log` has SHA-256 `64ce15a444ff26aa0efc89c77d6fb788cd67ed042f411007f6d3dc21b403f5b3`. It enumerated zero SoundWire peripherals. RX and TX macro nodes are marked okay. The VA macro and all four SoundWire controllers are disabled. The active kernel has `CONFIG_SOUNDWIRE=m`, with the Qualcomm manager, WCD938x SDW and the RX, TX and VA macro drivers unselected. No sound device was opened. [Physical probe](../tests/microphone/inspect.sh)

The current board DTS supplies a single `PRIMARY_MI2S_RX` speaker backend. The board-specific machine driver lists two speaker endpoints. Linux already provides codec-side `Analog Mic1`, `Analog Mic4`, `MIC BIAS1`, `MIC BIAS3`, ADC controls and the DEC2/DEC5 capture muxes. The board still needs the split codec, supplies, SoundWire devices, kernel options, analog bias and routing links, and a `TX_CODEC_DMA_TX_3` DAI link across the Q6, WCD capture, TX bus and TX macro. Once ALSA binds these, UCM can select the graph and export a physical capture PCM to WirePlumber. Moving those dependencies onto the existing card can also affect speaker card registration during probing. The Q6 machine driver already supports a 48 kHz TX3 back end. [Asphalt board patch](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/linux-kernel/sm8475/asphalt/patches/local/0008-asphalt-usb-audio.patch) · [Codec routes](https://github.com/torvalds/linux/blob/master/sound/soc/codecs/wcd938x.c) · [TX macro](https://github.com/torvalds/linux/blob/master/sound/soc/codecs/lpass-tx-macro.c)

## Kernel and board integration

Starting with the prepared board kernel configuration (`a20e5eb8…`), five explicit module settings survived `olddefconfig`. They are `SOUNDWIRE_QCOM`, `SND_SOC_WCD938X_SDW`, `SND_SOC_LPASS_RX_MACRO`, `SND_SOC_LPASS_TX_MACRO` and `SND_SOC_LPASS_VA_MACRO`. Kconfig selected the WCD938x core, WCD common, Class H, MBHC, LPASS macro common and SoundWire regmap. On this tree `swr1` takes its interface clock from `rxmacro`, `swr2` from `txmacro`, and both macros take `fsgen` from `vamacro`. VA therefore participates in the capture clock dependency even when the graph uses only TX3. An isolated build with Clang/LLD 21.1.8 compiled the Qualcomm manager, WCD938x core, WCD938x SDW and all three LPASS macros into six verified AArch64 ELF objects. The receipt is `out/microphone/native-driver-build.log`. These are compile checks. Module loading and runtime PM remain open. [SM8450 shared SoC tree](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/qcom/sm8450.dtsi)

The wiring check reads the original CN350 merged DTB and a saved running Android DTB from this tablet. Both resolve to the same codec supplies, four bias levels, GPIO reset states, SoundWire controllers, bus IDs, pin assignments and drive strengths. The tool checks the corresponding pins and regulator ranges in the prepared Debian DTB (`1fcd5ded…`). [Three-tree and factory mixer comparison](../tests/microphone/check-wiring.py) · [Factory channel map format](https://android.googlesource.com/kernel/msm.git/+/494fd11726717faabf58dbf2d7f56e58baafdda1/Documentation/devicetree/bindings/sound/wcd_codec.txt)

| Board connection | Confirmed stock and Linux integration facts |
| --- | --- |
| Codec power | Linux has `&pm8350_s10` at fixed 1.8 V and `&vreg_bob` with a DT range of 3.008–3.960 V. These match the stock phandle endpoints. Linux's WCD driver bulk-enables the supplies. The board still needs a consumer-scoped voltage request compatible with its shared BOB and other rail users. |
| Codec bias and reset | `qcom,micbias{1,2,3,4}-microvolt = <2700000>` corresponds to stock. The analog routes are `AMIC1 ← Analog Mic1 / MIC BIAS1` and `AMIC4 ← Analog Mic4 / MIC BIAS3`. The clock/data GPIOs below belong to LPASS. WCD reset uses the separate TLMM GPIO43, active low. |
| SoundWire pinctrl | TX clock GPIO0, data GPIO1/2/14, factory strength 4 mA. RX clock GPIO3, data GPIO4/5, factory strength 2 mA. The native SoC pin lists match, but both native groups default to 2 mA. |
| WCD transport | Both RX and TX slave phandles are required by the WCD core. The HDK uses `sdw20217010d00` on devices `<0 4>` for RX and `<0 3>` for TX. The factory TB320FC IDs agree on those two unique IDs. The WCD938x driver uses a four-entry static TX map to identify its TX peripheral. The active AMIC routes constrain entries 1 and 2 to manager ports 2 and 3, respectively. The codec and manager tables in both saved factory trees resolve to the default RX map `<1 2 3 4 5>` and TX map `<1 1 2 3>`. Applying the two named factory ADC overrides gives a candidate static TX map of `<2 3 2 3>` for the internal microphone profile. This leaves the dormant digital input destinations at their factory defaults. Actual bus channel allocation and acoustic order still await testing. |
| Q6 DAI link | The HDK's WCD capture link uses CPU `<&q6apmbedai TX_CODEC_DMA_TX_3>`, codec DAIs `<&wcd938x 1>, <&swr2 0>, <&txmacro 0>`, and platform `<&q6apm>`. Factory mixer values select DEC2 and DEC5. The installed speaker backend remains the separate primary MI2S link. |

In a read-only sample with the microphone absent, regulator sysfs reported S10 enabled at 1.800 V and BOB enabled at 3.032 V, with effective BOB limits of 3.032–3.960 V. These are software-reported regulator values. The PM8350C BOB driver in this kernel uses the `pmic5_bob` selector table, starting at 3.000 V with 32 mV steps. Its adjacent selectors are 3.288 and 3.320 V. Neither represents the factory consumer's exact 3.296 V request. A fixed `regulator_set_voltage(3296000, 3296000)` vote therefore cannot reproduce the factory setting with this driver. Board-specific qualification of the RPMh vote or regulator model is needed before choosing an active voltage. The factory WCD output target remains 2.700 V. The physical sample is in `out/microphone/regulator-metadata.log`. [PM8350C regulator and selector definitions](https://github.com/torvalds/linux/blob/master/drivers/regulator/qcom-rpmh-regulator.c)

The Linux binding accepts `qcom,wcd9380-codec` and `qcom,wcd9385-codec`. Both use the same probe. The Linux codec driver selects variant controls using the ID field of `WCD938X_DIGITAL_EFUSE_REG_0` (0 for WCD9380, 5 for WCD9385). Both stock DTs specify the family. The available saved OEM boot log and vendor audio XML provided no runtime variant. The factory `machine_dlkm.ko` constructs an ALSA `codecs` directory and calls `wcd938x_info_create_codec_entry`. In the shipped `wcd938x_dlkm.ko`, that function constructs `wcd938x` with separate `version` and `variant` leaves. Its variant reader contains both chip names. On an already running stock Android system, the specific check is the contents of `/proc/asound/card*/codecs/wcd938x/variant`. This file was absent from the saved inventories. The module hashes are `cf7a2e834dc3d3cc985a615f15d10887d2888bb4c5172a67cc6b1e9fab2e9d1d` (machine) and `7e4651a68cdf17413984a567efb545c5c9fd191c0c99cab6a722d37e42792e0a` (codec). A bootable microphone DT is pending that identification and a supported BOB voltage policy. Hardware transport and acoustic qualification then remain. [WCD938x binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/sound/qcom,wcd938x.yaml) · [SoundWire binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/sound/qcom,wcd938x-sdw.yaml)

## Offline AudioReach candidate

The small M4 extension in the test tree adds one two-channel MultiMedia3 capture frontend and one codec DMA TX3 backend to the existing board topology. It is adapted from the matching SM8450 HDK reference. The public Asphalt topology still contains only the two playback streams at revision `17f4a785`. [Board topology](https://github.com/dianqk/nixos-android-devices/blob/17f4a785e2737d4635d2bf55369e519a635bde49/pkgs/asphalt/audio/Lenovo-Y700.m4) · [AudioReach reference](https://github.com/linux-msm/audioreach-topology/blob/993a17dcb672357998a463a73f120064d6c74f4f/SM8450-HDK.m4) · [Candidate](../tests/microphone/tx3.m4)

On Linux, point the build below at the pinned sources. It creates a fresh output directory. `alsatplg` 1.2.15.2 with libatopology 1.2.15.3 reproduced the installed board blob. The test decodes the candidate, checks the 48 kHz S16_LE stereo PCM, endpoint module ID, RXTX/TX3 hardware parameters and all eight connections through to the shared-memory reader. Every original PCM, widget, embedded control and route payload is byte-identical in its original ABI block. The topology compiler reports the external speaker and capture DAI streams, which their kernel DAI drivers supply. The candidate is a PC-side firmware build only. Candidate hardware enumeration, microphone channel order, acoustic response and interaction with simultaneous speaker playback remain untested. [Build and ABI comparison](../tests/microphone/build-topology.py)

```sh
uv run --no-project tests/microphone/build-topology.py \
    "$ASPHALT/pkgs/asphalt/audio/Lenovo-Y700.m4" "$AUDIOREACH_TOPOLOGY" out/microphone-build
```

| Artifact | SHA-256 |
| --- | --- |
| Installed and rebuilt playback topology | `bfb28e0af200bdc000e7d03af30e11d191200a8620a4179a6afe2d5c8ef26d63` |
| Offline candidate with two-channel capture | `aa6d0c1a904bafa20915528cae810ee08560d262f174c52465c386629e1b6422` |
| Installed dev12.6 speaker UCM | `3147a57e096b84286a392f23a35ec2fbf73bd969565d5359e50dbbad16caa8c7` |

## Stereo driver and AudioReach verification

In the prepared 7.3.4 kernel, the TX macro remembered a single most recently selected decimator per audio interface. With DEC2 and DEC5 selected, selecting DEC2 a second time increased the reported channel count to three. Unmuting then affected only DEC2, and disabling both inputs left a stale route. The candidate derives the channel count from the active mask and mutes or unmutes every selected path. [TX macro fix](../config/kernel/asphalt-lpass-tx-stereo.patch)

The board also needs to tell AudioReach which physical DMA slots carry samples. The stock mixer selects DEC2 and DEC5. The published Waipio TX macro returns those decimator indices as bits, and Qualcomm's downstream graph manager passes the active bitmap to the DMA interface. The native CPU DAI initially assigns a two-channel stream to slots 0 and 1. The Y700 capture callback now supplies a fully specified map for TX3 after hardware-parameter setup and before the DSP command is built. This associates logical channels one and two with slots 2 and 5. Acoustic left/right placement remains unmeasured. [Waipio decimator map](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450/blob/877203a7cf9b79973d44a9db716490f95d820110/vendor/qcom/opensource/audio-kernel/asoc/codecs/lpass-cdc/lpass-cdc-tx-macro.c#L1142-L1158) · [Qualcomm graph manager](https://github.com/Xiaomi-SM8650/android_vendor_qcom_opensource_agm/blob/cb1c0fbbcdb8e75315ff09504bf4ef537ab52561/service/src/graph_module.c#L277-L301) · [Y700 DMA mapping](../config/kernel/asphalt-tx3-dma-map.patch)

Two fresh ARM64 QEMU guests used the same prepared Asphalt kernel. Each ran the real TX macro module against a RAM-backed register window and a registered ALSA card. A separate guest test used the actual board configuration callback, CPU DAI configuration functions, packet allocator and AudioReach command builder. It inspected the outgoing bytes at the DSP transport boundary. No physical DSP participated.

| Observation | Original driver | Candidate |
| --- | --- | --- |
| Active channels after selecting DEC2, DEC5, DEC2 | 3 | 2 |
| Paths actually unmuted | DEC2 | DEC2 and DEC5 |
| Paths reported after disabling both | Mask `0x04`, count 2 | Empty, count 0 |
| Reopen with only DEC5, then close | No unmuted path, stale count 3 on close | DEC5 alone, count 0 on close |
| 48 kHz, 16-bit stereo TX3 DMA command | `active_channels_mask=0x03` | `active_channels_mask=0x24` |

The two full kernel module builds and the compact serial receipts are in `out/microphone/tx-stereo/`. On a Linux build host, use an unmodified prepared kernel tree, its installed modules root, a static AArch64 BusyBox, Clang, dtc, uv and QEMU. The output directory must be new.

```sh
bash tests/microphone/tx-macro/run.sh "$kernel_build" "$modules_root" "$arm64_busybox" "$new_logs"
```

## Board wiring and desktop capture

The offline device-tree test compiled both WCD9380 and WCD9385 hypotheses against the exact board source. It compared the capture DAI, both SoundWire links, GPIO controllers, bias routes and ADC-to-TX links with the retained CN350 inputs. The speaker and regulator properties passed comparison to the base. The compiled variants differ only in the WCD compatible string. Both factory trees specify separate normal and active-only defaults for the BOB regulator, 3.296 V and 3.008 V respectively. Those properties specify requests. They do not establish the measured voltage when recording. The codec variant, a supported consumer voltage request, real bus enumeration, capture and simultaneous physical speaker operation are still open. [Board graph test](../tests/microphone/board-graph/README.md)

The candidate UCM includes the existing speaker sequence and looks up the capture PCM on the same card. With the capture endpoint absent, WirePlumber exposed no microphone, although a Pulse default recording request could still read the speaker monitor. With the endpoint present, the same unprivileged client recorded 48,000 frames at 48 kHz with a 1,000 Hz left and 1,500 Hz right signal. The simultaneous monitor carried 375 Hz on both channels. These generated signals exercised the sealed dev12.9 audio stack. [Candidate UCM](../packaging/microphone/HiFi-Mic.conf) · [ARM64 duplex test](../tests/microphone/virtual/README.md)
