#!/usr/bin/env python3
"""Exercise service-owned profile outcomes and bounded audio cleanup in QML."""
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
    assert match, name
    return match.group(0)


connections = re.search(
    r"^  Connections \{\n    target: root\.bluetoothService\n.*?^  \}",
    PANEL, re.M | re.S)
assert connections, "manual profile result connection is missing"

profile_qml = r'''
import QtQuick
import Quickshell
import "Model.js" as Model
ShellRoot {
  id: harness
  property int stage: 0
  property int firstResultId: 0
  property var initiator: null
  property var survivor: null
  property var replacement: null
  property var lateSurvivor: null
  readonly property string address: "00:11:22:33:44:55"
  readonly property string live: '{"001122334455":{"activeProfile":"headset"}}'
  function check(value, message) {
    if (value) return true
    console.error(message); Qt.exit(1); return false
  }
  Component {
    id: panelComponent
    Item {
      id: root
      property var bluetoothService: service
      property bool audioProfileChangeBusy: false
      property bool deviceActionBusy: false
      property bool devicePropertyBusy: false
      property var pendingAudioProfile: null
      property var unconfirmedAudioProfile: null
      property string audioProfileSetError: ""
      property string audioProfileReadError: ""
      property var audioProfiles: ({})
      property var connectedDevices: [{address:"00:11:22:33:44:55", connected:true}]
      readonly property string audioProfileError: bluetoothService.manualProfileError
      function pendingAction(address) { return "" }
      function audioProfileOptions(address) { return [{value:"headset"}] }
      function deviceByAddress(address) { return connectedDevices[0] }
      Timer { id: audioProfilePendingTimeout; interval: 4000 }
      Timer { id: audioProfileRefreshTimer; interval: 100 }
      Timer { id: audioProfileSettleTimer; interval: 250 }
      __CONNECTIONS__
      __METHODS__
    }
  }
  Service {
    id: service
    onReadyChanged: {
      if (!ready || harness.stage !== 0) return
      harness.initiator = panelComponent.createObject(service)
      harness.survivor = panelComponent.createObject(service)
      harness.initiator.setAudioProfile(harness.address, "headset")
      harness.initiator.destroy()
      // Confirm the live profile before the helper reports failed persistence.
      harness.survivor.updateAudioProfiles(harness.live)
      if (!harness.check(harness.survivor.pendingAudioProfile === null,
          "Early live confirmation did not settle")) return
      harness.stage = 1
    }
  }
  Timer {
    interval: 20; repeat: true; running: true
    onTriggered: {
      if (harness.stage === 1 && service.manualProfileResult) {
        var first = service.manualProfileResult
        if (!harness.check(first.outcome === "persistence_failed"
            && harness.survivor.audioProfileError.indexOf("could not be saved") >= 0,
            "Destroyed initiator lost the delayed persistence failure")) return
        harness.firstResultId = first.id
        harness.replacement = panelComponent.createObject(service)
        harness.lateSurvivor = panelComponent.createObject(service)
        if (!harness.check(harness.replacement.audioProfileError.indexOf("could not be saved") >= 0,
            "Replacement widget did not receive the stored outcome")) return
        harness.stage = 2
        harness.replacement.setAudioProfile(harness.address, "headset")
        harness.replacement.destroy()
      } else if (harness.stage === 2 && service.manualProfileResult
          && service.manualProfileResult.id !== harness.firstResultId) {
        if (!harness.check(service.manualProfileResult.outcome === "persistence_failed"
            && harness.lateSurvivor.pendingAudioProfile !== null,
            "Late live confirmation was not left pending")) return
        harness.lateSurvivor.updateAudioProfiles(harness.live)
        if (!harness.check(harness.lateSurvivor.pendingAudioProfile === null
            && harness.lateSurvivor.audioProfileError.indexOf("could not be saved") >= 0,
            "Live confirmation hid a known persistence failure")) return
        service.manualProfileOperation = {id: 900, address: harness.address, profile: "headset"}
        service.finishManualAudioProfile(900, null,
          {outcome: "rejected", message: "Rejected fixture"})
        if (!harness.check(service.manualProfileError === "Rejected fixture",
            "Rejected outcome was not retained")) return
        service.manualProfileOperation = {id: 901, address: harness.address, profile: "headset"}
        harness.lateSurvivor.destroy()
        service.finishManualAudioProfile(901, null,
          {outcome: "unknown", message: "Outcome unknown"})
        var finalPanel = panelComponent.createObject(service)
        if (!harness.check(finalPanel.audioProfileError.indexOf("may have changed") >= 0,
            "Unknown outcome was lost after widget destruction")) return
        service.ready = false
        harness.stage = 3
        finalPanel.setAudioProfile(harness.address, "headset")
        finalPanel.destroy()
      } else if (harness.stage === 3 && service.manualProfileResult
          && service.manualProfileResult.outcome === "persistence_failed") {
        var fallbackReplacement = panelComponent.createObject(service)
        if (!harness.check(fallbackReplacement.audioProfileError.indexOf("could not be saved") >= 0,
            "Service-owned helper fallback lost its final result")) return
        console.info("PASS: shared profile completion survives widget destruction and live confirmation")
        Qt.quit()
      }
    }
  }
  Timer { interval: 9000; running: true; onTriggered: { console.error("Profile recovery timeout"); Qt.exit(1) } }
}
'''.replace("__METHODS__", "\n".join(panel_method(name) for name in (
    "setAudioProfile", "finishAudioProfileOperation", "adoptManualProfileOperation",
    "updateAudioProfiles"))).replace("__CONNECTIONS__", connections.group(0))

forget_qml = r'''
import QtQuick
import Quickshell
ShellRoot {
  id: harness
  property int stage: 0
  property double settledAt: 0
  readonly property string recovered: "00:11:22:33:44:55"
  readonly property string exhausted: "11:22:33:44:55:66"
  readonly property string uncertain: "22:33:44:55:66:77"
  function check(value, message) {
    if (value) return true
    console.error(message); Qt.exit(1); return false
  }
  QtObject {
    id: fakeAudio
    property bool ready: true
    property var capabilities: ["devices.forget"]
    property var seen: ({})
    function request(method, params, callback) {
      var counts = Object.assign({}, seen)
      counts[params.address] = (counts[params.address] || 0) + 1
      seen = counts
      if (params.address === harness.uncertain)
        callback(null, {code:"timeout", outcome:"unknown", message:"Outcome unknown"})
      else if (params.address === harness.exhausted || counts[params.address] === 1)
        callback(null, {code:"busy", outcome:"rejected", message:"Audio configuration is busy"})
      else callback({outcome:"applied"}, null)
      return "mock"
    }
  }
  QtObject { id: fakeShell; function serviceFor(id) { return fakeAudio } }
  Service { id: service; shell: fakeShell }
  Timer {
    interval: 50; repeat: true; running: true
    onTriggered: {
      if (harness.stage === 0) {
        harness.stage = 1
        service.forgetAudioRoutes(harness.recovered)
      } else if (harness.stage === 1 && service.pendingAudioForgets.length === 0) {
        if (!harness.check(fakeAudio.seen[harness.recovered] === 2 && fakeAudio.ready,
            "Busy cleanup did not retry without a readiness change")) return
        harness.stage = 2
        service.forgetAudioRoutes(harness.exhausted)
      } else if (harness.stage === 2 && service.audioForgetFailures[harness.exhausted]) {
        if (!harness.check(fakeAudio.seen[harness.exhausted] === 4
            && service.pendingAudioForgets.indexOf(harness.exhausted) >= 0
            && service.audioForgetError !== "", "Busy retries were not bounded or exposed")) return
        harness.stage = 3
        harness.settledAt = Date.now()
      } else if (harness.stage === 3 && Date.now() - harness.settledAt > 700) {
        if (!harness.check(fakeAudio.seen[harness.exhausted] === 4,
            "Exhausted cleanup retried indefinitely")) return
        harness.stage = 4
        service.forgetAudioRoutes(harness.uncertain)
        harness.settledAt = Date.now()
      } else if (harness.stage === 4 && Date.now() - harness.settledAt > 700) {
        if (!harness.check(fakeAudio.seen[harness.uncertain] === 1
            && service.audioForgetFailures[harness.uncertain].outcome === "unknown",
            "Unknown cleanup outcome was retried or hidden")) return
        console.info("PASS: busy cleanup retries after lock release; terminal failures remain visible")
        Qt.quit()
      }
    }
  }
  Timer { interval: 9000; running: true; onTriggered: { console.error("Forget retry timeout"); Qt.exit(1) } }
}
'''


state_qml = r'''
import QtQuick
import Quickshell
import "Model.js" as Model
ShellRoot {
  id: harness
  property int stage: 0
  readonly property string key: "001122334455"
  function check(value, message) {
    if (value) return true
    console.error(message); Qt.exit(1); return false
  }
  QtObject {
    id: device
    property string address: "00:11:22:33:44:55"
    property bool connected: false
    property bool paired: true
    property bool bonded: true
    property bool trusted: true
    property bool blocked: false
  }
  Item {
    id: root
    property bool audioPreferencesReady: true
    property var audioPreferences: ({bluetoothAudioPolicies: {"001122334455":"output"}})
    property var bluetoothService: service
    property var bar: null
    property var devices: [device]
    property var pendingActions: ({})
    property var pendingActionKinds: ({})
    property var pendingActionDeadlines: ({})
    readonly property int pendingActionTimeoutMs: 20000
    property var deviceActionFailures: ({})
    property var activeDeviceAction: null
    property bool deviceActionCancelRequested: false
    function refreshAudioProfiles() {}
    function cloneMap(value) { return Model.cloneMap(value) }
    function pendingAction(address) { return "" }
    __METHODS__
  }
  Service { id: service }
  Timer {
    interval: 50; running: true; repeat: true
    onTriggered: {
      if (harness.stage === 0) {
        service.policyEngine.automaticRetries = false
        service.registerPanel(root)
        service.devices = [device]
        harness.stage = 1
      } else if (harness.stage === 1) {
        service.deviceActionResults = {
          "001122334455": {action:"connect", message:"Connection failed", outcome:"rejected"}
        }
        root.deviceActionFailures = {
          "001122334455": {action:"connect", message:"Connection failed"}
        }
        device.connected = true
        root.syncPendingActions()
        harness.stage = 2
      } else if (harness.stage === 2) {
        if (!harness.check(service.policyEngine.pendingApplications[harness.key]
            && service.policyEngine.connectionStates[harness.key] === true,
            "Existing device connection did not queue its policy")) return
        if (!harness.check(!service.deviceActionResults[harness.key]
            && root.deviceActionFailure(device.address) === null,
            "Recovered connection retained a visible failure")) return
        service.policyEngine.pendingApplications = ({})
        device.connected = false
        service.deviceActionResults = {
          "001122334455": {action:"disconnect", message:"Disconnect failed", outcome:"rejected"}
        }
        service.reconcileDeviceActionResults()
        if (!harness.check(!service.deviceActionResults[harness.key],
            "Recovered disconnect retained a failure")) return
        device.connected = true
        harness.stage = 3
      } else {
        if (!harness.check(service.policyEngine.pendingApplications[harness.key],
            "Second reconnect did not queue its policy")) return
        service.deviceActionResults = {
          "001122334455": {action:"forget", message:"Forget failed", outcome:"rejected"}
        }
        device.paired = false
        device.bonded = false
        if (!harness.check(service.deviceActionResults[harness.key],
            "Forget failure cleared while the device remained trusted")) return
        device.trusted = false
        if (!harness.check(!service.deviceActionResults[harness.key],
            "Recovered forget retained a failure")) return
        service.deviceActionResults = {
          "001122334455": {action:"connect", message:"Connection failed", outcome:"rejected"}
        }
        service.reconcileDeviceActionResults()
        if (!harness.check(!service.deviceActionResults[harness.key],
            "Failure arriving after recovery was retained")) return
        root.finishServiceDeviceAction({address:device.address, action:"connect"}, null,
          {message:"Connection failed", outcome:"rejected"})
        if (!harness.check(root.deviceActionFailure(device.address) === null,
            "Late command failure restored an already recovered panel error")) return
        console.info("PASS: existing-device reconnects queue policies and recovered errors disappear")
        Qt.quit()
      }
    }
  }
  Timer { interval: 3000; running: true; onTriggered: Qt.exit(1) }
}
'''.replace("__METHODS__", "\n".join(panel_method(name) for name in (
    "deviceActionFailure", "syncPendingActions", "setDeviceActionFailure",
    "adoptDeviceActionFailure", "finishServiceDeviceAction",
    "adoptPendingAction", "defaultDeviceActionError")))


for name, qml in (("profile", profile_qml), ("forget", forget_qml), ("state", state_qml)):
    with tempfile.TemporaryDirectory(prefix="bluetooth-service-recovery-") as temporary:
        work = Path(temporary)
        for filename in ("Service.qml", "BluetoothAudioPolicyEngine.qml", "Model.js"):
            shutil.copy2(ROOT / filename, work / filename)
        if name == "state":
            # Inject fake device QObjects while retaining the service's real
            # per-device signal subscriptions and reconciliation behavior.
            service = work / "Service.qml"
            source = service.read_text()
            binding = "readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []"
            assert binding in source
            service.write_text(source.replace(binding, "property var devices: []"))
        (work / "bin").mkdir()
        (work / "scripts").mkdir()
        shutil.copy2(ROOT / "bin/omarchy-bluetooth-service",
                     work / "bin/omarchy-bluetooth-service")
        helper = work / "scripts/bluetooth-audio-profile-set"
        helper.write_text('#!/bin/sh\nsleep .25\necho "Preference save failed" >&2\nexit 2\n')
        helper.chmod(0o755)
        (work / "Probe.qml").write_text(qml)
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", XDG_RUNTIME_DIR=temporary,
                   XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"),
                   XDG_CACHE_HOME=str(work / "cache"),
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(work / "absent-bus"))
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "QT_QPA_PLATFORMTHEME"):
            env.pop(key, None)
        result = subprocess.run(["quickshell", "-p", str(work / "Probe.qml"), "--no-color"],
                                env=env, capture_output=True, text=True, timeout=12)
        output = result.stdout + result.stderr
        expected = {"profile": "PASS: shared profile completion",
                    "forget": "PASS: busy cleanup retries",
                    "state": "PASS: existing-device reconnects"}[name]
        assert result.returncode == 0 and expected in output, output
        assert not any(error in output for error in (
            "Cannot call method", "TypeError:", "ReferenceError:")), output
        print(next(line.strip() for line in output.splitlines() if expected in line))
