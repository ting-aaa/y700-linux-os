"""Compare reviewed CN350 GPU and sensor payloads without exporting proprietary bytes."""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def audit(stock, components):
    sensor = components / 'firmware/sensors'
    gpu = components / 'board-firmware/qcom'
    names = ['a730_sqe.fw', 'gmu_gen70000.bin', 'a730_zap.mdt', *[f'a730_zap.b{i:02}' for i in range(3)]]
    inputs = [('vendor.img', '/firmware/' + name, gpu / ('sm8475/lenovo/tb320fc' if 'zap' in name else '') / name)
              for name in names]
    # mdir supplies the stock file list independently of the local reference set.
    listing = subprocess.check_output(['mdir', '-b', '-i', stock / 'modem.img', '::/image/slpi*'], text=True)
    stock_slpi = {line.strip().split('/')[-1] for line in listing.splitlines() if line.strip()}
    if stock_slpi != {p.name for p in (sensor / 'firmware').iterdir()}:
        raise ValueError('Stock and reference SLPI file sets differ')
    inputs += [('modem.img', '/image/' + name, sensor / 'firmware' / name) for name in sorted(stock_slpi)]
    for name in ('fastrpc_shell_2', 'libsns_device_mode_skel.so', 'libsns_direct_channel_skel.so',
                 'libstabilitydomain_skel.so', 'libsysmon_skel.so', 'libsysmondomain_skel.so', 'libsysmonquery_skel.so'):
        inputs.append(('dsp.img', '/sdsp/' + name, sensor / 'dsp' / name))
    rows = []
    with tempfile.TemporaryDirectory() as temp:
        for index, (image, path, reference) in enumerate(inputs):
            dest = Path(temp) / str(index)
            if image == 'modem.img':
                subprocess.run(['mcopy', '-i', stock / image, '::' + path, dest], check=True)
            else:
                subprocess.run(['debugfs', '-R', f'dump {path} {dest}', stock / image], check=True, capture_output=True)
            if not dest.is_file() or not dest.stat().st_size:
                raise ValueError(f'Missing firmware {image}:{path}')
            current, other = digest(dest), digest(reference)
            rows.append(dict(image=image, path=path, stock_sha256=current, reference_sha256=other, identical=current == other))
    return dict(stock_images={name: digest(stock / name) for name in sorted({row['image'] for row in rows})}, files=rows)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stock', type=Path)
    parser.add_argument('components', type=Path)
    parser.add_argument('receipt', type=Path)
    args = parser.parse_args()
    result = audit(args.stock, args.components)
    with args.receipt.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    for image in result['stock_images']:
        rows = [row for row in result['files'] if row['image'] == image]
        print(f'{image}: {sum(row["identical"] for row in rows)}/{len(rows)} byte-identical')
