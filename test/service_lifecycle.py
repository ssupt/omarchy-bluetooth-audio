#!/usr/bin/env python3
"""Run shared-service lifecycle fixtures independently of live Bluetooth devices."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'bin/omarchy-bluetooth-service'
SCENARIOS = (
    ('ServiceHarness.qml', 'PASS: shell service restart and panel handoff'),
    ('ServiceActionHarness.qml', 'PASS: service owns completion'),
    ('ManualAudioHarness.qml', 'PASS: manual audio defaults'),
)

for fixture, expected in SCENARIOS:
    with tempfile.TemporaryDirectory(prefix='bluetooth-lifecycle-') as temporary:
        work = Path(temporary)
        for name in ('Service.qml', 'BluetoothAudioPolicyEngine.qml', 'Model.js'):
            shutil.copy2(ROOT / name, work / name)
        shutil.copy2(ROOT / 'test/fixtures' / fixture, work / fixture)
        (work / 'bin').mkdir()
        shutil.copy2(BINARY, work / 'bin/omarchy-bluetooth-service')
        (work / 'scripts').mkdir()
        helper = work / 'scripts/bluetooth-device-action'
        helper.write_text('#!/bin/sh\nsleep .3\nexit 0\n')
        helper.chmod(0o755)
        env = dict(os.environ, QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=temporary,
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_STATE_HOME=str(work / 'state'),
                   XDG_CACHE_HOME=str(work / 'cache'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(work / 'absent-bus'))
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'QT_QPA_PLATFORMTHEME'):
            env.pop(key, None)
        result = subprocess.run(['quickshell', '-p', str(work / fixture), '--no-color'],
                                env=env, capture_output=True, text=True, timeout=20)
        output = result.stdout + result.stderr
        assert result.returncode == 0 and expected in output, output
        assert not any(error in output for error in ('TypeError:', 'ReferenceError:')), output
        print(next(line.strip() for line in output.splitlines() if expected in line))
