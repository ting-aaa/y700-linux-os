#!/bin/bash
# Isolate a short Chromium run from the physical display, network and owner profile.
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
trap 'echo "CHROMIUM_CHECK_FAILED line=$LINENO" >&2' ERR

if [[ ${1:-} != --worker ]]; then
    [[ $EUID == 0 && $# == 1 && ( $1 == product || $1 == vulkan ) ]] || {
        echo 'Usage as root: UV_BIN=/path/to/uv bash chromium-gpu-board.sh product|vulkan' >&2
        exit 2
    }
    here=$(cd "$(dirname "$0")" && pwd)
    uv=$(realpath -e "${UV_BIN:-$(command -v uv)}")
    stage=$(mktemp -d /run/y700-webgl.XXXXXXXX)
    trap 'rm -r -- "$stage"' EXIT
    install -m644 "$here"/chromium-gpu{.html,.py,-board.sh} "$stage/"
    install -m755 "$uv" "$stage/uv"
    chmod 711 "$stage"
    timeout -k 5 150 unshare --net --pid --fork --kill-child --mount-proc --propagation private \
        /bin/bash "$stage/chromium-gpu-board.sh" --worker "$1" "$stage"
    exit
fi

[[ $EUID == 0 && $$ == 1 && $# == 3 && ( $2 == product || $2 == vulkan ) ]]
mode=$2 stage=$3
grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release
[[ $(id -u y700) != 0 && -x /usr/bin/chromium && -x /usr/lib/chromium/chromium ]]
ip link set lo up
[[ $(ip -o link show up | wc -l) == 1 && -z $(ip route show default) && -z $(ip -6 route show default) ]]
mount -t tmpfs -o mode=755,nodev,nosuid tmpfs /home
mount -t tmpfs -o mode=755,nodev,nosuid tmpfs /run/user
mount -t tmpfs -o mode=1777,nodev,nosuid tmpfs /tmp
install -d -o y700 -g y700 -m700 /home/y700 /home/y700/runtime
cd /home/y700
options=(--product-launcher)
if [[ $mode == vulkan ]]; then options=(--backend vulkan); fi
printf 'CHROMIUM_BOARD mode=%s uid=%s version=%s net=loopback display=headless boot=%s\n' \
    "$mode" "$(id -u y700)" "$(dpkg-query -W -f='${Version}' chromium)" "$(cat /proc/sys/kernel/random/boot_id)"
setpriv --reuid=y700 --regid=y700 --init-groups env -i PATH="$PATH" HOME=/home/y700 \
    XDG_RUNTIME_DIR=/home/y700/runtime LC_ALL=C.UTF-8 "$stage/uv" run --offline --no-project \
    --python /usr/bin/python3 python -B "$stage/chromium-gpu.py" --headless --frames 60 --timeout 100 \
    "${options[@]}" > "$stage/report.json" 2>"$stage/browser.log" &
runner=$!
packaged_flag=0 sandbox=0 bypass=0 retired=0
while kill -0 "$runner" 2>/dev/null; do
    for proc in /proc/[0-9]*; do
        [[ $(readlink "$proc/exe" || :) == /usr/lib/chromium/chromium ]] || continue
        flags=$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null) || continue
        case " $flags" in *' --no-sandbox '*|*' --disable-gpu-sandbox '*|*' --disable-seccomp-filter-sandbox '*) bypass=1;; esac
        case " $flags" in *' --disable-gpu '*) packaged_flag=1;; esac
        if [[ " $flags" == *' --type=renderer '* ]] && awk '
            $1=="Seccomp:" && $2==2 {filter=1} $1=="NoNewPrivs:" && $2==1 {nnp=1}
            END {exit !(filter && nnp)}' "$proc/status" 2>/dev/null; then sandbox=1; fi
        if [[ " $flags" == *' --type=gpu-process '* && $retired == 0 ]]; then
            for info in "$proc"/fdinfo/*; do
                if awk '$1=="drm-driver:" && $2=="msm" {msm=1}
                    ($1=="drm-engine-gpu:" || $1=="drm-cycles-gpu:") && $2+0>0 {work=1}
                    END {exit !(msm && work)}' "$info" 2>/dev/null; then retired=1; break; fi
            done
        fi
    done
    sleep .12
done
status=0
wait "$runner" || status=$?
cat "$stage/report.json"
if grep -Eq 'Timed out waiting for|Chromium exited|\[Errno' "$stage/report.json"; then
    grep -Ei -m4 'error:|sandbox|failed to' "$stage/browser.log" | cut -c1-240 || :
fi
printf 'CHROMIUM_OBSERVED renderer_seccomp=%d sandbox_bypass=%d disable_gpu=%d msm_retired=%d\n' \
    "$sandbox" "$bypass" "$packaged_flag" "$retired"
[[ $sandbox == 1 && $bypass == 0 ]]
if [[ $mode == product ]]; then
    [[ $packaged_flag == 1 && $status == 1 ]]
    grep -Eq '"result": "software-renderer"|"error": "WebGL 2 context unavailable"' "$stage/report.json"
    echo CHROMIUM_PRODUCT_SOFTWARE_POLICY_CONFIRMED
else
    [[ $packaged_flag == 0 && $status == 0 && $retired == 1 ]]
    echo CHROMIUM_TURNIP_WEBGL_VERIFIED
fi
