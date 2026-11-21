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
from gi.repository import Atspi, GLib, Gio, NM

ONBOARD = os.environ.get('Y700_WIFI_ONBOARD') == '1'
TOUCH = os.environ.get('Y700_WIFI_TOUCH') == '1'
SCALE = 2 if ONBOARD else 1


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
    try:
        return subprocess.run(['xdotool', *args], check=False, text=True, capture_output=True, timeout=15)
    except subprocess.TimeoutExpired:
        raise ProbeError('x11-command-timeout-' + args[0]) from None


def tap(x, y):
    width, height = (2560, 1600) if ONBOARD else (1024, 768)
    if not 0 <= x < width or not 0 <= y < height:
        raise ProbeError('invalid-tap-target')
    if TOUCH:
        with open('/run/wifi-fixture/touch-command', 'w') as command:
            print('tap', round(x * 16000 / (width - 1)), round(y * 25600 / (height - 1)), file=command)
        with open('/run/wifi-fixture/touch-response') as response:
            if response.readline().strip() != 'DONE':
                raise ProbeError('type-b-tap-not-acknowledged')
        return
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
            if 8 <= width <= 64 * SCALE and 8 <= height <= 64 * SCALE:
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
    tap((rect.x + rect.width // 2) * SCALE, (rect.y + rect.height // 2) * SCALE)


def ssid(value):
    if value and value.get_size():
        return NM.utils_ssid_to_utf8(value.get_data())
    return None


def profiles(client):
    return [profile for profile in client.get_connections() if profile.get_setting_wireless()]


def saved_settings(client, exclude=None):
    return {pr.get_uuid(): pr.to_dbus(NM.ConnectionSerializationFlags.NO_SECRETS).unpack()
            for pr in profiles(client) if pr.get_uuid() != exclude}


def observe_sae_status(bus):
    def changed(_bus, _sender, _path, _interface, _signal, parameters):
        _, properties, _ = parameters.unpack()
        value = properties.get('AuthStatusCode')
        if value in (1, 15):
            print(f'WIFI_SAE_PROPERTY AuthStatusCode={value}', flush=True)
    bus.signal_subscribe('fi.w1.wpa_supplicant1', 'org.freedesktop.DBus.Properties', 'PropertiesChanged',
                         None, 'fi.w1.wpa_supplicant1.Interface', Gio.DBusSignalFlags.NONE, changed)
    bus.signal_subscribe('fi.w1.wpa_supplicant1', 'fi.w1.wpa_supplicant1.Interface', 'SaePasswordMismatch',
                         None, None, Gio.DBusSignalFlags.NONE,
                         lambda *_: print('WIFI_SAE_SIGNAL SaePasswordMismatch=1', flush=True))


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


def set_masked_entry(entry, secret):
    if ONBOARD:
        type_onboard(entry, secret)
        return
    editable = entry.get_editable_text_iface()
    if not editable or not editable.set_text_contents(secret):
        raise ProbeError('masked-gtk-field-edit-failed')
    text = entry.get_text_iface()
    if not text or text.get_character_count() != len(secret):
        raise ProbeError('password-field-length-mismatch')


def onboard_geometry():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    visible, = bus.call_sync('org.onboard.Onboard', '/org/onboard/Onboard/Keyboard',
                             'org.freedesktop.DBus.Properties', 'Get',
                             GLib.Variant('(ss)', ('org.onboard.Onboard.Keyboard', 'Visible')),
                             None, Gio.DBusCallFlags.NONE, 2000, None).unpack()
    if visible:
        for window in xdotool('search', '--onlyvisible', '--class', '^Onboard$').stdout.split():
            box = window_geometry(window)
            if box and box[2:] == (2560, 840):
                return box
    return None


def type_onboard(entry, secret):
    if not re.fullmatch('[a-z]{16}', secret):
        raise ProbeError('expected-random-lowercase-fixture-secret')
    tap_node(entry)
    x, y, width, height = await_value(onboard_geometry, 'stock-onboard-did-not-auto-show', 15)
    # A mapped dock can still be moving during its initial slide transition.
    time.sleep(.4)
    def key(rx, ry):
        tap(x + round(width * rx), y + round(height * ry))
    length = entry.get_text_iface().get_character_count
    if length():
        key(.043, .90)  # Ctrl, A, Backspace using Onboard's sticky modifier
        key(.144, .50)
        key(.822, .10)
        await_value(lambda: length() == 0, 'onboard-could-not-clear-old-password')
    # Centers of the three letter rows on the shipped English Compact layout.
    centers = {letter: (first + index * .061, cy)
               for row, first, cy in [('qwertyuiop', .129, .30), ('asdfghjkl', .144, .50),
                                      ('zxcvbnm', .181, .70)]
               for index, letter in enumerate(row)}
    for i, letter in enumerate(secret, 1):
        key(*centers[letter])
        try:
            await_value(lambda: length() == i, 'masked-field-did-not-receive-onboard-key', 5)
        except ProbeError:
            # Do not record coordinates, characters or window contents.
            print(f'WIFI_MASKED_COUNT expected={i} actual={length()} '
                  f'focused={int(entry.get_state_set().contains(Atspi.StateType.FOCUSED))} '
                  f'dock_visible={int(bool(onboard_geometry()))}', flush=True)
            raise
    key(.955, .10)  # Hide the dock to expose the dialog buttons
    await_value(lambda: not onboard_geometry(), 'onboard-dock-did-not-close')
    print(f'WIFI_ONBOARD masked_entry=1 {"touch" if TOUCH else "pointer"}_keys=16', flush=True)


def enter_password(entry, connect, secret):
    set_masked_entry(entry, secret)
    if ONBOARD:
        tap_node(connect)
        return
    action = connect.get_action_iface()
    if not action or not action.do_action(0):
        raise ProbeError('secured-gtk-connect-action-failed')


def edit_failed_profile(client, network, initial_uuids):
    matches = [profile for profile in profiles(client)
               if profile.get_uuid() not in initial_uuids and
               ssid(profile.get_setting_wireless().get_ssid()) == network['ssid']]
    if len(matches) != 1:
        raise ProbeError('failed-profile-not-unique')
    owned = matches[0]
    def other_profiles():
        return {p.get_uuid(): p.to_dbus(NM.ConnectionSerializationFlags.NO_SECRETS).unpack()
                for p in profiles(client) if p.get_uuid() != owned.get_uuid()}
    before = other_profiles()
    print('WIFI_EDITOR owned_failed_profile=1', flush=True)
    desktop = Atspi.get_desktop(0)

    def panel_apps():
        apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
        return [app for app in apps if app and ('panel' in app.get_name().lower() or
                                                'wrapper' in app.get_name().lower())]

    def named(trees, names):
        return next((item for tree in trees for item in nodes(tree)
                     if item.get_name() in names and showing(item)), None)

    for name in ('Applications', 'Settings', 'Advanced Network Configuration'):
        item = await_value(lambda: named(panel_apps(), {name}), 'launcher-missing-' + name)
        tap_node(item)
        print('WIFI_EDITOR launcher=' + name, flush=True)

    def editor_window():
        for i in range(desktop.get_child_count()):
            application = desktop.get_child_at_index(i)
            for j in range(application.get_child_count()):
                window = application.get_child_at_index(j)
                if window and window.get_name() == 'Network Connections' and showing(window):
                    return application
        return None

    editor = await_value(editor_window, 'gui-launched-editor-missing')
    row = await_value(lambda: named([editor], {owned.get_id()}), 'owned-editor-row-missing')
    tap_node(row)
    edit = await_value(lambda: named([editor], {'Edit'}), 'editor-edit-tool-missing')
    tap_node(edit)
    tab = await_value(lambda: named([editor], {'Wi-Fi Security'}), 'wifi-security-tab-missing')
    tap_node(tab)
    entry = await_value(lambda: next((n for n in nodes(editor)
                                      if n.get_role() == Atspi.Role.PASSWORD_TEXT and showing(n)), None),
                        'editor-password-field-missing')
    tap_node(entry)
    set_masked_entry(entry, network['correct'])
    save = await_value(lambda: named([editor], {'Save'}), 'editor-save-missing')
    tap_node(save)
    await_value(lambda: not named([editor], {'Save'}), 'editor-save-not-completed')
    if not client.get_connection_by_uuid(owned.get_uuid()) or other_profiles() != before:
        raise ProbeError('editing-changed-profile-inventory')
    print('WIFI_EDITOR saved=1 same_profile_uuid=1 other_profiles_preserved=1', flush=True)
    return owned.get_uuid()


def verify_password_retry(app, device, transitions, network, choose, edit=None, recovery=None):
    entry, connect = await_value(lambda: password_dialog(app), 'secured-password-dialog-missing', 45)
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
    if recovery:
        return recovery(reject_premature_activation)
    if edit:
        await_value(lambda: device.get_state() == NM.DeviceState.DISCONNECTED,
                    'failed-sae-did-not-disconnect')
        reject_premature_activation()
        identifier = edit()
        if device.get_state() == NM.DeviceState.DISCONNECTED:
            choose(identifier)
        return identifier

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


def recover_chooser(app, client, device, network, choose, attempt, initial_settings, reject_premature):
    def owned():
        matches = [pr for pr in profiles(client) if pr.get_uuid() not in initial_settings
                   and ssid(pr.get_setting_wireless().get_ssid()) == network['ssid']]
        return matches[0] if len(matches) == 1 else None

    identifier = await_value(owned, 'failed-profile-not-found').get_uuid()

    def same_profiles():
        profile = owned()
        return profile and profile.get_uuid() == identifier and saved_settings(client, identifier) == initial_settings

    retry = await_value(lambda: password_dialog(app) or (
        'reselect' if device.get_state() == NM.DeviceState.DISCONNECTED else None),
        'failed-sae-neither-dialog-nor-disconnect', 30)
    prompt = 'automatic'
    if retry == 'reselect':
        prompt = 'reselected'
        choose()
        if attempt == 'blocked':
            try:
                await_value(lambda: password_dialog(app), 'no-second-dialog', 50)
            except ProbeError:
                reject_premature()
                if not same_profiles():
                    raise ProbeError('failed-retry-modified-profiles')
                print('WIFI_STOCK_RETRY reselected=1 second_password=0 seconds=50 same_uuid=1 '
                      'other_profiles_preserved=1', flush=True)
                return None
            raise ProbeError('stock-unexpectedly-reprompted')
        retry = await_value(lambda: password_dialog(app), 'password-dialog-did-not-open-on-retry', 50)
    if attempt == 'blocked':
        raise ProbeError('stock-unexpectedly-reprompted')
    reject_premature()
    if attempt == 'cancel':
        dialog = retry[0]
        while dialog.get_role() != Atspi.Role.DIALOG:
            dialog = dialog.get_parent()
        cancel = next((n for n in nodes(dialog) if n.get_role() == Atspi.Role.PUSH_BUTTON
                       and n.get_name() == 'Cancel' and showing(n)), None)
        if not cancel:
            raise ProbeError('retry-has-no-cancel-button')
        tap_node(cancel)
        await_value(lambda: not password_dialog(app) and device.get_state() == NM.DeviceState.DISCONNECTED,
                    'cancel-did-not-release-activation', 35)
        if not same_profiles():
            raise ProbeError('cancel-modified-profiles')
        print('WIFI_CANCEL disconnected=1 same_uuid=1 other_profiles_preserved=1', flush=True)
        choose()
        retry = await_value(lambda: password_dialog(app), 'retry-after-cancel-missing', 55)
    enter_password(*retry, network['correct'])
    return identifier, prompt


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
    if ONBOARD:
        gi.require_version('Gtk', '3.0')
        from gi.repository import Gtk
        Gtk.init([])
        if Gtk.Window().get_scale_factor() != 2:
            raise ProbeError('expected-product-gtk-scale-2')
        print('WIFI_ONBOARD_SEAT screen=2560x1600 gtk_scale=2', flush=True)
    devices = [dev for dev in client.get_devices()
               if isinstance(dev, NM.DeviceWifi) and dev.get_managed()]
    if len(devices) != 1:
        raise ProbeError('expected-one-managed-wifi-device')
    device = devices[0]
    before_profiles = {profile.get_uuid() for profile in profiles(client)}
    initial_settings = saved_settings(client) if mode == 'fixture' else {}
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
        if network['mode'] == 'sae':
            supplicant_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
            observe_sae_status(supplicant_bus)

    def access_points():
        aps = device.get_access_points()
        return (len(aps), {ssid(ap.get_ssid()) for ap in aps} - {None}) if aps else None

    await_value(access_points, 'networkmanager-has-no-visible-aps')
    app = await_value(lambda: application(applet_pid), 'applet-not-accessible')
    position = await_value(tray_position, 'no-embedded-applet-x11-icon', 35)
    tap(*position)
    if mode == 'fixture':
        print('WIFI_UI tray_tapped=1', flush=True)

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
        chooser_case = attempt in ('chooser', 'blocked', 'cancel')
        if attempt not in ('fresh', 'retry', 'editor', 'onboard') and not chooser_case:
            raise ProbeError('bad-fixture-attempt')
        target = next((row for row, label in rows if label == network['ssid']), None)
        if not target:
            raise ProbeError('owned-ap-missing-from-menu')
        tap_node(target)
        print('WIFI_UI access_point_selected=1', flush=True)
        edited_uuid = None
        if network['mode'] != 'open' and (attempt in ('retry', 'editor', 'onboard') or chooser_case):
            def choose_again(edited=None):
                def activating():
                    active = device.get_active_connection()
                    return edited and active and active.get_uuid() == edited and (
                        NM.DeviceState.PREPARE <= device.get_state() <= NM.DeviceState.ACTIVATED)

                def owned_item(root):
                    for n in nodes(root):
                        if n.get_role() not in (Atspi.Role.MENU_ITEM, Atspi.Role.CHECK_MENU_ITEM,
                                              Atspi.Role.RADIO_MENU_ITEM) or not showing(n):
                            continue
                        name = n.get_name() or ''
                        if name == network['ssid'] or name.startswith(network['ssid'] + ': '):
                            return n
                    return None

                tap(*await_value(tray_position, 'retry-tray-icon-missing', 25))
                if edited:
                    def primary_choice():
                        if activating():
                            return 'automatic', None
                        if item := owned_item(app):
                            return 'primary', item
                        if item := submenu():
                            return 'submenu', item
                        return None
                    action, menu = await_value(primary_choice, 'retry-applet-menu-missing')
                    if action == 'automatic':
                        print('WIFI_EDITOR reconnect=automatic', flush=True)
                        return
                    if action == 'primary':
                        tap_node(menu)
                        print('WIFI_EDITOR reconnect=primary-row', flush=True)
                        return
                else:
                    menu = await_value(submenu, 'retry-applet-menu-missing')
                tap_node(menu)
                def find_row():
                    if activating():
                        return 'automatic'
                    return owned_item(menu)
                try:
                    choice = await_value(find_row, 'retry-ap-row-missing', 18)
                except ProbeError:
                    if edited:
                        visible = any(ssid(ap.get_ssid()) == network['ssid'] for ap in device.get_access_points())
                        print(f'WIFI_EDITOR retry_state={int(device.get_state())} owned_ap_visible={int(visible)}',
                              flush=True)
                    raise
                if choice == 'automatic':
                    print('WIFI_EDITOR reconnect=automatic', flush=True)
                else:
                    tap_node(choice)
                    if edited:
                        print('WIFI_EDITOR reconnect=submenu-row', flush=True)

            edit = None
            if attempt in ('editor', 'onboard'):
                if network['mode'] != 'sae' or os.geteuid() == 0:
                    raise ProbeError('sae-editor-requires-ordinary-seat')
                edit = lambda: edit_failed_profile(client, network, before_profiles)
            recovery = None
            if chooser_case:
                recovery = lambda reject: recover_chooser(app, client, device, network, choose_again,
                                                          attempt, initial_settings, reject)
            result = verify_password_retry(app, device, transitions, network, choose_again, edit, recovery)
            if attempt == 'blocked':
                return
            if chooser_case:
                edited_uuid, prompt = result
            else:
                edited_uuid = result
        elif network['mode'] != 'open':
            dialog = await_value(lambda: password_dialog(app), 'secured-password-dialog-missing')
            enter_password(*dialog, network['correct'])

        def connected():
            ap = device.get_active_access_point()
            return (ap and ssid(ap.get_ssid()) == network['ssid'] and
                    device.get_state() == NM.DeviceState.ACTIVATED and device.get_ip4_config())

        ip = await_value(connected, 'owned-ap-did-not-activate', 30)
        if edited_uuid and device.get_active_connection().get_uuid() != edited_uuid:
            raise ProbeError('active-profile-not-edited-profile')
        if chooser_case:
            if saved_settings(client, edited_uuid) != initial_settings:
                raise ProbeError('chooser-modified-unrelated-profile')
            print(f'WIFI_CHOOSER_RECOVERY prompt={prompt} same_uuid=1 other_profiles_preserved=1', flush=True)
        if not any(address.get_address().startswith('192.0.2.') for address in ip.get_addresses()):
            raise ProbeError('fixture-dhcp-address-missing')
        if network['mode'] != 'open':
            setting = device.get_active_connection().get_connection().get_setting_wireless_security()
            if not setting or setting.get_key_mgmt() != {'wpa2': 'wpa-psk', 'sae': 'sae'}[network['mode']]:
                raise ProbeError('unexpected-negotiated-security')
            method = 'onboard' if ONBOARD else 'gtk-a11y'
            print(f'WIFI_SECURED_PASS security={network["mode"]} input={method} attempt={attempt}')
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
