#!/usr/bin/python3
"""Y700 orientation bridge. Default to observing monitor-sensor in a terminal.

Xfce starts --session, which follows the user's rotation preference and active
login. The display helper updates panel and touch coordinates together.
"""
import argparse
import os
import re
import selectors
import signal
import subprocess
import time
from pathlib import Path

ROTATIONS = {'normal': 'normal', 'left-up': 'left',
             'bottom-up': 'inverted', 'right-up': 'right'}
EVENT = re.compile(r'orientation(?: changed)?: ([a-z-]+)(?:, tilt: [a-z-]+)?\)?\s*$')


class OrientationPolicy:
    def __init__(self, settle=0.8):
        self.settle = settle
        self.candidate = None
        self.since = 0.0
        self.applied = None

    def observe(self, orientation, now):
        value = ROTATIONS.get(orientation)
        if value != self.candidate:
            self.candidate, self.since = value, now

    def due(self, now, locked=False):
        if locked:
            # Unlock must receive a fresh event; do not jump to a stale pose.
            self.candidate = None
            self.applied = None
            return None
        if (self.candidate and self.candidate != self.applied and
                now - self.since >= self.settle):
            return self.candidate
        return None

    def complete(self, rotation, success, now):
        if success:
            self.applied = rotation
        else:
            self.since = now  # Bound retries after X11/touch failures.


def monitor_event(policy, line, now):
    if line.startswith(('--- iio-sensor-proxy vanished', '=== No accelerometer')):
        policy.due(now, locked=True)
        return
    match = EVENT.search(line)
    if match:
        policy.observe(match[1], now)


def run(apply, lock_file, settle):
    if apply and (not os.environ.get('DISPLAY') or
                  os.environ.get('XDG_SESSION_TYPE', 'x11') != 'x11'):
        raise RuntimeError('--apply requires an active X11 desktop session')
    policy = OrientationPolicy(settle)
    process = subprocess.Popen(['stdbuf', '-oL', 'monitor-sensor', '--accel'],
                               stdout=subprocess.PIPE, env={**os.environ, 'LC_ALL': 'C'})
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = b''
    try:
        while True:
            for key, _ in selector.select(timeout=0.1):
                chunk = os.read(key.fd, 4096)
                if not chunk:
                    # Loss of the sensor provider never applies a pending pose.
                    return process.wait()
                pending += chunk
                if len(pending) > 65536:
                    raise RuntimeError('Oversized sensor output')
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    monitor_event(policy, line.decode('utf-8', errors='replace'), time.monotonic())
            now = time.monotonic()
            rotation = policy.due(now, lock_file.exists())
            if rotation:
                success = True
                if apply:
                    success = subprocess.run(['y700-display', '--rotate', rotation],
                                             check=False).returncode == 0
                print(f'{"apply" if apply else "observe"}: {rotation}; success={success}', flush=True)
                policy.complete(rotation, success, now)
    finally:
        selector.close()
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true')
    mode.add_argument('--session', action='store_true', help='follow the Xfce rotation preference')
    parser.add_argument('--settle', type=float, default=0.8)
    parser.add_argument('--lock-file', type=Path,
                        default=Path(os.environ.get('XDG_RUNTIME_DIR', str(Path.home()/'.cache')))/'y700-rotation-locked')
    args = parser.parse_args()
    if not 0.2 <= args.settle <= 10:
        parser.error('--settle must be between 0.2 and 10 seconds')
    if args.session:
        if not os.environ.get('DISPLAY') or os.environ.get('XDG_SESSION_TYPE', 'x11') != 'x11':
            raise SystemExit(0)
        from rotation_session import run_session
        raise SystemExit(run_session(OrientationPolicy(args.settle)))
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        raise SystemExit(run(args.apply, args.lock_file, args.settle))
    except KeyboardInterrupt:
        raise SystemExit(130)
