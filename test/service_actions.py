#!/usr/bin/env python3
"""Run the real shared QML service with a disposable widget and fake helper."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'bin/omarchy-bluetooth-service'

with tempfile.TemporaryDirectory(prefix='bluetooth-service-actions-') as temporary:
    work = Path(temporary)
    for name in ('Service.qml', 'ServiceActionHarness.qml',
                 'BluetoothAudioPolicyEngine.qml', 'Model.js'):
        shutil.copy2(ROOT / name, work / name)
    (work / 'bin').mkdir()
    (work / 'scripts').mkdir()
    shutil.copy2(BINARY, work / 'bin/omarchy-bluetooth-service')
    helper = work / 'scripts/bluetooth-device-action'
    helper.write_text('#!/bin/sh\nsleep .3\nexit 0\n')
    helper.chmod(0o755)
    environment = dict(os.environ, QT_QPA_PLATFORM='offscreen')
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'QT_QPA_PLATFORMTHEME'):
        environment.pop(key, None)
    result = subprocess.run(['quickshell', '-p', str(work / 'ServiceActionHarness.qml'),
                             '--no-color'], env=environment, capture_output=True,
                            text=True, timeout=15)
    output = result.stdout + result.stderr
    assert result.returncode == 0 and 'PASS: service owns completion' in output, output
    assert 'Cannot call method' not in output, output
    print('PASS: shared service completes forget after widget destruction')
