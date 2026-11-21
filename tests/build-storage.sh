#!/usr/bin/env bash
# Linux scratch only; pass --mounts as root to include two real mount/loop controls.
set -euo pipefail
if [[ ${1:-} == --mounts && ${Y700_TEST_PRIVATE:-} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_TEST_PRIVATE=1 bash "$0" "$@"
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
guard=$repo/scripts/build-storage-guard.sh
store_cli=("${UV_BIN:-uv}" run --no-project --offline --python /usr/bin/python3 python "$repo/scripts/build-storage.py")
scratch=$(mktemp -d /var/tmp/y700-storage-test.XXXXXXXX)
loop=
test_mount=
cleanup() {
    if [[ -n $loop ]]; then losetup -d "$loop"; fi
    if [[ -n $test_mount ]] && mountpoint -q "$test_mount"; then umount "$test_mount"; fi
    rm -rf --one-file-system -- "$scratch"
}
trap cleanup EXIT
fail() { echo "unexpected success: $1" >&2; exit 1; }
cd "$scratch"
export Y700_STORAGE_FLOOR_MIB=1 Y700_STORAGE_HOST_FLOOR_MIB=1
bash "$guard" archive "$scratch" check 1
if Y700_STORAGE_FLOOR_MIB=999999999 bash "$guard" archive . check 1; then fail capacity; fi
if grep -iq microsoft /proc/sys/kernel/osrelease; then
    if Y700_STORAGE_HOST_FLOOR_MIB=999999999 bash "$guard" archive . check 1; then fail wsl_capacity; fi
    if Y700_WSL_HOST_VOLUME="$scratch" bash "$guard" archive . check 1; then fail missing_host; fi
fi
if [[ ${1:-} == --mounts ]]; then
    mkdir -p i/base/{etc/y700,usr/share/alsa/ucm2}
    touch i/base/.y700-base-packages-complete i/base/etc/y700/base-configured
    printf 'fixture' >i/base/usr/share/alsa/ucm2/ucm.conf
    truncate -s 6G i/root.ext4; truncate -s 1G i/linux-boot.fat; truncate -s 41406464 i/boot
    zero=$(printf '0%.0s' {1..64})
    deny() {
        local script=$1
        shift
        if Y700_STORAGE_FLOOR_MIB=999999999 bash "$repo/scripts/$script" "$@" >entry.log 2>&1; then fail "$script"; fi
        grep -q '^Insufficient free space' entry.log || { cat entry.log >&2; exit 1; }
        [[ ! -e result ]]; echo "ENTRY_PREFLIGHT_PASS $script output_created=0"
    }
    deny build-board-image.sh i/base i i/boot result
    deny update-sealed-root.sh tablet-desktop i/root.ext4 i result
    deny build-camera-esp.sh i/linux-boot.fat i result
    deny package-board-image.sh dev12.12 i/root.ext4 "$zero" i/linux-boot.fat "$zero" i/boot result
    deny build-ram-trial.sh --dev12.12 i result
    deny build-ram-receiver.sh i i result
    deny build-test-card.sh i result
    deny export-board-image.sh i result
fi
(
    source "$guard" archive "$scratch" reserve 1
    bash -c 'source "$1" archive "$2" reserve 1' sh "$guard" "$scratch"
    if env -u Y700_STORAGE_FD bash "$guard" archive . reserve 1; then fail concurrent_guard; fi
)
store=$scratch/store
run() { "${store_cli[@]}" "$1" "$store" "${@:2}"; }
run init --count 2 --single 2048 --total 2400
if run init; then fail overwrite_store; fi
mkdir foreign
if "${store_cli[@]}" status "$scratch/foreign"; then fail unmanaged; fi
run run a sh -c 'printf fixture >raw; printf fixture >same; printf keep >unique; head -c 1800 /dev/urandom >large; head -c 900 /dev/urandom >extra; head -c 4096 /dev/urandom >oversize'
if run run b false; then fail child_status; fi
if run run interrupted sh -c 'tr "\0" " " <"/proc/$PPID/cmdline" | grep -Fq build-storage.py && kill -TERM "$PPID"'; then fail interrupted; fi
run status >states
grep -Fxq 'job=interrupted state=interrupted' states
touch "$store/jobs/b/work/from-failed"
run archive a raw
run archive a same
run archive a large
if run archive a extra; then fail count_limit; fi
run status | grep -Fq 'state=failed'
if run prune a unique; then fail unknown; fi
printf changed >"$store/jobs/a/work/same"
if run prune a same; then fail changed; fi
test -s "$store/jobs/a/work/same"
( exec 7<"$store/jobs/a/work/raw"; if run prune a raw; then fail open_input; fi )
run prune a raw
test ! -e "$store/jobs/a/work/raw"
digest=$(printf fixture | sha256sum | cut -d' ' -f1)
target=$store/objects/$digest.zst
cp "$target" external.zst
if run retire "$digest" "$target"; then fail last_copy; fi
if run retire "$digest" /dev/null; then fail external_type; fi
run retire "$digest" "$scratch/external.zst"
printf fixture | cmp - <(zstd -qdc external.zst)
if run archive a extra; then fail total_limit; fi
rm "$store/jobs/a/work/same"
digest=$(sha256sum "$store/jobs/a/work/large" | cut -d' ' -f1)
cp "$store/objects/$digest.zst" "$scratch/second.zst"
run retire "$digest" "$scratch/second.zst"
if run archive a oversize; then fail object_limit; fi
test "$(find "$store/objects" -mindepth 1 | wc -l)" = 0
ln -s "$scratch/external.zst" "$store/jobs/a/work/indirect"
if run archive a indirect; then fail symlink; fi
if run archive a ../../../external.zst; then fail escape; fi
run archive b from-failed
run prune b from-failed
empty=$(printf '' | sha256sum | cut -d' ' -f1)
cp "$store/objects/$empty.zst" "$scratch/empty.zst"
run retire "$empty" "$scratch/empty.zst"
mkfifo "$scratch/done"
run run busy sh -c 'printf used >active; touch "$1"; read -r _ <"$2"' worker "$scratch/ready" "$scratch/done" &
runner=$!
for _ in {1..150}; do [[ ! -f ready ]] || break; sleep .1; done
test -f ready
if run archive busy active; then fail busy_job; fi
echo complete >done
wait "$runner"
run archive busy active
if [[ ${1:-} == --mounts ]]; then
    work=$store/jobs/busy/work
    mkdir "$work/mount"
    test_mount=$work/mount
    mount -t tmpfs -o size=1M tmpfs "$test_mount"
    if run prune busy active; then fail mount; fi
    umount "$work/mount"
    truncate -s 16384 "$work/loop-image"
    run archive busy loop-image
    loop=$(losetup --find --show "$work/loop-image")
    if run prune busy loop-image; then losetup -d "$loop"; fail loop; fi
    losetup -d "$loop"
    loop=
    run prune busy loop-image
fi
run prune busy active
test -s "$store/jobs/a/work/unique"
run status
echo 'BUILD_STORAGE_PASS original_unknown_preserved=1 count_bytes_and_single_caps=1 active_and_failed_jobs=1'
