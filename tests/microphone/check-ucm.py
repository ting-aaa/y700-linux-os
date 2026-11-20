"""Compare the optional microphone profile with CN350, the native codec and the compiled topology."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def require(text, fragment, source):
    if fragment not in text:
        raise ValueError(f"{source} is missing {fragment!r}")


def settings(sequence):
    return dict(re.findall(r'''cset "name='([^']+)' ([^"]+)"''', sequence))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mixer", type=Path, help="CN350 sku_cape/mixer_paths_waipio_mtp.xml")
    parser.add_argument("kernel", type=Path, help="prepared Linux source tree")
    parser.add_argument("topology", type=Path, help="compiled TX3 .tplg")
    args = parser.parse_args()

    directory = Path(__file__).resolve().parents[2] / "packaging/microphone"
    device = (directory / "Mic.conf").read_text()
    enabled, tail = device.split("DisableSequence")
    enable = settings(enabled)
    disable = settings(tail)
    mixer = ET.parse(args.mixer).getroot()
    defaults = {item.get("name"): item.get("value") for item in mixer.findall("ctl")}
    wcd = (args.kernel / "sound/soc/codecs/wcd938x.c").read_text()
    macro = (args.kernel / "sound/soc/codecs/lpass-tx-macro.c").read_text()
    with tempfile.TemporaryDirectory() as work:
        path = Path(work) / "decoded.conf"
        subprocess.run(["alsatplg", "-d", args.topology, "-o", path], check=True)
        topology = path.read_text()

    for name in ("speaker-mic", "handset-mic"):
        routes = mixer.findall(f"path[@name='{name}']/path")
        if [route.get("name") for route in routes] != ["amic1", "amic4"]:
            raise ValueError(f"Factory routes for {name} changed")

    expected = {}
    for amic, adc, dec, port in ((1, 1, 2, 2), (4, 3, 5, 3)):
        route = f"amic{amic}"
        stock = {ctl.get("name"): ctl.get("value") for ctl in mixer.findall(f"path[@name='{route}']/ctl")}
        if stock.pop(f"ADC{adc} ChMap") != f"SWRM_TX{port}_CH1":
            raise ValueError(f"Factory SoundWire port mismatch for {route}")
        # Native SoundWire routing uses the board's port table and ADCn Switch.
        expected[f"ADC{adc} Switch"] = stock.pop(f"AMIC{amic}_MIXER Switch")
        expected.update(stock)
        for control in (f"ADC{adc} Volume", f"TX_DEC{dec} Volume"):
            expected[control] = defaults[control]
        for fragment in (f'SOC_SINGLE_EXT("ADC{adc} Switch"', f'SOC_SINGLE_TLV("ADC{adc} Volume"',
                         f'SND_SOC_DAPM_MIXER_E("ADC{adc}_MIXER"'):
            require(wcd, fragment, "WCD938x")
        for name in (f"TX DEC{dec} MUX", f"TX SMIC MUX{dec}"):
            require(macro, f'{{"{name}", "{expected[name]}"', "LPASS TX route")
        require(macro, f'{{"TX_AIF1_CAP Mixer", "DEC{dec}", "TX DEC{dec} MUX"}}', "LPASS capture mixer")
        require(macro, f'SOC_SINGLE_S8_TLV("TX_DEC{dec} Volume"', "LPASS gain")
    for fragment in ('{"ADC3 MUX", "INP4", "AMIC4"}', '{"HDR34 MUX", "NO_HDR34", "ADC3 MUX"}'):
        require(wcd, fragment, "WCD938x mux")

    route = "MultiMedia3 Mixer TX_CODEC_DMA_TX_3"
    expected[route] = "1"
    if enable != expected:
        raise ValueError(f"Enable sequence differs from the factory/native mapping: {enable.items() ^ expected.items()}")
    releases = {name: "0" for name in enable if enable[name] == "1"}
    releases.update({"TX SMIC MUX2": "ZERO", "TX SMIC MUX5": "ZERO"})
    if disable != releases or list(disable)[0] != route:
        raise ValueError("Disable sequence must disconnect the frontend and release both ADCs and decimators")

    require(topology, "'MultiMedia3 Capture' {\n\t\tid 2", "AudioReach PCM")
    require(topology, "MultiMedia3 Mixer, TX_CODEC_DMA_TX_3, device120.logger1", "AudioReach route")
    capabilities = topology.split("SectionPCMCapabilities", 1)[1]
    capture = capabilities.split("'MultiMedia3 Capture' {", 1)[1].split("}", 1)[0]
    for parameter, value in (("formats", "'S16_LE'"), ("rate_min", "48000"), ("rate_max", "48000"),
                             ("channels_min", "2"), ("channels_max", "2")):
        require(capture, f"{parameter} {value}", "AudioReach capture capabilities")
    for value in ('CapturePCM "hw:${CardId},2"', "CaptureRate 48000", "CaptureChannels 2", 'CaptureFormat "S16_LE"'):
        require(device, value, "UCM capture endpoint")
    print(f"Internal Mic: FE2, S16_LE/48000/2, {len(enable)} route and gain settings, {len(disable)} release settings")


if __name__ == "__main__":
    main()
