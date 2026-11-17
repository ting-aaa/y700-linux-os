"""Generate a private overlay, never modify a running host or a tablet.

Run with uv; output must be a new directory. No private SSH key is accepted.
"""
import argparse
import base64
import ipaddress
import re
import secrets
from pathlib import Path


def generate(destination, device, host, user, public_key):
    device = ipaddress.IPv4Interface(device)
    host = ipaddress.IPv4Address(host)
    network = device.network
    if (host not in network or host == device.ip or
            any(address in (network.network_address, network.broadcast_address)
                for address in (host, device.ip)) or network.prefixlen > 30):
        raise ValueError('Use two different usable host addresses in the same IPv4 subnet')
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,30}', user) or user == 'root':
        raise ValueError('A non-root local maintenance user is required')
    parts = public_key.strip().split()
    if len(parts) < 2 or parts[0] != 'ssh-ed25519':
        raise ValueError('Expected one OpenSSH ED25519 public key without options')
    wire = base64.b64decode(parts[1], validate=True)
    if len(wire) != 51 or wire[:19] != b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20':
        raise ValueError('Malformed ED25519 public key')
    destination = Path(destination)
    destination.mkdir(mode=0o700, parents=False, exist_ok=False)
    def write(path, value, mode=0o644):
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value, encoding='utf-8', newline='\n')
        target.chmod(mode)
    device_mac = '02:' + ':'.join(f'{b:02x}' for b in secrets.token_bytes(5))
    host_mac = '06:' + ':'.join(f'{b:02x}' for b in secrets.token_bytes(5))
    write('etc/y700/maintenance.env',
          f'USB_SERIAL=Y700_{secrets.token_hex(12)}\nDEVICE_MAC={device_mac}\n'
          f'HOST_MAC={host_mac}\nDEVICE_CIDR={device}\n', 0o600)
    write('etc/NetworkManager/conf.d/20-y700-maintenance.conf',
          f'[keyfile]\nunmanaged-devices=mac:{device_mac}\n')
    write('etc/y700/maintenance-authorized-keys',
          f'restrict,from="{host}" {parts[0]} {parts[1]}\n')
    write('etc/y700/maintenance-sshd.conf',
          f'ListenAddress {device.ip}\nPort 22\nAddressFamily inet\n'
          'HostKey /var/lib/y700/ssh/ssh_host_ed25519_key\n'
          'AuthorizedKeysFile /etc/y700/maintenance-authorized-keys\n'
          f'AllowUsers {user}@{host}\n'
          'PermitRootLogin no\nPasswordAuthentication no\n'
          'KbdInteractiveAuthentication no\nPubkeyAuthentication yes\n'
          'AuthenticationMethods publickey\nUsePAM yes\nStrictModes yes\n'
          'DisableForwarding yes\nX11Forwarding no\nPermitTunnel no\n'
          'PermitUserEnvironment no\nSubsystem sftp internal-sftp\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device-cidr', required=True)
    parser.add_argument('--host-address', required=True)
    parser.add_argument('--user', required=True)
    parser.add_argument('--public-key', type=Path, required=True)
    args = parser.parse_args()
    generate(args.output, args.device_cidr, args.host_address, args.user,
             args.public_key.read_text())
    print('Private overlay created; no service started and no device contacted.')
