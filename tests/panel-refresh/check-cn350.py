"""Compare only the selected CN350 panel in the factory overlay and the booted Android DT."""
from pathlib import Path
import hashlib
import subprocess
import sys


def get(blob, node, prop, fmt="u"):
    return subprocess.check_output(["fdtget", "-t", fmt, blob, node, prop], text=True).strip()


def commands(blob, timing, name):
    raw = bytes(int(v, 16) for v in get(blob, timing, "qcom,mdss-dsi-" + name, "bx").split())
    pos = 0
    packets = []
    while pos < len(raw):
        header = raw[pos:pos + 7]
        assert len(header) == 7 and header[0] == 0x39
        length = int.from_bytes(header[5:], "big")
        pos += 7
        payload = raw[pos:pos + length]
        assert len(payload) == length and length > 0
        packets.append(payload)
        pos += length
    return packets


def check(overlay, live):
    name = "qcom,mdss_dsi_nt36523n_fhd_plus_cphy_144hz_vid"
    assert hashlib.sha256(overlay.read_bytes()).hexdigest() == "453750b8c9371b870207c4014d6a70aeb39930b2f1a153f754cf198b0e29361e"
    assert hashlib.sha256(live.read_bytes()).hexdigest() == "bda4b80b9cb73e1b001cf22666890ad0139f0246e08a86d432a190d8e06ba4c6"
    assert f"msm_drm.dsi_display0={name}:" in get(live, "/chosen", "bootargs", "s").split()
    for blob, parent in ((overlay, "/fragment@52/__overlay__"), (live, "/soc/qcom,mdss_mdp@ae00000")):
        panel = parent + "/" + name
        timings = panel + "/qcom,mdss-dsi-display-timings"
        assert subprocess.check_output(["fdtget", "-l", blob, timings], text=True).split() == ["timing@0"]
        timing = timings + "/timing@0"
        assert get(blob, panel, "qcom,dsi-supported-dfps-list") == "144 120 60 30"
        assert get(blob, panel, "qcom,mdss-dsi-pan-fps-update", "s") == "dfps_immediate_porch_mode_vfp"
        keys = ("panel-framerate", "panel-width", "h-front-porch", "h-pulse-width", "h-back-porch",
                "panel-height", "v-front-porch", "v-pulse-width", "v-back-porch", "panel-clockrate")
        assert tuple(int(get(blob, timing, "qcom,mdss-dsi-" + k)) for k in keys) == (
            120, 800, 137, 20, 54, 2560, 30, 4, 256, 573510000)
        props = subprocess.check_output(["fdtget", "-p", blob, timing], text=True).split()
        assert "qcom,mdss-dsi-timing-switch-command" not in props
        init = commands(blob, timing, "on-command")
        page, registers = None, {}
        for packet in init:
            if len(packet) == 2:
                addr, data = packet
                if addr == 0xff:
                    page = data
                else:
                    registers[page, addr] = data
        assert len(init) == 459 and registers[0x10, 0xb2] == 0x91 and registers[0x10, 0xb3] == 0x01
        assert commands(blob, timing, "dispparam-pen-others-switch-command") == [b"\xff\x10", b"\xb3\x01"]
        assert commands(blob, timing, "dispparam-pen-others-enable-control-command") == [b"\xff\x10", b"\xb2\x91"]
    print("PANEL_CN350 factory_overlay=14 selected_runtime=matched base=120 low=60 algorithm=VFP "
          "non144_page10=B2:91,B3:01 cold_init_records=459")


if __name__ == "__main__":
    check(*(Path(s) for s in sys.argv[1:]))
