"""Export one generated UAC1 device to the disposable guest's kernel VHCI."""
import math
from pathlib import Path
import struct
import signal
import threading

from usbip import protocol, SPEED_FULL, Loopback
from usbip.device import USBDevice
from usbip.classes.device import UAC

assert "y700.test_uac=1" in Path("/proc/cmdline").read_text().split()
assert Path("/sys/block/vda/ro").read_text().strip() == "1"
done = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: done.set())
device = USBDevice(0x1209, 0x7001, manufacturer="Test", product="Generated UAC1", serial="fixture")
device.set_speed(SPEED_FULL)
# 440 Hz has 11 complete cycles in 1200 samples at 48 kHz. Generate once
# so a CPU-emulated guest need not calculate every 1 ms packet in Python.
period = b"".join(struct.pack("<h", round(16000 * math.sin(2 * math.pi * 11 * i / 1200)))
                  for i in range(1200))


def generated_tone(_stream, frames, index):
    start = 2 * (index % 1200)
    length = frames * 2
    return (period * (1 + (start + length) // len(period)))[start:start + length]


events = {}


def event(message):
    kind = message.split(" (")[0]
    events[kind] = events.get(kind, 0) + 1
    if events[kind] == 1:
        print(message, flush=True)


device.add(UAC(mic_source=generated_tone, on_event=event))
# Immediate completion keeps this software peer's submit/unlink replies ordered.
device.set_iso_pacing(False)
transport = Loopback()
device.plug(via=transport)
vhci = Path("/sys/devices/platform/vhci_hcd.0")
# Only run on an empty virtual controller in this no-NIC QEMU test.
assert not any(
    p.read_text().strip() == "1209" for p in Path("/sys/bus/usb/devices").glob("*/idVendor")
)
try:
    with transport.connect() as sock:
        sock.settimeout(None)
        info = protocol.client_import(sock)
        assert (info["idVendor"], info["idProduct"], info["speed"]) == (0x1209, 0x7001, 2)  # Linux USB_SPEED_FULL
        devid = info["busnum"] << 16 | info["devnum"]
        (vhci / "attach").write_text(f"0 {sock.fileno()} {devid} {info['speed']}")
        try:
            done.wait(145)
        finally:
            (vhci / "detach").write_text("0")
finally:
    device.unplug()
