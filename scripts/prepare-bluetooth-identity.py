"""Write the tablet's original, local Android adapter address to a private file."""

import argparse
import os
from pathlib import Path
import re
import tempfile


MAC = re.compile(r'(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')
PROPERTY = re.compile(r'^\[persist\.vendor\.service\.bdroid\.bdaddr\]:\s*\[([^]]*)\]$')


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
    if len(matches) != 1 or not MAC.fullmatch(matches[0]):
        raise ValueError('Expected one local address in the Android Adapter section.')
    address = matches[0]
    if address in {'00:00:00:00:00:00', 'FF:FF:FF:FF:FF:FF'}:
        raise ValueError('Android reported a placeholder adapter address.')
    return address


def cross_check(properties, address):
    values = [match[1].upper() for line in properties if (match := PROPERTY.fullmatch(line.strip()))]
    if values != [address]:
        raise ValueError('The TB320FC Android property and local adapter record disagree.')


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
    parser.add_argument('--android-config', type=Path, required=True, help="This tablet's bt_config.conf")
    parser.add_argument('--getprop', type=Path, help='Optional saved Android getprop output from the same tablet')
    parser.add_argument('--output', type=Path, required=True, help='New file inside a private directory')
    args = parser.parse_args()
    try:
        with args.android_config.open(encoding='utf-8-sig') as config:
            address = local_address(config)
        if args.getprop:
            with args.getprop.open(encoding='utf-8-sig') as props:
                cross_check(props, address)
        save_new(args.output, address)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    print('Prepared the local adapter identity.')


if __name__ == '__main__':
    main()
