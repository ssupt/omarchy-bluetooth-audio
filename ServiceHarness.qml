import QtQuick
import Quickshell

ShellRoot {
  id: harness
  property int phase: 0
  property int firstPid: 0
  property bool forgetBridgeVerified: false

  QtObject {
    id: fakeAudio
    property bool ready: false
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
    id: firstPanel
    property bool audioPreferencesReady: false
  }
  QtObject {
    id: replacementPanel
    property bool audioPreferencesReady: false
  }

  Service {
    id: service
    shell: fakeShell
    onReadyChanged: {
      if (!ready) {
        if (harness.phase === 1) harness.phase = 2
        return
      }
      if (harness.phase === 2) {
        if (controller !== replacementPanel || panels.length !== 1
            || !harness.forgetBridgeVerified) {
          console.error("Panel handoff was lost during service restart")
          Qt.exit(1)
          return
        }
        request("health", {}, function(result, failure) {
          if (failure || !result || result.status !== "ok"
              || !result.pid || result.pid === harness.firstPid) {
            console.error("Bluetooth service did not recover after exit")
            Qt.exit(1)
            return
          }
          console.info("PASS: shell service restart and panel handoff")
          Qt.quit()
        })
        return
      }
      if (harness.phase !== 0) return
      var timedOut = false
      var staleId = "qml-test-expired"
      pending = ({})
      pending[staleId] = {
        callback: function(_result, failure) { timedOut = failure && failure.code === "timeout" },
        started: 0, method: "health"
      }
      expirePending(Date.now())
      consume(JSON.stringify({ version: 1, id: staleId, result: { status: "ok" } }) + "\n")
      if (!timedOut || expired[staleId] || !ready) {
        console.error("Late Bluetooth reply disrupted the service")
        Qt.exit(1)
        return
      }
      request("health", {}, function(result, failure) {
        if (failure || !result || result.status !== "ok" || !result.pid) {
          console.error("Bluetooth service health request failed")
          Qt.exit(1)
          return
        }
        harness.firstPid = result.pid
        registerPanel(firstPanel)
        registerPanel(firstPanel)
        registerPanel(replacementPanel)
        unregisterPanel(firstPanel)
        if (controller !== replacementPanel || panels.length !== 1) {
          console.error("Replacement panel did not take ownership")
          Qt.exit(1)
          return
        }
        request("health", {}, function(afterHandoff, handoffFailure) {
          if (handoffFailure || !afterHandoff || afterHandoff.pid !== harness.firstPid) {
            console.error("Panel handoff restarted the shared service")
            Qt.exit(1)
            return
          }
          harness.phase = 1
          Quickshell.execDetached(["/usr/bin/kill", "-TERM", String(result.pid)])
        })
      })
    }
  }

  Timer {
    interval: 100
    running: true
    onTriggered: {
      service.forgetAudioRoutes("AA:BB:CC:DD:EE:FF")
      if (fakeAudio.requests.length !== 0 || service.pendingAudioForgets.length !== 1) {
        console.error("Forgotten routes were sent before audio became ready")
        Qt.exit(1)
        return
      }
      fakeAudio.ready = true
      Qt.callLater(function() {
        if (fakeAudio.requests.length !== 1
            || fakeAudio.requests[0].method !== "devices.forget"
            || fakeAudio.requests[0].address !== "AA:BB:CC:DD:EE:FF"
            || service.pendingAudioForgets.length !== 0) {
          console.error("Queued Bluetooth forget did not clean saved audio routes")
          Qt.exit(1)
          return
        }
        harness.forgetBridgeVerified = true
      })
    }
  }

  Timer {
    interval: 15000
    running: true
    onTriggered: {
      console.error("Bluetooth service did not complete its lifecycle test")
      Qt.exit(1)
    }
  }
}
