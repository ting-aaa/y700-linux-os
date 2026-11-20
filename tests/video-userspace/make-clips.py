"""Make a tiny software-encoded video corpus and matching linear Iris-layout test data."""
import argparse
from pathlib import Path
import shutil
import subprocess

COLOURS = [(81, 90, 240), (145, 54, 34), (41, 240, 110)]
FRAMES = 6


def make_raw(directory, width, height):
    stride = (width + 127) // 128 * 128
    scanlines = (height + 31) // 32 * 32
    packed = bytearray()
    padded = bytearray()
    for index in range(FRAMES):
        left, right = COLOURS[index % 3], COLOURS[(index + 1) % 3]
        y = bytes([left[0]]) * (width // 2) + bytes([right[0]]) * (width // 2)
        u = bytes([left[1]]) * (width // 4) + bytes([right[1]]) * (width // 4)
        v = bytes([left[2]]) * (width // 4) + bytes([right[2]]) * (width // 4)
        packed.extend(y * height + u * (height // 2) + v * (height // 2))
        uv = bytes(value for pair in zip(u, v) for value in pair)
        for row, visible, stored in ((y, height, scanlines), (uv, height // 2, scanlines // 2)):
            padded.extend((row + b"\xa5" * (stride - width)) * visible)
            padded.extend(b"\xa5" * stride * (stored - visible))
    (directory / "expected.i420").write_bytes(packed)
    (directory / "padded.nv12").write_bytes(padded)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("directory", type=Path)
    cli.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    cli.add_argument("--full-hd", action="store_true", help="generate 1920×1080 desktop playback fixtures")
    args = cli.parse_args()
    if not args.ffmpeg:
        import imageio_ffmpeg
        args.ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    destination = args.directory.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    width, height = (1920, 1080) if args.full_hd else (192, 112)
    make_raw(destination, width, height)

    def encode(arguments):
        subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-n", *arguments],
                       cwd=destination, check=True, timeout=35)

    raw = ["-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", f"{width}x{height}",
           "-framerate", "2", "-i", "expected.i420", "-an", "-threads", "1"]
    colour = ["-colorspace", "smpte170m", "-color_primaries", "smpte170m", "-color_trc", "smpte170m"]
    encode(raw + ["-c:v", "libx264", "-profile:v", "baseline", "-crf", "16", "-bf", "0",
                  "-x264-params", "aud=1:repeat-headers=1:keyint=12", *colour, "-movflags", "+faststart", "h264.mp4"])
    encode(raw + ["-c:v", "libx265", "-profile:v", "main", "-x265-params",
                  "log-level=error:pools=none:frame-threads=1:bframes=0:keyint=12", *colour, "-tag:v", "hvc1",
                  "-movflags", "+faststart", "hevc.mp4"])
    encode(raw + ["-c:v", "libvpx-vp9", "-lossless", "1", "-row-mt", "0", "-lag-in-frames", "0",
                  *colour, "-fflags", "+bitexact", "vp9.webm"])
    for name, ext, bsf in (("h264.mp4", "h264", "h264_mp4toannexb"), ("hevc.mp4", "hevc", "hevc_mp4toannexb"),
                           ("vp9.webm", "vp9", None)):
        encoded = ["-i", name, "-map", "0:v:0", "-c:v", "copy"]
        if bsf:
            encoded += ["-bsf:v", bsf]
        encode(encoded + ["-f", "image2", f"au-%02d.{ext}"])
        assert len(list(destination.glob("au-*." + ext))) == FRAMES


if __name__ == "__main__":
    main()
