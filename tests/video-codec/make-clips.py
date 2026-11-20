"""Build bounded, synthetic access units and independent software frame hashes."""
import argparse
import hashlib
from pathlib import Path
import re
import struct
import subprocess


COUNT = 24


def annex_b_units(data, codec):
    starts = []
    for match in re.finditer(b"\x00\x00(?:\x00)?\x01", data):
        header = data[match.end()]
        nal_type = (header & 31) if codec == "h264" else ((header >> 1) & 63)
        is_aud = nal_type == (9 if codec == "h264" else 35)
        if is_aud:
            starts.append(match.start())
    if len(starts) != COUNT:
        raise ValueError(f"Unexpected number of {codec} access unit delimiters")
    starts[0] = 0  # Preserve any headers before the first AUD.
    return [data[start:end] for start, end in zip(starts, starts[1:] + [len(data)])]


def ivf_units(data):
    if data[:4] != b"DKIF" or data[8:12] != b"VP90":
        raise ValueError("Expected VP9 in an IVF container")
    offset = struct.unpack_from("<H", data, 6)[0]
    frames = []
    while offset < len(data):
        size, timestamp = struct.unpack_from("<IQ", data, offset)
        offset += 12
        if timestamp != len(frames) or not size or offset + size > len(data):
            raise ValueError("Unexpected IVF packet")
        frames.append(data[offset:offset + size])
        offset += size
    return frames


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("ffmpeg")
    cli.add_argument("output", type=Path)
    cli.add_argument("--full-hd", action="store_true", help="1920x1080 with B pictures in H.264 and HEVC")
    args = cli.parse_args()
    args.output.mkdir()
    width, height = (1920, 1080) if args.full_hd else (384, 256)
    bframes = 2 if args.full_hd else 0
    options = {
        "h264": ["-c:v", "libx264", "-preset", "fast", "-x264-params", f"aud=1:repeat-headers=1:bframes={bframes}:threads=1"],
        "hevc": ["-c:v", "libx265", "-preset", "fast", "-x265-params", f"aud=1:repeat-headers=1:bframes={bframes}:pools=none:frame-threads=1:log-level=error"],
        "vp9": ["-c:v", "libvpx-vp9", "-deadline", "good", "-cpu-used", "4", "-lag-in-frames", "0", "-auto-alt-ref", "0"],
    }
    common = [args.ffmpeg, "-nostdin", "-v", "error"]
    for codec, encoder in options.items():
        folder = args.output / codec
        folder.mkdir()
        encode = common + ["-f", "lavfi", "-i", f"testsrc2=size={width}x{height}:rate=12",
                           "-frames:v", str(COUNT), "-pix_fmt", "yuv420p", "-threads", "1"]
        if codec == "vp9":
            data = subprocess.check_output(encode + encoder + ["-f", "ivf", "pipe:1"])
            media = folder / "clip.webm"
            subprocess.run(common + ["-f", "ivf", "-i", "pipe:0", "-c:v", "copy", "-bitexact", str(media)],
                           input=data, check=True)
        else:
            # Mux the encoder's original PTS and DTS so B pictures keep their presentation order.
            media = folder / "clip.mp4"
            subprocess.run(encode + encoder + ["-movflags", "+faststart", "-bitexact", str(media)], check=True)
            data = subprocess.check_output(common + [
                "-i", str(media), "-c:v", "copy", "-bsf:v", f"{codec}_mp4toannexb", "-f", codec, "pipe:1",
            ])
        packets = ivf_units(data) if codec == "vp9" else annex_b_units(data, codec)
        if len(packets) != COUNT:
            raise ValueError("Incorrect packet count")
        for index, packet in enumerate(packets):
            (folder / f"{index:03d}.au").write_bytes(packet)
        raw = subprocess.check_output(common + [
            "-hwaccel", "none", "-threads", "1", "-i", str(media),
            "-fps_mode", "passthrough", "-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1",
        ])
        frame_size = width * height * 3 // 2
        if len(raw) != COUNT * frame_size:
            raise ValueError(f"{codec} software output has {len(raw)} bytes, expected {COUNT * frame_size}")
        hashes = [hashlib.sha256(raw[i:i + frame_size]).hexdigest() for i in range(0, len(raw), frame_size)]
        if len(set(hashes)) != COUNT:
            raise ValueError("Reference must distinguish every picture")
        (folder / "reference.sha256").write_text("\n".join(hashes) + "\n", encoding="ascii", newline="\n")
        (folder / "geometry").write_text(f"{width} {height}\n", encoding="ascii", newline="\n")
        print(f"{codec} packets={COUNT} unique_frames={COUNT} stream_sha256={hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
