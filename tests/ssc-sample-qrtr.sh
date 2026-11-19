#!/bin/bash
# Run only inside the disposable, networkless QRTR VM with the mock payload.
set -euo pipefail
cd /opt/ssc-test
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PYTHONPATH=/opt/ssc-test:/opt/ssc-test/ssc_server:/opt/ssc-test/python
export UV_CACHE_DIR=/run/ssc-uv-cache PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
test "$(dpkg-query -W -f='${Version}' libssc2)" = 0.4.4-2.1~bpo13+1.y7001
grep -qw y700.ssc_fixture=1 /proc/cmdline
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
    local mode=$1
    ./uv run --offline --no-project --python /usr/bin/python3 python ./mock.py "$mode" >/run/ssc-server.log 2>&1 &
    server=$!
    for _ in {1..60}; do
        if grep -q 'Waiting for MSGs' /run/ssc-server.log; then return 0; fi
        if ! kill -0 "$server" 2>/dev/null; then break; fi
        sleep 0.1
    done
    tail -n 30 /run/ssc-server.log >&2
    return 1
}

start_server normal
for name in accelerometer gyroscope magnetometer light proximity compass; do
    ./ssc-sample.arm64 "$name" 3 8 | tee "/run/ssc-$name.log"
    grep -Eq "^SSC_DISCOVERY sensor=$name data_type=[a-z_]+ status=found$" "/run/ssc-$name.log"
    grep -Eq "^SSC_RESULT sensor=$name status=ok discovered=yes available=yes subscribed=yes closed=yes requested=3 accepted=3 rejected=[0-9]+$" "/run/ssc-$name.log"
    test "$(grep -c '^SSC_SAMPLE ' "/run/ssc-$name.log")" = 3
    awk -F'host_monotonic_us=' '/^SSC_SAMPLE / {if ($2+0 <= last) exit 1; last=$2+0}' "/run/ssc-$name.log"
done
grep -q 'rejected=1$' /run/ssc-gyroscope.log
stop_server
sleep 0.5
start_server silent-light
status=0
./ssc-sample.arm64 light 1 3 > /run/ssc-no-data.log || status=$?
cat /run/ssc-no-data.log
test "$status" = 4
grep -Fxq 'SSC_RESULT sensor=light status=no-data discovered=yes available=yes subscribed=yes closed=yes requested=1 accepted=0 rejected=0' /run/ssc-no-data.log
echo SSC_QRTR_FIXTURE_PASS
