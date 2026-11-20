"""Offline synthetic tests for the packed camera focus decoder."""

import runpy
import struct
import unittest
from pathlib import Path


DECODER = Path(__file__).resolve().parents[1] / "scripts" / "decode-camera-focus.py"
Module = runpy.run_path(str(DECODER))["Module"]


def fixture(park=b""):
    # Build the older packed container with different register and travel values.
    symbols = bytearray()
    data = bytearray()
    positions = {}

    def add(name, payload, count=1, group=0xffffffff):
        ident = len(symbols) // 60 + 1
        positions.setdefault(name, len(data))
        symbols.extend(struct.pack("<I32s6I", ident, name.encode(), 0, 0, group,
                                   len(data), len(payload), ident))
        data.extend(payload)
        return struct.pack("<II", count, ident)

    def init_row(register, value):
        return (
            bytes(8) + struct.pack("<I", register)
            + add("registerData", struct.pack("<I", value))
            + struct.pack("<III", 1, 1, 0)
            + add("delayUs", struct.pack("<I", 150))
        )

    name = b"gt9768_hi1339\0"
    initial = init_row(6, 0x40)
    tamp = add("region", struct.pack("<III", 385, 7200, 0))
    scenario = struct.pack("<H", 330) + add("scenario", tamp)
    actuator = (
        struct.pack("<III", 1, 0, 0)
        + add("actuatorName", name, len(name))
        + add("actuatorID", b"", 0)
        + struct.pack("<HIIH", 0x18, 3, 0, 10)
        + add("powerSetting", struct.pack("<III", 4, 1, 2))
        + add("powerSetting", struct.pack("<III", 4, 0, 3))
        + add("registerParam", struct.pack("<18I", 1, 1, 5, 0, 4, 5000, 0, 0, 0,
                                                    1, 2, 3, 0, 1, 0, 0, 0, 0), 2)
        + add("regSetting", initial)
        + add("activateSettings", b"", 0)
        + add("standbySettings", b"", 0)
        + add("uninitSettings", b"", 0)
        + struct.pack("<H", 55)
        + add("parkLensParams", park, len(park))
        + add("region", struct.pack("<HHfI", 330, 0, 1.25, 64))
        + scenario + scenario
    )
    add("actuatorDriver", actuator, group=0)
    configuration = bytearray(214)
    configuration[0x02:0x0A] = add("moduleName", add("[0]", b"txd\0", 4))
    configuration[0x0A:0x12] = add("sensorName", b"hi1339\0", 7)
    configuration[0x22:0x2A] = add("actuatorName", add("[0]", name, len(name)))
    configuration[0x2A:0x32] = add("actuatorSlaveAddress", b"", 0)
    add("cameraModuleData", struct.pack("<III", 1, 0, 0) + add("moduleConfiguration", configuration), group=0)

    header = bytearray(0xCC)
    magic = b"QTI Chromatix Header\0"
    header[:len(magic)] = magic
    revision = b"Parameter Parser V3.5.1 (synthetic)"
    header[0x28:0x28 + len(revision)] = revision
    start = len(header) + len(symbols)
    index = start + len(data)
    struct.pack_into("<I", header, 0x1C, index + 4)
    struct.pack_into("<II", header, 0xA0, 0xA8, 3)
    struct.pack_into("<9I", header, 0xA8, 0, len(header), len(symbols),
                     1, start, len(data), 2, index, 4)
    return header + symbols + data + b"\xff" * 4 + bytes(4), start + positions["actuatorDriver"]


class CameraFocusTests(unittest.TestCase):
    def test_decodes_packed_fields(self):
        data, address = fixture()
        info = Module(data).actuator()
        self.assertEqual(info["record_offset"], address)
        self.assertEqual(info["camera_slot"], 0)
        self.assertEqual((info["camx_write_address"], info["cci_address_7bit"]), (0x18, 0x0c))
        self.assertEqual(info["init_registers"], [{"register": 6, "value": 0x40, "delay_us": 150}])
        self.assertEqual(info["position_operations"], [
            {"operation": "poll", "register": 5, "value": 0, "delay_us": 5000},
            {"operation": "write_dac", "register": 3, "data_bytes": 2},
        ])
        self.assertEqual(info["nominal_travel"], {
            "initial_dac_code": 55, "macro_step_boundary": 330,
            "infinity_step_boundary": 0, "code_per_step": 1.25, "q_value": 64,
        })
        self.assertEqual(info["forward_damping"], {
            "step_limit": 330, "dac_step": 385, "delay_us": 7200, "hw_params": 0,
        })
        self.assertEqual(info["forward_damping"], info["reverse_damping"])
        self.assertFalse(info["explicit_park_present"])

    def test_rejects_truncated_overlapping_or_duplicate_records(self):
        data, _ = fixture()
        with self.assertRaisesRegex(ValueError, "V3.5.1"):
            Module(data[:-1])
        struct.pack_into("<I", data, 0xB8, 0xCC)
        with self.assertRaisesRegex(ValueError, "overlapping"):
            Module(data)
        data, _ = fixture()
        struct.pack_into("<I", data, 0xCC + 60, 1)
        with self.assertRaisesRegex(ValueError, "duplicate symbol"):
            Module(data)

    def test_rejects_mismatched_references_and_non_write_address(self):
        data, actuator = fixture()
        struct.pack_into("<I", data, actuator + 0x44, 0xFFFFFFFF)
        with self.assertRaisesRegex(ValueError, "regSetting reference"):
            Module(data).actuator()
        data, actuator = fixture()
        struct.pack_into("<H", data, actuator + 0x1C, 0x19)
        with self.assertRaisesRegex(ValueError, "actuator address"):
            Module(data).actuator()

    def test_nonempty_park_sequence_requires_a_supported_layout(self):
        data, _ = fixture(park=b"\0")
        with self.assertRaisesRegex(ValueError, "additional actuator ID or sequence"):
            Module(data).actuator()


if __name__ == "__main__":
    unittest.main()
