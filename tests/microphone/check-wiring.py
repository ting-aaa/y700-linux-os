#!/usr/bin/env python3
"""Compare microphone wiring in two TB320FC Android trees and the native DTB."""
from pathlib import Path
import argparse
import hashlib
import re
import subprocess
import xml.etree.ElementTree as ET


def prop(dtb, node, name, kind="s"):
    return subprocess.check_output(["fdtget", "-t", kind, dtb, node, name], text=True).strip()


def expect(actual, wanted, label):
    if actual != wanted:
        raise SystemExit(f"{label}: {actual!r}, wanted {wanted!r}")


def port_map(dtb, codec, bus, direction):
    def rows(node, name, width):
        words = [int(v) for v in prop(dtb, node, name, "u").split()]
        expect(len(words) % width, 0, name + " cell count")
        return [words[start:start + width] for start in range(0, len(words), width)]

    # Factory manager entries use (port, type, channels). Codec entries use
    # (zero-based port, slave type, channels, rate, corresponding manager type).
    master = {kind: port for port, kind, _ in rows(bus, "qcom,swr-port-mapping", 3)}
    ports = {}
    for port, _, _, _, kind in rows(codec, f"qcom,{direction}_swr_ch_map", 5):
        previous = ports.setdefault(port, master[kind])
        expect(master[kind], previous, direction + " default port ambiguity")
    return [ports[i] for i in range(len(ports))]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("stock_merged", type=Path, help="CN350 base with overlay 14 and symbols")
    ap.add_argument("stock_running", type=Path, help="saved Android runtime DTB")
    ap.add_argument("native", type=Path, help="built Asphalt Linux DTB")
    ap.add_argument("mixer", type=Path, help="CN350 sku_cape/mixer_paths_waipio_mtp.xml")
    args = ap.parse_args()

    def symbol(name):
        return prop(args.stock_merged, "/__symbols__", name)

    codec = symbol("wcd938x_codec")
    mixer = {p.get("name"): p for p in ET.parse(args.mixer).getroot().findall("path")}
    for path in ("handset-mic", "speaker-mic"):
        expect([p.get("name") for p in mixer[path].findall("path")], ["amic1", "amic4"], path)
    for dtb in (args.stock_merged, args.stock_running):
        def check(node, name, wanted, kind="s"):
            expect(prop(dtb, node, name, kind), wanted, f"{node}/{name}")

        check(codec, "compatible", "qcom,wcd938x-codec")
        for bias in range(1, 5):
            check(codec, f"qcom,cdc-micbias{bias}-mv", "2700", "u")
        for name in ("cdc-vdd-rxtx", "cdc-vddio", "cdc-vdd-buck", "cdc-vdd-mic-bias"):
            microphone = name == "cdc-vdd-mic-bias"
            supply = symbol("pm8350c_bob" if microphone else "pm8350_s10")
            uv = 3296000 if microphone else 1800000
            check(codec, name + "-supply", prop(dtb, supply, "phandle", "u"), "u")
            check(codec, "qcom," + name + "-voltage", f"{uv} {uv}", "u")

        check(codec, "qcom,wcd-rst-gpio-node",
              prop(dtb, symbol("wcd938x_rst_gpio"), "phandle", "u"), "u")
        for state, output in (("active", "output-high"), ("sleep", "output-low")):
            config = symbol("wcd938x_reset_" + state) + "/config"
            check(config, "pins", "gpio43")
            check(config, output, "", "u")
        for direction, address, peripheral in (("rx", "3210000", "1170224"),
                                               ("tx", "33b0000", "1170223")):
            node = symbol("wcd938x_" + direction + "_slave")
            check(codec, "qcom," + direction + "-slave", prop(dtb, node, "phandle", "u"), "u")
            check(node, "reg", "d " + peripheral, "x")
            check(node.rsplit("/", 1)[0], "swrm-io-base", address + " 0", "x")
            ports = port_map(dtb, codec, node.rsplit("/", 1)[0], direction)
            if direction == "rx":
                expect(ports, [1, 2, 3, 4, 5], "RX master port map")
            else:
                expect(ports, [1, 1, 2, 3], "default TX master port map")
                for idx, (route, adc) in enumerate((("amic1", "ADC1"), ("amic4", "ADC3"))):
                    chmap = mixer[route].find(f"ctl[@name='{adc} ChMap']")
                    if chmap is None:
                        raise SystemExit(f"{route}: missing {adc} channel mapping")
                    selected = re.fullmatch(r"SWRM_TX(\d+)_CH1", chmap.get("value"))
                    if selected is None:
                        raise SystemExit(f"{route}: unexpected {adc} channel mapping")
                    ports[idx] = int(selected.group(1))
                expect(ports, [2, 3, 2, 3], "internal-mic TX master port map")
        for state, gpio in (("tx_swr_clk", 0), ("tx_swr_data0", 1), ("tx_swr_data1", 2),
                            ("tx_swr_data2", 14), ("rx_swr_clk", 3), ("rx_swr_data", 4),
                            ("rx_swr_data1", 5)):
            conf = symbol(state + "_active") + "/config"
            check(conf, "pins", f"gpio{gpio}")
            check(conf, "drive-strength", "4" if state.startswith("tx_") else "2", "u")
        print(f"factory_wiring_ok={hashlib.sha256(dtb.read_bytes()).hexdigest()}")

    rsc = "/soc@0/rsc@17a00000"
    for node, lo, hi in (("regulators-0/smps10", 1800000, 1800000),
                         ("regulators-1/bob", 3008000, 3960000)):
        for name, value in (("min", lo), ("max", hi)):
            expect(prop(args.native, f"{rsc}/{node}", f"regulator-{name}-microvolt", "u"),
                   str(value), node + " " + name)
    for direction, address, clock, data in (("tx", "33b0000", 0, "gpio1 gpio2 gpio14"),
                                            ("rx", "3210000", 3, "gpio4 gpio5")):
        pins = f"/soc@0/pinctrl@3440000/{direction}-swr-active-state"
        bus = f"/soc@0/soundwire@{address}"
        expect(prop(args.native, bus, "pinctrl-0", "u"),
               prop(args.native, pins, "phandle", "u"), direction + " pinctrl")
        expect(prop(args.native, pins + "/clk-pins", "pins"), f"gpio{clock}", direction + " clock")
        expect(prop(args.native, pins + "/data-pins", "pins"), data, direction + " data")
    print(f"native_resources_ok={hashlib.sha256(args.native.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
