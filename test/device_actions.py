#!/usr/bin/env python3
"""Check controller-specific device actions without touching Bluetooth hardware."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ADDRESS = "00:11:22:33:44:55"
DEVICE = "/org/bluez/hci1/dev_00_11_22_33_44_55"
ADAPTER = "/org/bluez/hci1"

with tempfile.TemporaryDirectory(prefix="bluetooth-device-actions-") as temporary:
    log = Path(temporary) / "calls"
    environment = dict(os.environ, PATH=str(ROOT / "test/mocks") + ":" + os.environ["PATH"],
                       BLUETOOTH_ACTION_LOG=str(log))

    def run(action, path=DEVICE, **overrides):
        log.write_text("")
        arguments = [str(ROOT / "scripts/bluetooth-device-action"), action, ADDRESS]
        if path is not None:
            arguments.append(path)
        result = subprocess.run(arguments, env=dict(environment, **overrides),
                                capture_output=True, text=True, timeout=10)
        return result, log.read_text().splitlines()

    result, calls = run("pair")
    assert result.returncode == 0, result.stderr
    assert calls == [
        f"get-property org.bluez {ADAPTER} org.bluez.Adapter1 Powered",
        f"get-property org.bluez {DEVICE} org.bluez.Device1 Blocked",
        f"call org.bluez {DEVICE} org.bluez.Device1 Pair",
        f"set-property org.bluez {DEVICE} org.bluez.Device1 Trusted b true",
        f"call org.bluez {DEVICE} org.bluez.Device1 Connect",
    ], calls
    result, calls = run("connect", BLUETOOTH_ACTION_BUS_BLOCKED="true")
    assert result.returncode != 0 and "blocked" in result.stderr, (result, calls)
    assert not any(" call " in " " + call + " " for call in calls), calls

    result, calls = run("forget", BLUETOOTH_ACTION_BUS_POWERED="false",
                        BLUETOOTH_ACTION_POWER_FAIL="1",
                        BLUETOOTH_ACTION_BUS_FAIL_METHOD="Disconnect")
    assert result.returncode == 0, result.stderr
    assert calls == [
        f"call org.bluez {DEVICE} org.bluez.Device1 Disconnect",
        f"call org.bluez {ADAPTER} org.bluez.Adapter1 RemoveDevice o {DEVICE}",
    ], calls
    for path in (None, DEVICE):
        result, _ = run("forget", path=path,
                        BLUETOOTH_ACTION_FAIL_COMMAND="remove",
                        BLUETOOTH_ACTION_BUS_FAIL_METHOD="RemoveDevice",
                        BLUETOOTH_ACTION_FAIL_MESSAGE=f"Device {ADDRESS} not available")
        assert result.returncode != 0, "Unavailable device was reported as forgotten"
    result, calls = run("connect", path="/org/bluez/hci1/dev_AA_BB_CC_DD_EE_FF")
    assert result.returncode != 0 and not calls, (result, calls)
    result, _ = run("pair", BLUETOOTH_ACTION_BUS_FAIL_METHOD="Pair",
                    BLUETOOTH_ACTION_FAIL_MESSAGE="Call failed: Authentication Rejected")
    assert result.returncode != 0 and "Pairing was rejected" in result.stderr, result

    for action, method in (("connect", "Connect"), ("pair", "Pair")):
        log.write_text("")
        with subprocess.Popen([str(ROOT / "scripts/bluetooth-device-action"), action,
                               ADDRESS, DEVICE],
                              env=dict(environment, BLUETOOTH_ACTION_BUS_DELAY_METHOD=method,
                                       BLUETOOTH_ACTION_DELAY_SECONDS="10"),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            deadline = time.monotonic() + 3
            while f"org.bluez.Device1 {method}" not in log.read_text():
                assert time.monotonic() < deadline, "Connection helper did not start"
                time.sleep(.01)
            cancelled_at = time.monotonic()
            process.terminate()
            process.communicate(timeout=4)
            assert process.returncode != 0 and time.monotonic() - cancelled_at < 4
            calls = log.read_text().splitlines()
            assert calls[-1] == f"call org.bluez {DEVICE} org.bluez.Device1 Disconnect", calls
            if action == "pair":
                assert calls[-2] == f"call org.bluez {DEVICE} org.bluez.Device1 CancelPairing", calls
                assert not any(" Trusted " in call or call.endswith(" Connect") for call in calls), calls

print("PASS: controller-specific actions preserve ownership, reject unconfirmed removal, and cancel promptly")
