# Check one file-load operation on the fixture's initial ARM64 kernel.
# This kernel caps ITS at 16 LPI bits and rounds both table types to 64 KiB.
function hex(s,   n, i, digit) {
    sub(/^(@|mem=|memsz=)?0x/, "", s)
    sub(/^0+/, "", s)
    if (length(s) > 13 || s !~ /^[0-9a-fA-F]+$/) return -1
    n = 0
    for (i = 1; i <= length(s); i++) {
        digit = index("0123456789abcdef", tolower(substr(s,i,1))) - 1
        n = n * 16 + digit
    }
    return n
}
/GICv3: using LPI property table @0x/ {
    table["property"] = hex($NF)
    properties++
}
/GICv3: CPU[0-9]+: using (allocated|reserved) LPI pending table @0x/ {
    cpu = $0
    sub(/^.*GICv3: CPU/, "", cpu)
    sub(/:.*/, "", cpu)
    if (cpu + 0 >= cpus || cpu in pending) bad = 1
    pending[cpu] = 1
    table["cpu" cpu] = hex($NF)
}
/kexec_file: nr_segments = / {
    loads++
    declared = $NF
}
/kexec_file: segment\[[0-9]+\]: / {
    id = $0
    sub(/^.*kexec_file: segment\[/, "", id)
    sub(/\].*/, "", id)
    if (id in start || $(NF-1) !~ /^mem=0x/ || $NF !~ /^memsz=0x/) bad = 1
    start[id] = hex($(NF-1))
    size[id] = hex($NF)
}
END {
    if (cpus < 1 || properties != 1 || length(pending) != cpus || loads != 1 ||
        declared !~ /^[0-9]+$/ || declared < 3 || declared > 16 || length(start) != declared) bad = 1
    for (t in table) {
        key = sprintf("%.0f", table[t])
        if (table[t] <= 0 || table[t] % 65536 || key in addresses) bad = 1
        addresses[key] = 1
    }
    if (bad) {
        print "RAM_QA_KEXEC_LAYOUT_REJECT incomplete table or segment inventory"
        exit 1
    }
    for (i = 0; i < declared; i++) {
        if (!(i in start) || start[i] <= 0 || size[i] <= 0) {
            print "RAM_QA_KEXEC_LAYOUT_REJECT invalid segment"
            exit 1
        }
        for (t in table) {
            if (start[i] < table[t] + 65536 && table[t] < start[i] + size[i]) {
                print "RAM_QA_KEXEC_LAYOUT_REJECT overlap segment=" i " table=" t
                exit 1
            }
        }
    }
    print "RAM_QA_KEXEC_LAYOUT_OK segments=" declared " tables=" length(table)
}
