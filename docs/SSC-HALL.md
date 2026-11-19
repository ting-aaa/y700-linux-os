# Read Y700 cover Hall events

The archived CN350 Android input list has no `SW_LID` capability. The merged CN350 device tree and the Debian Asphalt tree expose power and volume buttons. CN350's vendor filesystem configures `sns_bu52053nvx` as SSC `hall` on an interrupt input, and Android starts the `sensorspd` listener. The registry's chip-pin index is 83. SM8450 also exposes GPIO83 as a QUP SPI21 pin, and neither the live AP ownership nor the electrical polarity has been established. The same-board port lists BU52053NVX in SSC and leaves the cover behavior untested. [Asphalt status](https://github.com/dianqk/nixos-android-devices/blob/17f4a785e2737d4635d2bf55369e519a635bde49/docs/asphalt/status.md#L85) · [Asphalt registry config](https://github.com/dianqk/nixos-android-devices/blob/17f4a785e2737d4635d2bf55369e519a635bde49/pkgs/asphalt/sensors/config/waipio_bu52053nvx_0.json)

`ssc-hall` uses the existing `libssc2` `0.4.4-2.1~bpo13+1.y7001`. It discovers `hall` through the public sensor API and opens its stream. The original library chooses the on-change request from the sensor's advertised type. The reader uses a checked GObject raw report signal from this library revision and accepts high-accuracy event 770 from the discovered Hall sensor. It reports `NEAR` and `FAR` and counts rejected Hall payloads. [Qualcomm Hall wire schema](https://github.com/qualcomm/sensinghub/blob/076cf252bd68c5ea5abcddcad9d8cb2a3462ba45/apis/proto/sns_hall.proto)

Build on Debian 13 ARM64 with the matching `libssc-dev`, a C compiler and pkg-config. Use the existing SSC firmware and listener. This optional command provides observations for a cover test. It leaves suspend and display policy to the host desktop.

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror src/sensors/ssc-hall.c \
  -o ssc-hall $(pkg-config --cflags --libs libssc)
./ssc-hall --discover --timeout 5
./ssc-hall --count 4 --timeout 30
```

For the physical test, record the open and closed positions separately and correlate changes with at least two deliberate cover cycles. Retain event text and counts. Exit 3 means discovery was unavailable, exit 4 means too few valid events arrived, and exit 5 means a subscription or library interface failed. Wake from suspend needs a separate test after the awake transitions are established.

The networkless ARM64 VM fixture uses the existing libssc QRTR test environment and adds the [Hall sensor metadata](../tests/ssc-hall-sensor.json), [mock reports](../tests/ssc-hall-mock.py) and [guest assertions](../tests/ssc-hall-qrtr.sh). It verified discovery without a subscription, the on-change request, accepted `NEAR` and `FAR` events, five rejected Hall payloads and timeout cleanup when no Hall event arrived. The fixture also supplied an unrelated sensor's SUID and a proximity event to check that the reader ignores both. It leaves hardware cover direction and power behavior open for the attended test. [Base QRTR fixture](../tests/ssc-sample.md)
