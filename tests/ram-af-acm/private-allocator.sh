# Source from the RAM service. Bind the alias exclusively into its measurement unit.
with_private_allocator() (
    set -euo pipefail
    local node=/dev/udmabuf sys=/sys/class/misc/udmabuf dir major minor numbers original
    [[ $EUID == 0 && -c $node && ! -L $node && -r $sys/dev && $(findmnt -nro FSTYPE -T /dev) == devtmpfs ]] || exit 1
    IFS=: read -r major minor < "$sys/dev"
    [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ && $sys -ef /sys/dev/char/$major:$minor ]] || exit 1
    printf -v numbers '%x:%x' "$major" "$minor"
    [[ $(stat -c %t:%T "$node") == "$numbers" ]] || exit 1
    original=$(stat -c %i:%u:%g:%a:%t:%T "$node")
    dir=$(mktemp -d /dev/y700-af-dma.XXXXXXXX) || exit 1
    cleanup_allocator() {
        local rc=$?
        rm -f -- "$dir/udmabuf" && rmdir -- "$dir" || exit 1
        [[ $(stat -c %i:%u:%g:%a:%t:%T "$node") == "$original" ]] || exit 1
        echo 'AF_ALLOCATOR cleanup=1 original_unchanged=1'
        exit "$rc"
    }
    trap cleanup_allocator EXIT
    [[ $(stat -c %u:%a "$dir") == 0:700 ]] || exit 1
    mknod -m 0600 "$dir/udmabuf" c "$major" "$minor" || exit 1
    chown y700 "$dir/udmabuf" || exit 1
    [[ $(stat -c %u:%a:%t:%T "$dir/udmabuf") == "$(id -u y700):600:$numbers" ]] || exit 1
    local rc=0
    Y700_AF_PRIVATE_NODE="$dir/udmabuf" "$@" || rc=$?
    exit "$rc"
)
