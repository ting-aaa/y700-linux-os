#!/usr/bin/env bash
# Private initramfs using the same signed package inputs and hwsim infrastructure as the GUI.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
: "${WIFI_CANDIDATE_DEBS:?final two ARM64 packages}"
test -f "$WIFI_CANDIDATE_DEBS/network-manager_1.52.1-1+0y7001_arm64.deb"
test -f "$WIFI_CANDIDATE_DEBS/wpasupplicant_2.10-24+0y7001_arm64.deb"
(cd "$WIFI_CANDIDATE_DEBS" && sha256sum --strict -c - <<'HASHES'
25b3540fa3f6dfcd26a0c55f17938de527b7af2e4114d5124c9d979884a15c2d  network-manager_1.52.1-1+0y7001_arm64.deb
f2f380f53cc8aa314f43c4a0a041f24eb6ef408b0f540d61a0743f99c6fc1226  wpasupplicant_2.10-24+0y7001_arm64.deb
HASHES
)
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-sae-agent.XXXXXXXX")
trap 'rm -r -- "$work"' EXIT
cp -r "$here/../wifi-chooser" "$work/fixture"
# Reuse the same nonroot PAM seat, AP, namespaces and negotiated-link checks.
# Replace only the UI actor and omit the GTK-specific host receipt checks.
install -m644 "$here/agent.py" "$work/fixture/probe.py"
cat > "$work/fixture/session.sh" <<'SESSION'
#!/usr/bin/env bash
set -euo pipefail
export UV_CACHE_DIR="$XDG_RUNTIME_DIR/sae-uv" PYTHONDONTWRITEBYTECODE=1
agent=(/opt/wifi-test/bin/uv run --offline --no-project --python /usr/bin/python3 python /opt/wifi-test/probe.py)
timeout -k 2 60 "${agent[@]}" --absent
exec timeout -k 2 117 "${agent[@]}"
SESSION
awk '/^grep -Fxq .WIFI_VM_EXIT=0/ { seen++; exit } { print } END { if (seen != 1) exit 1 }' \
    "$work/fixture/run-vm.sh" > "$work/fixture/headless.sh"
export WIFI_ACTOR=seat WIFI_SECURITY=sae WIFI_ATTEMPT=fresh WIFI_KEYBOARD=onboard WIFI_TOUCHSCREEN=0 WIFI_REJOIN=0
bash "$work/fixture/headless.sh" | tee "$work/result.log"
expect() { grep -Fxq "$1" "$work/result.log"; }
expect 'WIFI_VM_EXIT=0'
expect 'WIFI_SEAT ordinary_uid=1 active=1 local=1 type=x11 network_control=yes'
expect 'WIFI_AGENT absent-PASS failed_reason=53 replacement_requests=0 mismatch=0'
expect 'WIFI_FIXTURE_PASS nm_connected=1 nl80211_associated=1 local_dhcp=1 local_ping=1'
expect 'WIFI_SAE_NEGOTIATED akm=SAE pmf=1'
mode=legacy; selections=2; status=1; automatic=0; explicit=1
if [[ -n ${WIFI_AP_DEBS:-} ]]; then mode=modern; selections=1; status=15; automatic=1; explicit=0; fi
expect "WIFI_AGENT PASS mode=$mode replacements=1 selections=$selections same_profile_and_ap=1 unrelated_preserved=1"
grep -Eq "^WIFI_AGENT get-secrets request_new=1 flags=[0-9]+ activation=$selections$" "$work/result.log"
expect "WIFI_AGENT station-auth-status code=$status"
expect "WIFI_NM_PROMPTS automatic=$automatic explicit=$explicit"
