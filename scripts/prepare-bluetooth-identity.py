"""Write the tablet's original, local Android adapter address to a private file."""

import argparse
import codecs
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile


MAC = re.compile(r'(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')
CACHE = 'persist.vendor.service.bdroid.bdaddr'
LENOVO = 'ro.odm.lenovo.btaddr'
MODEL = 'ro.product.vendor.model'
DEVICE = 'ro.product.vendor.device'
KEYS = (MODEL, DEVICE, LENOVO, CACHE)
PROPERTY = re.compile(r'^\[([^]]+)\]:\s*\[([^]]*)\]$')


def checked_address(value):
    address = value.upper()
    if not MAC.fullmatch(address):
        raise ValueError('Invalid Bluetooth adapter address format.')
    if address in {'00:00:00:00:00:00', 'FF:FF:FF:FF:FF:FF', '02:00:00:00:00:00'}:
        raise ValueError('Android reported a placeholder adapter address.')
    return address


def local_address(config):
    in_adapter = False
    matches = []
    for line in config:
        line = line.strip()
        if line.startswith('[') and line.endswith(']'):
            in_adapter = line.casefold() == '[adapter]'
        elif in_adapter:
            key, sep, value = line.partition('=')
            if sep and key.strip().casefold() == 'address':
                matches.append(value.strip().upper())
    if len(matches) != 1:
        raise ValueError('Expected one local address in the Android Adapter section.')
    return checked_address(matches[0])


def property_address(lines, adapter=None):
    properties = {}
    for line in lines:
        match = PROPERTY.fullmatch(line.strip())
        if match and match[1] in KEYS:
            if match[1] in properties:
                raise ValueError('Duplicate Bluetooth or board identity property.')
            properties[match[1]] = match[2]
    if adapter is None:
        if any(properties.get(key) != 'TB320FC' for key in (MODEL, DEVICE)):
            raise ValueError('Expected TB320FC Android vendor model and device properties.')
        if not properties.get(LENOVO):
            raise ValueError('The Lenovo adapter property is missing. Use the original Android Adapter record.')
    if not properties.get(CACHE):
        raise ValueError('The Android Bluetooth service address is missing.')
    cached = checked_address(properties[CACHE])
    if properties.get(LENOVO) and checked_address(properties[LENOVO]) != cached:
        raise ValueError('The Lenovo and Android Bluetooth service addresses disagree.')
    if adapter is not None and cached != adapter:
        raise ValueError('The Android Bluetooth service address and local adapter record disagree.')
    return cached


def adb_properties(serial):
    # Run all four reads on one selected device. Only fixed property names enter the shell.
    command = ('for p in ' + ' '.join(KEYS) +
               '; do printf "[%s]: [%s]\\n" "$p" "$(getprop "$p")"; done')
    result = subprocess.run(['adb', '-s', serial, 'shell', '-T', command],
                            capture_output=True, timeout=15, check=False)
    if result.returncode:
        raise ValueError('Could not read properties over ADB. Check the selected device and USB debugging authorization.')
    return result.stdout.decode('ascii').splitlines()


def saved_address(path, adapter=None):
    with path.open('rb') as raw:
        # Windows PowerShell 5 redirection produces UTF-16 with a BOM.
        utf16 = raw.peek(2).startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE))
        with io.TextIOWrapper(raw, encoding='utf-16' if utf16 else 'utf-8-sig') as rows:
            return property_address(rows, adapter)


def save_new(output, address):
    # Publish a complete 0600 file atomically, and never replace an existing identity.
    fd, name = tempfile.mkstemp(dir=output.parent, prefix='.y700-bt-')
    pending = Path(name)
    try:
        with os.fdopen(fd, 'wb') as stream:
            if os.name == 'posix' and os.fstat(stream.fileno()).st_mode & 0o077:
                raise ValueError('Choose a private Linux filesystem that enforces file permissions.')
            stream.write((address + '\n').encode('ascii'))
        os.link(pending, output)
    finally:
        pending.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-config', type=Path, help="This tablet's original bt_config.conf")
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument('--getprop', type=Path, help='Saved Android getprop output from this tablet')
    sources.add_argument('--adb-serial', help='Read four stock properties from this connected Android device')
    parser.add_argument('--output', type=Path, required=True, help='New file inside a private directory')
    args = parser.parse_args()
    if not (args.android_config or args.getprop or args.adb_serial):
        parser.error('Provide --getprop, --adb-serial or --android-config.')
    try:
        address = None
        if args.android_config:
            with args.android_config.open(encoding='utf-8-sig') as config:
                address = local_address(config)
        if args.getprop:
            address = saved_address(args.getprop, address)
        elif args.adb_serial:
            address = property_address(adb_properties(args.adb_serial), address)
        save_new(args.output, address)
    except subprocess.TimeoutExpired:
        parser.exit(1, 'The ADB property query timed out.\n')
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    print('Prepared the local adapter identity.')


if __name__ == '__main__':
    main()
