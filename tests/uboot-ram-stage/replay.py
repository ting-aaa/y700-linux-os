"""Replay the 11/17 console receipts and exercise the receiver without any USB I/O."""
import importlib.util
import io
from pathlib import Path
import re
import subprocess
import sys
import uuid
import zlib
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ram_stage", Path(__file__).resolve().parents[2] / "scripts/uboot-ram-stage.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
passed = 0


def checked(condition):
    global passed
    if not condition:
        raise AssertionError("Unexpected replay result")
    passed += 1


def rejects(func):
    try:
        func()
    except stage.Refused:
        checked(True)
        return
    raise AssertionError("Expected rejection")


def historical(debian):
    old = debian / "physical-20261117-ram-recovery"
    board = (old / "uboot-console.log").read_bytes().decode(errors="replace").replace("\r", "")
    final = (old / "linux-handoff-console.log").read_bytes().decode(errors="replace").replace("\r", "")
    addresses, _ = stage.layout(board, board)
    version = (debian / "physical-20261116-uboot-prc" / "uboot-serial.log").read_bytes()
    console = (debian / "physical-20261116-uboot-prc" / "uboot-console.log").read_bytes()
    checked(b"U-Boot 2026.10 (" in version + console)
    shipped = (debian / "uboot-prc" / "asphalt-prc-u-boot.dtb").read_bytes()
    checked(b"Lenovo Legion Y700 2nd gen\0" in shipped and b"lenovo,asphalt\0qcom,sm8475\0" in shipped)
    for name, filename in zip(stage.SLOTS, ("Image", "initrd.zst", "asphalt-prc-linux.dtb"), strict=True):
        blob = (debian / "usb-ram-recovery" / filename).read_bytes()
        addr = addresses[name]
        line = stage.one(rf"^(crc32 for {addr:x} [^\n]+)$", final)
        stage.verify_crc(line, addr, blob)
        checked(True)
        rejects(lambda: stage.verify_crc(line, addr, blob[:-1]))
    collided = re.sub(r"(?m)^ramdisk_addr_r=[0-9a-f]+$", f"ramdisk_addr_r={addresses['kernel.efi']:x}", board)
    damaged = re.sub(r"(?m)^\s*reserved\[3\][^\n]*$", "", board)
    protected = re.sub(r"(?m)^(\s*reserved\[\d+\].+flags: )none$", r"\1no-overwrite", board)
    for env, table in ((collided, board), (board, damaged), (board, protected),
                       (board.replace("fdtcontroladdr=", "removed="), board)):
        rejects(lambda: stage.layout(env, table))
    regions = re.findall(r'^region_country = "[^"]+"$', board, re.M)
    checked(len(regions) == 2 and set(regions) == {'region_country = "PRC"'})
    region = regions[-1]
    identity = 'model = "Lenovo Legion Y700 2nd gen"\ncompatible = "lenovo,asphalt", "qcom,sm8475"\n' + region
    stage.verify_board(identity)
    rejects(lambda: stage.verify_board(identity.replace('"PRC"', '"ROW"')))
    rejects(lambda: stage.verify_board(identity.replace("lenovo,asphalt", "lenovo,other")))
    return addresses, identity


def final_gate(blobs, addresses, identity, cmdline):
    crc = {}
    for name, data in blobs.items():
        addr = addresses[name]
        crc[f"crc32 {addr:x} {len(data):x}"] = f"crc32 for {addr:x} ... {addr+len(data)-1:x} ==> {zlib.crc32(data):08x}"
    fdt = addresses["board.dtb"]
    responses = {**crc, f"fdt addr {fdt:x}": f"Working FDT set to {fdt:x}",
                 f"setenv bootargs {cmdline}": "", "printenv bootargs": f"bootargs={cmdline}"}
    for row in identity.splitlines():
        responses["fdt print / " + row.split(" =")[0]] = row
    for node in stage.CONTROLLERS:
        responses[f"fdt print {node} status"] = 'status = "disabled"'
    def exercise(mapping, boot):
        port = io.BytesIO()
        with patch.object(stage, "command", lambda p, key, *args: mapping[key]), patch.object(stage, "receipt"):
            stage.finish(port, blobs, addresses, cmdline, boot)
        return port.getvalue()
    checked(exercise(responses, False) == b"")
    checked(exercise(responses, True) ==
            f"booti {addresses['kernel.efi']:x} {addresses['initrd']:x}:{len(blobs['initrd']):x} {fdt:x}\r".encode())
    for key, wrong in [(next(iter(crc)), ""), ("printenv bootargs", "bootargs=stale"),
                       (f"fdt print {stage.CONTROLLERS[0]} status", 'status = "okay"'),
                       (f"fdt addr {fdt:x}", "libfdt error")]:
        rejects(lambda: exercise({**responses, key: wrong}, True))


def ymodem():
    data = bytes(range(256)) * 5
    class Serial:
        def __init__(self):
            self.stream = io.BytesIO(b"C\x06C\x15\x06\x06\x06C\x06\r\n## Total Size = 0x500 = 1280 Bytes\r\n=> ")
            self.sent = []
        @property
        def in_waiting(self):
            return len(self.stream.getvalue()) - self.stream.tell()
        def read(self, count):
            return self.stream.read(count)
        def write(self, block):
            self.sent.append(block)
            return len(block)
    port = Serial()
    stage.loady(port, 0x200000, data)
    checked(port.sent[0] == b"loady 200000\r" and port.sent[1][3:16] == b"payload\x001280\x00")
    checked(port.sent[2] == port.sent[3] and b"".join([port.sent[3][3:-2], port.sent[4][3:259]]) == data)
    checked(port.sent[-2] == b"\x04" and port.sent[-1] == stage.packet(0, b"", 128))
    checked(stage.packet(256, bytes(128), 128)[:3] == b"\x01\x00\xff")
    port = Serial()
    port.stream = io.BytesIO(b"C\x18\x18")
    rejects(lambda: stage.loady(port, 0x200000, data))
    checked(port.sent[-1] == b"\x18" * 4 + b"\x08" * 4)


def esp(blobs, addresses):
    pin = uuid.UUID("e4c847c7-0c60-43e5-b7a0-32298b2025de")
    kernel = blobs["kernel.efi"]
    addr, size = addresses["kernel.efi"], len(kernel)
    all_slots = [addresses[name] for name in ("board.dtb", "kernel.efi", "initrd")]

    def exercise(case):
        queries, transfers = [], []
        def query(port, cmd, *args):
            queries.append(cmd)
            if cmd.startswith("part number "):
                lun = int(cmd.split()[3])
                return "0x12" if case != "label" and (lun == 3 or case == "duplicate" and lun == 5) else "not found"
            if cmd.startswith("part uuid "):
                return str(uuid.UUID(int=0) if case == "identity" else pin)
            if cmd == f"if fatsize scsi 3:12 {stage.ESP_KERNEL}; then printenv filesize; fi":
                return "" if case == "missing" else f"filesize={size + int(case == 'size'):x}"
            if cmd == f"if fatload scsi 3:12 {addr:x} {stage.ESP_KERNEL} {size:x}; then printenv fileaddr filesize; fi":
                if case == "lost":
                    raise stage.Refused("U-Boot shell prompt missing")
                return f"{size - int(case == 'short')} bytes read in 1 ms\nfileaddr={addr + int(case == 'address'):x}\nfilesize={size:x}"
            if cmd == f"crc32 {addr:x} {size:x}":
                return f"crc32 for {addr:x} ... {addr + size - 1:x} ==> {zlib.crc32(kernel) ^ int(case == 'crc'):08x}"
            raise AssertionError(cmd)
        with (patch.object(stage, "command", query), patch.object(stage, "receipt"),
              patch.object(stage, "loady", lambda p, a, b: transfers.append(a))):
            def transfer():
                stage.serial_stage(None, blobs, addresses, None if case == "off" else pin)
            if case == "lost":
                rejects(transfer)
            else:
                transfer()
        return queries, transfers

    checked(exercise("off") == ([], all_slots))
    for case in ("label", "identity", "duplicate", "missing", "size", "short", "address", "crc"):
        queries, transfers = exercise(case)
        checked(transfers == all_slots)
        if case in ("label", "identity", "duplicate", "missing", "size"):
            checked(not any("fatload " in command for command in queries))
    queries, transfers = exercise("hit")
    checked(transfers == [all_slots[0], all_slots[-1]])
    checked(queries[-1] == f"crc32 {addr:x} {size:x}")
    checked(exercise("lost")[1] == [])


def bulk(address):
    blobs = dict(zip(stage.SLOTS, (b"k" * 41, b"r" * 13, b"dt"), strict=True))
    base = address["kernel.efi"]
    def exercise(failure):
        calls = []
        def run(argv, **kwargs):
            if argv == ["test-fastboot", "devices"]:
                answer = "fixture-tag\tfastboot\n"
            else:
                checked(argv[:3] == ["test-fastboot", "-s", "fixture-tag"])
                args = argv[3:]
                calls.append(args)
                if args[0] == "getvar":
                    value = {"y700field": "wrong" if failure == "identity" else "challenge",
                             "version-bootloader": "U-Boot 2026.10", "max-download-size": "0x08000000"}[args[1]]
                    answer = f"{args[1]}: {value}\n"
                elif args[0] == "stage":
                    checked(Path(args[1]).read_bytes() == b"".join(blobs.values()))
                    if failure == "upload":
                        return subprocess.CompletedProcess(argv, 1, b"", b"")
                    answer = "Finished."
                else:
                    answer = "OKAY"
            return subprocess.CompletedProcess(argv, 0, answer.encode(), b"")
        def command(port, cmd):
            if cmd == "printenv fastboot.y700field":
                return "fastboot.y700field=challenge"
            return ""
        with (patch.object(stage.secrets, "token_hex", side_effect=["challenge", "field"]),
              patch.object(stage.subprocess, "run", run), patch.object(stage, "command", command),
              patch.object(stage, "connect", return_value=io.BytesIO()), patch.object(stage, "inspect", return_value=address)):
            def transfer():
                stage.fastboot(io.BytesIO(), "test-fastboot", blobs, address).close()
            if failure:
                rejects(transfer)
            else:
                transfer()
        return [args for args in calls if args[0] != "getvar"]
    calls = exercise(None)
    checked(len(calls) == 4 and calls[0][0] == "stage" and calls[1:] == [
        ["oem", f"run:cp.b {base+41:x} {address['initrd']:x} d"],
        ["oem", f"run:cp.b {base+54:x} {address['board.dtb']:x} 2"], ["continue"]])
    checked(exercise("identity") == [])
    checked([x[0] for x in exercise("upload")] == ["stage", "continue"])


def efi_handoff(debian):
    raw = (debian / "physical-20261117-ram-recovery/uboot-console.log").read_bytes()
    # Strip the later commands from the archived ANSI menu rendering.
    start = raw.index(b"*** U-Boot Boot Menu ***")
    end = raw.index(b"0. Exit", start) + len(b"0. Exit")
    menu = raw[start:end]
    version = b" systemd-boot 262 (aa64), UEFI Specification 2.110, Vendor Das U-Boot 8230.4096 "
    pause = b" Press any key to continue..."
    for displays, expected, success in [
        ([b"", version, pause, menu], b"vQ\x03\x1b\x03", True),
        ([menu], b"\x1b\x03", True),
        ([b"=> "], b"\x03", True),
        ([b"", b"v"], b"v\x03", True),
        ([pause], b"", False),
        ([menu.replace(b"Boot NixOS", b"Other OS")], b"", False),
        ([version, b""], b"v", False),  # A stale identity cannot authorize Q.
        ([b"", version.replace(b"262", b"261")], b"v", False),
        ([b"", version.replace(b"8230.4096", b"8230.40960")], b"v", False),
        ([b"", version + b"\r\n=> "], b"v", False),
        ([b"", b"Other firmware menu"], b"v", False),
        ([b"", version, b"Reboot now?"], b"vQ", False),
        ([b"", version, b"Reset requested\r\n" + pause], b"vQ", False),
        ([b"", version, pause, menu.replace(b"Drop to shell", b"Restart")], b"vQ\x03", False),
    ]:
        port = io.BytesIO()
        with (patch.object(stage, "read_display", side_effect=displays), patch.object(stage, "prompt"),
              patch.object(stage.time, "sleep"), patch.object(stage, "receipt")):
            if success:
                stage.acquire_from_efi(port)
            else:
                rejects(lambda: stage.acquire_from_efi(port))
        checked(port.getvalue() == expected)


if __name__ == "__main__":
    debian, new, pin = sys.argv[1:]
    addrs, identity = historical(Path(debian))
    blobs, cmdline = stage.inputs(Path(new), pin)
    rejects(lambda: stage.inputs(Path(new), "0" * 64))
    final_gate(blobs, addrs, identity, cmdline)
    ymodem()
    esp(blobs, addrs)
    bulk(addrs)
    efi_handoff(Path(debian))
    stage.receipt(host_assertions=passed, historical_crcs=3, hardware_commands=0)
