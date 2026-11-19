"""Validate the optional camera development layer before installation or image assembly."""

import json
import re
from pathlib import Path


CONFIG = Path(__file__).resolve().parents[1] / 'config'
DEFAULT_LOCK = CONFIG / 'camera-layer.lock.json'
RECEIPT = Path('var/lib/y700/build/camera-layer.lock.json')
RUNTIME = 'y700-camera-runtime'
FIELDS = ('package', 'version', 'architecture', 'size', 'sha256')


def fields(package):
    return {key: package[key] for key in FIELDS}


def load_camera_lock(path):
    return validate_camera_lock(json.loads(path.read_text()))


def validate_camera_lock(lock):
    authenticated = json.loads((CONFIG / 'camera-debian-auth.lock.json').read_text())
    if (not authenticated['repository_signature_chain_revalidated'] or authenticated['unmatched']
            or authenticated['authenticated_count'] != 6):
        raise ValueError('The camera Debian dependency provenance is incomplete')
    packages = lock['packages']
    entries = {item['package']: fields(item) for item in packages}
    if lock['format'] != 1 or len(packages) != 7 or len(entries) != 7 or RUNTIME not in entries:
        raise ValueError('The camera layer requires exactly seven distinct packages')

    runtime = entries.pop(RUNTIME)
    defaults = json.loads(DEFAULT_LOCK.read_text())['packages']
    pinned_runtime = next(item for item in defaults if item['package'] == RUNTIME)
    if (runtime['version'] != pinned_runtime['version'] or runtime['architecture'] != 'arm64'
            or type(runtime['size']) is not int or runtime['size'] <= 0
            or not re.fullmatch(r'[0-9a-f]{64}', runtime['sha256'])):
        raise ValueError('Use a reviewed camera runtime archive for the pinned ARM64 version')
    expected = {item['package']: fields(item) for item in authenticated['packages']}
    if entries != expected:
        raise ValueError('Camera Debian dependencies differ from the authenticated archives')

    return sorted([runtime, *entries.values()], key=lambda item: item['package'])
