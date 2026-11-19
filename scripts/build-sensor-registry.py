"""Build only SSC defaults from pinned upstream; no firmware/device access.

Run through uv. Output is a private build input, not a distributable sensor
driver or a copy of calibration from a running device.
"""
import argparse
import hashlib
import importlib.util
import json
import subprocess
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
pin = json.loads((repo/'upstream.lock.json').read_text())['asphalt']
upstream = repo/pin['path']


def build(output, upstream=upstream):
    head = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(upstream), 'status', '--porcelain'], text=True)
    if head != pin['commit'] or dirty:
        raise ValueError('Sensor inputs require the exact clean pinned upstream checkout')
    source = upstream/'pkgs/asphalt/sensors/config'
    generator = upstream/'pkgs/mobile/ssc-registry/generate.py'
    spec = importlib.util.spec_from_file_location('ssc_registry', generator)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.generate(source, output, 'MTP', '531', '7')
    inputs = [generator, *sorted(source.glob('*.json'))]
    outputs = sorted(path for path in output.rglob('*') if path.is_file())
    def hashes(paths, relative_to):
        return {p.relative_to(relative_to).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in paths}
    receipt = {'format': 1, 'asphalt_commit': head,
               'selectors': {'platform': 'MTP', 'soc_id': '531', 'registry_version': '7'},
               'scope': 'build-only; defaults selection is not live sensor identification',
               'inputs': hashes(inputs, upstream), 'outputs': hashes(outputs, output)}
    (output/'build-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
    print(f'Built {len(outputs)} sensor registry files; firmware and native SSC stack still required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--asphalt-checkout', type=Path, default=upstream)
    args = parser.parse_args()
    build(args.output, args.asphalt_checkout)
