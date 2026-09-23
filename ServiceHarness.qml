import QtQuick
import Quickshell

ShellRoot {
  Service {
    id: service
    onReadyChanged: {
      if (!ready) return
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
