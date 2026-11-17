"""Build the CN350 U-Boot candidate offline from the verified ROW payload and tablet FDT."""
import copy
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

out = Path(__file__).resolve().parent
debian = out.parent
linux = debian.parent
upstream = linux / "asphalt-upstream"
sys.dont_write_bytecode = True
sys.path.insert(0, str(upstream / "pkgs/mobile-device"))
from boot_image import fdt_tree, inspect_image


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked(output, *args):
    subprocess.run(args, check=True, stdout=output)


def words(value):
    return [n[0] for n in struct.iter_unpack(">I", value)]


def reservations(tree):
    rows = []
    for name, node in tree["nodes"]["reserved-memory"]["nodes"].items():
        props = node["props"]
        if "reg" not in props or props.get("status", b"okay\0") not in (b"ok\0", b"okay\0"):
            continue
        for addr, size in struct.iter_unpack(">QQ", props["reg"]):
            rows.append((addr, addr + size, "no-map" in props, name))
    return rows


if not __debug__:
    raise RuntimeError("Run without Python optimization; input and output checks are required")

uefi = debian / "images/uefi"
source = uefi / "asphalt-u-boot.img"
firmware = Path("/home/builder/y700-asphalt-debian/efi/board-src")
reference = linux / "vendor-build-20261025/readonly-fdt-v4-capture-run01/capture01/runtime-fdt.bin"
selected = linux.parent / "linux-review-20261016/local/stock350-vendor_boot-dtb-2.dtb"
mk = linux / "tools/mkbootimg"
revision = subprocess.check_output(["git", "-C", upstream, "rev-parse", "HEAD"], text=True).strip()
assert revision == "8dcb481fc2ce91794fd294630e06f15a52ec7513"
manifest = {}
for line in (uefi / "SHA256SUMS").read_text().splitlines():
    expected, filename = line.split()
    with (uefi / filename).open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == expected, filename
    manifest[filename] = expected
assert len(manifest) == 4 and manifest[source.name] == "b5e0749bd086f18a40123e784857ee73f95a15835119192e0675a8968839a84a"
live_blob = reference.read_bytes()
assert digest(live_blob) == "132a3f0d890c2a8964adde3c491173b4f6bc5cb0a17017ee4127a673a63a52ba"
assert digest(selected.read_bytes()) == "600e2d1ea4b95ea253adc41544578f16ee37b1b63de764792266f88cea4c8c85"
live, base = fdt_tree(live_blob), fdt_tree(selected.read_bytes())
rp = live["props"]
memory = live["nodes"]["memory"]["props"]
assert rp["region_country"] == base["props"]["region_country"] == b"PRC\0"
assert words(rp["qcom,board-id"]) == [65544, 0]
assert live["props"]["#address-cells"] == live["props"]["#size-cells"] == struct.pack(">I", 2)
assert memory["device_type"] == b"memory\0"
banks = list(struct.iter_unpack(">QQ", memory["reg"]))
assert len(banks) == 5 and sum(size for _, size in banks) == 16989028352
dst = out / "asphalt-prc-u-boot.img"

with tempfile.TemporaryDirectory(prefix="asphalt-prc-uboot-") as tmp:
    tmp = Path(tmp)
    unpack = [sys.executable, str(mk / "unpack_bootimg.py")]
    args = subprocess.check_output([*unpack, "--boot_img", source, "--out", tmp / "in",
                                    "--format=mkbootimg", "-0"]).decode().removesuffix("\0").split("\0")
    old_dtb = (tmp / "in/dtb").read_bytes()
    assert old_dtb == (firmware / "u-boot.dtb").read_bytes()
    old = fdt_tree(old_dtb)
    assert old["props"]["region_country"] == b"ROW\0"
    assert old["props"]["qcom,board-id"] == rp["qcom,board-id"]
    assert old["props"]["qcom,msm-id"] == base["props"]["qcom,msm-id"] == rp["qcom,msm-id"][:8]
    assert old["props"]["compatible"] == b"lenovo,asphalt\0qcom,sm8475\0"
    assert old["nodes"]["memory@a0000000"]["props"] == {
        "device_type": b"memory\0", "reg": struct.pack(">QQ", 0xa0000000, 0)
    }
    dtb = tmp / "in/dtb"
    checked(None, "fdtput", "-t", "s", dtb, "/", "region_country", "PRC")
    checked(None, "fdtput", "-r", dtb, "/memory@a0000000")
    checked(None, "fdtput", "-c", dtb, "/memory")
    checked(None, "fdtput", "-t", "s", dtb, "/memory", "device_type", "memory")
    checked(None, "fdtput", "-t", "x", dtb, "/memory", "reg", *(f"{n:x}" for n in words(memory["reg"])))
    # fdtput packs its result tightly. Preserve the work space in the delivered
    # ROW blob for ABL's runtime additions (memory, /chosen, framebuffer).
    old_header = struct.unpack_from(">10I", old_dtb)
    old_used = max(old_header[2] + old_header[9], old_header[3] + old_header[8])
    headroom = old_dtb[old_used:]
    assert len(headroom) >= 4096 and not any(headroom)
    updated = bytearray(dtb.read_bytes())
    new_header = struct.unpack_from(">10I", updated)
    assert max(new_header[2] + new_header[9], new_header[3] + new_header[8]) == len(updated)
    assert old_dtb[old_header[4]:old_header[2]] == updated[new_header[4]:new_header[2]]
    updated.extend(headroom)
    struct.pack_into(">I", updated, 4, len(updated))
    dtb.write_bytes(updated)
    expected = copy.deepcopy(old)
    expected["props"]["region_country"] = rp["region_country"]
    expected["nodes"]["memory"] = expected["nodes"].pop("memory@a0000000")
    expected["nodes"]["memory"]["props"]["reg"] = memory["reg"]
    packaged = fdt_tree(dtb.read_bytes())
    assert packaged == expected  # includes all UFS/USB/power nodes, /chosen, reserves and phandles
    assert len(reservations(live)) == 38
    covered = []
    for a, e, no_map, name in reservations(live):
        covering = [n for start, end, _, n in reservations(packaged) if start <= a and end >= e]
        assert covering, name
        covered.append({"stock": name, "start": hex(a), "end": hex(e), "covering_nodes": covering})
    assert packaged["nodes"]["reserved-memory"]["nodes"]["splash_region"]["props"]["reg"] == live["nodes"]["reserved-memory"]["nodes"]["splash_region"]["props"]["reg"]
    program = (firmware / "u-boot-nodtb.bin").read_bytes()
    payload = (tmp / "in/kernel").read_bytes()
    symbols = subprocess.check_output(["aarch64-linux-gnu-nm", firmware / "u-boot"], text=True)
    addresses = {cols[2]: int(cols[0], 16) for line in symbols.splitlines()
                 if len(cols := line.split()) == 3 and cols[2] in ("_end", "__image_copy_start")}
    fallback = addresses["_end"] - addresses["__image_copy_start"]
    assert fallback == len(program) == 1432232 and len(payload) == 41289792
    assert payload == program.ljust(len(payload), b"\0")
    assert not any(payload[fallback:])
    assert (firmware / "u-boot-dtb.bin").read_bytes() == program + old_dtb
    image = tmp / "asphalt-prc-u-boot.img"
    checked(None, sys.executable, mk / "mkbootimg.py", *args, "-o", image)
    checked(subprocess.DEVNULL, *unpack, "--boot_img", image, "--out", tmp / "check")
    for part in ("kernel", "ramdisk", "dtb"):
        assert (tmp / "in" / part).read_bytes() == (tmp / "check" / part).read_bytes()
    validation = subprocess.check_output([sys.executable, debian / "verify-dtb.py", tmp / "check/dtb"], text=True).strip()
    assert inspect_image(image.read_bytes()) == ("asphalt", False)
    new = image.read_bytes()
    original = source.read_bytes()
    assert len(new) <= 100663296
    changed = [i for i,(x,y) in enumerate(zip(original[:4096],new[:4096])) if x != y]
    assert all(576 <= i < 608 or 1648 <= i < 1652 for i in changed)
    kernel_digest = digest(payload)
    receipt = {
        "source_commit": revision, "original_delivery_rehashed": manifest,
        "runtime_fdt_sha256": digest(live_blob), "selected_stock_base_sha256": digest(selected.read_bytes()),
        "original_external_dtb_sha256": digest(old_dtb), "prc_external_dtb_sha256": digest(dtb.read_bytes()),
        "preserved_runtime_fdt_headroom_bytes": len(headroom),
        "country": "PRC", "board_id": words(rp["qcom,board-id"]), "selected_base_msm_id": words(base["props"]["qcom,msm-id"]),
        "memory_banks_start_bytes": [[hex(a),s] for a,s in banks],
        "unchanged_board_tree_except_country_and_memory": True, "stock_fixed_ranges": covered,
        "unchanged_splash": True, "nodtb_code_bytes": len(program), "nodtb_code_sha256": digest(program),
        "padded_payload_sha256": kernel_digest, "padded_payload_bytes": len(payload),
        "internal_fdt_offset": fallback, "internal_fdt_present": False,
        "raw_ramdisk_sha256": digest((tmp / "check/ramdisk").read_bytes()),
        "changed_header_offsets": changed, "static_dtb_validation": validation,
        "upstream_inspection": ["asphalt","boot"], "sha256": digest(new), "bytes": len(new),
        "physical_boot_verified": False
    }
    shutil.copyfile(image, dst)
    shutil.copyfile(dtb, out / "asphalt-prc-u-boot.dtb")
    (out / "validation.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    (out / "SHA256SUMS").write_text(f"{digest(new)}  {dst.name}\n{digest(dtb.read_bytes())}  asphalt-prc-u-boot.dtb\n")
    print(validation, f"{dst.name} {len(new)} bytes {digest(new)}", sep="\n")
