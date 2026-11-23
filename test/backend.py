#!/usr/bin/env python3
"""Exercise the standalone Rust command boundary without Bluetooth hardware."""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "bin/omarchy-bluetooth-service"


_reply_buffers = {}


def receive(process):
    buffer = _reply_buffers.setdefault(process.pid, bytearray())
    deadline = time.monotonic() + 15
    while b"\n" not in buffer:
        readable, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        assert readable, "backend did not respond"
        chunk = os.read(process.stdout.fileno(), 4096)
        assert chunk, "backend closed its response stream"
        buffer.extend(chunk)
    line, _, rest = buffer.partition(b"\n")
    _reply_buffers[process.pid] = bytearray(rest)
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
        "bluetooth-device-action": '#!/bin/sh\nprintf "start:%s\\n" "$1" >> "$BT_TEST_LOG"\nif [ -n "$3" ]; then printf "path:%s\\n" "$3" >> "$BT_TEST_LOG"; fi\nif [ "$2" = "$BT_TEST_HOLD_ADDRESS" ]; then sleep 9; else sleep .15; fi\nprintf "end:%s\\n" "$1" >> "$BT_TEST_LOG"\n',
        "bluetooth-device-property": '#!/bin/sh\nexit 0\n',
        "audio-preferences": '#!/bin/sh\nprintf "policy\\n" >> "$BT_TEST_LOG"\nexit 0\n',
    }
    for name, contents in scripts.items():
        path = root / "scripts" / name
        path.write_text(contents)
        path.chmod(0o755)
    environment = dict(os.environ, BT_TEST_LOG=str(log),
                       XDG_RUNTIME_DIR=str(root),
                       BT_TEST_HOLD_ADDRESS="22:33:44:55:66:77")
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
        assert lines == ["start:connect", "end:connect", "start:disconnect", "end:disconnect"], lines
        device_path = "/org/bluez/hci1/dev_00_11_22_33_44_55"
        send(process, "path", "device.action", action="disconnect",
             address="00:11:22:33:44:55", path=device_path)
        assert receive(process)["result"]["outcome"] == "applied"
        assert "path:" + device_path in log.read_text().splitlines()
        for invalid_path in ("/org/bluez/hci1/dev_AA_BB_CC_DD_EE_FF",
                             "/org/bluez/hci1/../dev_00_11_22_33_44_55", 7):
            send(process, "bad-path", "device.action", action="connect",
                 address="00:11:22:33:44:55", path=invalid_path)
            assert receive(process)["error"]["code"] == "invalid_params"
        send(process, 9, "device.action", action="connect", address="00:11:22:33:44:55")
        deadline = time.monotonic() + 3
        while log.read_text().splitlines().count("start:connect") < 2:
            assert time.monotonic() < deadline, "holding action did not start"
            time.sleep(.01)
        send(process, 10, "device.action", action="pair", address="11:22:33:44:55:66")
        send(process, 11, "device.cancel", address="11:22:33:44:55:66", requestId="10")
        replies = {reply["id"]: reply for reply in (receive(process), receive(process), receive(process))}
        assert replies["11"]["result"]["outcome"] == "cancel_requested", replies
        assert replies["10"]["error"]["code"] == "cancelled", replies
        assert "start:pair" not in log.read_text(), log.read_text()
        for number in range(20, 60):
            send(process, number, "device.action", action="connect",
                 address="33:44:55:66:77:88")
        capacity = [receive(process) for _ in range(40)]
        assert sum(reply.get("error", {}).get("code") == "busy" for reply in capacity) >= 7, capacity
        assert sum(reply.get("result", {}).get("outcome") == "applied" for reply in capacity) <= 33, capacity
        send(process, 60, "device.action", action="connect", address="22:33:44:55:66:77")
        deadline = time.monotonic() + 3
        while "start:connect" not in log.read_text().splitlines()[-1:]:
            assert time.monotonic() < deadline, "holding action did not start"
            time.sleep(.01)
        send(process, 61, "policy.set", address="44:55:66:77:88:99", policy="output")
        deadline_replies = {reply["id"]: reply for reply in (receive(process), receive(process))}
        assert deadline_replies["61"]["error"]["code"] == "timeout", deadline_replies
        assert "policy" not in log.read_text().splitlines(), log.read_text()
        send(process, 7, "device.action", action="connect", address="not-an-address")
        assert receive(process)["error"]["code"] == "invalid_params"
        send(process, 70, "device.cancel", address="00:11:22:33:44:55", requestId=7)
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

    # Backend distinguishes clean cancellation (130) from failed cleanup (131).
    action_script = root / "scripts/bluetooth-device-action"
    action_script.write_text('''#!/bin/sh
if [ "$2" = "00:11:22:33:44:55" ]; then
  exit 130
elif [ "$2" = "11:22:33:44:55:66" ]; then
  echo "Could not disconnect the device: org.bluez.Error.Failed" >&2
  exit 131
fi
exit 0
''')
    action_script.chmod(0o755)
    with subprocess.Popen([root / "bin/omarchy-bluetooth-service", "--stdio"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, env=environment) as process:
        send(process, 1, "device.action", action="connect", address="00:11:22:33:44:55")
        cancelled = receive(process)
        assert cancelled["error"]["code"] == "cancelled" and cancelled["error"]["outcome"] == "rejected", cancelled
        send(process, 2, "device.action", action="connect", address="11:22:33:44:55:66")
        failed_cancel = receive(process)
        assert failed_cancel["error"]["code"] == "cancel_failed", failed_cancel
        assert failed_cancel["error"]["outcome"] == "unknown", failed_cancel
        assert "Could not disconnect" in failed_cancel["error"]["message"], failed_cancel
        process.stdin.close()
        assert process.wait(timeout=5) == 0

    # SIGTERM terminates and reaps running helpers with cleanup time,
    # and a replacement backend cannot finish a disconnect before the old connect ends.
    shutdown_log = root / "shutdown.log"
    action_script.write_text('''#!/bin/bash
printf 'start:%s\\n' "$1" >> "$BT_SHUTDOWN_LOG"
child=
trap 'if [[ -n $child ]]; then kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi; sleep .25; printf "cleanup:%s\\n" "$1" >> "$BT_SHUTDOWN_LOG"; exit 130' TERM INT
if [[ $1 == connect ]]; then
  sleep 10 &
  child=$!
  wait "$child"
else
  sleep .05
fi
printf 'end:%s\\n' "$1" >> "$BT_SHUTDOWN_LOG"
''')
    action_script.chmod(0o755)
    shutdown_env = dict(environment, BT_SHUTDOWN_LOG=str(shutdown_log))
    with subprocess.Popen([root / "bin/omarchy-bluetooth-service", "--stdio"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, env=shutdown_env) as first_backend:
        send(first_backend, 1, "device.action", action="connect", address="00:11:22:33:44:55")
        deadline = time.monotonic() + 3
        while not shutdown_log.exists() or "start:connect" not in shutdown_log.read_text():
            assert time.monotonic() < deadline, "slow connect helper did not start"
            time.sleep(.01)
        first_backend.terminate()
        with subprocess.Popen([root / "bin/omarchy-bluetooth-service", "--stdio"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, env=shutdown_env) as second_backend:
            send(second_backend, 1, "device.action", action="disconnect", address="00:11:22:33:44:55")
            reply = receive(second_backend)
            assert reply["result"]["outcome"] == "applied", reply
            second_backend.stdin.close()
            assert second_backend.wait(timeout=5) == 0
        assert first_backend.wait(timeout=5) == 0
    events = shutdown_log.read_text().splitlines()
    assert events == ["start:connect", "cleanup:connect", "start:disconnect", "end:disconnect"], events

print("PASS: Rust command service protocol, bounds, and serialization")
