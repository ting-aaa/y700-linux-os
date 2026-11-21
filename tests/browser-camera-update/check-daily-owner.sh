#!/bin/bash
# Run over the trusted maintenance connection after a normal desktop login.
set -euo pipefail
export LC_ALL=C
user_id=$(id -u y700)
seat=$(loginctl show-seat seat0 -p ActiveSession --value)
[[ $(loginctl show-session "$seat" -p Active --value) == yes ]]
[[ $(loginctl show-session "$seat" -p User --value) == "$user_id" ]]
[[ $(loginctl show-session "$seat" -p Type --value) == x11 ]]
runtime=/run/user/$user_id
actor=(runuser -u y700 -- env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus")
pkg=y700-camera-pipewire
version=$(dpkg-query -W -f='${Version}' "$pkg")
[[ $version == 1.4.2-1+y700.5 ]]
so=/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
base=/var/lib/y700/updates/browser-camera-orientation-y7005
deb=$(find "$base" -maxdepth 1 -name '*y700.5_arm64.deb' -print -quit)
echo "73cfdd2a0b1dad67f02aef3efbbb54b9129fb6a918bddc33b0574a08cd343cfc  $deb" | sha256sum --strict --quiet -c -
expected=$(dpkg-deb --fsys-tarfile "$deb" | tar -xO "./${so#/}" | sha256sum)
actual=$(sha256sum "$so")
[[ ${actual%% *} == ${expected%% *} ]]
for service in pipewire wireplumber; do
    pid=$("${actor[@]}" systemctl --user show -p MainPID --value "$service")
    [[ $pid =~ ^[1-9][0-9]*$ ]]
    awk -v p="$so" -v ino="$(stat -c %i "$so")" '
        $6 == p { seen++; if ($5 != ino || NF != 6) stale = 1 }
        END { exit !(seen && !stale) }' "/proc/$pid/maps"
    echo "$service mapped_installed_plugin=1"
done
"${actor[@]}" pw-dump | perl -MJSON::PP -0777 -ne '
    my %graph = map { $_->{id} => $_ } @{decode_json($_)};
    my @names;
    for my $item (values %graph) {
        my $props = $item->{info}{props} // {};
        next unless ($props->{"node.name"} // "") =~ /^y700_camera_/;
        my $factory = $graph{$props->{"factory.id"}}->{info}{props};
        die "Unexpected camera factory" unless $factory->{"factory.name"} eq "spa-node-factory"
            && $props->{"factory.name"} eq "api.libcamera.source";
        die "Camera in use" unless $item->{info}{state} =~ /^(idle|suspended)$/;
        push @names, $props->{"node.name"};
    }
    die "Missing camera sources" unless join(",",sort @names) eq "y700_camera_front,y700_camera_macro,y700_camera_rear";
    print "physical_sources=3 factory=spa-node-factory all_idle=1\n";
'
echo "active_daily_x11=1 package=$version plugin_sha256=${actual%% *}"
