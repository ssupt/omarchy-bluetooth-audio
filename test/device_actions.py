#!/usr/bin/env python3
"""Check controller-specific device actions without touching Bluetooth hardware."""
import os
from pathlib import Path
import shutil
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
                       XDG_RUNTIME_DIR=temporary,
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
        f"get-property org.bluez {DEVICE} org.bluez.Device1 Bonded",
        f"set-property org.bluez {DEVICE} org.bluez.Device1 Trusted b true",
        f"call org.bluez {DEVICE} org.bluez.Device1 Connect",
    ], calls

    # Ordinary reconnects must preserve existing Trust instead of re-enabling it.
    result, calls = run("connect")
    assert result.returncode == 0, result.stderr
    assert calls == [
        f"get-property org.bluez {ADAPTER} org.bluez.Adapter1 Powered",
        f"get-property org.bluez {DEVICE} org.bluez.Device1 Blocked",
        f"call org.bluez {DEVICE} org.bluez.Device1 Connect",
    ], calls

    # Pairing without a saved bond must not enable Trust, even if Paired=true.
    result, calls = run("pair", BLUETOOTH_ACTION_BUS_BONDED="false",
                        BLUETOOTH_ACTION_BUS_PAIRED="true")
    assert result.returncode == 0, result.stderr
    assert not any(" Paired" in call or " Trusted " in call for call in calls), calls

    # A timeout or D-Bus error reading Bonded must not fall back to Paired=true
    # and grant Trust without positive bond evidence.
    for bonded_mode in ("timeout", "error"):
        result, calls = run("pair", BLUETOOTH_ACTION_BUS_BONDED=bonded_mode,
                            BLUETOOTH_ACTION_BUS_PAIRED="true")
        assert result.returncode == 0, (bonded_mode, result.stderr)
        assert not any(" Paired" in call or " Trusted " in call for call in calls), (bonded_mode, calls)

    # Older BlueZ without Device1.Bonded falls back to Paired only when BlueZ
    # reports that the Bonded property does not exist.
    for missing_mode in ("missing", "no_such_property"):
        result, calls = run("pair", BLUETOOTH_ACTION_BUS_BONDED=missing_mode,
                            BLUETOOTH_ACTION_BUS_PAIRED="true")
        assert result.returncode == 0, (missing_mode, result.stderr)
        assert any(" Paired" in call for call in calls), (missing_mode, calls)
        assert any(" Trusted b true" in call for call in calls), (missing_mode, calls)
    result, calls = run("pair", BLUETOOTH_ACTION_BUS_BONDED="no_such_property",
                        BLUETOOTH_ACTION_BUS_PAIRED="false")
    assert result.returncode == 0, result.stderr
    assert any(" Paired" in call for call in calls), calls
    assert not any(" Trusted " in call for call in calls), calls
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
            assert process.returncode == 130 and time.monotonic() - cancelled_at < 4
            calls = log.read_text().splitlines()
            assert calls[-1] == f"call org.bluez {DEVICE} org.bluez.Device1 Disconnect", calls
            if action == "pair":
                assert calls[-2] == f"call org.bluez {DEVICE} org.bluez.Device1 CancelPairing", calls
                assert not any(" Trusted " in call or call.endswith(" Connect") for call in calls), calls

    # Distinguish already-disconnected (130) from a failed cleanup disconnect (131).
    for fail_message, expected_rc in (
        ("Call failed: org.bluez.Error.NotConnected", 130),
        ("Call failed: org.bluez.Error.Failed", 131),
    ):
        log.write_text("")
        with subprocess.Popen([str(ROOT / "scripts/bluetooth-device-action"), "connect",
                               ADDRESS, DEVICE],
                              env=dict(environment, BLUETOOTH_ACTION_BUS_DELAY_METHOD="Connect",
                                       BLUETOOTH_ACTION_DELAY_SECONDS="10",
                                       BLUETOOTH_ACTION_BUS_FAIL_METHOD="Disconnect",
                                       BLUETOOTH_ACTION_FAIL_MESSAGE=fail_message),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            deadline = time.monotonic() + 3
            while "org.bluez.Device1 Connect" not in log.read_text():
                assert time.monotonic() < deadline, "Connection helper did not start"
                time.sleep(.01)
            process.terminate()
            _, stderr = process.communicate(timeout=4)
            assert process.returncode == expected_rc, (fail_message, process.returncode, stderr)
            if expected_rc == 131:
                assert "Could not disconnect" in stderr, stderr

    # Cancelling while powering the adapter on (before Connect is called) must
    # exit cleanly (130) without calling Disconnect on an unpowered adapter.
    log.write_text("")
    with subprocess.Popen([str(ROOT / "scripts/bluetooth-device-action"), "connect",
                           ADDRESS, DEVICE],
                          env=dict(environment, BLUETOOTH_ACTION_BUS_POWERED="false",
                                   BLUETOOTH_ACTION_POWER_DELAY="10",
                                   BLUETOOTH_ACTION_BUS_FAIL_METHOD="Disconnect",
                                   BLUETOOTH_ACTION_FAIL_MESSAGE="Call failed: org.bluez.Error.NotReady"),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        deadline = time.monotonic() + 3
        while "power on" not in log.read_text():
            assert time.monotonic() < deadline, "Power helper did not start"
            time.sleep(.01)
        process.terminate()
        _, stderr = process.communicate(timeout=4)
        assert process.returncode == 130, (process.returncode, stderr)
        calls = log.read_text().splitlines()
        assert not any("Disconnect" in call for call in calls), calls

    # Combined AuthenticationFailed + Key Missing must report missing pairing key.
    result, _ = run("connect", BLUETOOTH_ACTION_BUS_FAIL_METHOD="Connect",
                    BLUETOOTH_ACTION_FAIL_MESSAGE="Call failed: org.bluez.Error.AuthenticationFailed: Key Missing")
    assert result.returncode != 0 and "pairing key is missing" in result.stderr, result.stderr

    # Child processes must not inherit the mutation lock FD 9.
    fd_probe_dir = Path(temporary) / "fd-mocks"
    fd_probe_dir.mkdir()
    for name in ("busctl", "bluetoothctl", "omarchy-bluetooth-power"):
        shutil.copy2(ROOT / "test/mocks" / name, fd_probe_dir / name)
    busctl_probe = fd_probe_dir / "busctl"
    busctl_probe.write_text(
        "#!/bin/bash\nif [[ -e /proc/$$/fd/9 ]]; then echo 'FD9_LEAKED' >&2; exit 99; fi\n"
        + f'exec "{ROOT / "test/mocks/busctl"}" "$@"\n'
    )
    busctl_probe.chmod(0o755)
    log.write_text("")
    fd_result = subprocess.run(
        [str(ROOT / "scripts/bluetooth-device-action"), "connect", ADDRESS, DEVICE],
        env=dict(environment, PATH=str(fd_probe_dir) + ":" + os.environ["PATH"]),
        capture_output=True, text=True, timeout=10,
    )
    assert fd_result.returncode == 0 and "FD9_LEAKED" not in fd_result.stderr, fd_result.stderr

print("PASS: controller-specific actions preserve ownership, reject unconfirmed removal, and cancel promptly")
