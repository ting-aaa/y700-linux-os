"""Exercise the production prompt parser on a diskless ARM64 QEMU serial console.

Use the reference QEMU u-boot.bin for the shell case. A second build of the same
tree with CONFIG_CMD_BOOTMENU=y can also check exiting the menu on the virtual
console with --menu. All input and output use pipes connected to QEMU.
"""
import argparse
import io
from pathlib import Path
import re
import runpy
import subprocess
import time


helpers = runpy.run_path(str(Path(__file__).with_name("esp-qemu.py")))
stage = helpers["stage"]
FIRMWARE = "ccfe8c4136a02adccdc68b2e7567fa4a06cc8874213064f62f20463803706c4f"


class Replay(io.BytesIO):
    @property
    def in_waiting(self):
        return len(self.getbuffer()) - self.tell()

    def read(self, count):
        if not self.in_waiting:
            time.sleep(.002)
        return super().read(count)


def wait_for_text(port, token):
    deadline = time.monotonic() + 5
    output = bytearray()
    while token not in output:
        if time.monotonic() > deadline or len(output) > 65536:
            raise RuntimeError("Virtual menu or command echo did not appear")
        output.extend(port.read(65536))


def verify(port, menu):
    port.interrupt_autoboot()  # Consumes the original prompt before the host reconnects.
    port.write(b"\x03")
    assert "<INTERRUPT>\n" in stage.prompt(port)
    port.write(b"\x03\x03")
    # Read the entire burst, even if the backend delivers the prompts separately.
    burst = bytearray()
    deadline = time.monotonic() + 5
    while burst.count(b"<INTERRUPT>\r\n=> ") < 2:
        if time.monotonic() >= deadline:
            raise RuntimeError("Missing second interrupt response")
        burst.extend(port.read(4096))
    assert stage.prompt(Replay(burst), 1).count("<INTERRUPT>\n") == 2

    stage.command(port, "setenv y700_prompt_qa untouched")
    port.write(b"setenv y700_prompt_qa unexpected")
    wait_for_text(port, b"unexpected")
    port.write(b"\x03")
    stage.prompt(port)
    if menu:
        stage.command(port, "setenv bootmenu_0 Diagnostic=setenv y700_prompt_qa selected")
        port.write(b"bootmenu -1\r")
        wait_for_text(port, b"Diagnostic")
    port.write(b"\x1b")
    time.sleep(.3)
    port.write(b"\x03")
    stage.prompt(port)
    version = stage.command(port, "version")
    assert re.search(r"^U-Boot 2026\.10 ", version, re.M)
    value = stage.command(port, "printenv y700_prompt_qa")
    assert "y700_prompt_qa=untouched\n" in value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("uboot", type=Path)
    parser.add_argument("--qemu", default="qemu-system-aarch64")
    parser.add_argument("--data", type=Path)
    parser.add_argument("--menu", action="store_true",
                        help="Also exercise a second QEMU firmware built with CONFIG_CMD_BOOTMENU")
    args = parser.parse_args()
    digest = helpers["digest"](args.uboot)
    if not args.menu and digest != FIRMWARE:
        raise SystemExit("Expected the reference ARM64 QEMU U-Boot for the shell-only test")
    for malformed in (b"=> => ", b"status=> "):
        try:
            stage.prompt(Replay(malformed), .05)
        except stage.Refused:
            pass
        else:
            raise AssertionError("Ambiguous prompt was accepted")
    cmd = [args.qemu, "-nodefaults", "-no-user-config", "-machine", "virt,gic-version=3",
           "-cpu", "cortex-a72", "-m", "512", "-serial", "stdio", "-display", "none",
           "-monitor", "none", "-nic", "none", "-bios", str(args.uboot)]
    if args.data:
        cmd.extend(["-L", str(args.data)])
    with subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
        try:
            verify(helpers["Console"](process), args.menu)
        finally:
            process.terminate()
            process.wait(timeout=10)
    menu_result = "pass" if args.menu else "not_requested"
    print(f"UBOOT_PROMPT firmware_sha256={digest} missed=pass repeated_ctrl_c=pass "
          f"partial_discarded=1 menu_cancel={menu_result} ambiguous_rejected=2 "
          "version_verified=1 disks=0 hardware_commands=0")


if __name__ == "__main__":
    main()
