#!/usr/bin/env python3
"""Exercise manual audio-default results through the long-lived QML service."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'bin/omarchy-bluetooth-service'

with tempfile.TemporaryDirectory(prefix='bluetooth-manual-audio-') as temporary:
    work = Path(temporary)
    for name in ('Service.qml', 'ManualAudioHarness.qml',
                 'BluetoothAudioPolicyEngine.qml', 'Model.js'):
        shutil.copy2(ROOT / name, work / name)
    (work / 'bin').mkdir()
    shutil.copy2(BINARY, work / 'bin/omarchy-bluetooth-service')
    environment = dict(os.environ, QT_QPA_PLATFORM='offscreen')
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'QT_QPA_PLATFORMTHEME'):
        environment.pop(key, None)
    result = subprocess.run(['quickshell', '-p', str(work / 'ManualAudioHarness.qml'),
                             '--no-color'], env=environment, capture_output=True,
                            text=True, timeout=15)
    output = result.stdout + result.stderr
    assert result.returncode == 0 and 'PASS: manual audio defaults' in output, output
    assert 'Cannot call method' not in output, output
    print('PASS: manual output rejection, partial input failure, unsaved preference and reload')
