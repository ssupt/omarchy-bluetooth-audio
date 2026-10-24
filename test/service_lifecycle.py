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
SCENARIOS = tuple((fixture, expected, 130) for fixture, expected in (
    ('ServiceHarness.qml', 'PASS: shell service restart and panel handoff'),
    ('ServiceActionHarness.qml', 'PASS: service owns completion'),
    ('ManualAudioHarness.qml', 'PASS: manual audio defaults'),
    ('ServiceConnectionHarness.qml', 'PASS: connection replacement'),
)) + (('ServiceConnectionHarness.qml', 'PASS: connection replacement', 0),)

for fixture, expected, cancel_status in SCENARIOS:
    with tempfile.TemporaryDirectory(prefix='bluetooth-lifecycle-') as temporary:
        work = Path(temporary)
        for name in ('Service.qml', 'BluetoothAudioPolicyEngine.qml', 'Model.js'):
            shutil.copy2(ROOT / name, work / name)
        shutil.copy2(ROOT / 'test/fixtures' / fixture, work / fixture)
        (work / 'bin').mkdir()
        shutil.copy2(BINARY, work / 'bin/omarchy-bluetooth-service')
        (work / 'scripts').mkdir()
        helper = work / 'scripts/bluetooth-device-action'
        if fixture == 'ServiceConnectionHarness.qml':
            helper.write_text('''#!/bin/bash
printf 'start:%s:%s\\n' "$1" "$2" >> "$BT_TEST_LOG"
child=
cancel() {
  trap - TERM INT
  if [[ -n $child ]]; then kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
  sleep .15
  exit "$BT_TEST_CANCEL_STATUS"
}
trap cancel TERM INT
if [[ $2 == 00:11:22:33:44:55 && ( $1 == connect || $1 == pair ) ]]; then sleep 10 & else sleep .1 & fi
child=$!
wait "$child"
''')
        else:
            helper.write_text('#!/bin/sh\nsleep .3\nexit 0\n')
        helper.chmod(0o755)
        env = dict(os.environ, QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=temporary,
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_STATE_HOME=str(work / 'state'),
                   XDG_CACHE_HOME=str(work / 'cache'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(work / 'absent-bus'),
                   BT_TEST_LOG=str(work / 'actions.log'),
                   BT_TEST_CANCEL_STATUS=str(cancel_status))
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'QT_QPA_PLATFORMTHEME'):
            env.pop(key, None)
        result = subprocess.run(['quickshell', '-p', str(work / fixture), '--no-color'],
                                env=env, capture_output=True, text=True, timeout=20)
        output = result.stdout + result.stderr
        assert result.returncode == 0 and expected in output, output
        assert not any(error in output for error in ('TypeError:', 'ReferenceError:')), output
        if fixture == 'ServiceConnectionHarness.qml':
            calls = (work / 'actions.log').read_text().splitlines()
            assert not any(line.endswith(':11:22:33:44:55:66') for line in calls), calls
            assert calls.count('start:connect:22:33:44:55:66:77') == 2, calls
            if cancel_status == 0:
                assert calls.count('start:disconnect:00:11:22:33:44:55') == 6, calls
        print(next(line.strip() for line in output.splitlines() if expected in line)
              + (' (completion race)' if cancel_status == 0 else ''))
