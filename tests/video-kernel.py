"""Check the two sealed board descriptions and VPU firmware without opening a device."""

import argparse
import gzip
import hashlib
import struct
import subprocess
from pathlib import Path


def require(condition, description):
    if not condition:
        raise SystemExit(f"FAIL {description}")


def image_identity(path, expected):
    require(path.is_file(), f"expected ordinary image file {path}")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    require(digest == expected, f"unexpected {path.name} sha256={digest}")
    print(f"{path.name} sha256={digest}", flush=True)


def property_value(tree, node, key, kind="x"):
    return subprocess.check_output(["fdtget", "-t", kind, tree, node, key], text=True).strip()


def check_kernel(image):
    data = image.read_bytes()
    marker = b"IKCFG_ST"
    start = data.index(marker + b"\x1f\x8b\x08") + len(marker)
    end = data.index(b"IKCFG_ED", start)
    config = set(gzip.decompress(data[start:end]).decode().splitlines())
    for key in ("VIDEO_QCOM_IRIS", "QCOM_SCM", "QCOM_MDT_LOADER", "ARM_SMMU_QCOM"):
        require(f"CONFIG_{key}=y" in config, f"built-in {key}")
    print("kernel built-in VIDEO_QCOM_IRIS QCOM_SCM QCOM_MDT_LOADER ARM_SMMU_QCOM")


def check_tree(tree, android):
    if android:
        codec = "/soc/qcom,vidc@aa00000"
        region = "/reserved-memory/video_region@85700000"
        secure = codec + "/secure_non_pixel_cb"
        require(property_value(tree, codec, "vidc,firmware-name", "s") == "vpu20_4v", "stock firmware name")
        require("qcom,msm-vidc-iris2" in property_value(tree, codec, "compatible", "s").split(), "stock binding")
        require(property_value(tree, codec, "pas-id") == "9", "stock PAS")
        streams = [property_value(tree, codec + "/" + cb, "iommus").split()
                   for cb in ("non_secure_cb", "non_secure_pixel_cb")]
    else:
        codec = "/soc@0/video-codec@aa00000"
        region = "/reserved-memory/memory@85700000"
        secure = codec + "/secure-arp"
        require(property_value(tree, codec, "firmware-name", "s") == FIRMWARE, "Linux firmware name")
        require(property_value(tree, codec, "compatible", "s") == "qcom,sm8450-venus", "Linux binding")
        require(property_value(tree, secure, "compatible", "s") == "qcom,sm8450-iris-secure-arp", "secure binding")
        cells = property_value(tree, codec, "iommus").split()
        streams = [cells[:3], cells[3:]]

    require(property_value(tree, codec, "status", "s") == "okay", "codec status")
    expected_reg = "aa00000 f0000" if android else "0 aa00000 0 f0000"
    require(property_value(tree, codec, "reg") == expected_reg, "codec MMIO")
    require(property_value(tree, codec, "interrupts") == "0 ae 4", "codec interrupt")
    require(property_value(tree, codec, "memory-region") == property_value(tree, region, "phandle"), "memory link")
    require(property_value(tree, region, "reg") == "0 85700000 0 700000", "memory range")
    require(property_value(tree, region, "no-map") == "", "no-map")
    require(property_value(tree, secure, "qcom,iommu-vmid") == "b", "secure VMID")
    streams.append(property_value(tree, secure, "iommus").split())
    smmu = streams[0][0]
    require(streams == [[smmu, sid, "400"] for sid in ("2180", "2187", "2184")], "SMMU IDs and masks")
    print(f"{tree.name} mmio=0xaa00000 spi=174 reserved=0x85700000+0x700000 "
          "nonsecure_sid=2180,2187 secure_sid=2184 vmid=11")


def read_firmware(image, path):
    return subprocess.check_output(["debugfs", "-R", f"cat {path}", image], stderr=subprocess.DEVNULL)


def verify_segments(blob):
    require(blob[:6] == b"\x7fELF\x01\x01", "little-endian ELF32")
    phoff, = struct.unpack_from("<I", blob, 28)
    entry_size, count = struct.unpack_from("<HH", blob, 42)
    require(entry_size == 32 and phoff + entry_size * count <= len(blob), "program header table")
    ranges = []
    for index in range(count):
        kind, offset, _, addr, filesz, memsz, flags, _ = struct.unpack_from("<8I", blob, phoff + index * entry_size)
        if kind != 1 or ((flags >> 24) & 7) == 2 or memsz == 0:
            continue
        require(filesz <= memsz and offset + filesz <= len(blob), f"contained firmware segment {index}")
        ranges.append((addr, (addr + memsz + 4095) & ~4095))
    require(ranges, "loadable firmware segments")
    span = max(end for _, end in ranges) - min(start for start, _ in ranges)
    require(span == 0x700000, "aligned MDT span must match the board reservation")
    require(b"QC_IMAGE_VERSION_STRING=video-firmware.2.4-" in blob, "firmware generation marker")
    print(f"ELF32 headers={count} loadable={len(ranges)} MDT_span=0x{span:x} firmware=video-firmware.2.4")


FIRMWARE = "qcom/sm8475/lenovo/tb320fc/vpu20_4v.mbn"
FIRMWARE_SHA = "d96846cf4b000142e1e3f5bb03a54368bb9a45cb1804d4f798990dc946a210fb"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("kernel_efi", "board_dtb", "android_runtime_dtb", "vendor_ext4", "root_ext4"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    image_identity(args.kernel_efi, "4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1")
    check_kernel(args.kernel_efi)
    image_identity(args.board_dtb, "1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d")
    image_identity(args.android_runtime_dtb, "bda4b80b9cb73e1b001cf22666890ad0139f0246e08a86d432a190d8e06ba4c6")
    check_tree(args.board_dtb, android=False)
    check_tree(args.android_runtime_dtb, android=True)
    image_identity(args.vendor_ext4, "589dbd163ae9f9d8f8e2f806640e4196cb3b090ab24de14a10217a15487b12ef")
    image_identity(args.root_ext4, "2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511")
    stock = read_firmware(args.vendor_ext4, "/firmware/vpu20_4v.mbn")
    packaged = read_firmware(args.root_ext4, "/usr/lib/firmware/" + FIRMWARE)
    require(stock == packaged and len(stock) == 2024040, "CN350 and Debian monolithic firmware bytes")
    require(hashlib.sha256(stock).hexdigest() == FIRMWARE_SHA, "firmware digest")
    verify_segments(packaged)
    print(f"PASS firmware_bytes={len(stock)} sha256={FIRMWARE_SHA}")


if __name__ == "__main__":
    main()
