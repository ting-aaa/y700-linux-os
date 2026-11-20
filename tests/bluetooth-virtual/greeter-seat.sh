# Sourced only on the VM's second boot, with real PID 1, udev and logind.
[[ $bond_phase == resume && $(cat /proc/1/comm) == systemd ]]
dpkg-deb -x dummy.deb /
install -d -m755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/99-hid-fixture.conf <<'CONF'
[LightDM]
logind-check-graphical=false
[Seat:*]
xserver-command=/usr/bin/Xorg -config /opt/y700-virtual-hid/dummy.conf -logfile /run/Xorg.log
CONF
/usr/sbin/lightdm --show-config 2>&1 | grep -F 'greeter-session=arctica-greeter' >/dev/null
systemctl start --no-block lightdm
for _ in {1..150}; do
    if pgrep -u lightdm -x arctica-greeter >/dev/null; then break; fi
    sleep .4
done
if ! pgrep -u lightdm -x arctica-greeter >/dev/null; then
    systemctl show lightdm -p ActiveState -p Result
    grep -Ei 'fail|error|seat.*graphical|stopping|exited' /var/log/lightdm/lightdm.log | tail -12 || :
    exit 1
fi
systemctl is-active --quiet lightdm
session=$(loginctl show-seat seat0 -p ActiveSession --value)
[[ $(loginctl show-session "$session" -p Class --value) == greeter ]]
[[ $(loginctl show-session "$session" -p Type --value) == x11 ]]
echo "CLASSIC_RECONNECT_SEAT lightdm=active greeter=arctica class=greeter seat=seat0 type=x11"
export Y700_BT_GREETER=1
