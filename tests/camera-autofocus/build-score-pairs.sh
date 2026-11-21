#!/bin/bash
# Reuse the qualified ARM64 camera SDK, object inputs and public IPA key.
set -euo pipefail
[[ $# == 3 && $EUID == 0 ]] || { echo "Usage: sudo bash $0 ARM64_DEBIAN_SDK SETTLED_BUILD_INPUT NEW_OUTPUT" >&2; exit 2; }
sdk=$(realpath "$1"); previous=$(realpath "$2"); out=$(realpath -m "$3")
[[ -d $sdk/usr/include && -d $previous/source && ! -e $out && ! -L $out ]]
here=$(cd "$(dirname "$0")" && pwd)
patches=$(realpath "$here/../../packaging/camera-autofocus")
parent_sha=ab1cd0e90330a2b3905d8103b5be42fa098c4f15e494e8284c13f4decfcc5d23
candidate_sha=a56b92c1c2528582e23b151275291d4cbb4ae70e7fc8c446c885914f5c715012
work=$(mktemp -d /var/tmp/y700-af-rebuild.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
(
	cd "$previous"
	sha256sum --strict -c - <<'SUMS'
0adefb927723915e0c29343620bca301403cc6dd43f3420cd736e40cb25e1ff8  compile-native.sh
0f7a21382b15eeeba0e79b59439fbcbde430d98f5fa47583e46aee580101ed99  objects.rsp
c8e5382fe932fd9f42288930432adbd885773429ed49c681d485b40d339632de  ipa_pub_key.cpp
SUMS
	cp -a source generated objects.rsp compile-native.sh reuse ipa_pub_key.cpp production "$work/"
)
mkdir "$work"/{upper,overlay-work,root,native-objects,tmp,receipts}
cp "$here/score-pairs.cpp" "$work/"
unshare --mount --propagation private -- bash -seu -o pipefail -- "$work" "$sdk" "$patches" "$parent_sha" "$candidate_sha" <<'NAMESPACE'
w=$1; sdk=$2; patches=$3; parent=$4; candidate=$5
root=$w/root
mount -t overlay overlay -o "lowerdir=$sdk,upperdir=$w/upper,workdir=$w/overlay-work" "$root"
mkdir -p "$root/build/diag"
mount --bind "$w" "$root/build/diag"
pipe=src/libcamera/pipeline/simple
check() {
	local name=$1; shift
	chroot "$root" /bin/bash -ec '
		cd /build/diag
		pipeline=source/src/libcamera/pipeline/simple
		g++ -std=c++17 -O2 -Wall -Wextra -Werror -I"$pipeline" "${@:2}" score-pairs.cpp "$pipeline/contrast_scan.cpp" -o points-test
		./points-test
	' check "$name" "$@" > "$w/receipts/$name.log"
}
build() {
	chroot "$root" /bin/bash /build/diag/compile-native.sh
	aarch64-linux-gnu-strip --strip-unneeded -o "$w/libcamera.so.0.7" "$w/native-objects/libcamera.so.0.7.2"
	printf '%s  %s\n' "$1" "$w/libcamera.so.0.7" | sha256sum --strict -c -
}
build "$parent"
check parent -DY700_PRE_PAIR_TRACE
cp "$w/source/$pipe/contrast_scan.cpp" "$w/parent.cpp"
patch --fuzz=0 --batch -d "$w/source" -p1 < "$patches/score-pairs.patch"
build "$candidate"
check paired
diff <(grep '^PASS synthetic' "$w/receipts/parent.log") <(grep '^PASS synthetic' "$w/receipts/paired.log")
# Test the independent full-grid decision candidate on its own source in the same ARM64 SDK.
patch --fuzz=0 --batch -R -d "$w/source" -p1 < "$patches/score-pairs.patch"
cmp "$w/parent.cpp" "$w/source/$pipe/contrast_scan.cpp"
patch --fuzz=0 --batch -d "$w/source" -p1 < "$patches/full-grid-vga.patch"
check full-grid -DY700_PRE_PAIR_TRACE -DY700_FULL_GRID_DECISION
NAMESPACE
mkdir "$out"
install -m644 "$work/libcamera.so.0.7" "$work/receipts/"*.log "$out/"
(cd "$out" && sha256sum libcamera.so.0.7 *.log > SHA256SUMS)
