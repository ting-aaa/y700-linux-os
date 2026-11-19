#!/bin/bash
# Run in the disposable networkless ARM64 QRTR fixture after staging Hall inputs.
set -euo pipefail
cd /opt/ssc-test
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PYTHONPATH=/opt/ssc-test:/opt/ssc-test/ssc_server:/opt/ssc-test/python
export UV_CACHE_DIR=/run/ssc-uv-cache PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
grep -qw y700.ssc_fixture=1 /proc/cmdline
test "$(dpkg-query -W -f='${Version}' libssc2)" = 0.4.4-2.1~bpo13+1.y7001
if [[ ! -e /usr/lib/aarch64-linux-gnu/libqrtr.so.1 ]]; then
    install -m644 lib/libqrtr.so.1 /usr/lib/aarch64-linux-gnu/libqrtr.so.1
fi

server=
stop_server() {
    if [[ -n $server ]]; then
        kill "$server" 2>/dev/null || true
        wait "$server" 2>/dev/null || true
        server=
    fi
}
trap stop_server EXIT

start_server() {
    ./uv run --offline --no-project --python /usr/bin/python3 python ./hall-mock.py "$1" > /run/hall-server.log 2>&1 &
    server=$!
    for _ in {1..60}; do
        if grep -q 'Waiting for MSGs' /run/hall-server.log; then return 0; fi
        if ! kill -0 "$server" 2>/dev/null; then break; fi
        sleep 0.1
    done
    tail -n 30 /run/hall-server.log >&2
    return 1
}

start_server normal
./ssc-hall --discover --timeout 5 | tee /run/hall-discovery.log
grep -Fxq 'Hall sensor discovered: hall' /run/hall-discovery.log
! grep -Fq 'Hall on-change subscription received' /run/hall-server.log
./ssc-hall --count 2 --timeout 8 | tee /run/hall-reports.log
test "$(grep '^Hall sensor measurement:' /run/hall-reports.log)" = "$(printf 'Hall sensor measurement: NEAR\nHall sensor measurement: FAR')"
grep -Fxq 'Hall result: accepted=2 rejected=5' /run/hall-reports.log
grep -Fxq 'Hall on-change subscription received' /run/hall-server.log
grep -Fq 'Disabling sensor 12,12' /run/hall-server.log
stop_server
sleep 0.5

start_server silent
status=0
./ssc-hall --count 1 --timeout 3 > /run/hall-silent.log || status=$?
cat /run/hall-silent.log
test "$status" = 4
grep -Fxq 'Hall result: accepted=0 rejected=0' /run/hall-silent.log
grep -Fq 'Disabling sensor 12,12' /run/hall-server.log
echo SSC_HALL_QRTR_FIXTURE_PASS
