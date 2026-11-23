#!/usr/bin/env python3
"""Targeted QML regression fixtures for panel, service, and policy edge cases."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PANEL = (ROOT / "Panel.qml").read_text()


def panel_method(name):
    match = re.search(r"^  function " + re.escape(name) + r"\(.*?^  \}",
                      PANEL, re.M | re.S)
    assert match, f"Missing Panel.qml method: {name}"
    return match.group(0)


def panel_block(pattern, label):
    match = re.search(pattern, PANEL, re.M | re.S)
    assert match, f"Missing Panel.qml block: {label}"
    return match.group(0)


# 1. Multi-adapter identity & confirmation expiration + Retry Pair Again
identity_and_retry_qml = r'''
import QtQuick
import Quickshell
import "Model.js" as Model

ShellRoot {
  id: harness
  function check(ok, msg) {
    if (ok) return true
    console.error(msg)
    Qt.exit(1)
    return false
  }

  QtObject {
    id: devHci0
    property string address: "00:11:22:33:44:55"
    property string dbusPath: "/org/bluez/hci0/dev_00_11_22_33_44_55"
    property string name: "Headset"
    property string deviceName: "Headset"
    property string icon: "audio-headset"
    property bool connected: false
    property int state: 0
    property bool paired: true
    property bool bonded: true
    property bool trusted: true
    property bool blocked: false
    property bool wakeAllowed: false
    property bool batteryAvailable: false
    property real battery: 0
    property bool pairing: false
  }
  QtObject {
    id: devHci1
    property string address: "00:11:22:33:44:55"
    property string dbusPath: "/org/bluez/hci1/dev_00_11_22_33_44_55"
    property string name: "Headset"
    property string deviceName: "Headset"
    property string icon: "audio-headset"
    property bool connected: false
    property int state: 0
    property bool paired: true
    property bool bonded: true
    property bool trusted: true
    property bool blocked: false
    property bool wakeAllowed: false
    property bool batteryAvailable: false
    property real battery: 0
    property bool pairing: false
  }
  QtObject {
    id: unbondedTrusted
    property string address: "AA:BB:CC:DD:EE:FF"
    property string dbusPath: "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
    property string name: "Headset Unbonded"
    property string deviceName: "Headset Unbonded"
    property bool connected: false
    property bool paired: false
    property bool bonded: false
    property bool trusted: true
    property bool blocked: false
  }

  Item {
    id: root
    property var devices: [devHci0, devHci1, unbondedTrusted]
    property string deviceDetailsAddress: ""
    property string deviceDetailsPath: ""
    property int deviceDetailsIndex: 0
    property string focusedDeviceAddress: ""
    property string focusedDevicePath: ""
    property bool forgetConfirmationOpen: false
    property string forgetConfirmationAddress: ""
    property string forgetConfirmationPath: ""
    property bool audioProfileMenuOpen: false
    property string devicePropertyError: ""
    property bool deviceDetailsControlsBusy: false
    property bool deviceActionBusy: false
    property bool opened: false
    property var forgottenPaths: []
    property var actionCalls: []
    property var failures: ({})
    readonly property var deviceDetailsRow: {
      var dev = deviceByIdentity(deviceDetailsAddress, deviceDetailsPath)
      return dev ? Model.deviceRow(dev) : null
    }
    readonly property bool deviceDetailsOpen: deviceDetailsAddress !== "" || deviceDetailsPath !== ""
    onDeviceDetailsRowChanged: {
      if (forgetConfirmationOpen
          && !deviceByIdentity(forgetConfirmationAddress || deviceDetailsAddress,
            forgetConfirmationPath || deviceDetailsPath)) {
        forgetConfirmationOpen = false
        forgetConfirmationAddress = ""
        forgetConfirmationPath = ""
      }
    }
    QtObject {
      id: deviceDetailsView
      function reset() {}
      function clearNameFocus() {}
      function resetConfirmation() {}
    }
    QtObject { id: keyCatcher; function forceActiveFocus() {} }
    function closeAudioProfileMenus() {}
    function deviceDisplayName(d) { return d ? d.name : "" }
    function reselectFocusedDevice() {}
    function restorePanelFocus() {}
    function pendingAction() { return "" }
    function forgetDevice(device) { forgottenPaths = forgottenPaths.concat([device.dbusPath]) }
    function deviceActionFailure(addr) { return failures[Model.normalizedAddress(addr)] || null }
    function runDeviceAction(device, action, pending) {
      actionCalls = actionCalls.concat([{ action: action, path: device.dbusPath }])
    }
    function disconnectDevice() {}
    __METHODS__
  }

  Component.onCompleted: Qt.callLater(function() {
    // Select hci1 row explicitly when hci0 shares the same MAC.
    var row1 = { dev: Model.deviceRow(devHci1) }
    var resolved = root.deviceFor(row1)
    if (!harness.check(resolved === devHci1, "Row lookup resolved wrong adapter")) return
    root.openDeviceDetails(resolved)
    if (!harness.check(root.deviceDetailsRow && root.deviceDetailsRow.dbusPath === devHci1.dbusPath,
        "Details opened wrong adapter")) return
    root.requestForgetConfirmation()
    if (!harness.check(root.forgetConfirmationOpen
        && root.forgetConfirmationPath === devHci1.dbusPath,
        "Forget confirmation did not capture hci1 path")) return
    root.confirmForgetDevice()
    if (!harness.check(root.forgottenPaths.length === 1
        && root.forgottenPaths[0] === devHci1.dbusPath,
        "Forget passed wrong adapter: " + JSON.stringify(root.forgottenPaths))) return

    // If hci1 disappears while confirmation is open, expire it and never touch hci0.
    root.openDeviceDetails(devHci1)
    root.requestForgetConfirmation()
    if (!harness.check(root.forgetConfirmationOpen, "Second confirmation did not open")) return
    root.devices = [devHci0, unbondedTrusted]
    if (!harness.check(!root.forgetConfirmationOpen && root.deviceDetailsRow === null,
        "Disappeared object did not expire confirmation")) return
    root.confirmForgetDevice()
    if (!harness.check(root.forgottenPaths.length === 1,
        "Expired confirmation still forgot hci0")) return

    // Trusted without bond after auth failure -> Retry chooses pair.
    root.failures = {
      "aabbccddeeff": {
        action: "connect",
        message: "Pairing failed authentication. Remove the device's old pairing and try again."
      }
    }
    if (!harness.check(Model.shouldPairAgainOnRetry(unbondedTrusted, root.deviceActionFailure(unbondedTrusted.address)),
        "shouldPairAgainOnRetry was false for trusted unbonded auth failure")) return
    root.retryDeviceAction(unbondedTrusted)
    if (!harness.check(root.actionCalls.length === 1 && root.actionCalls[0].action === "pair",
        "Retry did not choose pair: " + JSON.stringify(root.actionCalls))) return

    console.info("PASS: adapter identity and pair-again retry")
    Qt.quit()
  })
  Timer { interval: 5000; running: true; onTriggered: Qt.exit(1) }
}
'''.replace("__METHODS__", "\n".join(panel_method(m) for m in (
    "deviceByPath", "deviceByAddress", "deviceByIdentity", "deviceFor",
    "openDeviceDetails", "closeDeviceDetails", "sameDetailsTarget",
    "requestForgetConfirmation", "cancelForgetConfirmation", "confirmForgetDevice",
    "connectDevice", "retryDeviceAction",
)))

# 2. Failed cancellation disconnect hides nothing and stops replacement
cancel_failure_qml = r'''
import QtQuick
import Quickshell

ShellRoot {
  id: harness
  property int stage: 0
  readonly property string first: "00:11:22:33:44:55"
  readonly property string second: "22:33:44:55:66:77"
  function check(ok, msg) {
    if (ok) return true
    console.error(msg)
    Qt.exit(1)
    return false
  }
  QtObject { id: panel; property bool audioPreferencesReady: false }
  Service {
    id: service
    onReadyChanged: {
      if (!ready || harness.stage !== 0) return
      registerPanel(panel)
      harness.stage = 1
      if (!harness.check(chooseDeviceConnection("connect", harness.first,
          "/org/bluez/hci1/dev_00_11_22_33_44_55"), "First connect rejected")) return
      clickTimer.restart()
    }
    onDeviceActionFinished: function(operation, _result, failure) {
      if (harness.stage === 1) {
        if (!harness.check(operation.address === harness.first, "Wrong address finished")) return
        if (!harness.check(!operation.cancelled && operation.cancellationFailed,
            "Failed cleanup disconnect was marked cleanly cancelled")) return
        if (!harness.check(!!failure && failure.outcome === "unknown",
            "Failed cleanup did not propagate unknown outcome")) return
        var stored = service.deviceActionResults["001122334455"]
        if (!harness.check(stored && stored.outcome === "unknown" && stored.message !== "",
            "Stored result lacked unknown outcome or message: " + JSON.stringify(stored))) return
        if (!harness.check(!service.queuedConnection,
            "Replacement connection was not cleared after failed disconnect")) return
        harness.stage = 2
        settleTimer.restart()
      } else {
        harness.check(false, "Replacement device connected despite failed disconnect: " + operation.address)
      }
    }
  }
  Timer {
    id: clickTimer
    interval: 150
    onTriggered: {
      harness.check(service.chooseDeviceConnection("connect", harness.second,
        "/org/bluez/hci1/dev_22_33_44_55_66_77"), "Replacement click rejected")
    }
  }
  Timer {
    id: settleTimer
    interval: 300
    onTriggered: {
      if (!harness.check(Object.keys(service.deviceActions).length === 0,
          "Unexpected active device action after failed cancellation")) return
      console.info("PASS: failed cancellation disconnect stays unknown and blocks replacement")
      Qt.quit()
    }
  }
  Timer { interval: 8000; running: true; onTriggered: Qt.exit(1) }
}
'''

# 3. Policy FileView load failures, malformed JSON, and v2 schema validation
policy_files_qml = r'''
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

ShellRoot {
  id: harness
  property int stage: 0
  readonly property string sharedPath: "__SHARED__"
  readonly property string missingPolicyPath: "__MISSING__"
  readonly property string unreadablePolicyPath: "__UNREADABLE__"
  readonly property string malformedPolicyPath: "__MALFORMED__"
  readonly property string v2PolicyPath: "__V2__"
  readonly property string validManualPolicyPath: "__VALID_MANUAL__"

  function check(ok, msg) {
    if (ok) return true
    console.error(msg)
    Qt.exit(1)
    return false
  }

  Item {
    id: root
    property var sharedAudioPreferences: Model.parseAudioPreferences("")
    property var audioPolicyOverrides: ({})
    property bool hasValidAudioPolicyOverrides: false
    readonly property var audioPreferences: Model.mergeAudioPreferences(
      sharedAudioPreferences, audioPolicyOverrides,
      audioPolicyOverridesReady || hasValidAudioPolicyOverrides)
    property bool sharedAudioPreferencesReady: false
    property bool audioPolicyOverridesReady: false
    readonly property bool audioPreferencesReady: sharedAudioPreferencesReady
      && audioPolicyOverridesReady
    property string sharedAudioPreferencesError: ""
    property string audioPolicyPreferencesError: ""
    property string audioPreferenceWriteError: ""
    __METHODS__
  }

  FileView {
    id: sharedView
    path: harness.sharedPath
    printErrors: false
    onLoaded: root.loadAudioPreferences(text())
    onLoadFailed: function(error) { root.handleAudioPreferencesLoadFailed(error) }
  }

  FileView {
    id: policyView
    path: harness.unreadablePolicyPath
    printErrors: false
    onLoaded: root.loadAudioPolicyOverrides(text())
    onLoadFailed: function(error) { root.handleAudioPolicyOverridesLoadFailed(error) }
  }

  Timer {
    interval: 150
    repeat: true
    running: true
    onTriggered: {
      if (harness.stage === 0 && root.sharedAudioPreferencesReady
          && root.audioPolicyPreferencesError !== "") {
        // Stage 0: unreadable policy file must suspend routing, report error,
        // and not reactivate legacy output-mic from shared preferences.
        if (!harness.check(!root.audioPreferencesReady,
            "Unreadable policy file marked preferences ready")) return
        if (!harness.check(Model.deviceAudioPolicy(root.audioPreferences, "00:11:22:33:44:55") === "manual",
            "Unreadable policy file reactivated legacy output-mic")) return
        harness.stage = 1
        policyView.path = harness.malformedPolicyPath
      } else if (harness.stage === 1
          && root.audioPolicyPreferencesError.indexOf("invalid JSON") !== -1) {
        if (!harness.check(!root.audioPreferencesReady,
            "Malformed policy file marked preferences ready")) return
        if (!harness.check(Model.deviceAudioPolicy(root.audioPreferences, "00:11:22:33:44:55") === "manual",
            "Malformed policy file reactivated legacy output-mic")) return
        harness.stage = 2
        policyView.path = harness.v2PolicyPath
      } else if (harness.stage === 2
          && root.audioPolicyPreferencesError.indexOf("unsupported version") !== -1) {
        if (!harness.check(!root.audioPreferencesReady,
            "Version-2 policy file marked preferences ready")) return
        if (!harness.check(Model.deviceAudioPolicy(root.audioPreferences, "00:11:22:33:44:55") === "manual",
            "Version-2 policy file reactivated legacy output-mic")) return
        harness.stage = 3
        policyView.path = harness.validManualPolicyPath
      } else if (harness.stage === 3 && root.audioPreferencesReady) {
        if (!harness.check(root.audioPolicyPreferencesError === ""
            && Model.deviceAudioPolicy(root.audioPreferences, "00:11:22:33:44:55") === "manual",
            "Valid manual policy did not load cleanly")) return
        // Now corrupt it after a valid load: must retain manual AND suspend routing.
        harness.stage = 4
        policyView.path = harness.malformedPolicyPath
      } else if (harness.stage === 4 && !root.audioPreferencesReady) {
        if (!harness.check(root.audioPolicyPreferencesError !== ""
            && Model.deviceAudioPolicy(root.audioPreferences, "00:11:22:33:44:55") === "manual",
            "Corrupt reload after valid manual load lost manual override")) return
        // First-run missing file (FileNotFound) IS ready with no error.
        harness.stage = 5
        policyView.path = harness.missingPolicyPath
      } else if (harness.stage === 5 && root.audioPreferencesReady) {
        if (!harness.check(root.audioPolicyPreferencesError === "",
            "Missing first-run policy file produced an error")) return
        if (!harness.check(Model.deviceAudioPolicy(root.audioPreferences, "00:11:22:33:44:55") === "output-mic",
            "First-run missing policy file did not read legacy shared rule")) return
        console.info("PASS: policy FileView validation and read failures fail safe")
        Qt.quit()
      }
    }
  }
  Timer { interval: 6000; running: true; onTriggered: { console.error("Policy FileView timeout at stage " + harness.stage + " err=" + root.audioPolicyPreferencesError); Qt.exit(1) } }
}
'''.replace("__METHODS__", "\n".join(panel_method(m) for m in (
    "fileViewErrorDetail", "isFileNotFoundError",
    "loadAudioPreferences", "handleAudioPreferencesLoadFailed",
    "loadAudioPolicyOverrides", "handleAudioPolicyOverridesLoadFailed",
)))

# 4. Fallback profile switch recovery + Late property reply
local_engine_block = panel_block(
    r"^  BluetoothAudioPolicyEngine \{\n    id: localPolicyEngine\n.*?^  \}",
    "localPolicyEngine",
)
policy_proc_block = panel_block(
    r"^  Process \{\n    id: policyProfileSwitchProc\n.*?^  \}",
    "policyProfileSwitchProc",
)
prop_timer_block = panel_block(
    r"^  Timer \{\n    id: devicePropertyConfirmTimer\n.*?^  \}",
    "devicePropertyConfirmTimer",
)

recovery_and_property_qml = r'''
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

ShellRoot {
  id: harness
  property int stage: 0
  property var trustCallback: null
  property var blockCallback: null
  function check(ok, msg) {
    if (ok) return true
    console.error(msg)
    Qt.exit(1)
    return false
  }

  QtObject {
    id: dev
    property string address: "00:11:22:33:44:55"
    property string dbusPath: "/org/bluez/hci0/dev_00_11_22_33_44_55"
    property string name: "Headset"
    property string deviceName: "Headset"
    property bool connected: true
    property bool trusted: false
    property bool blocked: false
    property bool wakeAllowed: false
  }

  BluetoothAudioPolicyEngine {
    id: fakeSharedEngine
    controller: root
    automaticRetries: false
    preferencesReady: true
  }

  QtObject {
    id: fakeService
    property bool ready: false
    property var policyEngine: fakeSharedEngine
    function request(method, params, callback) {
      if (method === "device.property") {
        if (params.property === "trusted") harness.trustCallback = callback
        else if (params.property === "blocked") harness.blockCallback = callback
      }
      return "req"
    }
  }

  Item {
    id: root
    property var devices: [dev]
    property var bluetoothService: fakeService
    readonly property var policyEngine: bluetoothService && bluetoothService.ready
      ? bluetoothService.policyEngine : localPolicyEngine
    property bool audioPreferencesReady: true
    property var audioPreferences: ({
      bluetoothProfiles: {},
      bluetoothAudioPolicies: { "001122334455": "output-mic" }
    })
    property bool audioProfileChangeBusy: false
    property bool deviceActionBusy: false
    property bool devicePropertyBusy: false
    property bool manualAudioBusy: false
    property string audioPreferencesError: ""
    property string audioPreferenceWriteError: ""
    property string deviceDetailsAddress: dev.address
    property string deviceDetailsPath: dev.dbusPath
    readonly property var deviceDetailsRow: Model.deviceRow(dev)
    property bool deviceDetailsControlsBusy: pendingDeviceProperty !== null
    property var pendingDeviceProperty: null
    property int devicePropertySequence: 0
    property string devicePropertyStderr: ""
    property string devicePropertyError: ""
    function pluginScript(name) { return "__SCRIPTS__/" + name }
    function publishAudioPolicyApplications() {}
    function syncAudioControlAliases() {}
    function deviceDisplayName(d) { return d ? d.name : "" }
    QtObject { id: deviceDetailsView; function updateNameIfIdle() {} }
    QtObject {
      id: devicePropertyProc
      property var command: []
      property int operationId: 0
      property bool running: false
      function prepare() {}
    }
    Timer { id: audioProfileRefreshTimer; interval: 100 }
    __LOCAL_ENGINE__
    __POLICY_PROC__
    __PROP_TIMER__
    __METHODS__
  }

  Component.onCompleted: Qt.callLater(function() {
    // Start fallback policy profile switch while service is NOT ready,
    // then flip bluetoothService.ready = true before the helper exits.
    var started = localPolicyEngine.requestProfileSwitch(
      "001122334455",
      { address: dev.address },
      { value: "headset-head-unit-msbc" })
    if (!harness.check(started && localPolicyEngine.profileSwitchBusy,
        "Fallback profile switch did not start")) return
    fakeService.ready = true
    harness.stage = 1
  })

  Timer {
    interval: 40
    repeat: true
    running: true
    onTriggered: {
      if (harness.stage === 1 && !policyProfileSwitchProc.running) {
        // Switching back to fallback must NOT expose a stuck busy flag.
        fakeService.ready = false
        if (!harness.check(!localPolicyEngine.profileSwitchBusy,
            "Service recovery left localPolicyEngine.profileSwitchBusy stuck true")) return

        // Early BlueZ update clears Trust edit, Block edit starts,
        // then late Trust reply arrives -> must NOT start Block's confirmation timer!
        fakeService.ready = true
        root.updateDeviceBoolean("trusted", true, "Trust failed")
        if (!harness.check(root.pendingDeviceProperty !== null
            && root.pendingDeviceProperty.propertyName === "trusted"
            && !!harness.trustCallback, "Trust property edit did not start")) return
        // Early BlueZ live update settles Trust before service reply arrives.
        dev.trusted = true
        root.confirmDevicePropertyIfReached()
        if (!harness.check(root.pendingDeviceProperty === null,
            "Early Trust update did not settle")) return

        // Start Block edit next.
        root.updateDeviceBoolean("blocked", true, "Block failed")
        if (!harness.check(root.pendingDeviceProperty !== null
            && root.pendingDeviceProperty.propertyName === "blocked",
            "Block edit did not start")) return
        // Late Trust reply arrives while Block is pending!
        harness.trustCallback({ outcome: "applied" }, null)
        if (!harness.check(!devicePropertyConfirmTimer.running,
            "Late Trust reply started Block's confirmation timer")) return
        // Even a late Trust error must not fail Block!
        harness.trustCallback(null, { message: "Stale trust failure" })
        if (!harness.check(root.pendingDeviceProperty !== null
            && root.pendingDeviceProperty.propertyName === "blocked"
            && root.devicePropertyError === "",
            "Late Trust reply disrupted active Block edit")) return

        // Now Block finishes and confirms cleanly.
        dev.blocked = true
        harness.blockCallback({ outcome: "applied" }, null)
        if (!harness.check(root.pendingDeviceProperty === null && root.devicePropertyError === "",
            "Block edit did not confirm cleanly")) return

        console.info("PASS: fallback profile switch clears busy and late property replies are ignored")
        Qt.quit()
      }
    }
  }
  Timer { interval: 6000; running: true; onTriggered: Qt.exit(1) }
}
'''.replace("__LOCAL_ENGINE__", local_engine_block) \
   .replace("__POLICY_PROC__", policy_proc_block) \
   .replace("__PROP_TIMER__", prop_timer_block) \
   .replace("__METHODS__", "\n".join(panel_method(m) for m in (
       "deviceByPath", "deviceByAddress", "deviceByIdentity", "devicePropertyCommand",
       "liveDeviceProperty", "updateDeviceProperty", "finishDeviceProperty",
       "sameDetailsTarget", "updateDeviceBoolean", "confirmDeviceProperty",
       "confirmDevicePropertyIfReached",
   )))


def run_quickshell(work, qml_text, expected, env_extra=None):
    probe = work / "Probe.qml"
    probe.write_text(qml_text)
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", XDG_RUNTIME_DIR=str(work),
               XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
               XDG_CACHE_HOME=str(work / "cache"),
               DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(work / "absent-bus"))
    if env_extra:
        env.update(env_extra)
    for key in ("DISPLAY", "WAYLAND_DISPLAY", "QT_QPA_PLATFORMTHEME"):
        env.pop(key, None)
    result = subprocess.run(["quickshell", "-p", str(probe), "--no-color"],
                            env=env, capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    assert result.returncode == 0 and expected in output, output
    assert not any(err in output for err in ("Cannot call method", "TypeError:", "ReferenceError:")), output
    print(next(line.strip() for line in output.splitlines() if expected in line))


with tempfile.TemporaryDirectory(prefix="bluetooth-panel-regressions-") as temporary:
    base = Path(temporary)

    # Case 1 & 15
    work1 = base / "identity"
    work1.mkdir()
    shutil.copy2(ROOT / "Model.js", work1 / "Model.js")
    run_quickshell(work1, identity_and_retry_qml, "PASS: adapter identity and pair-again retry")

    # Case 5
    work2 = base / "cancel"
    work2.mkdir()
    for name in ("Service.qml", "BluetoothAudioPolicyEngine.qml", "Model.js"):
        shutil.copy2(ROOT / name, work2 / name)
    (work2 / "bin").mkdir()
    (work2 / "scripts").mkdir()
    shutil.copy2(ROOT / "bin/omarchy-bluetooth-service", work2 / "bin/omarchy-bluetooth-service")
    helper = work2 / "scripts/bluetooth-device-action"
    helper.write_text('''#!/bin/bash
child=
trap 'if [[ -n $child ]]; then kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi; echo "Could not disconnect the device: org.bluez.Error.Failed" >&2; exit 131' TERM INT
if [[ $1 == connect ]]; then sleep 10 & child=$!; wait "$child"; fi
exit 0
''')
    helper.chmod(0o755)
    run_quickshell(work2, cancel_failure_qml,
                   "PASS: failed cancellation disconnect stays unknown and blocks replacement")

    # Case 7
    work3 = base / "policy-files"
    work3.mkdir()
    shutil.copy2(ROOT / "Model.js", work3 / "Model.js")
    shared = work3 / "shared.json"
    shared.write_text('{"version":1,"bluetoothAudioPolicies":{"001122334455":"output-mic"}}\n')
    unreadable = work3 / "unreadable.json"
    unreadable.write_text('{"version":1,"bluetoothAudioPolicies":{"001122334455":"manual"}}\n')
    unreadable.chmod(0o000)
    malformed = work3 / "malformed.json"
    malformed.write_text('{broken json')
    v2 = work3 / "v2.json"
    v2.write_text('{"version":2,"bluetoothAudioPolicies":{"001122334455":"manual"}}\n')
    valid_manual = work3 / "valid-manual.json"
    valid_manual.write_text('{"version":1,"bluetoothAudioPolicies":{"001122334455":"manual"}}\n')
    missing = work3 / "does-not-exist.json"
    try:
        qml7 = (policy_files_qml
                .replace("__SHARED__", str(shared))
                .replace("__MISSING__", str(missing))
                .replace("__UNREADABLE__", str(unreadable))
                .replace("__MALFORMED__", str(malformed))
                .replace("__V2__", str(v2))
                .replace("__VALID_MANUAL__", str(valid_manual)))
        run_quickshell(work3, qml7, "PASS: policy FileView validation and read failures fail safe")
    finally:
        unreadable.chmod(0o600)

    # Case 12 & 13
    work4 = base / "recovery-prop"
    work4.mkdir()
    for name in ("BluetoothAudioPolicyEngine.qml", "Model.js"):
        shutil.copy2(ROOT / name, work4 / name)
    scripts4 = work4 / "scripts"
    scripts4.mkdir()
    prof_helper = scripts4 / "bluetooth-audio-profile-set"
    prof_helper.write_text("#!/bin/sh\nsleep .2\nexit 0\n")
    prof_helper.chmod(0o755)
    qml12 = recovery_and_property_qml.replace("__SCRIPTS__", str(scripts4))
    run_quickshell(work4, qml12,
                   "PASS: fallback profile switch clears busy and late property replies are ignored")
