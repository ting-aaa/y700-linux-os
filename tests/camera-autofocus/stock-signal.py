"""Read public sensor parameters from a local, exact CN350 HI1339 module binary."""

import argparse
import hashlib
from pathlib import Path
import runpy
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stock_module", type=Path)
    args = parser.parse_args()
    contents = args.stock_module.read_bytes()
    if hashlib.sha256(contents).hexdigest() != "34ba25820a0ac983acd57075d8be57cb1b6eba55c3d315f5f7475c946149a3a8":
        parser.error("expected the exact CN350 TXD HI1339 sensor module")
    common = Path(__file__).resolve().parents[2] / "scripts" / "decode-camera-focus.py"
    module = runpy.run_path(str(common))["Module"](contents)
    module.camera_configuration()
    data = module.payload(module.top_level("sensorDriverData", 584))
    # colorLevelInfo sits between the testPatternData and optical-black dimension refs.
    patterns = module.reference(data, 0x1C0, "testPatternData", 12)
    optical_black = struct.unpack("<4I", module.reference(data, 0x1DC, "dimension", 16))
    white, red, gr, gb, blue = struct.unpack_from("<5I", data, 0x1C8)
    frame, line, coarse = struct.unpack_from("<3I", data, 0x70)
    gain, = struct.unpack_from("<I", data, 0x8C)
    print(f"CN350 white={white} black_r_gr_gb_b={red},{gr},{gb},{blue}")
    print("CN350 optical_black_region=" + ",".join(map(str, optical_black)))
    print(f"CN350 frame_length=0x{frame:04x} line_length=0x{line:04x} exposure=0x{coarse:04x} analogue_gain=0x{gain:04x}")
    for start in range(0, len(patterns), 12):
        mode, = struct.unpack_from("<I", patterns, start)
        settings = module.reference(patterns, start + 4, "regSetting", 40)
        writes = []
        for row in range(0, len(settings), 40):
            address, = struct.unpack_from("<I", settings, row + 8)
            value, = struct.unpack("<I", module.reference(settings, row + 12, "registerData", 4))
            writes.append(f"{address:04x}={value:04x}")
        print(f"CN350 test_mode={mode} settings={','.join(writes)}")


if __name__ == "__main__":
    main()
