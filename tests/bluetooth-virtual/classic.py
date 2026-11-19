"""Register a Classic HID SDP record and open accessory-initiated HIDP channels."""
import ctypes as C
import socket
import struct
from contextlib import contextmanager

HID = "00001124-0000-1000-8000-00805f9b34fb"


def uint16(value):
    return b"\x09" + struct.pack(">H", value)


def uuid16(value):
    return b"\x19" + struct.pack(">H", value)


def sized(kind, payload):
    if len(payload) < 256:
        return bytes([kind | 5, len(payload)]) + payload
    return bytes([kind | 6]) + struct.pack(">H", len(payload)) + payload


def seq(*elements):
    return sized(0x30, b"".join(elements))


def record(report_map):
    def protocols(psm):
        return seq(seq(uuid16(0x0100), uint16(psm)), seq(uuid16(0x0011)))

    attrs = {
        0x0001: seq(uuid16(0x1124)), 0x0004: protocols(0x11),
        0x0005: seq(uuid16(0x1002)), 0x0006: seq(uint16(0x656e), uint16(106), uint16(0x100)),
        0x0009: seq(seq(uuid16(0x1124), uint16(0x0101))), 0x000d: seq(protocols(0x13)),
        0x0100: sized(0x20, b"Y700 virtual Classic HID"),
        0x0200: uint16(0x0100), 0x0201: uint16(0x0111), 0x0202: b"\x08\xc0", 0x0203: b"\x08\x00",
        0x0204: b"\x28\x01", 0x0205: b"\x28\x01",
        0x0206: seq(seq(b"\x08\x22", sized(0x20, report_map))),
        0x0207: seq(seq(uint16(0x0409), uint16(0x100))),
        0x0208: b"\x28\x00", 0x0209: b"\x28\x00", 0x020a: b"\x28\x00",
        0x020b: uint16(0x0101), 0x020c: uint16(0x0c80), 0x020d: b"\x28\x00", 0x020e: b"\x28\x00",
    }
    return seq(*(uint16(attr) + value for attr, value in attrs.items()))


@contextmanager
def registered(address, report_map):
    lib = C.CDLL("libbluetooth.so.3", use_errno=True)
    lib.sdp_connect.argtypes = [C.c_void_p, C.c_void_p, C.c_uint32]
    lib.sdp_connect.restype = C.c_void_p
    lib.sdp_close.argtypes = [C.c_void_p]
    lib.sdp_device_record_register_binary.argtypes = [
        C.c_void_p, C.c_void_p, C.c_void_p, C.c_uint32, C.c_uint8, C.POINTER(C.c_uint32)]
    session = lib.sdp_connect(bytes(6), bytes.fromhex("000000ffffff"), 0)
    if not session:
        raise OSError(C.get_errno(), "sdp_connect")
    try:
        data = record(report_map)
        handle = C.c_uint32()
        peer = bytes.fromhex(address.replace(":", ""))[::-1]
        if lib.sdp_device_record_register_binary(session, peer, data, len(data), 0, C.byref(handle)) < 0:
            raise OSError(C.get_errno(), "sdp_device_record_register_binary")
        print(f"SDP peer={address} handle={handle.value:#x}", flush=True)
        yield
    finally:
        lib.sdp_close(session)


@contextmanager
def outgoing(peer, host):
    channels = []
    try:
        for psm in (0x11, 0x13):
            channel = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
            channels.append(channel)
            channel.settimeout(8)
            channel.bind((peer, 0))
            channel.connect((host, psm))
            print(f"HIDP_CONNECTED_PSM_{psm:02X}", flush=True)

        def emit():
            for data in (b"\xa1\x01\x01", b"\xa1\x01\x00",
                         bytes.fromhex("a1 02 01 07 fd 01"), bytes.fromhex("a1 02 00 00 00 00")):
                channels[1].sendall(data)
            return True

        yield emit
    finally:
        for channel in reversed(channels):
            channel.close()
