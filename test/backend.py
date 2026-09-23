#!/usr/bin/env python3
"""Exercise the standalone Rust command boundary without Bluetooth hardware."""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "bin/omarchy-bluetooth-service"


def receive(process):
    readable, _, _ = select.select([process.stdout], [], [], 5)
    assert readable, "backend did not respond"
    line = process.stdout.readline()
    assert line, "backend closed its response stream"
    return json.loads(line)


def send(process, number, method, **params):
    process.stdin.write(json.dumps(dict(version=1, id=str(number), method=method, params=params)) + "\n")
    process.stdin.flush()


with tempfile.TemporaryDirectory(prefix="bluetooth-service-test-") as temporary:
    root = Path(temporary)
    (root / "bin").mkdir()
    (root / "scripts").mkdir()
    shutil.copy2(BINARY, root / "bin/omarchy-bluetooth-service")
    log = root / "operations.log"
    scripts = {
        "bluetooth-audio-profiles": '#!/bin/sh\nprintf \'{"card":{}}\\n\'\n',
        "bluetooth-audio-profile-set": '#!/bin/sh\necho "saved preference failed" >&2\nexit 2\n',
        "bluetooth-device-action": '#!/bin/sh\nprintf "start:%s\\n" "$1" >> "$BT_TEST_LOG"\nsleep .15\nprintf "end:%s\\n" "$1" >> "$BT_TEST_LOG"\n',
        "bluetooth-device-property": '#!/bin/sh\nexit 0\n',
        "audio-preferences": '#!/bin/sh\nexit 0\n',
    }
    for name, contents in scripts.items():
        path = root / "scripts" / name
        path.write_text(contents)
        path.chmod(0o755)
    environment = dict(os.environ, BT_TEST_LOG=str(log))
    with subprocess.Popen([root / "bin/omarchy-bluetooth-service", "--stdio"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, env=environment) as process:
        send(process, 1, "hello")
        hello = receive(process)
        assert hello["result"]["name"] == "omarchy-bluetooth-service"
        send(process, 2, "profile.list")
        assert receive(process)["result"] == {"card": {}}
        send(process, 3, "profile.set", address="00:11:22:33:44:55", profile="headset")
        assert receive(process)["result"]["outcome"] == "persistence_failed"
        send(process, 4, "device.property", property="name",
             path="/org/bluez/hci0/dev_00_11_22_33_44_55", value="")
        assert receive(process)["result"]["outcome"] == "applied"
        send(process, 5, "device.action", action="connect", address="00:11:22:33:44:55")
        send(process, 6, "device.action", action="disconnect", address="00:11:22:33:44:55")
        assert {receive(process)["id"], receive(process)["id"]} == {"5", "6"}
        lines = log.read_text().splitlines()
        assert lines in (["start:connect", "end:connect", "start:disconnect", "end:disconnect"],
                         ["start:disconnect", "end:disconnect", "start:connect", "end:connect"]), lines
        send(process, 7, "device.action", action="connect", address="not-an-address")
        assert receive(process)["error"]["code"] == "invalid_params"
        inventory = root / "scripts/bluetooth-audio-profiles"
        inventory.write_text("#!/bin/sh\nhead -c 140000 /dev/zero\n")
        send(process, 8, "profile.list")
        assert receive(process)["error"]["code"] == "too_large"
        process.stdin.close()
        assert process.wait(timeout=5) == 0, process.stderr.read()

    oversized = subprocess.run([root / "bin/omarchy-bluetooth-service", "--stdio"],
                               input="x" * 70000 + "\n", capture_output=True,
                               text=True, timeout=5, env=environment)
    assert oversized.returncode != 0 and not oversized.stdout

print("PASS: Rust command service protocol, bounds, and serialization")
