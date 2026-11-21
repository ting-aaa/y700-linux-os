"""Verify the released Qt chooser without physical devices or starting a camera."""
import os
from pathlib import Path
import runpy

probe = runpy.run_path('/qa/board-chooser.py')
fixtures = probe['fixture']
lenses = ('main', 'front', 'macro')
log = Path(os.environ['XDG_RUNTIME_DIR']) / 'qcam-test.log'
os.environ.update(QT_SCALE_FACTOR='2', QT_LINUX_ACCESSIBILITY_ALWAYS_ON='1',
                  LIBCAMERA_PIPELINES_MATCH_LIST='virtual', LIBCAMERA_LOG_FILE=str(log),
                  LD_PRELOAD=':'.join('/qa/lib/' + f for f in
                                      ('libyuv.so.0', 'libcamera-base.so.0.7.2', 'libcamera.so.0.7.2')))
for locale, names in [('C.UTF-8', [fixtures['CAMERAS'][lens][1] for lens in lenses]),
                      ('zh_CN.UTF-8', [fixtures['CHINESE_NAMES'][lens] for lens in lenses])]:
    probe['inspect_chooser'](locale, names, True)
    trace = log.read_text()
    assert 'configuring streams' not in trace and 'Starting capture' not in trace
print('DEV1213_QCAM released_binary=1 synthetic_lenses=3 rear_default=2 locales=en,zh '
      'cancellations=2 streams=0 physical_devices=0')
