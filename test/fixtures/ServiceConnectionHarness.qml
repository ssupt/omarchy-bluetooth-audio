import QtQuick
import Quickshell

ShellRoot {
  id: harness
  readonly property string first: "00:11:22:33:44:55"
  readonly property string skipped: "11:22:33:44:55:66"
  readonly property string latest: "22:33:44:55:66:77"
  property string stage: ""
  property bool fallback: false
  property double startedAt: 0

  function check(value, message) {
    if (value) return true
    console.error(message)
    Qt.exit(1)
    return false
  }

  function choose(action, address) {
    return service.chooseDeviceConnection(action, address,
      "/org/bluez/hci1/dev_" + address.replace(/:/g, "_"))
  }

  function begin() {
    stage = "replace"
    startedAt = Date.now()
    if (!check(choose("connect", first), "Initial connection was rejected")) return
    clickTimer.restart()
  }

  QtObject { id: firstPanel; property bool audioPreferencesReady: false }
  QtObject { id: replacementPanel; property bool audioPreferencesReady: false }
  Service {
    id: service
    onReadyChanged: {
      if (ready && harness.stage === "") {
        registerPanel(firstPanel)
        harness.begin()
      }
    }
    onDeviceActionFinished: function(operation, result, failure) {
      if (harness.stage === "replace") {
        if (!harness.check(operation.address === harness.first && operation.cancelled
            && queuedConnection && queuedConnection.address === harness.latest
            && Date.now() - harness.startedAt < 4000,
            "Old connection did not cancel promptly with the newest choice retained")) return
        harness.stage = "latest"
      } else if (harness.stage === "latest") {
        if (!harness.check(operation.address === harness.latest && !failure
            && result.outcome === "applied" && !queuedConnection,
            "Replacement connection did not complete")) return
        harness.stage = "pair"
        Qt.callLater(function() {
          harness.choose("pair", harness.first)
          clickTimer.restart()
        })
      } else if (harness.stage === "pair") {
        if (!harness.check(operation.address === harness.first && operation.cancelled
            && !queuedConnection, "Clicking the pairing device again did not cancel it")) return
        harness.stage = "queued"
        Qt.callLater(function() {
          harness.choose("connect", harness.first)
          clickTimer.restart()
        })
      } else if (harness.stage === "queued") {
        if (!harness.check(operation.cancelled && !queuedConnection,
            "Cancelled queued selection started a connection")) return
        if (!harness.fallback) {
          harness.fallback = true
          ready = false
          Qt.callLater(function() { harness.begin() })
        } else {
          console.info("PASS: connection replacement keeps the latest choice and supports cancellation with helper fallback")
          Qt.quit()
        }
      } else {
        harness.check(false, "Unexpected device completion: " + operation.address)
      }
    }
  }

  Timer {
    id: clickTimer
    interval: 200
    onTriggered: {
      if (harness.stage === "replace") {
        if (!harness.check(harness.choose("connect", harness.skipped)
            && harness.choose("connect", harness.latest), "Replacement click was rejected")) return
        service.registerPanel(replacementPanel)
        service.unregisterPanel(firstPanel)
        if (!harness.check(service.controller === replacementPanel,
            "Panel handoff lost the pending choice")) return
      } else if (harness.stage === "pair") {
        if (!harness.check(harness.choose("pair", harness.first)
            && service.activeConnection.cancelled && !service.queuedConnection,
            "Second click did not cancel the active pairing")) return
      } else if (harness.stage === "queued") {
        harness.choose("connect", harness.skipped)
        harness.choose("connect", harness.first)
        if (!harness.check(service.queuedConnection
            && service.queuedConnection.address === harness.first,
            "Returning to the original choice lost the replacement")) return
        harness.choose("connect", harness.skipped)
        harness.choose("connect", harness.skipped)
        if (!harness.check(!service.queuedConnection,
            "Clicking the queued choice again did not cancel it")) return
      }
    }
  }
  Timer { interval: 12000; running: true; onTriggered: Qt.exit(1) }
}
