# /// script
# requires-python = ">=3.11"
# dependencies = ["av==19.0.2", "imageio-ffmpeg==0.6.0"]
# ///
"""Build or independently check the three indexed 16-second Parole seek fixtures."""
import argparse
from fractions import Fraction
import hashlib
from pathlib import Path
import subprocess
import tempfile

import av
import imageio_ffmpeg


FPS = 12
SECONDS = 16
GOP = 2 * FPS
# BT.709 limited-range Y, Cb, Cr for full-intensity RGB primaries and yellow.
COLORS = (("red", (63, 102, 240)), ("green", (173, 42, 26)),
          ("blue", (32, 240, 118)), ("yellow", (219, 16, 138)))
ENCODERS = {
    "h264.mp4": ["-c:v", "libx264", "-preset", "veryfast", "-x264-params",
                 "threads=1:scenecut=0:open-gop=0", "-movflags", "+faststart"],
    "hevc.mp4": ["-c:v", "libx265", "-preset", "veryfast", "-x265-params",
                 "pools=none:frame-threads=1:scenecut=0:open-gop=0:log-level=error",
                 "-tag:v", "hvc1", "-movflags", "+faststart"],
    "vp9.webm": ["-c:v", "libvpx-vp9", "-deadline", "good", "-cpu-used", "5",
                 "-lag-in-frames", "0", "-auto-alt-ref", "0",
                 "-cluster_time_limit", "1000", "-cues_to_front", "1"],
}


def encode(path):
    samples = bytearray()
    for _, (y, u, v) in COLORS:
        samples.extend(bytes((y, y, y, y, u, v)) * (4 * FPS))
    subprocess.run([
        imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-v", "error", "-nostdin", "-n",
        "-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", "2x2",
        "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-framerate", str(FPS), "-i", "pipe:0", "-filter_threads", "1",
        "-vf", "scale=1920:1080:flags=neighbor",
        "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709",
        "-color_trc", "bt709", "-threads", "1", "-g", str(GOP), "-keyint_min", str(GOP),
        "-force_key_frames", "expr:gte(t,n_forced*2)", *ENCODERS[path.name],
        "-fflags", "+bitexact", str(path),
    ], input=samples, check=True, timeout=180)


def check_frame(frame, index):
    expected_pts = Fraction(index, FPS)
    # The WebM muxer timestamps these 12 fps frames in whole milliseconds.
    if frame.pts is None or abs(frame.pts * frame.time_base - expected_pts) > Fraction(1, 2000):
        raise ValueError(f"frame {index} has unexpected PTS {frame.pts} at {frame.time_base}")
    if (frame.width, frame.height, frame.format.name) != (1920, 1080, "yuv420p"):
        raise ValueError(f"unexpected decoded format at frame {index}")
    color, expected = COLORS[index // (4 * FPS)]
    for plane, value in zip(frame.planes, expected, strict=True):
        data = memoryview(plane)
        for dx, dy in ((1, 1), (3, 1), (2, 2), (1, 3), (3, 3)):
            observed = data[(plane.height * dy // 4) * plane.line_size + plane.width * dx // 4]
            if abs(observed - value) > 3:
                raise ValueError(f"frame {index} {color} expected {expected}, got plane sample {observed}")


def verify(path):
    with av.open(str(path)) as source:
        if len(source.streams) != 1 or source.duration != SECONDS * av.time_base:
            raise ValueError(f"{path.name} streams={len(source.streams)} duration_us={source.duration}")
        stream, = source.streams.video
        if stream.codec_context.name != path.stem or stream.average_rate != FPS:
            raise ValueError(f"unexpected codec or frame rate in {path.name}")
        stream.codec_context.thread_count = 1
        # Seek before any sequential decode, so it cannot populate a missing index.
        for second in (10, 2, 14, 6):
            target = Fraction(2 * second + 1, 2)
            source.seek(int(target / stream.time_base), stream=stream, backward=True, any_frame=False)
            indexed = {entry.pos for entry in stream.index_entries if entry.is_keyframe}
            if len(indexed) != SECONDS // 2:
                raise ValueError(f"{path.name} index has {len(indexed)} distinct keyframe offsets")
            decoded = source.decode(stream)
            for index in range(second * FPS, int(target * FPS) + 1):
                frame = next(decoded)
                if index == second * FPS and not frame.key_frame:
                    raise ValueError(f"{path.name} seek to {target}s missed the preceding keyframe")
                check_frame(frame, index)
        source.seek(0, stream=stream)
        keyframes = []
        frames = 0
        for index, frame in enumerate(source.decode(stream)):
            check_frame(frame, index)
            if frame.key_frame:
                keyframes.append(index)
            frames += 1
        if frames != SECONDS * FPS or keyframes != list(range(0, frames, GOP)):
            raise ValueError(f"{path.name} had {frames} frames and keyframes at {keyframes}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"{path.name} bytes={path.stat().st_size} frames={frames} fps={FPS} duration={SECONDS}s "
          f"keyframes={len(keyframes)} seek=10.5:blue,2.5:red,14.5:yellow,6.5:green sha256={digest}",
          flush=True)
    return f"{digest}  {path.name}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--verify-only", action="store_true", help="recheck existing files and SHA256SUMS")
    args = parser.parse_args()
    if args.verify_only:
        manifest = "".join(verify(args.output / name) for name in ENCODERS)
        if (args.output / "SHA256SUMS").read_text(encoding="ascii") != manifest:
            raise ValueError("SHA256SUMS does not match the verified media")
        return
    if args.output.exists():
        parser.error("choose a new output directory or use --verify-only")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as work:
        prepared = Path(work) / "clips"
        prepared.mkdir()
        for name in ENCODERS:
            encode(prepared / name)
        manifest = "".join(verify(prepared / name) for name in ENCODERS)
        (prepared / "SHA256SUMS").write_text(manifest, encoding="ascii", newline="\n")
        prepared.rename(args.output)


if __name__ == "__main__":
    main()
