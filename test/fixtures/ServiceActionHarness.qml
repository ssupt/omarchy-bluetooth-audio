import QtQuick
import Quickshell

ShellRoot {
  id: harness
  property bool started: false
  property int completions: 0
  property var initiator: null

  QtObject {
    id: fakeAudio
    property bool ready: true
    property var capabilities: ["devices.forget"]
    property var requests: []
    function request(method, params, callback) {
      requests = requests.concat([{ method: method, address: params.address }])
      callback({ outcome: "applied" }, null)
      return "mock"
    }
  }
  QtObject {
    id: fakeShell
    function serviceFor(id) { return id === "ssupt.audio-control" ? fakeAudio : null }
  }
  QtObject {
    id: survivingPanel
    property bool audioPreferencesReady: false
  }
  Component {
    id: disposablePanel
    Item {
      property bool audioPreferencesReady: false
      function forget() {
        if (!service.startDeviceAction("forget", "00:11:22:33:44:55", "forgetting")) {
          console.error("Could not admit forget action")
          Qt.exit(1)
          return
        }
        destroy()
      }
    }
  }
  Service {
    id: service
    shell: fakeShell
    onReadyChanged: {
      if (!ready || harness.started) return
      harness.started = true
      harness.initiator = disposablePanel.createObject(service)
      registerPanel(harness.initiator)
      registerPanel(survivingPanel)
      harness.initiator.forget()
      unregisterPanel(harness.initiator)
      // The audio plugin reloads while the Bluetooth helper is in flight.
      fakeAudio.ready = false
    }
    onDeviceActionFinished: function(operation, result, failure) {
      harness.completions += 1
      if (failure || !result || result.outcome !== "applied"
          || operation.action !== "forget" || controller !== survivingPanel
          || Object.keys(deviceActions).length !== 0
          || fakeAudio.requests.length !== 0
          || pendingAudioForgets.length !== 1
          || pendingAudioForgets[0] !== operation.address
          || deviceActionResults[actionKey(operation.address)].outcome !== "applied") {
        console.error("Destroyed widget lost forget completion during audio reload")
        Qt.exit(1)
        return
      }
      fakeAudio.ready = true
      Qt.callLater(function() {
        if (harness.completions !== 1 || fakeAudio.requests.length !== 1
            || fakeAudio.requests[0].method !== "devices.forget"
            || fakeAudio.requests[0].address !== operation.address
            || pendingAudioForgets.length !== 0) {
          console.error("Audio reload did not deliver one queued forget cleanup")
          Qt.exit(1)
          return
        }
        console.info("PASS: service owns completion and resumes audio cleanup after reload")
        Qt.quit()
      })
    }
  }
  Timer {
    interval: 10000
    running: true
    onTriggered: {
      console.error("Bluetooth action did not complete after widget destruction")
      Qt.exit(1)
    }
  }
}
