"""Exercise the installed GStreamer libraries; the sealed image has no gst-launch or Gst GI."""
import ctypes as C
import hashlib
from pathlib import Path


gst = C.CDLL("libgstreamer-1.0.so.0")
glib = C.CDLL("libglib-2.0.so.0")
ptr = C.c_void_p


class Error(C.Structure):
    _fields_ = [("domain", C.c_uint), ("code", C.c_int), ("message", C.c_char_p)]


def symbol(lib, name, result, *args):
    func = getattr(lib, name)
    func.argtypes, func.restype = args, result
    return func


symbol(gst, "gst_init", None, ptr, ptr)(None, None)
factory = symbol(gst, "gst_element_factory_find", ptr, C.c_char_p)
parse = symbol(gst, "gst_parse_launch", ptr, C.c_char_p, C.POINTER(C.POINTER(Error)))
bus_for = symbol(gst, "gst_element_get_bus", ptr, ptr)
set_state = symbol(gst, "gst_element_set_state", C.c_int, ptr, C.c_int)
pop = symbol(gst, "gst_bus_timed_pop_filtered", ptr, ptr, C.c_uint64, C.c_int)
structure = symbol(gst, "gst_message_get_structure", ptr, ptr)
parse_error = symbol(gst, "gst_message_parse_error", None, ptr, C.POINTER(C.POINTER(Error)), ptr)
free_error = symbol(glib, "g_error_free", None, C.POINTER(Error))
unref = symbol(gst, "gst_object_unref", None, ptr)
release_message = symbol(gst, "gst_mini_object_unref", None, ptr)


def pipeline(description):
    error = C.POINTER(Error)()
    element = parse(description.encode(), C.byref(error))
    if error:
        message = error.contents.message.decode()
        free_error(error)
        if element:
            unref(element)
        raise RuntimeError(message)
    bus = bus_for(element)
    try:
        set_state(element, 4)  # PLAYING
        event = pop(bus, 15_000_000_000, 1 | 2)  # EOS or ERROR
        if not event:
            raise TimeoutError("No terminal bus message")
        try:
            if structure(event):  # ERROR has a structure. EOS is an empty message.
                parse_error(event, C.byref(error), None)
                reason = error.contents.message.decode()
                free_error(error)
                return reason
            return None
        finally:
            release_message(event)
    finally:
        set_state(element, 1)  # NULL
        unref(bus)
        unref(element)


def main():
    assert not list(Path("/dev").glob("video[0-9]*")), "This reference requires a guest without decoder hardware"
    for name in ("rawvideoparse", "videoconvert", "matroskademux", "vp9dec", "qtdemux", "h264parse",
                 "h265parse", "avdec_h264", "openh264dec", "v4l2h264dec", "v4l2h265dec", "v4l2vp9dec", "v4l2src"):
        found = factory(name.encode())
        print(f"GST_FACTORY {name}={int(bool(found))}", flush=True)
        if found:
            unref(found)
    expected = Path("expected.i420").read_bytes()
    assert len(expected) == 6 * 192 * 112 * 3 // 2
    reason = pipeline("filesrc location=padded.nv12 ! rawvideoparse format=nv12 width=192 height=112 "
                      'plane-strides="<256,256>" plane-offsets="<0,32768>" frame-size=49152 framerate=2/1 '
                      "! videoconvert ! video/x-raw,format=I420 ! filesink location=cropped.i420")
    assert not reason, reason
    assert Path("cropped.i420").read_bytes() == expected
    print("GST_LINEAR_NV12 stride=256 scanlines=128 visible=192x112 frames=6 exact_i420=1", flush=True)
    for name in ("vp9.webm", "h264.mp4", "hevc.mp4"):
        reason = pipeline(f"uridecodebin uri={Path(name).resolve().as_uri()} ! videoconvert "
                          "! video/x-raw,format=I420 ! filesink location=decoded.i420")
        if name == "vp9.webm":
            assert not reason and Path("decoded.i420").read_bytes() == expected, reason
            print("GST_AUTO vp9 decoded=1 frames=6 reference_match=1", flush=True)
        else:
            assert reason and ("missing" in reason.lower() or "no suitable" in reason.lower()), reason
            print(f"GST_AUTO {name} decoded=0 missing_decoder=1", flush=True)
    board = Path("/opt/video-userspace/board-vp9.webm")
    if board.is_file():
        error = pipeline(f"uridecodebin uri={board.as_uri()} ! videoconvert "
                         "! video/x-raw,format=I420 ! filesink location=decoded.i420")
        assert not error, error
        frames = Path("decoded.i420").read_bytes()
        size = 384 * 256 * 3 // 2
        expected_hashes = board.with_suffix(".sha256").read_text().splitlines()
        actual = [hashlib.sha256(frames[i:i + size]).hexdigest() for i in range(0, len(frames), size)]
        assert len(expected_hashes) == len(set(expected_hashes)) == 24
        assert actual == expected_hashes, (len(actual), actual[0] == expected_hashes[0])
        print("GST_BOARD_VP9 driver=none frames=24 first_match=1 ordered_frame_hashes=24", flush=True)


if __name__ == "__main__":
    main()
