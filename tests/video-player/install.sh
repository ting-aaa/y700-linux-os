#!/bin/bash
# Apply only the qualified additive transaction. No apt update or network required.
set -euo pipefail
export LC_ALL=C
case ${1:---check} in --check|--install) ;; *) echo 'Usage: install.sh [--check|--install]' >&2; exit 2;; esac
cd "$(dirname "$0")"
base=a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84
result=89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d
test "$(dpkg --print-architecture)" = arm64
sha256sum --quiet -c - <<'MANIFEST'
50fe420f763e66318913155904c55bfc72ec0a225d104407c0b7eb73037e195c  SHA256SUMS
815d1ec4ca4443f79b648bab8f6c9ed9fc57dd05824f377ebc30f8b9da4b2ad0  additions.tsv
MANIFEST
sha256sum --strict --check --quiet SHA256SUMS
package_digest() {
    dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n' |
        awk -F '\t' '$4=="installed" {print $1 "\t" $2 "\t" $3}' | sort | sha256sum | cut -d' ' -f1
}
before=$(package_digest)
if [[ $before == "$result" ]]; then
    test -z "$(dpkg --audit)"
    echo "Player already installed. Package digest $result"
    exit 0
fi
[[ $before == "$base" && -z $(dpkg --audit) ]] || { echo 'Expected a fully configured dev12.8 baseline.' >&2; exit 1; }
archives=("$PWD"/packages/*.deb)
(( ${#archives[@]} == 116 ))
# APT's --no-download also disables its local file acquisition method. An empty
# sources configuration leaves only the named and verified local archives.
config=$(mktemp -d)
trap 'rm -r -- "$config"' EXIT
touch "$config/sources.list"
mkdir "$config/empty"
chmod 755 "$config"
options=(--no-install-recommends --no-remove -o "Dir::Etc::sourcelist=$config/sources.list"
         -o "Dir::Etc::sourceparts=$config/empty" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=)
plan=$(apt-get -s "${options[@]}" install "${archives[@]}")
grep -Eq '^0 upgraded, 116 newly installed, 0 to remove' <<< "$plan"
echo 'Preflight passed for 116 additions and zero upgrades or removals.'
[[ ${1:---check} == --install ]] || exit 0
[[ $EUID == 0 ]]
export DEBIAN_FRONTEND=noninteractive
apt-get -y "${options[@]}" install "${archives[@]}"
mapfile -t automatic < <(awk -F '\t' '$1!="parole" && $1!="gstreamer1.0-plugins-bad" {print $1}' additions.tsv)
apt-mark auto "${automatic[@]}" >/dev/null
apt-get "${options[@]}" check
[[ -z $(dpkg --audit) && $(package_digest) == "$result" ]]
echo "Installed 1240 packages. Package digest $result"
