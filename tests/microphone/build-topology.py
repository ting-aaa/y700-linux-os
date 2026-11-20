#!/usr/bin/env python3
"""Compile the isolated TB320FC TX3 candidate and compare its ALSA topology ABI."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import struct
import subprocess

BASE_M4 = "113c32aa27d43bfabb7757a585435f550bf9331250e0a7827e72b8510d11f24f"
BASE_TPLG = "bfb28e0af200bdc000e7d03af30e11d191200a8620a4179a6afe2d5c8ef26d63"
HEADER = struct.Struct("<9I")  # Linux uapi/sound/asoc.h, snd_soc_tplg_hdr


def require(condition, detail):
    if not condition:
        raise SystemExit(detail)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_topology(name, inputs, library, out):
    conf = out / (name + ".conf")
    binary = out / (name + ".tplg")
    decoded = out / (name + ".decoded.conf")
    with conf.open("wb") as stream:
        subprocess.run(["m4", "-I", library, *inputs], check=True, stdout=stream)
    result = subprocess.run(["alsatplg", "-c", conf, "-o", binary], check=True,
                            capture_output=True, text=True)
    # alsatplg resolves internal widgets. The machine driver supplies these two DAIs.
    expected = ["undefined sink widget/stream 'Primary MI2S Playback'"]
    if name == "tx3":
        expected.append("undefined source widget/stream 'TX_CODEC_DMA_TX_3 Capture'")
    lines = result.stderr.splitlines()
    require(len(lines) == len(expected) and
            all(any(line.endswith(text) for line in lines) for text in expected),
            f"{name}: unexpected compiler diagnostics: {lines}")
    subprocess.run(["alsatplg", "-d", binary, "-o", decoded], check=True)
    print(f"{name}_sha256={sha256(binary)}")
    return binary, decoded.read_text()


def blocks(path):
    data = path.read_bytes()
    offset = 0
    result = {}
    while offset < len(data):
        magic, abi, _, kind, size, _, length, index, count = HEADER.unpack_from(data, offset)
        require((magic, abi, size) == (0x41536F43, 5, HEADER.size), "unknown topology header")
        start = offset + size
        offset = start + length
        key = kind, index
        require(offset <= len(data) and key not in result, "invalid or duplicate block")
        result[key] = count, data[start:offset]
    return result


def verify(base, candidate, decoded):
    require(sha256(base) == BASE_TPLG, "rebuilt base differs from the physical board")
    original, new = blocks(base), blocks(candidate)
    # Existing playback objects remain byte-exact in their original indexed blocks.
    # The manifest holds aggregate counts. Shared widget and route blocks gain 7 objects.
    require(new.keys() - original.keys() == {(5, 2), (7, 2), (4, 2)}, "new block identities")
    for key, (count, payload) in original.items():
        ncount, npayload = new[key]
        if key == (8, 0):
            continue
        if key in {(4, 1), (5, 1)}:
            require(ncount == count + 7 and npayload.startswith(payload), f"changed {key}")
        else:
            require((ncount, npayload) == (count, payload), f"changed {key}")
    pcm = re.search(r"'MultiMedia3 Capture' \{\s+formats 'S16_LE'\s+rate_min 48000"
                    r"\s+rate_max 48000\s+channels_min 2\s+channels_max 2\s+}", decoded)
    require(pcm and "pcm.capture.capabilities 'MultiMedia3 Capture'" in decoded,
            "missing native stereo PCM")
    ep = re.search(r"'device120\.codec_dma_tx1:tuple0' \{(.*?)\n\t}", decoded, re.S)
    require(ep is not None, "missing AudioReach codec DMA endpoint")
    words = {int(k): int(v) for k, v in re.findall(r"token(\d+) (\d+)", ep.group(1))}
    # Codec DMA source module, hardware interface RXTX/TX3, fixed-point samples.
    for token, value in {200: 0x07001024, 251: 1, 250: 4, 253: 1}.items():
        require(words.get(token) == value, f"unexpected codec DMA endpoint token {token}")
    nodes = ("TX_CODEC_DMA_TX_3 Capture", "device120.codec_dma_tx1", "device120.logger1",
             "MultiMedia3 Mixer", "stream2.logger1", "stream2.mfc1", "stream2.pcm_converter1",
             "stream2.pcm_encoder1", "stream2.rdsh_ep1")
    for source, sink in zip(nodes, nodes[1:]):
        control = "TX_CODEC_DMA_TX_3" if sink == "MultiMedia3 Mixer" else ""
        require(f"'{sink}, {control}, {source}'" in decoded, f"missing edge {source} -> {sink}")
    print("existing_playback=two_original_pcm_and_all_playback_objects_byte_exact")
    print("new_capture=MultiMedia3 S16_LE 48000 2ch RXTX/TX3 codec_dma_to_shared_memory")
    print("external_dais=Primary MI2S Playback | TX_CODEC_DMA_TX_3 Capture")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_m4", type=Path, help="unchanged Asphalt Lenovo-Y700.m4")
    parser.add_argument("library", type=Path, help="pinned linux-msm/audioreach-topology")
    parser.add_argument("out", type=Path, help="new directory for compiled and decoded files")
    args = parser.parse_args()
    require(sha256(args.base_m4) == BASE_M4, "unexpected board topology source")
    os.environ["LC_ALL"] = "C"
    args.out.mkdir(parents=True, exist_ok=False)
    base, _ = compile_topology("stock", [args.base_m4], args.library, args.out)
    extra = Path(__file__).with_name("tx3.m4")
    candidate, decoded = compile_topology("tx3", [args.base_m4, extra], args.library, args.out)
    verify(base, candidate, decoded)


if __name__ == "__main__":
    main()
