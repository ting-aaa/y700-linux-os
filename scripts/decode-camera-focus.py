#!/usr/bin/env python3
"""Decode the CN350 TXD HI1339 actuator record without loading vendor code."""

import argparse
import hashlib
import json
import math
import struct
from dataclasses import dataclass
from pathlib import Path


# This producer uses packed 32-bit section metadata, symbol IDs and references.
SYMBOL = struct.Struct("<I32s6I")
REF = struct.Struct("<II")
DATA_GROUP = 0xFFFFFFFF
MAX_FILE_BYTES = 1024 * 1024


@dataclass(frozen=True)
class Symbol:
    name: str
    group: int
    offset: int
    size: int


class Module:
    def __init__(self, data):
        self.data = data
        if (
            len(data) < 0xCC
            or not data.startswith(b"QTI Chromatix Header\0")
            or struct.unpack_from("<I", data, 0x1C)[0] != len(data) - 4
            or not data[0x28:0x58].startswith(b"Parameter Parser V3.5.1 ")
        ):
            raise ValueError("expected a packed Parameter Parser V3.5.1 container")
        table, count = REF.unpack_from(data, 0xA0)
        if count != 3 or table < 0xA8 or table + 36 > len(data) - 4:
            raise ValueError("invalid section table")
        sections = {}
        end = table + 36
        for kind, offset, size in struct.iter_unpack("<III", data[table:end]):
            if kind in sections or offset != end or offset + size > len(data) - 4:
                raise ValueError("invalid or overlapping sections")
            sections[kind] = (offset, size)
            end = offset + size
        if set(sections) != {0, 1, 2} or end != len(data) - 4:
            raise ValueError("missing section or trailing section data")
        symbols_offset, symbols_size = sections[0]
        data_offset, data_size = sections[1]
        if symbols_size % SYMBOL.size:
            raise ValueError("misaligned symbol table")
        self.symbols = {}
        rows = data[symbols_offset:symbols_offset + symbols_size]
        for ident, name, _major, _other_version, group, offset, size, _alias in SYMBOL.iter_unpack(rows):
            if ident in self.symbols or offset + size > data_size:
                raise ValueError("duplicate symbol ID or out-of-range symbol")
            label = name.split(b"\0", 1)[0].decode("ascii")
            self.symbols[ident] = Symbol(label, group, data_offset + offset, size)

    def payload(self, symbol):
        return self.data[symbol.offset:symbol.offset + symbol.size]

    def reference(self, parent, offset, expected_name, element_size):
        count, ident = REF.unpack_from(parent, offset)
        symbol = self.symbols.get(ident)
        if (
            symbol is None
            or symbol.group != DATA_GROUP
            or symbol.name != expected_name
            or symbol.size != count * element_size
        ):
            raise ValueError(f"invalid {expected_name} reference")
        return self.payload(symbol)

    def top_level(self, name, size):
        symbols = [
            symbol for symbol in self.symbols.values()
            if symbol.name == name and symbol.group == 0
        ]
        if len(symbols) != 1 or symbols[0].size != size:
            raise ValueError(f"expected one CN350 TXD {name} layout")
        return symbols[0]

    def sensor_slot(self, actuator_name):
        module = self.payload(self.top_level("cameraModuleData", 20))
        configuration = self.reference(module, 0x0C, "moduleConfiguration", 214)
        if len(configuration) != 214:
            raise ValueError("expected one camera module configuration")
        camera_id, = struct.unpack_from("<H", configuration)
        module_name = self.reference(configuration, 0x02, "moduleName", REF.size)
        name = self.reference(module_name, 0, "[0]", 1)
        sensor = self.reference(configuration, 0x0A, "sensorName", 1)
        actuator = self.reference(configuration, 0x22, "actuatorName", REF.size)
        actuator = self.reference(actuator, 0, "[0]", 1)
        override = self.reference(configuration, 0x2A, "actuatorSlaveAddress", 2)
        if (camera_id, name, sensor, actuator, override) != (0, b"txd\0", b"hi1339\0", actuator_name, b""):
            raise ValueError("camera module identity or actuator override does not match CN350 TXD")
        return camera_id

    def actuator(self):
        symbol = self.top_level("actuatorDriver", 134)
        data = self.payload(symbol)
        version = struct.unpack_from("<III", data)
        name = self.reference(data, 0x0C, "actuatorName", 1)
        if version != (1, 0, 0) or name != b"gt9768_hi1339\0":
            raise ValueError("unexpected actuator version or name")

        address, frequency_mode, kind, width = struct.unpack_from("<HIIH", data, 0x1C)
        if address & 1 or not 0x08 <= address >> 1 <= 0x77:
            raise ValueError("invalid actuator address")
        if frequency_mode > 3 or kind != 0 or width != 10:
            raise ValueError("unsupported actuator frequency, kind or DAC width")
        actuator_id = self.reference(data, 0x14, "actuatorID", 4)
        active = self.reference(data, 0x48, "activateSettings", 40)
        standby = self.reference(data, 0x50, "standbySettings", 40)
        uninit = self.reference(data, 0x58, "uninitSettings", 40)
        park = self.reference(data, 0x62, "parkLensParams", 1)
        if active or standby or uninit or park or actuator_id:
            raise ValueError("unsupported additional actuator ID or sequence")

        regions = self.reference(data, 0x6A, "region", 12)
        if len(regions) != 12:
            raise ValueError("expected one actuator region")
        macro, infinity, code_per_step, q_value = struct.unpack("<HHfI", regions)
        init_code, = struct.unpack_from("<H", data, 0x60)
        if init_code >= (1 << width) or macro < infinity or not math.isfinite(code_per_step):
            raise ValueError("invalid nominal actuator travel")
        return {
            "actuator": name[:-1].decode("ascii"),
            "camera_slot": self.sensor_slot(name),
            "record_offset": symbol.offset,
            "camx_write_address": address,
            "cci_address_7bit": address >> 1,
            "camx_frequency_mode": frequency_mode,
            "dac_bits": width,
            "power_up": self.power(data, 0x28),
            "power_down": self.power(data, 0x30),
            "init_registers": self.init_registers(data),
            "position_operations": self.position_operations(data),
            "nominal_travel": {
                "initial_dac_code": init_code,
                "macro_step_boundary": macro,
                "infinity_step_boundary": infinity,
                "code_per_step": code_per_step,
                "q_value": q_value,
            },
            "forward_damping": self.damping(data, 0x72),
            "reverse_damping": self.damping(data, 0x7C),
            "explicit_park_present": False,
        }

    def power(self, actuator, offset):
        settings = self.reference(actuator, offset, "powerSetting", 12)
        return [
            {"config_type": kind, "config_value": value, "delay_ms": delay}
            for kind, value, delay in struct.iter_unpack("<III", settings)
        ]

    def init_registers(self, actuator):
        settings = self.reference(actuator, 0x40, "regSetting", 40)
        records = []
        for offset in range(0, len(settings), 40):
            row = settings[offset:offset + 40]
            slave_count, _, register = struct.unpack_from("<III", row)
            values = self.reference(row, 12, "registerData", 4)
            address_bytes, data_bytes, opcode = struct.unpack_from("<III", row, 20)
            delay = self.reference(row, 32, "delayUs", 4)
            if slave_count or len(values) != 4 or len(delay) != 4 or (address_bytes, data_bytes, opcode) != (1, 1, 0):
                raise ValueError("unexpected initialization operation")
            value, = struct.unpack("<I", values)
            delay_us, = struct.unpack("<I", delay)
            if register > 255 or value > 255:
                raise ValueError("initialization register or value does not fit in a byte")
            records.append({"register": register, "value": value, "delay_us": delay_us})
        return records

    def position_operations(self, actuator):
        settings = self.reference(actuator, 0x38, "registerParam", 36)
        records = []
        for address_bytes, data_bytes, register, value, opcode, delay, mask, shift, data_shift in struct.iter_unpack(
            "<9I", settings
        ):
            if address_bytes != 1 or data_bytes not in (1, 2) or register > 255 or mask or shift or data_shift:
                raise ValueError("unsupported actuator register operation")
            if opcode == 4 and data_bytes == 1 and value <= 255:
                records.append({"operation": "poll", "register": register, "value": value, "delay_us": delay})
            elif opcode == 1 and data_bytes == 2 and value == 0:
                records.append({"operation": "write_dac", "register": register, "data_bytes": data_bytes})
            else:
                raise ValueError("unexpected position operation")
        return records

    def damping(self, actuator, offset):
        limit, = struct.unpack_from("<H", actuator, offset)
        scenario = self.reference(actuator, offset + 2, "scenario", REF.size)
        if len(scenario) != REF.size:
            raise ValueError("expected one damping scenario")
        region = self.reference(scenario, 0, "region", 12)
        step, delay, params = struct.unpack("<III", region)
        return {"step_limit": limit, "dac_step": step, "delay_us": delay, "hw_params": params}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("module", type=Path, help="local stock com.qti.sensormodule.txd_hi1339.bin")
    args = parser.parse_args()
    try:
        with args.module.open("rb") as stream:
            data = stream.read(MAX_FILE_BYTES + 1)
        if len(data) > MAX_FILE_BYTES:
            raise ValueError("module exceeds the supported file size")
        result = Module(data).actuator()
    except (OSError, ValueError, struct.error) as exc:
        parser.exit(1, f"Camera focus decode failed: {exc}\n")
    result["sha256"] = hashlib.sha256(data).hexdigest()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
