"""Tap the real Xfce Wi-Fi applet and emit only reduced acceptance results."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import gi

gi.require_version('Atspi', '2.0')
gi.require_version('NM', '1.0')
from gi.repository import Atspi, GLib, NM


class ProbeError(Exception):
    pass


def await_value(predicate, failure, seconds=12):
    deadline = time.monotonic() + seconds
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        try:
            if value := predicate():
                return value
        except GLib.Error:
            pass
        time.sleep(0.12)
    raise ProbeError(failure)


def xdotool(*args):
    return subprocess.run(['xdotool', *args], check=False, text=True, capture_output=True, timeout=3)


def tap(x, y):
    if x <= 0 or y <= 0 or x >= 1100 or y >= 800:
        raise ProbeError('invalid-tap-target')
    # Consecutive equal passphrase characters tap the same pixel again.
    if xdotool('mousemove', str(x), str(y), 'click', '1').returncode:
        raise ProbeError('xtest-click-failed')


def window_geometry(window):
    if not window.isdecimal():
        return None
    parts = dict(re.findall(r'^(X|Y|WIDTH|HEIGHT)=(-?\d+)$',
                            xdotool('getwindowgeometry', '--shell', window).stdout, re.M))
    if len(parts) == 4:
        return tuple(int(parts[key]) for key in ('X', 'Y', 'WIDTH', 'HEIGHT'))
    return None


def tray_position():
    result = xdotool('search', '--onlyvisible', '--class', '^Nm-applet$')
    for window in result.stdout.split():
        if geometry := window_geometry(window):
            x, y, width, height = geometry
            if 8 <= width <= 64 and 8 <= height <= 64:
                return x + width // 2, y + height // 2
    return None


def application(pid):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child and child.get_process_id() == pid:
            return child
    return None


def nodes(root, depth=0):
    if not root or depth > 12:
        return
    yield root
    for index in range(min(root.get_child_count(), 256)):
        yield from nodes(root.get_child_at_index(index), depth + 1)


def showing(node):
    return node.get_state_set().contains(Atspi.StateType.SHOWING)


def tap_node(node):
    component = node.get_component_iface()
    if not component:
        raise ProbeError('menu-item-without-screen-component')
    rect = component.get_extents(Atspi.CoordType.SCREEN)
    if rect.width < 1 or rect.height < 1:
        raise ProbeError('empty-menu-item-geometry')
    tap(rect.x + rect.width // 2, rect.y + rect.height // 2)


def ssid(value):
    if value and value.get_size():
        return NM.utils_ssid_to_utf8(value.get_data())
    return None


def profiles(client):
    return [profile for profile in client.get_connections() if profile.get_setting_wireless()]


def network_rows(root, visible_ssids):
    rows = []
    for node in nodes(root):
        if node.get_role() in (Atspi.Role.MENU_ITEM, Atspi.Role.CHECK_MENU_ITEM) and showing(node):
            # nm-applet adds the signal percentage and security to the ATK name.
            label, _, detail = node.get_name().rpartition(': ')
            if label in visible_ssids and re.fullmatch(r'\d{1,3}%(?:, (?:in)?secure\.)*|ad-hoc', detail):
                rows.append((node, label))
    return rows


def editor_count(profile_names):
    editor = subprocess.Popen(['nm-connection-editor', '--show', '--type', 'wifi'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        tree = await_value(lambda: application(editor.pid), 'saved-editor-not-accessible')

        def names():
            return {node.get_name() for node in nodes(tree) if showing(node)} & profile_names

        return len(await_value(names, 'saved-editor-no-matching-profile'))
    finally:
        editor.terminate()
        editor.wait(timeout=4)


def password_dialog(app):
    for dialog in nodes(app):
        if dialog.get_role() != Atspi.Role.DIALOG or not showing(dialog):
            continue
        entry = None
        connect = None
        for child in nodes(dialog):
            if child.get_role() == Atspi.Role.PASSWORD_TEXT and showing(child):
                entry = child
            if (child.get_role() == Atspi.Role.PUSH_BUTTON and child.get_name() == 'Connect' and showing(child)):
                connect = child
        if entry and connect:
            return entry, connect
    return None


def enter_password(entry, connect, secret):
    editable = entry.get_editable_text_iface()
    if not editable or not editable.set_text_contents(secret):
        raise ProbeError('masked-gtk-field-edit-failed')
    text = entry.get_text_iface()
    if not text or text.get_character_count() != len(secret):
        raise ProbeError('password-field-length-mismatch')
    action = connect.get_action_iface()
    if not action or not action.do_action(0):
        raise ProbeError('secured-gtk-connect-action-failed')


def verify_password_retry(app, device, transitions, network, choose):
    entry, connect = await_value(lambda: password_dialog(app), 'secured-password-dialog-missing')
    before = len(transitions)
    enter_password(entry, connect, network['wrong'])

    def reject_premature_activation():
        if (device.get_state() == NM.DeviceState.ACTIVATED or
                any(state == NM.DeviceState.ACTIVATED for state, _ in transitions[before:])):
            raise ProbeError('wrong-password-unexpectedly-activated')

    def wrong_failed():
        reject_premature_activation()
        tried = False
        for state, reason in transitions[before:]:
            if state == NM.DeviceState.CONFIG:
                tried = True
            elif tried and state in (NM.DeviceState.NEED_AUTH, NM.DeviceState.FAILED):
                return state, reason
        return None

    state, reason = await_value(wrong_failed, 'wrong-password-failure-not-observed', 55)
    print(f'WIFI_WRONG_REJECTED nm_state={state} nm_reason={reason}', flush=True)

    def retry_ready():
        dialog = password_dialog(app)
        if dialog:
            return dialog
        if device.get_state() == NM.DeviceState.DISCONNECTED:
            return 'reselect'
        return None

    retry = await_value(retry_ready, 'wrong-password-dialog-did-not-return', 18)
    if retry == 'reselect':
        choose()
        retry = await_value(lambda: password_dialog(app), 'password-dialog-did-not-open-on-retry', 50)
    reject_premature_activation()
    enter_password(*retry, network['correct'])


def main(mode, applet_pid):
    if mode not in ('physical', 'fixture'):
        raise ProbeError('bad-mode')
    if mode == 'fixture' and 'y700.wifi_fixture=1' not in Path('/proc/cmdline').read_text().split():
        raise ProbeError('selection-requires-isolated-wifi-fixture')
    if mode == 'physical' and os.geteuid() == 0:
        raise ProbeError('physical-ui-requires-ordinary-user')
    Atspi.init()
    Atspi.set_timeout(2500, 2500)
    client = NM.Client.new(None)
    devices = [dev for dev in client.get_devices()
               if isinstance(dev, NM.DeviceWifi) and dev.get_managed()]
    if len(devices) != 1:
        raise ProbeError('expected-one-managed-wifi-device')
    device = devices[0]
    before_profiles = {profile.get_uuid() for profile in profiles(client)}
    profile_names = {profile.get_id() for profile in profiles(client)}
    saved_ssids = {ssid(profile.get_setting_wireless().get_ssid()) for profile in profiles(client)} - {None}
    before = device.get_active_connection()
    before_uuid = before.get_uuid() if before else None
    transitions = []
    device.connect('state-changed', lambda _, state, _previous, reason: transitions.append((state, reason)))
    if mode == 'physical' and (not before or device.get_state() != NM.DeviceState.ACTIVATED):
        raise ProbeError('physical-active-connection-required')
    network = None
    if mode == 'fixture':
        if before or (Path('/sys/class/net') / device.get_iface() /
                      'device/driver').resolve().name != 'mac80211_hwsim':
            raise ProbeError('fixture-hwsim-idle-station-required')
        network = json.loads(Path('/run/wifi-fixture/network.json').read_text())

    def access_points():
        aps = device.get_access_points()
        return (len(aps), {ssid(ap.get_ssid()) for ap in aps} - {None}) if aps else None

    await_value(access_points, 'networkmanager-has-no-visible-aps')
    app = await_value(lambda: application(applet_pid), 'applet-not-accessible')
    position = await_value(tray_position, 'no-embedded-applet-x11-icon')
    tap(*position)

    def submenu():
        return next((node for node in nodes(app)
                     if node.get_name() == 'Available networks' and showing(node)), None)

    available = await_value(submenu, 'network-menu-did-not-open-after-tap')
    active_main_rows = 0
    if mode == 'physical':
        active_ap = device.get_active_access_point()
        active_name = ssid(active_ap.get_ssid()) if active_ap else None
        active_main_rows = len(network_rows(app, {active_name}))
        if active_main_rows != 1:
            raise ProbeError('active-ap-missing-from-primary-menu')
    tap_node(available)
    count, names = access_points()
    rows = await_value(lambda: network_rows(available, names), 'submenu-has-no-visible-nm-ap-rows')
    matched_labels = {label for _, label in rows}
    if network:
        parameters = dict(item.split('=', 1) for item in Path('/proc/cmdline').read_text().split() if '=' in item)
        attempt = parameters.get('y700.wifi_attempt', 'retry')
        if attempt not in ('fresh', 'retry'):
            raise ProbeError('bad-fixture-attempt')
        target = next((row for row, label in rows if label == network['ssid']), None)
        if not target:
            raise ProbeError('owned-ap-missing-from-menu')
        tap_node(target)
        if network['mode'] != 'open' and attempt == 'retry':
            def choose_again():
                tap(*position)
                menu = await_value(submenu, 'retry-applet-menu-missing')
                tap_node(menu)
                choices = await_value(lambda: network_rows(menu, {network['ssid']}), 'retry-ap-row-missing')
                tap_node(choices[0][0])

            verify_password_retry(app, device, transitions, network, choose_again)
        elif network['mode'] != 'open':
            dialog = await_value(lambda: password_dialog(app), 'secured-password-dialog-missing')
            enter_password(*dialog, network['correct'])

        def connected():
            ap = device.get_active_access_point()
            return (ap and ssid(ap.get_ssid()) == network['ssid'] and
                    device.get_state() == NM.DeviceState.ACTIVATED and device.get_ip4_config())

        ip = await_value(connected, 'owned-ap-did-not-activate', 30)
        if not any(address.get_address().startswith('192.0.2.') for address in ip.get_addresses()):
            raise ProbeError('fixture-dhcp-address-missing')
        if network['mode'] != 'open':
            setting = device.get_active_connection().get_connection().get_setting_wireless_security()
            if not setting or setting.get_key_mgmt() != {'wpa2': 'wpa-psk', 'sae': 'sae'}[network['mode']]:
                raise ProbeError('unexpected-negotiated-security')
            print(f'WIFI_SECURED_PASS security={network["mode"]} input=gtk-a11y attempt={attempt}')
        print('WIFI_FIXTURE_ASSOCIATION activated=1 dhcp=1')
    else:
        xdotool('key', 'Escape', 'Escape')
        saved_visible = editor_count(profile_names)
        after = device.get_active_connection()
        if (not after or after.get_uuid() != before_uuid or transitions or
                device.get_state() != NM.DeviceState.ACTIVATED or
                {profile.get_uuid() for profile in profiles(client)} != before_profiles):
            raise ProbeError('physical-network-or-profile-inventory-changed')
        print(f'WIFI_SAVED profiles={len(before_profiles)} editor_rows={saved_visible} '
              f'nearby_saved={len(names & saved_ssids)} submenu_saved={len(matched_labels & saved_ssids)} '
              f'active_main_rows={active_main_rows} state_transitions={len(transitions)}')

    print(f'WIFI_MENU primary_open=1 submenu_open=1 nm_ap_objects={count} '
          f'nm_named_networks={len(names)} submenu_rows={len(rows)} matched_labels={len(matched_labels)}')


if __name__ == '__main__':
    try:
        main(sys.argv[1], int(sys.argv[2]))
    except ProbeError as error:
        print(f'WIFI_PROBE_ERROR {error}', file=sys.stderr)
        raise SystemExit(1)
    except Exception as error:
        # GLib or applet error strings may contain identifiers. Reduce them at source.
        print(f'WIFI_PROBE_ERROR {type(error).__name__}', file=sys.stderr)
        raise SystemExit(1)
