"""Boot the stock EFI kernel from removable media, then eject that medium."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time


def eject():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as control:
        control.settimeout(15)
        control.connect("firmware-qmp.sock")
        with control.makefile("rwb") as stream:
            if "QMP" not in json.loads(stream.readline()):
                raise RuntimeError("QEMU control handshake failed")
            for operation in ({"execute": "qmp_capabilities"},
                              {"execute": "device_del", "arguments": {"id": "firmware-media"}}):
                stream.write(json.dumps(operation).encode() + b"\n")
                stream.flush()
                acknowledged = removed = False
                while not acknowledged or (operation["execute"] == "device_del" and not removed):
                    item = json.loads(stream.readline())
                    if "error" in item:
                        raise RuntimeError(item["error"])
                    acknowledged |= "return" in item
                    removed |= (item.get("event") == "DEVICE_DELETED" and
                                item.get("data", {}).get("device") == "firmware-media")
    print("RAM_QA_FIRMWARE_MEDIA_REMOVED", flush=True)


def deliver_payload(bundle):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as port:
        port.settimeout(220)
        port.connect("boot-payload.sock")
        with port.makefile("rb") as response:
            if response.readline(64) != b"RAM_QA_PAYLOAD_READY\n":
                raise RuntimeError("The baseline did not request the sealed payload")
            for name in ("kernel.efi", "initrd"):
                with (bundle / name).open("rb") as source:
                    if port.sendfile(source) != os.fstat(source.fileno()).st_size:
                        raise RuntimeError(f"Incomplete transfer of {name}")
            if response.readline(64) != b"RAM_QA_PAYLOAD_RECEIVED\n":
                raise RuntimeError("The baseline did not acknowledge the complete transfer")
    print("RAM_QA_PAYLOAD_DELIVERED", flush=True)


def main(args):
    args = list(args)

    def take(option):
        if args.count(option) != 1:
            raise ValueError(f"Expected exactly one {option}")
        index = args.index(option)
        args.pop(index)
        return args.pop(index)

    if (take("-machine"), take("-cpu"), take("-m"), take("-smp")) != ("virt,gic-version=3", "max", "9216", "3"):
        raise ValueError("Unexpected virtual board configuration")
    if any(arg in {"-bios", "-drive", "-pflash", "-blockdev"} or "nolpi" in arg or "its=off" in arg for arg in args):
        raise ValueError("Unexpected firmware, media or IRQ option")
    for option in ("-kernel", "-initrd", "-dtb", "-append"):
        take(option)
    serial = take("-serial")
    if not serial.startswith("file:"):
        raise ValueError("Expected the fixture's serial log")
    log = Path(serial.removeprefix("file:"))
    disk = Path.cwd() / "firmware-boot.img"
    if not disk.is_file() or disk.is_symlink():
        raise RuntimeError("The private firmware boot medium is missing")
    command = [os.environ["Y700_REAL_QEMU"], *args, "-serial", serial, "-bios", os.environ["Y700_UBOOT"],
               "-machine", "virt,gic-version=3,acpi=off", "-cpu", "cortex-a72", "-m", "9216", "-smp", "3",
               "-device", "qemu-xhci,id=firmware-usb", "-drive", f"if=none,id=esp,file={disk},readonly=on,format=raw",
               "-device", "usb-storage,id=firmware-media,drive=esp,bus=firmware-usb.0",
               "-chardev", "socket,id=payload,path=boot-payload.sock,server=on,wait=off",
               "-device", "virtserialport,chardev=payload,name=org.y700.boot-payload",
               "-qmp", "unix:firmware-qmp.sock,server=on,wait=off"]
    guest = subprocess.Popen(command, stdin=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 480
        while time.monotonic() < deadline:
            if log.exists() and b"efi: EFI v2.11 by Das U-Boot" in log.read_bytes():
                break
            if guest.poll() is not None:
                raise RuntimeError("The first EFI kernel did not start")
            time.sleep(.25)
        else:
            raise TimeoutError("The first EFI kernel did not identify U-Boot")
        # EFI has exited its boot services and delivered the initrd in RAM.
        eject()
        deliver_payload(Path(os.environ["Y700_HANDOVER_BUNDLE"]))
        return guest.wait()
    finally:
        if guest.poll() is None:
            guest.terminate()
            try:
                guest.wait(10)
            except subprocess.TimeoutExpired:
                guest.kill()
                guest.wait()


if __name__ == "__main__":
    def stop(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, stop)
    raise SystemExit(main(sys.argv[1:]))
