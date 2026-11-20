"""Check the TB320FC_PRC hardware connections in a shipped DTB or the running board tree."""
import argparse
import struct
import subprocess
from functools import cache
from pathlib import Path


def check_tree(read):
    def string(node, prop):
        return read(node, prop).rstrip(b"\0").decode().split("\0")

    def cell(node, prop):
        return struct.unpack(">I", read(node, prop))[0]

    def expect(actual, expected, location):
        if actual != expected:
            raise SystemExit(f"{location}: expected {expected!r}, found {actual!r}")

    def enabled(node, compatible):
        if compatible not in string(node, "compatible"):
            raise SystemExit(f"{node}: missing {compatible}")
        for parent in (node, *node.parents):
            try:
                status = string(parent, "status")
            except FileNotFoundError:
                continue  # A DT node with no status property is available.
            if status not in (["okay"], ["ok"]):
                raise SystemExit(f"{parent}: status {status}")

    board = Path("/")
    soc = board / "soc@0"
    panel = soc / "display-subsystem@ae00000/dsi@ae94000/panel@0"
    touch = soc / "geniqup@9c0000/spi@990000/touchscreen@0"
    gpu = soc / "gpu@3d00000"
    slpi = soc / "remoteproc@2400000"
    adsp = soc / "remoteproc@3000000"
    isp = soc / "isp@acb7000"
    expect(string(board, "compatible"), ["lenovo,asphalt", "qcom,sm8475"], board)
    expect(string(board, "region_country"), ["PRC"], board)
    for node, compatible in (
        (panel, "lenovo,y700-nt36523n"), (touch, "novatek,nt36523n-spi"),
        (soc / "geniqup@8c0000/serial@894000/bluetooth", "qcom,wcn6855-bt"),
        (soc / "pcie@1c00000/pcie@0/wifi@0", "pci17cb,1103"),
        (board / "wcn6855-pmu", "qcom,wcn6855-pmu"), (gpu, "qcom,adreno-730.1"),
        (adsp, "qcom,sm8450-adsp-pas"), (slpi, "qcom,sm8450-slpi-pas"),
        (board / "sound", "lenovo,y700-sndcard"), (isp, "qcom,sm8450-camss"),
    ):
        enabled(node, compatible)
    expect(cell(touch, "panel"), cell(panel, "phandle"), touch)
    for node, name in ((touch, "novatek/lenovo-tb320fc.bin"),
                       (slpi, "qcom/sm8475/lenovo/tb320fc/slpi.mdt"),
                       (adsp, "qcom/sm8475/lenovo/tb320fc/adsp.mdt"),
                       (gpu / "zap-shader", "qcom/sm8475/lenovo/tb320fc/a730_zap.mdt")):
        expect(string(node, "firmware-name"), [name], node)
    for address, part in (("30", "spk1-cs35l45"), ("31", "spk2-cs35l45")):
        amp = soc / f"geniqup@ac0000/i2c@a94000/speaker-amp@{address}"
        enabled(amp, "cirrus,cs35l45")
        expect(string(amp, "cirrus,dsp-part-name"), [part], amp)
    for path, compatible, port, lanes, frequency in (
        ("cci@ac15000/i2c-bus@0/camera@20", "hynix,hi1339", 0, 4, 608_000_000),
        ("cci@ac15000/i2c-bus@1/camera@10", "samsung,s5k4h7", 2, 4, 340_000_000),
        ("cci@ac16000/i2c-bus@0/camera@36", "smartsens,sc202cs", 1, 1, 360_000_000),
    ):
        sensor = soc / path
        enabled(sensor, compatible)
        source = sensor / "port/endpoint"
        sink = isp / f"ports/port@{port}/endpoint"
        expect(cell(source, "remote-endpoint"), cell(sink, "phandle"), source)
        expect(cell(sink, "remote-endpoint"), cell(source, "phandle"), sink)
        for endpoint, first_lane in ((source, 1), (sink, 0)):
            actual = [v for (v,) in struct.iter_unpack(">I", read(endpoint, "data-lanes"))]
            expect(actual, list(range(first_lane, first_lane + lanes)), endpoint)
        expect(struct.unpack(">Q", read(source, "link-frequencies"))[0], frequency, source)
        print(f"{compatible} -> CSIPHY{port}, {lanes} lanes, {frequency // 1_000_000} MHz")
    print("PASS TB320FC_PRC panel/touch link, WCN6855 Wi-Fi/Bluetooth, two speaker amps, "
          "GPU, ADSP, SLPI firmware references and three reciprocal camera links")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dtb", type=Path)
    mode.add_argument("--live", action="store_true")
    args = parser.parse_args()

    if args.live:
        tree = Path("/sys/firmware/devicetree/base")
        check_tree(lambda node, prop: (tree / node.relative_to("/") / prop).read_bytes())
    else:
        @cache
        def read_dtb(node, prop):
            result = subprocess.check_output(
                ["fdtget", "-t", "bx", "-d", "MISSING", args.dtb, node, prop], text=True
            ).split()
            if result == ["MISSING"]:
                raise FileNotFoundError(node / prop)
            return bytes(int(v, 16) for v in result)

        check_tree(read_dtb)
