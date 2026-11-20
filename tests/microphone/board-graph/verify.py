"""Verify the compiled board microphone phandles against both saved CN350 trees."""
from functools import cache
import hashlib
from pathlib import Path
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET


@cache
def prop(dtb, node, name):
    value = subprocess.check_output(["fdtget", "-t", "bx", dtb, node, name], text=True)
    return bytes(int(word, 16) for word in value.split())


def names(dtb, node, name):
    return prop(dtb, node, name).rstrip(b"\0").decode().split("\0")


def cells(dtb, node, name):
    return [value for value, in struct.iter_unpack(">I", prop(dtb, node, name))]


def handle(dtb, node):
    value, = cells(dtb, node, "phandle")
    return value


def properties(dtb, node):
    keys = subprocess.check_output(["fdtget", "-p", dtb, node], text=True).splitlines()
    return {key: prop(dtb, node, key) for key in keys}


def expect(actual, expected, location):
    if actual != expected:
        raise ValueError(f"{location}: {actual!r} differs from {expected!r}")


soc = "/soc@0/"
sound = "/sound"
wcd = "/audio-codec"
rx = soc + "soundwire@3210000"
tx = soc + "soundwire@33b0000"
va = soc + "codec@33f0000"
s10 = soc + "rsc@17a00000/regulators-0/smps10"
bob = soc + "rsc@17a00000/regulators-1/bob"
tlmm = soc + "pinctrl@f100000"
lpi = soc + "pinctrl@3440000"


def factory_wiring(dtb, symbols, stock):
    def symbol(label):
        return names(symbols, "/__symbols__", label)[0]

    codec = symbol("wcd938x_codec")
    for number in range(1, 5):
        mv, = cells(stock, codec, f"qcom,cdc-micbias{number}-mv")
        expect(cells(dtb, wcd, f"qcom,micbias{number}-microvolt"), [mv * 1000], f"MIC BIAS{number}")
    for old, new, source, target in (("cdc-vddio", "vdd-io", "pm8350_s10", s10),
                                     ("cdc-vdd-rxtx", "vdd-rxtx", "pm8350_s10", s10),
                                     ("cdc-vdd-buck", "vdd-buck", "pm8350_s10", s10),
                                     ("cdc-vdd-mic-bias", "vdd-mic-bias", "pm8350c_bob", bob)):
        expect(cells(stock, codec, old + "-supply"), [handle(stock, symbol(source))], old)
        expect(cells(dtb, wcd, new + "-supply"), [handle(dtb, target)], new)
    expect(cells(dtb, wcd, "reset-gpios"), [handle(dtb, tlmm), 43, 1], "active-low GPIO reset")
    for index, state in enumerate(("active", "sleep")):
        original = properties(stock, symbol("wcd938x_reset_" + state) + "/config")
        node = f"{tlmm}/wcd-reset-{state}-state"
        selected = properties(dtb, node)
        for key in ("pins", "drive-strength", "output-high" if state == "active" else "output-low"):
            expect(selected[key], original[key], f"GPIO43 {state} {key}")
        expect(names(dtb, node, "function"), ["gpio"], node)
        expect(cells(dtb, wcd, f"pinctrl-{index}"), [handle(dtb, node)], node)
    for direction, bus, unit, slots in (("rx", rx, 4, [1, 2, 3, 4, 5]), ("tx", tx, 3, [2, 3, 2, 3])):
        slave = f"{bus}/codec@0,{unit}"
        expect(cells(stock, symbol(f"wcd938x_{direction}_slave"), "reg"), [13, 0x01170220 + unit], slave)
        expect(names(dtb, slave, "compatible"), ["sdw20217010d00"], slave)
        expect(cells(dtb, slave, "reg"), [0, unit], slave)
        expect(cells(dtb, slave, f"qcom,{direction}-port-mapping"), slots, slave)
        expect(cells(dtb, wcd, f"qcom,{direction}-device"), [handle(dtb, slave)], slave)
        pins = f"{lpi}/{direction}-swr-active-state"
        expect(cells(dtb, bus, "pinctrl-0"), [handle(dtb, pins)], pins)
        for group, suffixes in (("clk", ["clk"]), ("data", ["data0", "data1", "data2"] if direction == "tx" else ["data", "data1"])):
            target = f"{pins}/{group}-pins"
            factory = [symbol(f"{direction}_swr_{s}_active") + "/config" for s in suffixes]
            expect(names(dtb, target, "pins"), [names(stock, node, "pins")[0] for node in factory], target)
            expect(names(dtb, target, "function"), [f"swr_{direction}_{group}"], target)
            for node in factory:
                for key in ("drive-strength", "slew-rate", "bias-disable" if group == "clk" else "bias-bus-hold"):
                    expect(prop(dtb, target, key), prop(stock, node, key), f"{target} {key}")
    expect(cells(dtb, va, "qcom,dmic-sample-rate"), cells(stock, symbol("va_macro"), "qcom,va-dmic-sample-rate"), va)


def board_graph(base, dtb, variant):
    expect(names(dtb, wcd, "compatible"), [f"qcom,wcd{variant}-codec"], wcd)
    routes = names(base, sound, "audio-routing") + [
        "AMIC1", "Analog Mic1", "AMIC1", "MIC BIAS1", "AMIC4", "Analog Mic4", "AMIC4", "MIC BIAS3",
        "TX SWR_INPUT4", "ADC1_OUTPUT", "TX SWR_INPUT8", "ADC3_OUTPUT",
    ]
    expect(names(dtb, sound, "audio-routing"), routes, sound)
    apm = soc + "remoteproc@3000000/glink-edge/gpr/service@1"
    link = sound + "/internal-mic-capture-dai-link"
    expect(cells(dtb, link + "/cpu", "sound-dai"), [handle(dtb, apm + "/bedais"), 120], "TX_CODEC_DMA_TX_3")
    expect(cells(dtb, link + "/platform", "sound-dai"), [handle(dtb, apm)], "Q6 APM")
    expect(cells(dtb, link + "/codec", "sound-dai"),
           [handle(dtb, wcd), 1, handle(dtb, tx), 0, handle(dtb, soc + "codec@3220000"), 0], "capture DAIs")
    for bus, macro in ((rx, soc + "codec@3200000"), (tx, soc + "codec@3220000")):
        expect(names(dtb, bus, "status"), ["okay"], bus)
        expect(cells(dtb, bus, "clocks"), [handle(dtb, macro)], bus + " iface")
        expect(names(dtb, macro, "clock-names")[-1], "fsgen", macro)
        expect(cells(dtb, macro, "clocks")[-1], handle(dtb, va), macro + " fsgen")
    expect(names(dtb, va, "status"), ["okay"], va)
    speaker = sound + "/speaker-playback-dai-link"
    bus = soc + "geniqup@ac0000/i2c@a94000/speaker-amp@"
    for node in (s10, bob, bus + "30", bus + "31", speaker, *(speaker + "/" + x for x in ("cpu", "platform", "codec"))):
        expect(properties(dtb, node), properties(base, node), node)
    old = properties(base, sound)
    new = properties(dtb, sound)
    for fields in (old, new):
        del fields["audio-routing"]
    expect(new, old, "unchanged sound card properties")


def main():
    base, small, large, merged, runtime, manager = map(Path, sys.argv[1:])
    profiles = ET.parse(manager).getroot()
    for name in ("handset", "speaker"):
        device = profiles.find(f".//device_profile/in-device[id='PAL_DEVICE_IN_{name.upper()}_MIC']")
        if device is None:
            raise ValueError(f"Missing factory {name} microphone")
        fields = ("back_end_name", "channels", "samplerate", "bit_width", "snd_device_name")
        expect([device.findtext(field) for field in fields],
               ["CODEC_DMA-LPAIF_RXTX-TX-3", "2", "48000", "16", name + "-mic"], name)
    for variant, dtb in ((9380, small), (9385, large)):
        board_graph(base, dtb, variant)
        for stock in (merged, runtime):
            factory_wiring(dtb, merged, stock)
        print(f"WCD{variant} hypothesis: TX3 capture, two factory analog routes, both SoundWire links, clock chain, GPIOs and supplies verified")
        print(f"sha256 {hashlib.sha256(dtb.read_bytes()).hexdigest()}")
    first = small.read_bytes()
    expect(first.count(b"qcom,wcd9380-codec\0"), 1, "variant string count")
    if first.replace(b"qcom,wcd9380-codec\0", b"qcom,wcd9385-codec\0") != large.read_bytes():
        raise ValueError("Compiled hypotheses differ outside the WCD compatible")
    print("Both compiled hypotheses preserve the speaker and regulator properties. Only the WCD compatible differs.")


if __name__ == "__main__":
    main()
