#!/usr/bin/env bash
# Fetch only the seven public upstream blobs listed in the pinned source ledger.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: fetch-inputs.sh NEW_DIRECTORY' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd); out=$(realpath -m "$1")
[[ ! -e $out && ! -L $out ]]
stage=$(mktemp -d "$(dirname "$out")/.ufs-inputs.XXXXXXXX")
trap '[[ ! -d $stage ]] || rm -r -- "$stage"' EXIT
gh=${GH_BIN:-gh}
base=8dcb481fc2ce91794fd294630e06f15a52ec7513
next=21d4a113ac49892723986a843bb2ce6942567d62
while read -r digest name; do
    ref=$next
    case "$name" in
        003[2345]-*) ref=$base; path=pkgs/linux-kernel/sm8475/asphalt/patches/local/$name ;;
        0036-*) path=pkgs/linux-kernel/sm8475/asphalt/patches/local/$name ;;
        ufs-opp-init-order.patch) path=pkgs/linux-kernel/patches/$name ;;
        asphalt-ufs.py) path=tests/$name ;;
        *) exit 1 ;;
    esac
    "$gh" api "repos/dianqk/nixos-android-devices/contents/$path?ref=$ref" --jq .content </dev/null |
        tr -d '\r\n' | base64 --decode > "$stage/$name"
    echo "$digest  $stage/$name" | sha256sum --strict -c -
done < "$here/inputs.sha256"
(cd "$stage"; sha256sum --strict --quiet -c "$here/inputs.sha256")
mv -T --no-clobber "$stage" "$out"
[[ ! -d $stage ]]
