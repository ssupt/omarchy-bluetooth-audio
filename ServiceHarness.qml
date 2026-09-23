import QtQuick
import Quickshell

ShellRoot {
  Service {
    id: service
    onReadyChanged: {
      if (!ready) return
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
        if (failure || !result || result.status !== "ok") {
          console.error("Bluetooth service health request failed")
          Qt.exit(1)
        } else {
          console.info("PASS: shell service handshake and health")
          Qt.quit()
        }
      })
    }
  }

  Timer {
    interval: 5000
    running: true
    onTriggered: {
      console.error("Bluetooth service did not become ready")
      Qt.exit(1)
    }
  }
}
