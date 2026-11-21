# /// script
# requires-python = ">=3.11"
# dependencies = ["pyserial==3.5"]
# ///
"""Verify and load the dev12.12 storage-disabled early USB receiver into RAM."""

import argparse
import binascii
from contextlib import closing
import hashlib
from pathlib import Path
import re
import secrets
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib


MIB = 1 << 20
SLOTS = {"kernel.efi": ("kernel_addr_r", 128 * MIB), "initrd": ("ramdisk_addr_r", 128 * MIB),
         "board.dtb": ("fdt_addr_r", 2 * MIB)}
KERNEL = "0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60"
DISKLESS_DT = "8ad76f844d20ebb57f7ebcaad91c61e0484f139a1e9fdfccec02ba198c02cf82"
CONTROLLERS = ("/soc@0/ufshc@1d84000", "/soc@0/mmc@8804000")
ESP_KERNEL = "/EFI/y700-display-12-11.efi"
EFI_ID = b"systemd-boot 262 (aa64), UEFI Specification 2.110, Vendor Das U-Boot 8230.4096"
RETURN_WAIT = b"Press any key to continue..."
BOARD_MENU = [b"*** U-Boot Boot Menu ***", b"Press UP/DOWN to move, ENTER to select, ESC to quit",
              b"1. Boot NixOS", b"2. Enable USB serial console", b"3. Drop to shell",
              b"4. Reset device", b"0. Exit"]
SHELL_PROMPT = re.compile(rb"(?:^|[\r\n])=> $")


class Refused(Exception):
    pass


def need(ok, reason):
    if not ok:
        raise Refused(reason)


def receipt(**values):
    print(" ".join(f"{key}={int(value)}" for key, value in values.items()), flush=True)


def one(pattern, text):
    matches = re.findall(pattern, text, re.M)
    need(len(matches) == 1, "Missing, duplicate or inconsistent console field")
    return matches[0]


def inputs(directory, pin):
    manifest = (directory / "SHA256SUMS").read_bytes()
    need(hashlib.sha256(manifest).hexdigest() == pin, "Incorrect release manifest")
    hashes = {}
    for line in manifest.decode("ascii").splitlines():
        digest, name = one(r"^([0-9a-f]{64})  ([a-z0-9.]+)$", line)
        need(name not in hashes, "Duplicate manifest entry")
        hashes[name] = digest
    need(set(hashes) == set(SLOTS) | {"cmdline.txt", "carrier.squashfs"}, "Unexpected receiver manifest")
    need(hashes["kernel.efi"] == KERNEL and hashes["board.dtb"] == DISKLESS_DT, "Unexpected kernel or diskless DT")
    blobs = {}
    for name, digest in hashes.items():
        path = directory / name
        if name == "carrier.squashfs":
            with path.open("rb") as source:
                need(hashlib.file_digest(source, "sha256").hexdigest() == digest, "Wrong second-stage carrier")
            continue
        limit = SLOTS[name][1] if name in SLOTS else 460
        need(0 < path.stat().st_size <= limit, "Payload exceeds its slot or command buffer")
        blob = path.read_bytes()
        need(len(blob) <= limit and hashlib.sha256(blob).hexdigest() == digest, "Host payload mismatch")
        blobs[name] = blob
    kernel = blobs["kernel.efi"]
    text_offset, image_size, flags = struct.unpack_from("<QQQ", kernel, 8)
    need(kernel[56:60] == b"ARM\x64" and text_offset == 0 and flags & 8 and
         len(kernel) <= image_size <= SLOTS["kernel.efi"][1], "Unexpected ARM64 Image footprint")
    cmdline = blobs.pop("cmdline.txt").decode("ascii").removesuffix("\n")
    need(re.fullmatch(r"[a-zA-Z0-9=.,:/_ -]+", cmdline) and
         cmdline.split()[:5] == ["rdinit=/y700-ram-receive-init", "y700.media=ram", "fstab=no",
                                 "systemd.gpt_auto=0", "noresume"] and
         all(t.split("=")[0] not in {"root", "init", "resume", "rdinit"} for t in cmdline.split()[5:]),
         "Unexpected early receiver command line")
    need(sum(map(len, blobs.values())) <= SLOTS["kernel.efi"][1], "First-stage payload exceeds staging space")
    return blobs, cmdline


def number(name, text):
    return int(one(rf"^{name}=(?:0x)?([0-9a-fA-F]+)$", text), 16)


def lmb(kind, text):
    count = int(one(rf"^\s*{kind}\.count\s*=\s*(0x[0-9a-fA-F]+)\s*$", text), 16)
    lines = [line.strip() for line in text.splitlines() if line.lstrip().startswith(kind + "[")]
    need(0 < count == len(lines) <= 256, "Incomplete LMB table")
    result = []
    for i, line in enumerate(lines):
        spec = rf"^{kind}\[{i}\]\s+\[0x([\da-fA-F]+)-0x([\da-fA-F]+)\], 0x([\da-fA-F]+) bytes, flags: (.+)$"
        start, last, size, flags = one(spec, line)
        lo, end = int(start, 16), int(last, 16) + 1
        need(0 <= lo < end <= 1 << 64 and int(size, 16) == end - lo and
             (not result or result[-1][1] <= lo), "Inconsistent or overlapping LMB entry")
        result.append((lo, end, flags))
    return result


def layout(env, board):
    memory, reserved = lmb("memory", board), lmb("reserved", board)
    addresses = {name: number(var, env) for name, (var, _) in SLOTS.items()}
    # Qualcomm board_late_init allocates contiguous LMB_NONE slots downwards,
    # starting with the 128-MiB kernel and 128-MiB initrd, ending at the DT.
    # The physical firmware coalesces this entire allocation into one range.
    k, r, f = (addresses[n] for n in SLOTS)
    need(k == r + 128 * MIB and f + 2 * MIB <= r and
         all(addr % (2 * MIB) == 0 for addr in addresses.values()), "Unexpected firmware slot order")
    top = k + 128 * MIB
    need(any(lo <= f and top <= end and flags == "none" for lo, end, flags in memory) and
         (f, top, "none") in reserved, "Named slots do not match the complete allocated DRAM reservation")
    control = number("fdtcontroladdr", env)
    reported = int(one(r"^fdt_blob\s*=\s*(0x[\da-fA-F]+)\s*$", board), 16)
    need(control == reported and any(lo <= control < end and "no-overwrite" in flags
                                      for lo, end, flags in reserved), "Unprotected or wrong control DT")
    return addresses, control


def verify_board(text):
    need(one(r'^model = "([^"]+)"$', text) == "Lenovo Legion Y700 2nd gen" and
         one(r'^compatible = (.+)$', text) == '"lenovo,asphalt", "qcom,sm8475"' and
         one(r'^region_country = "([^"]+)"$', text) == "PRC", "Unexpected board, SoC or region")


def verify_crc(text, addr, blob):
    start, last, value = one(r"^crc32 for ([\da-fA-F]+) \.\.\. ([\da-fA-F]+) ==> ([\da-fA-F]{8})$", text)
    need((int(start, 16), int(last, 16), int(value, 16)) ==
         (addr, addr + len(blob) - 1, zlib.crc32(blob)), "Target address, size or CRC mismatch")


def write(port, data):
    need(port.write(data) == len(data), "Incomplete USB serial write")


def prompt(port, timeout=12):
    end, raw = time.monotonic() + timeout, bytearray()
    while time.monotonic() < end and len(raw) < 128 * 1024:
        raw.extend(port.read(max(port.in_waiting, 1)))
        if SHELL_PROMPT.search(raw):
            return raw.decode("ascii", "replace").replace("\r", "").removesuffix("=> ")
    raise Refused("U-Boot shell prompt missing")


def command(port, cmd, timeout=12):
    write(port, cmd.encode("ascii") + b"\r")
    return prompt(port, timeout)


def cancel_menu(port):
    write(port, b"\x1b")
    time.sleep(.3)
    write(port, b"\x03")
    prompt(port)


def read_display(port, timeout=4):
    """Read one serial display update through a quiet interval without sending a key."""
    deadline = time.monotonic() + timeout
    latest = None
    raw = bytearray()
    while time.monotonic() < deadline:
        data = port.read(min(max(port.in_waiting, 1), 4096))
        if data:
            raw.extend(data)
            need(len(raw) < 128 * 1024, "Unexpectedly large boot menu response")
            latest = time.monotonic()
        elif latest is not None and time.monotonic() - latest >= .3:
            return bytes(raw)
    need(latest is None, "Boot menu response did not settle")
    return b""


def display_rows(raw):
    # Colour changes preserve text. Cursor movement and erasure delimit fields
    # on both the U-Boot ANSI display and systemd-boot's EFI text console.
    raw = re.sub(rb"\x1b\[[0-9;]*m", b"", raw)
    raw = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"\n", raw)
    return [line.strip() for line in raw.splitlines() if line.strip()]


def board_menu(rows):
    return rows[-len(BOARD_MENU):] == BOARD_MENU


def acquire_from_efi(port):
    initial = read_display(port, 1.5)
    rows = display_rows(initial)
    if SHELL_PROMPT.search(initial):
        write(port, b"\x03")
        prompt(port)
        return
    if board_menu(rows):
        cancel_menu(port)
        return
    need(RETURN_WAIT not in rows, "Unverified continuation prompt already active")
    need(BOARD_MENU[0] not in rows, "Unrecognized or incomplete U-Boot maintenance menu")

    # 'v' displays the EFI version. In an already-running shell it merely
    # echoes the typed character. Never submit that character as a command.
    write(port, b"v")
    fresh = read_display(port)
    if fresh == b"v":
        write(port, b"\x03")
        prompt(port)
        return
    # The EFI text console can draw a horizontal border below the status line.
    fields = [row for row in display_rows(fresh) if row.replace("─".encode(), b"")]
    need(fields == [EFI_ID], "Expected the verified systemd-boot and U-Boot version display")
    write(port, b"Q")
    rows = display_rows(read_display(port, 8))
    need(rows == [RETURN_WAIT], "EFI did not return to the expected continuation prompt")
    write(port, b"\x03")
    need(board_menu(display_rows(read_display(port, 8))), "Expected the PRC U-Boot maintenance menu")
    cancel_menu(port)
    receipt(efi_menu_exit=1)


def connect(wait, exit_efi_menu=False):
    import serial
    from serial.tools import list_ports
    end = time.monotonic() + wait
    while time.monotonic() < end:
        ports = [item for item in list_ports.comports() if (item.vid, item.pid) == (0x18d1, 0x4ee0)]
        need(len(ports) <= 1, "Ambiguous U-Boot ACM interface")
        if ports:
            try:
                port = serial.Serial(ports[0].device, 115200, timeout=.15, write_timeout=5)
            except serial.SerialException:
                time.sleep(.4)
                continue
            try:
                if exit_efi_menu:
                    acquire_from_efi(port)
                else:
                    cancel_menu(port)
                return port
            except BaseException:
                port.close()
                raise
        time.sleep(.4)
    raise Refused("No enabled U-Boot ACM port")


def inspect(port):
    version = command(port, "version")
    one(r"^U-Boot 2026\.10(?:-rc[0-9]+)?(?:[- (].*)?$", version)
    board = command(port, "bdinfo")
    env = command(port, "printenv kernel_addr_r ramdisk_addr_r fdt_addr_r fdtcontroladdr")
    addresses, control = layout(env, board)
    select_dt(port, control)
    read_board(port)
    return addresses


def read_board(port):
    verify_board("\n".join(command(port, "fdt print / " + key) for key in ("model", "compatible", "region_country")))


def select_dt(port, address):
    text = command(port, f"fdt addr {address:x}")
    need(int(one(r"^Working FDT set to (?:0x)?([0-9a-fA-F]+)$", text), 16) == address,
         "Did not select the requested FDT")


def response(port, accepted, timeout):
    end = time.monotonic() + timeout
    cancel = False
    while time.monotonic() < end:
        value = port.read(1)
        need(not (cancel and value == b"\x18"), "YMODEM receiver cancelled")
        if value in accepted:
            return value
        cancel = value == b"\x18"
    raise TimeoutError("YMODEM response timed out")


def packet(index, data, size):
    data = data.ljust(size, b"\0")
    return bytes((1 if size == 128 else 2, index % 256, 255 - index % 256)) + data + binascii.crc_hqx(data, 0).to_bytes(2, "big")


def send_packet(port, data):
    for _ in range(8):
        write(port, data)
        try:
            if response(port, (b"\x06", b"\x15"), 8) == b"\x06":
                return
        except TimeoutError:
            pass
    raise Refused("YMODEM retries exhausted")


def loady(port, addr, blob):
    deadline = time.monotonic() + 360 + len(blob) / 4096
    write(port, f"loady {addr:x}\r".encode())
    try:
        response(port, (b"C",), 30)
        send_packet(port, packet(0, b"payload\0" + str(len(blob)).encode() + b"\0", 128))
        for offset in range(0, len(blob), 1024):
            need(time.monotonic() < deadline, "YMODEM transfer deadline reached")
            send_packet(port, packet(1 + offset // 1024, blob[offset:offset + 1024], 1024))
            if offset and offset % (4 * MIB) == 0:
                receipt(sent_bytes=offset + 1024, component_bytes=len(blob))
        send_packet(port, b"\x04")
        response(port, (b"C",), 15)
        send_packet(port, packet(0, b"", 128))
    except BaseException:
        write(port, b"\x18" * 4 + b"\x08" * 4)
        raise
    hex_size, decimal = one(r"^.*Total Size\s*=\s*0x([a-fA-F0-9]+)\s*=\s*(\d+) Bytes\s*$", prompt(port, 25))
    need(int(decimal) == int(hex_size, 16) == len(blob), "YMODEM receiver size mismatch")


def esp_kernel(port, expected_uuid, addr, blob):
    # Use the board's normal pre-scanned UFS LUNs and partition label. Never
    # mount a filesystem, enumerate files, or use paths supplied by the host.
    matches = []
    for lun in range(8):
        numbers = re.findall(r"^0x([0-9a-fA-F]{1,2})$", command(port, f"part number scsi {lun} linux-boot"), re.M)
        if len(numbers) == 1 and int(numbers[0], 16) > 0:
            target = f"{lun}:{int(numbers[0], 16):x}"
            ids = re.findall(r"^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$",
                             command(port, f"part uuid scsi {target}").lower(), re.M)
            if ids == [str(expected_uuid)]:
                matches.append(target)
    if len(matches) != 1:
        return False
    target = matches[0]
    size = len(blob)
    size_text = command(port, f"if fatsize scsi {target} {ESP_KERNEL}; then printenv filesize; fi")
    sizes = re.findall(r"^filesize=(?:0x)?([0-9a-fA-F]+)$", size_text, re.M)
    if len(sizes) != 1 or int(sizes[0], 16) != size:
        return False
    # Never let unexpected file growth write beyond the authenticated image.
    read = command(port, f"if fatload scsi {target} {addr:x} {ESP_KERNEL} {size:x}; then printenv fileaddr filesize; fi", 90)
    counts = re.findall(r"^(\d+) bytes read(?: in .*)?$", read, re.M)
    try:
        if counts != [str(size)] or number("fileaddr", read) != addr or number("filesize", read) != size:
            return False
    except Refused:
        return False
    crc = command(port, f"crc32 {addr:x} {size:x}", 60)
    try:
        verify_crc(crc, addr, blob)
    except Refused:
        return False
    return True


def serial_stage(port, blobs, addresses, esp_uuid):
    cached = esp_uuid is not None and esp_kernel(port, esp_uuid, addresses["kernel.efi"], blobs["kernel.efi"])
    if esp_uuid is not None:
        receipt(esp_kernel_hit=cached, usb_bytes_saved=len(blobs["kernel.efi"]) if cached else 0)
    for name in ("board.dtb", "kernel.efi", "initrd"):
        if name != "kernel.efi" or not cached:
            loady(port, addresses[name], blobs[name])


def fastboot(port, executable, blobs, address):
    # A volatile challenge ties fastboot (and the returned ACM shell) to this
    # exact session without recording a USB serial number or assuming a port.
    token = secrets.token_hex(16)
    field = "y700" + secrets.token_hex(4)
    command(port, f"setenv fastboot.{field} {token}")
    need(one(rf"^fastboot\.{field}=(\w+)$", command(port, f"printenv fastboot.{field}")) == token, "Missing session tag")
    base = address["kernel.efi"]
    write(port, ("setenv stdin serial,button-kbd; setenv stdout vidconsole,serial; "
                 "setenv stderr vidconsole,serial; "
                 f"fastboot -l {base:x} -s 8000000 usb 0; run serial_gadget\r").encode())
    port.close()

    def run(*args, timeout=15):
        p = subprocess.run([executable, *args], capture_output=True, timeout=timeout)
        need(p.returncode == 0, "Fastboot command did not complete")
        return (p.stdout + p.stderr).decode(errors="replace").replace("\r", "")

    end = time.monotonic() + 40
    serial_number = None
    while time.monotonic() < end and not serial_number:
        devices = [line.split() for line in run("devices").splitlines() if line.strip()]
        need(len(devices) <= 1, "Ambiguous fastboot devices")
        if devices:
            need(len(devices[0]) == 2 and devices[0][1] == "fastboot", "Unexpected fastboot enumeration")
            serial_number = devices[0][0]
        else:
            time.sleep(.4)
    need(serial_number, "Fastboot driver/device absent; ACM can be restored at the board")
    def fb(*args, timeout=15):
        return run("-s", serial_number, *args, timeout=timeout)
    def getvar(key):
        return one(rf"^{re.escape(key)}: (.+)$", fb("getvar", key))
    need(getvar(field) == token and getvar("version-bootloader") == "U-Boot 2026.10" and
         int(getvar("max-download-size"), 0) == 128 * MIB, "Fastboot session identity or capacity mismatch")
    try:
        with tempfile.TemporaryDirectory(prefix="y700-fastboot-ram-") as work:
            path = Path(work, "stage.bin")
            path.write_bytes(b"".join(blobs[n] for n in SLOTS))
            fb("stage", str(path), timeout=150)
        offset = len(blobs["kernel.efi"])
        for name in ("initrd", "board.dtb"):
            size = len(blobs[name])
            fb("oem", f"run:cp.b {base + offset:x} {address[name]:x} {size:x}")
            offset += size
    finally:
        if getvar(field) == token:
            fb("continue")
    target = connect(45)
    try:
        need(one(rf"^fastboot\.{field}=(\w+)$", command(target, f"printenv fastboot.{field}")) == token,
             "Returned ACM differs from original session")
        need(inspect(target) == address, "RAM layout changed across USB handover")
        command(target, f"setenv fastboot.{field}")
        return target
    except BaseException:
        target.close()
        raise


def finish(port, blobs, address, cmdline, boot):
    for name in SLOTS:
        addr, blob = address[name], blobs[name]
        verify_crc(command(port, f"crc32 {addr:x} {len(blob):x}", 60), addr, blob)
    select_dt(port, address["board.dtb"])
    read_board(port)
    for controller in CONTROLLERS:
        need(one(r'^status = "(\w+)"$', command(port, f"fdt print {controller} status")) == "disabled",
             "Staged DT enables a storage controller")
    receipt(target_crcs=3, disabled_storage_controllers=2)
    if boot:
        command(port, "setenv bootargs " + cmdline)
        need(one(r"^bootargs=(.*)$", command(port, "printenv bootargs")) == cmdline, "Boot arguments differ")
        write(port, f"booti {address['kernel.efi']:x} {address['initrd']:x}:{len(blobs['initrd']):x} {address['board.dtb']:x}\r".encode())
        receipt(boot_requests=1)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("action", choices=("check", "inspect", "stage", "boot", "boot-staged"))
    cli.add_argument("directory", type=Path)
    cli.add_argument("manifest_sha256")
    cli.add_argument("--fastboot", type=Path, help="Use this host fastboot executable instead of ACM YMODEM")
    cli.add_argument("--esp-kernel", type=uuid.UUID, metavar="PARTUUID",
                     help="Allow read-only UFS access to the verified linux-boot ESP to save kernel upload time")
    cli.add_argument("--exit-efi-menu", action="store_true",
                     help="Allow exiting the verified dev12.11 systemd-boot menu back to its U-Boot shell")
    args = cli.parse_args()
    if args.esp_kernel and (args.fastboot or args.action not in ("stage", "boot")):
        cli.error("--esp-kernel applies to YMODEM stage or boot")
    if args.exit_efi_menu and args.action == "check":
        cli.error("--exit-efi-menu applies to board actions")
    blobs, cmdline = inputs(args.directory, args.manifest_sha256)
    receipt(host_verified=5, first_stage_files=3, first_stage_bytes=sum(map(len, blobs.values())))
    if args.action == "check":
        return
    executable = None if args.fastboot is None else str(args.fastboot.resolve(strict=True))
    with closing(connect(30, args.exit_efi_menu)) as serial_port:
        address = inspect(serial_port)
        receipt(verified_boards=1, verified_ram_slots=3)
        if args.action == "inspect":
            return
        if args.action == "boot-staged":
            finish(serial_port, blobs, address, cmdline, True)
            return
        if executable:
            with closing(fastboot(serial_port, executable, blobs, address)) as returned:
                finish(returned, blobs, address, cmdline, args.action == "boot")
        else:
            serial_stage(serial_port, blobs, address, args.esp_kernel)
            finish(serial_port, blobs, address, cmdline, args.action == "boot")


if __name__ == "__main__":
    try:
        main()
    except (Refused, OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error) if isinstance(error, Refused) else f"Transport or input failed ({type(error).__name__})")
