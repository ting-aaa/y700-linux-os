# Offline TB320FC microphone graph

This test builds the board tree twice, once for each WCD silicon variant supported by Linux. The saved CN350 trees identify the WCD938x family. The silicon variant on this board still requires identification. The test keeps the compiled files inside a temporary directory and prints their hashes.

Use the prepared Linux 7.3.4 Asphalt source and its built `scripts/dtc/dtc`, Clang, `fdtget`, Bash and uv. The inputs are the CN350 base with overlay 14 applied, the saved CN350 running Android tree, and the matching vendor `etc/audio/sku_cape` directory. Run from the product checkout.

```sh
bash tests/microphone/board-graph/run.sh "$KERNEL" "$MERGED_DTB" "$ANDROID_DTB" "$SKU_CAPE"
```

The unmodified Linux source must reproduce the board DTB with SHA-256 `1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d`. Both variants describe AMIC1 through ADC1 and SWR input 4, and AMIC4 through ADC3 and SWR input 8. The native TX3 link connects the WCD capture DAI, TX SoundWire manager and LPASS TX macro to Q6 APM. The VA macro provides the frame clock used by RX and TX. The two original amplifier nodes, speaker DAI selection, S10 and BOB regulator properties are compared directly in the compiled trees. The only byte difference between the two experimental trees is the WCD compatible string.

The WCD mic-bias supply phandle identifies PM8350C BOB. CN350 requests 3.296 V at this consumer. The native PMIC selector has adjacent steps at 3.288 and 3.320 V. The graph preserves the shared rail constraints. Hardware use still needs a supported consumer voltage policy, identification of the WCD variant, the stereo TX macro fix, and physical validation of binding, runtime power and acoustic channel order. The native VA clock dependency is included. CN350 supplies no separate VA digital-microphone supply in its VA node, and the internal analog paths use WCD bias. [Board evidence and supply limits](../../../docs/MICROPHONE.md)
