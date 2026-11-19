#!/usr/bin/env bash
set -Eeuo pipefail
test "$(id -un)" = y700
work=/run/topology
id=$(/usr/bin/xinput list --id-only 'NT36523N Capacitive Touchscreen')
[[ $id =~ ^[0-9]+$ ]]
prop='Coordinate Transformation Matrix'
matrix() {
    /usr/bin/xinput list-props "$id" | awk -F: '/Coordinate Transformation Matrix \(/ {
        v=$2; gsub(/,/, " ", v); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v);
        n=split(v,a,/[[:space:]]+/); if (n != 9) exit 1;
        for(i=1;i<=9;i++) printf "%s%.4f", (i==1 ? "" : " "), a[i]; print "";
    }'
}
identity='1.0000 0.0000 0.0000 0.0000 1.0000 0.0000 0.0000 0.0000 1.0000'
half='0.5000 0.0000 0.0000 0.0000 1.0000 0.0000 0.0000 0.0000 1.0000'
panel() { /usr/bin/xrandr --query | sed -n '/^DUMMY0 connected/p'; }
size() { /usr/bin/xrandr --query | sed -nE '1s/.*current ([0-9]+) x ([0-9]+),.*/\1x\2/p'; }
single() { /usr/bin/xrandr --output DUMMY1 --off --output DUMMY0 --mode portrait --primary --pos 0x0 --fb 1600x2560; }
dual() { /usr/bin/xrandr --fb 3200x2560 --output DUMMY1 --mode portrait --right-of DUMMY0; }
wait_for() {
    local end=$((SECONDS + 10))
    until "$@"; do (( SECONDS < end )) || return 1; sleep .15; done
}
mapped() { [[ $(matrix) == "$1" ]]; }
writes() { wc -l < "$XDG_RUNTIME_DIR/writes"; }
count_is() { [[ $(writes) == "$1" ]]; }
polls() { wc -l < "$XDG_RUNTIME_DIR/queries"; }
polls_reached() { [[ $(polls) -ge $1 ]]; }
observe_idle() { wait_for polls_reached "$(( $(polls) + 3 ))"; }
watcher= listener=
stop_watch() {
    if [[ -n $watcher ]]; then
        kill -- "-$watcher" 2>/dev/null || :
        wait "$watcher" 2>/dev/null || :
        watcher=
        wait_for flock -n "$XDG_RUNTIME_DIR/y700-touch-sync.lock" true
    fi
}
cleanup() {
    rc=$?
    if (( rc )); then
        /usr/bin/xrandr --query | sed -n '1p; /^DUMMY[01] /p'
        echo "CTM $(matrix)"
        awk '/^EVENT/ {touch= /\(TouchBegin\)/} touch' "$XDG_RUNTIME_DIR/xi.log" 2>/dev/null | head -40 || :
        tail -30 "$XDG_RUNTIME_DIR/watcher.log" "$XDG_RUNTIME_DIR/xi.log" 2>/dev/null || :
    fi
    stop_watch
    if [[ -n $listener ]]; then kill "$listener" 2>/dev/null || :; fi
}
trap cleanup EXIT
trap 'echo "Topology case failed at line $LINENO" >&2' ERR
start_watch() {
    : > "$XDG_RUNTIME_DIR/writes"
    : > "$XDG_RUNTIME_DIR/queries"
    setsid "$1" --watch > "$XDG_RUNTIME_DIR/watcher.log" 2>&1 & watcher=$!
    wait_for test -s "$XDG_RUNTIME_DIR/writes"
}
topology() {
    [[ $(size) == "$1" && $(panel) == "$fixed_panel" ]]
}
replay() {
    local prior
    prior=$(grep -c '^DONE$' "$work/input.log" || :)
    printf 'normal pinch\n' > "$work/feed"
    finished() { [[ $(grep -c '^DONE$' "$work/input.log") -gt $prior ]]; }
    wait_for finished
}
sample() {
    local expected=$1 log=$XDG_RUNTIME_DIR/xi.log first_line
    stdbuf -oL /usr/bin/xinput test-xi2 --root > "$log" & listener=$!
    # xinput prints inventory before all XI2 subscriptions take effect. Finish
    # a warm-up trace, then start a fresh observation on the same subscription.
    wait_for test -s "$log"
    for _ in 1 2 3; do
        replay
        grep -q '(TouchEnd)' "$log" && break
    done
    wait_for grep -q '(TouchEnd)' "$log"
    first_line=$(( $(wc -l < "$log") + 1 ))
    replay
    ended() { tail -n +"$first_line" "$log" | grep '(TouchEnd)' >/dev/null; }
    wait_for ended
    kill "$listener"
    wait "$listener" 2>/dev/null || :
    listener=
    # The normal pinch starts at (48%,47%) and (66%,47%) in raw panel space.
    # Match source ID and both coordinates on the server's processed events.
    awk -v id="$id" -v width="$expected" -v first="$first_line" '
      NR < first { next }
      /^EVENT/ { touch = /\(TouchBegin\)/; source = 0 }
      touch && $1=="device:" { source = ($3 == "(" id ")") }
      touch && source && $1=="root:" && $2 ~ /\// {
          split($2, p, "/"); x=p[1]+0; y=p[2]+0;
          if (y > 1200 && y < 1207) {
              if (x > width*.48-3 && x < width*.48+3) a=x
              if (x > width*.66-3 && x < width*.66+3) b=x
          }
      }
      END { if (!a || !b) exit 1;
            printf "TOPOLOGY_XI2 source=%s touch_begin_x=%.1f,%.1f y=%.1f expected_width=%s\n",id,a,b,y,width }
    ' "$log"
}
single
/usr/bin/xrandr --addmode DUMMY1 portrait
fixed_panel=$(panel)
[[ $fixed_panel == *'1600x2560+0+0'* ]]
topology 1600x2560
start_watch ./old-watcher
dual
topology 3200x2560
observe_idle
mapped "$identity"
[[ $(writes) == 1 ]]
echo 'OLD_ADD_STALE root=3200x2560 panel=1600x2560+0+0 scale_x=1'
sample 3200
stop_watch
start_watch ./old-watcher
mapped "$half"
single
topology 1600x2560
observe_idle
mapped "$half"
[[ $(writes) == 1 ]]
echo 'OLD_REMOVE_STALE root=1600x2560 scale_x=0.5'
sample 800
stop_watch
start_watch /usr/bin/y700-display
wait_for mapped "$identity"
dual
topology 3200x2560
wait_for mapped "$half"
wait_for count_is 2
echo 'NEW_ADD_MAPPED root=3200x2560 panel=1600x2560+0+0 scale_x=0.5'
sample 1600
before=$(writes)
/usr/bin/xinput set-prop "$id" "$prop" 1 0 0 0 1 0 0 0 1
topology 3200x2560
wait_for mapped "$half"
wait_for count_is $((before+1))
echo 'NEW_SAME_GEOMETRY_REPAIRED'
sample 1600
single
topology 1600x2560
wait_for mapped "$identity"
wait_for count_is 4
echo 'NEW_REMOVE_MAPPED root=1600x2560 scale_x=1'
sample 1600
before=$(writes)
observe_idle
kill -0 "$watcher"
[[ $(writes) == "$before" ]]
echo "NEW_IDLE idle_polls=3 extra_maps=0 total_maps=$before"
echo TOPOLOGY_PASS
