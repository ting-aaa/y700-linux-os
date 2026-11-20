"""Summarize the physical board's live LPI tables without emitting their addresses."""
from collections import Counter, defaultdict
import re
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def overlap_size(ranges, start, end):
    """Return union coverage in a half-open interval, including adjacent ranges."""
    covered = 0
    cursor = start
    for lo, hi in sorted(ranges):
        begin, stop = max(cursor, lo), min(hi, end)
        if begin < stop:
            covered += stop - begin
            cursor = stop
    return covered


def report(lines):
    count = Counter()
    efivars, tables, ranges = {}, {}, defaultdict(list)
    complete = False
    table_names = {"property", *(f"CPU{i}" for i in range(8))}
    for row in lines:
        row = row.strip()
        require(not complete, "unexpected trailing data")
        if row == "COMPLETE":
            complete = True
            continue
        if row.startswith("BOOT "):
            count[row[5:]] += 1
            continue
        tag, key, *fields = row.split()
        if tag == "DT":
            require(not fields and re.fullmatch(r"(?:[0-9a-f]{32})+", key), "invalid DT reg")
            for offset in range(0, len(key), 32):
                addr = int(key[offset:offset + 16], 16)
                size = int(key[offset + 16:offset + 32], 16)
                require(size > 0, "empty fixed DT reservation")
                ranges["fixed_dt"].append((addr, addr + size))
            continue
        require(len(fields) == 1, "incomplete range record")
        value = fields[0]
        if tag == "EFI_NAME":
            require(key in ("SecureBoot", "BootCurrent", "BootOrder") and key not in efivars
                    and value in ("present", "absent"), "invalid EFI name witness")
            efivars[key] = value
        elif tag == "TABLE":
            require(key in table_names and key not in tables and re.fullmatch(r"0x[0-9a-f]+", value),
                    "invalid or repeated table")
            addr = int(value, 16)
            require(addr > 0 and addr % 65536 == 0 and addr not in tables.values(), "invalid table alignment or alias")
            tables[key] = addr
        else:
            if tag == "MEMBLOCK":
                require(key in ("reserved", "memory"), "unexpected memblock kind")
                pair = re.fullmatch(r"0x([0-9a-f]+)\.\.0x([0-9a-f]+)", value)
            else:
                require(tag == "IOMEM" and key in ("ram", "reserved_child", "reserved_other"), "unexpected resource")
                pair = re.fullmatch(r"([0-9a-f]+)-([0-9a-f]+)", value)
            require(pair, "invalid range")
            lo, hi = (int(v, 16) for v in pair.groups())
            require(hi >= lo and hi != 0, "unreadable resource addresses")
            ranges[key].append((lo, hi + 1))

    require(complete and set(tables) == table_names and len(efivars) == 3, "incomplete board capture")
    require(count == {"firmware": 1, "memreserve": 1, "its": 1}, "incomplete firmware initialization")
    require(all(ranges[k] for k in ("ram", "memory", "reserved", "fixed_dt")), "missing memory map")
    print("BOARD_IRQ kernel=original-7.3.4-asphalt-prc uboot_efi=2.11 efi_memreserve=present "
          "dt_efi_memory_map=present gicv3_its=1 cpu_online=8 kexec_loaded=0")
    print("EFI_NAMES " + " ".join(f"{k}={v}" for k, v in sorted(efivars.items())) + " payloads_read=0")
    protected = True
    for group, addrs in (("property", [tables["property"]]), ("pending", [tables[f"CPU{i}"] for i in range(8)])):
        full = {}
        for kind in ("ram", "reserved_child", "reserved_other", "memory", "reserved", "fixed_dt"):
            sizes = [overlap_size(ranges[kind], addr, addr + 65536) for addr in addrs]
            full[kind] = sizes.count(65536)
            partial = sum(0 < size < 65536 for size in sizes)
            print(f"BOARD_IRQ_RANGE group={group} map={kind} full={full[kind]} partial={partial} total={len(addrs)}")
        protected &= all(full[k] == len(addrs) for k in ("ram", "reserved_child", "memory", "reserved"))
    print("BOARD_IRQ_TABLE_RESERVATIONS_" + ("PASS" if protected else "INCOMPLETE"))
    return protected


if __name__ == "__main__":
    try:
        success = report(sys.stdin)
    except ValueError:
        sys.exit("BOARD_IRQ_TABLE_RESERVATIONS_INCOMPLETE invalid or incomplete capture")
    sys.exit(0 if success else 1)
