"""Read the current PHY link center frequency without enumerating nearby WLANs."""
import ctypes
import struct


def frequencies(index):
    """Return all current link frequencies in MHz, using Windows SDK wlanapi.h."""
    api, iphelper = ctypes.windll.wlanapi, ctypes.windll.iphlpapi
    luid, guid = ctypes.c_uint64(), (ctypes.c_ubyte * 16)()
    handle, version = ctypes.c_void_p(), ctypes.c_ulong()
    size, address = ctypes.c_ulong(), ctypes.c_void_p()
    ref = ctypes.byref

    def checked(code):
        if code:
            raise OSError(code, "WLAN quality query unavailable")

    checked(iphelper.ConvertInterfaceIndexToLuid(index, ref(luid)))
    checked(iphelper.ConvertInterfaceLuidToGuid(ref(luid), ref(guid)))
    checked(api.WlanOpenHandle(2, None, ref(version), ref(handle)))
    try:
        # wlan_intf_opcode_realtime_connection_quality is explicitly location-free.
        checked(api.WlanQueryInterface(handle, ref(guid), 19, None, ref(size), ref(address), None))
        if not address or not 24 <= size.value <= 8192:
            raise ValueError("Unexpected WLAN quality structure")
        data = ctypes.string_at(address, size.value)
        links, = struct.unpack_from("<I", data, 20)
        # WLAN_REALTIME_CONNECTION_QUALITY_LINK_INFO includes WLAN_RATE_SET[126].
        stride = 272
        if not 1 <= links <= 16 or len(data) < 24 + links * stride:
            raise ValueError("Incomplete WLAN quality links")
        result = []
        for link in range(links):
            raw, = struct.unpack_from("<I", data, 28 + link * stride)
            # Windows documents the field named ...Mhz in kHz. Some drivers return MHz.
            if 2400000 <= raw <= 7125000 and raw % 1000 == 0:
                raw //= 1000
            if not (2400 <= raw <= 2500 or 4900 <= raw <= 7125):
                raise ValueError("Unrecognized WLAN channel frequency")
            result.append(raw)
        return tuple(result)
    finally:
        if address:
            api.WlanFreeMemory(address)
        api.WlanCloseHandle(handle, None)


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("ifindex", type=int)
    print("WINDOWS_WLAN_MHZ", *frequencies(p.parse_args().ifindex))
