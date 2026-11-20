"""Check the CN350 main-camera lens ID or its factory AF calibration over the native CCI bus."""
import argparse
from contextlib import contextmanager, nullcontext
import ctypes
import fcntl
import json
import os
import re
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import time
import uuid


DT = Path("/sys/firmware/devicetree/base")
BUS_NODE = DT / "soc@0/cci@ac15000/i2c-bus@0"
SENSOR_NODE = BUS_NODE / "camera@20"
SYS = Path("/sys/bus/i2c/devices")
I2C_SLAVE = 0x0703
I2C_SMBUS = 0x0720
I2C_RDWR = 0x0707


class SMBusData(ctypes.Union):
    # Linux uapi union i2c_smbus_data, including the block-length byte.
    _fields_ = [("byte", ctypes.c_uint8), ("word", ctypes.c_uint16),
                ("block", ctypes.c_uint8 * 34)]


class SMBusRequest(ctypes.Structure):
    _fields_ = [("read_write", ctypes.c_uint8), ("command", ctypes.c_uint8),
                ("size", ctypes.c_uint32), ("data", ctypes.POINTER(SMBusData))]


class I2CMessage(ctypes.Structure):
    _fields_ = [("address", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("length", ctypes.c_uint16), ("data", ctypes.POINTER(ctypes.c_uint8))]


class I2CTransfer(ctypes.Structure):
    _fields_ = [("messages", ctypes.POINTER(I2CMessage)), ("count", ctypes.c_uint32)]


def contents(path):
    return path.read_text().strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def singleton(paths, message):
    items = list(paths)
    require(len(items) == 1, message)
    return items[0]


def hardware():
    require(b"lenovo,asphalt" in (DT / "compatible").read_bytes().split(b"\0")
            and (DT / "region_country").read_bytes().rstrip(b"\0") == b"PRC", "Unexpected board")
    require(int.from_bytes((BUS_NODE / "clock-frequency").read_bytes(), "big") == 400000,
            "Expected the board's 400 kHz camera bus")
    bus = singleton((p for p in SYS.glob("i2c-*") if (p / "of_node").resolve() == BUS_NODE),
                    "Could not identify exactly one CCI0 master 0")
    require(contents(bus / "name") == "Qualcomm-CCI", "Unexpected adapter driver")
    nr = int(bus.name.removeprefix("i2c-"))
    sensor = SYS / f"{nr}-0020"
    require((sensor / "of_node").resolve() == SENSOR_NODE
            and b"hynix,hi1339" in (SENSOR_NODE / "compatible").read_bytes().split(b"\0")
            and (sensor / "driver").is_symlink(), "Expected bound rear HI1339 on this adapter")
    require(not (SENSOR_NODE / "lens-focus").exists()
            and not (SYS / f"{nr}-000c").exists(), "An existing lens driver or device owns the address")
    master = bus.resolve().parent
    require((master / "of_node").resolve() == BUS_NODE.parent
            and contents(master / "power/control") == "auto", "Unexpected camera controller")
    return bus, sensor, master


def rail_levels():
    supplies = [(DT / "soc@0/rsc@17a00000/regulators-1/bob", 3008000, 3960000),
                (DT / "regulator-camera-io", 1800000, 1800000)]
    levels = []
    for node, low, high in supplies:
        reg = singleton((p for p in Path("/sys/class/regulator").glob("regulator.*")
                         if (p / "of_node").resolve() == node), f"Missing {node.name} supply")
        microvolts = int(contents(reg / "microvolts"))
        require(contents(reg / "state") == "enabled" and low <= microvolts <= high
                and int(contents(reg / "num_users")) > 0, f"Supply {node.name} is not ready")
        levels.append(microvolts)
    return tuple(levels)


def check_idle(sensor, master):
    for dev in (sensor, master):
        require(contents(dev / "power/runtime_status") == "suspended",
                f"{dev.name} is in use or has not returned to suspend")
        require(contents(dev / "power/control") == "auto", f"{dev.name} is not managed by runtime PM")


@contextmanager
def main_sensor_power(sensor, enabled):
    if not enabled:
        yield
        return
    require((sensor / "driver").resolve().name == "asphalt-sensors",
            "Runtime power mode requires the reviewed Asphalt camera driver")
    control = sensor / "power/control"
    require(contents(control) == "auto", "Rear sensor already has a power override")
    # The recovery timer remains effective if the USB host or this process exits.
    unit = "y700-focus-pm-" + uuid.uuid4().hex
    subprocess.run(["systemd-run", "--quiet", "--collect", "--expand-environment=no",
                    "--unit=" + unit, "--on-active=30s",
                    "--timer-property=AccuracySec=1s", "/bin/sh", "-ec",
                    'if [ "$(cat "$1")" = on ]; then echo auto >"$1"; fi', "sh", str(control)],
                   check=True)
    try:
        control.write_text("on\n")
        require(contents(sensor / "power/runtime_status") == "active", "Rear sensor did not resume")
        print("During read: HI1339=active mode=runtime-power-only", flush=True)
        yield
    finally:
        control.write_text("auto\n")
        require(contents(control) == "auto", "Failed to restore rear sensor runtime PM")
        subprocess.run(["systemctl", "stop", unit + ".timer"], check=True)


@contextmanager
def open_bus(bus, address):
    fd = os.open(Path("/dev") / bus.name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        actual = os.fstat(fd)
        major, minor = map(int, contents(bus / "i2c-dev" / bus.name / "dev").split(":"))
        require(stat.S_ISCHR(actual.st_mode) and actual.st_rdev == os.makedev(major, minor),
                "Device node differs from the selected adapter")
        fcntl.ioctl(fd, I2C_SLAVE, address)
        yield fd
    finally:
        os.close(fd)


def read_chip_id(bus):
    # Register 0x00, SMBus byte-data read. The command only selects the register.
    result = SMBusData()
    request = SMBusRequest(1, 0x00, 2, ctypes.pointer(result))
    with open_bus(bus, 0x0C) as fd:
        fcntl.ioctl(fd, I2C_SMBUS, request)
    print(f"GT9768 id_register=0x00 observed=0x{result.byte:02x} expected=0xe9", flush=True)
    require(result.byte == 0xe9, "ID mismatch")


def verify_calibration(bus, layout, decode):
    address = 0x58
    nr = int(bus.name.removeprefix("i2c-"))
    require(not (SYS / f"{nr}-0058").exists(), "The EEPROM address is already owned")
    # Fixed window excludes module IDs, serials and unrelated calibration.
    offset = (ctypes.c_uint8 * 2)(0x00, 0x27)
    block = (ctypes.c_uint8 * 11)()
    messages = (I2CMessage * 2)(I2CMessage(address, 0, len(offset), offset),
                                I2CMessage(address, 1, len(block), block))
    transfer = I2CTransfer(messages, len(messages))
    with open_bus(bus, address) as fd:
        count = fcntl.ioctl(fd, I2C_RDWR, transfer)
        require(count == 2, "Incomplete AF block transfer")
    print("AF EEPROM address=0x58 window=0x27..0x31 bytes=11", flush=True)
    values = decode(bytes(block), layout)
    require(0 <= values["factory_infinity_dac"] < values["factory_macro_dac"] <= 1023,
            "AF endpoints outside 10-bit range")
    print("AF factory CRC=valid endpoints=ordered within_10bit=yes", flush=True)


def queue_events(trace):
    pending = None
    rows = []
    for line in trace.splitlines():
        if "queue_start:" in line:
            entered = re.search(r"\bmaster=(0x[0-9a-f]+|[0-9]+) queue=(0x[0-9a-f]+|[0-9]+)$", line)
            require(entered is not None and pending is None, "Incomplete CCI queue entry")
            pending = tuple(int(value, 0) for value in entered.groups())
        elif "queue_done:" in line:
            status = re.search(r"\bstatus=(-?[0-9]+)$", line)
            caller = re.search(r"\((cci_xfer\+0x[0-9a-f]+)\b", line)
            require(status is not None and pending is not None, "Unmatched CCI queue return")
            rows.append((*pending, int(status[1]), caller[1] if caller else "unresolved"))
            pending = None
    require(rows and pending is None, "No complete CCI queue capture")
    return rows


@contextmanager
def trace_queues():
    tracefs = Path("/sys/kernel/tracing")
    group = "y700cci_" + uuid.uuid4().hex[:16]
    instance = tracefs / "instances" / group
    unit = "y700-cci-clean-" + group
    # Removing a private instance releases its event references before unregistering the probes.
    cleanup = ["/bin/sh", "-ec", """
        if [ -d "$1/instances/$2" ]; then rmdir "$1/instances/$2"; fi
        for event in queue_start queue_done; do
            if [ -d "$1/events/$2/$event" ]; then
                printf -- '-:%s/%s\\n' "$2" "$event" >> "$1/kprobe_events"
            fi
        done
    """, "sh", str(tracefs), group]
    subprocess.run(["systemd-run", "--quiet", "--collect", "--expand-environment=no",
                    "--unit=" + unit, "--on-active=30s", "--timer-property=AccuracySec=1s",
                    *cleanup], check=True)
    try:
        instance.mkdir()
        (instance / "tracing_on").write_text("0\n")
        (instance / "set_event_pid").write_text(f"{os.getpid()}\n")
        for event in (f"p:{group}/queue_start cci_run_queue master=%x1:u8 queue=%x2:u8",
                      f"r:{group}/queue_done cci_run_queue status=$retval:s32"):
            # tracefs accepts an append write but does not support seeking to EOF.
            fd = os.open(tracefs / "kprobe_events", os.O_WRONLY | os.O_APPEND)
            try:
                definition = (event + "\n").encode("ascii")
                require(os.write(fd, definition) == len(definition), "Incomplete probe definition")
            finally:
                os.close(fd)
        (instance / "events" / group / "enable").write_text("1\n")
        (instance / "tracing_on").write_text("1\n")
        try:
            yield
        finally:
            (instance / "tracing_on").write_text("0\n")
            for master, queue, status, caller in queue_events((instance / "trace").read_text()):
                print(f"CCI queue master={master} queue={queue} status={status} caller={caller}", flush=True)
    finally:
        subprocess.run(cleanup, check=True)
        subprocess.run(["systemctl", "stop", unit + ".timer"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--read-id", action="store_true", help="perform the single chip-ID read")
    mode.add_argument("--af-layout", type=Path, help="verify the AF block with CN350 decoder metadata")
    parser.add_argument("--power-main", action="store_true",
                        help="hold the HI1339 driver's normal runtime power during the read")
    parser.add_argument("--trace-queues", action="store_true",
                        help="record this read's ARM64 CCI queue numbers and return statuses")
    args = parser.parse_args()
    if args.trace_queues and not (args.read_id or args.af_layout):
        parser.error("--trace-queues requires a read operation")
    if args.af_layout and not args.power_main:
        parser.error("the factory EEPROM read requires --power-main")
    if args.power_main and not (args.read_id or args.af_layout):
        parser.error("--power-main requires a read operation")
    if args.af_layout:
        layout = json.loads(args.af_layout.read_text())
        require(layout["sha256"] == "34ba25820a0ac983acd57075d8be57cb1b6eba55c3d315f5f7475c946149a3a8"
                and layout["eeprom"] == "txd_hi1339_eeprom" and layout["cci_address_7bit"] == 0x58
                and (layout["af"]["start_offset"], layout["af"]["length"]) == (0x27, 11),
                "Expected the CN350 TXD main-camera AF layout")
        decoder = Path(__file__).resolve().parents[1] / "scripts/decode-camera-focus.py"
        decode = runpy.run_path(str(decoder))["decode_af_block"]
    bus, sensor, master = hardware()
    check_idle(sensor, master)
    levels = rail_levels()
    print(f"CCI0 master=0 rate=400000 VAF_uV={levels[0]} camera_io_uV={levels[1]} "
          "HI1339=suspended CCI=suspended", flush=True)
    if not (args.read_id or args.af_layout):
        return
    try:
        with main_sensor_power(sensor, args.power_main):
            with trace_queues() if args.trace_queues else nullcontext():
                if args.af_layout:
                    verify_calibration(bus, layout, decode)
                else:
                    read_chip_id(bus)
    finally:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if all(contents(dev / "power/runtime_status") == "suspended" for dev in (sensor, master)):
                break
            time.sleep(.1)
        check_idle(sensor, master)
        require(rail_levels() == levels, "Regulator level changed during probe")
        print("After read: CCI=suspended HI1339=suspended existing_rails=enabled", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as exc:
        sys.exit(str(exc))
