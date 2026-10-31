#!/usr/bin/env python3
"""Exercise the real watcher with failed, replaced, and empty rfkill streams."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import time
log = Path(os.environ['RFKILL_START_LOG'])
starts = len(log.read_text().splitlines()) if log.exists() else 0
with log.open('a') as stream:
    stream.write('start\n')
scenario = os.environ['RFKILL_SCENARIO']
if scenario == 'cap':
    raise SystemExit(1)
if starts == 0:
    print('idx 2 type 2 op 0 soft 1 hard 0', flush=True)
    if scenario in ('recover', 'empty'):
        time.sleep(.15)
        raise SystemExit(1)
elif scenario == 'recover':
    if starts == 1:
        # A second failure before the device can even be read must preserve
        # the last state and increase the retry delay.
        raise SystemExit(1)
    print('idx 3 type 2 op 0 soft 1 hard 1', flush=True)
elif scenario == 'adapter':
    print('idx 4 type 2 op 0 soft 1 hard 0', flush=True)
while True:
    time.sleep(1)
'''

for scenario, expected_starts in (('recover', 3), ('empty', 2), ('cap', 1), ('adapter', 2)):
    with tempfile.TemporaryDirectory(prefix='rfkill-test-') as temporary:
        work = Path(temporary)
        for name in ('RfkillMonitor.qml', 'Model.js'):
            shutil.copy2(ROOT / name, work / name)
        shutil.copy2(ROOT / 'test/fixtures/RfkillMonitorHarness.qml', work / 'shell.qml')
        (work / 'bin').mkdir()
        helper = work / 'bin/rfkill'
        helper.write_text(MOCK)
        helper.chmod(0o755)
        env = dict(os.environ, PATH=str(work / 'bin') + ':' + os.environ['PATH'],
                   RFKILL_SCENARIO=scenario, RFKILL_START_LOG=str(work / 'starts'),
                   QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=temporary,
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_STATE_HOME=str(work / 'state'),
                   XDG_CACHE_HOME=str(work / 'cache'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(work / 'absent-bus'))
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'QT_QPA_PLATFORMTHEME'):
            env.pop(key, None)
        result = subprocess.run(['quickshell', '-p', str(work / 'shell.qml'), '--no-color'],
                                env=env, capture_output=True, text=True, timeout=12)
        output = result.stdout + result.stderr
        expected = 'PASS: rfkill monitor ' + scenario
        assert result.returncode == 0 and expected in output, output
        assert not any(error in output for error in ('TypeError:', 'ReferenceError:')), output
        starts = (work / 'starts').read_text().splitlines()
        assert len(starts) == expected_starts, (scenario, starts, output)
        print(expected)
