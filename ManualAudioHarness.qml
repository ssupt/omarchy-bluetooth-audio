import QtQuick
import Quickshell

ShellRoot {
  id: harness
  property var initiator: null

  function check(condition, message) {
    if (condition) return true
    console.error(message)
    Qt.exit(1)
    return false
  }

  QtObject {
    id: fakeAudio
    property bool ready: true
    property var capabilities: ["default.compat"]
    property var requests: []
    function request(method, params, callback) {
      requests = requests.concat([{ method: method, params: params, callback: callback }])
      return "mock-" + requests.length
    }
    function complete(index, result, failure) {
      requests[index].callback(result, failure)
    }
  }
  QtObject {
    id: fakeShell
    function serviceFor(id) { return id === "ssupt.audio-control" ? fakeAudio : null }
  }
  Component {
    id: disposablePanel
    Item {
      function select() {
        service.selectDeviceAudio("00:11:22:33:44:55",
          { id: 12, name: "bluez_output.test", previous: "old-output" },
          { id: 13, name: "bluez_input.test", previous: "old-input" })
        destroy()
      }
    }
  }
  Service {
    id: service
    shell: fakeShell
  }

  Component.onCompleted: Qt.callLater(function() {
    harness.initiator = disposablePanel.createObject(service)
    harness.initiator.select()
    Qt.callLater(function() {
      if (!check(fakeAudio.requests.length === 1 && service.manualAudioBusy,
          "Manual output was not admitted")) return
      if (!check(fakeAudio.requests[0].method === "default.compat"
          && fakeAudio.requests[0].params.direction === "output"
          && fakeAudio.requests[0].params.previous === "old-output",
          "Manual output command lost its captured state")) return
      fakeAudio.complete(0, null, {
        code: "busy", outcome: "rejected", message: "Audio queue busy"
      })
      if (!check(fakeAudio.requests.length === 1 && !service.manualAudioBusy
          && service.manualAudioError.indexOf("Audio queue busy") !== -1,
          "Rejected output was hidden or microphone was sent anyway")) return

      service.selectDeviceAudio("00:11:22:33:44:55",
        { id: 12, name: "bluez_output.test", previous: "old-output" },
        { id: 13, name: "bluez_input.test", previous: "old-input" })
      fakeAudio.complete(1, { outcome: "applied" }, null)
      if (!check(fakeAudio.requests.length === 3 && service.manualAudioBusy
          && fakeAudio.requests[2].params.direction === "input"
          && fakeAudio.requests[2].params.previous === "old-input",
          "Microphone was not sequenced after confirmed output")) return
      fakeAudio.complete(2, { outcome: "persistence_failed" }, null)
      if (!check(!service.manualAudioBusy
          && service.manualAudioError.indexOf("input preference could not be saved") !== -1,
          "Unsaved microphone preference was hidden")) return

      service.selectDeviceAudio("00:11:22:33:44:55",
        { id: 12, name: "bluez_output.test", previous: "old-output" },
        { id: 13, name: "bluez_input.test", previous: "old-input" })
      fakeAudio.complete(3, { outcome: "applied" }, null)
      fakeAudio.complete(4, null, {
        code: "conflict", outcome: "rejected", message: "Previous microphone changed"
      })
      if (!check(!service.manualAudioBusy
          && service.manualAudioError.indexOf("Bluetooth output changed") !== -1
          && service.manualAudioError.indexOf("Previous microphone changed") !== -1,
          "Partial output-only completion was hidden")) return

      service.selectDeviceAudio("00:11:22:33:44:55",
        { id: 12, name: "bluez_output.test", previous: "old-output" },
        { id: 13, name: "bluez_input.test", previous: "old-input" })
      fakeAudio.complete(5, { outcome: "applied" }, null)
      fakeAudio.ready = false
      if (!check(!service.manualAudioBusy
          && service.manualAudioError.indexOf("could not be confirmed") !== -1,
          "Audio-service reload lost the in-flight microphone result")) return
      var error = service.manualAudioError
      fakeAudio.complete(6, { outcome: "applied" }, null)
      if (!check(service.manualAudioError === error,
          "Late reply replaced the unknown outcome")) return
      console.info("PASS: manual audio defaults retain results after panel destruction")
      Qt.quit()
    })
  })

  Timer {
    interval: 10000
    running: true
    onTriggered: {
      console.error("Manual audio action did not complete")
      Qt.exit(1)
    }
  }
}
