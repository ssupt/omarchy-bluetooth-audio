import QtQuick
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  property bool active: false
  property var blocks: ({})
  readonly property bool softwareBlocked: Model.rfkillBluetoothBlocked(blocks)
  readonly property bool running: watcher.running
  property var snapshot: ({})
  property bool snapshotReceived: false
  property bool restartPending: false
  property int retryDelay: 500
  readonly property int maximumRetryDelay: 10000
  property bool destroying: false

  onActiveChanged: if (!active) {
    restart.stop()
    restartPending = false
    retryDelay = 500
    blocks = ({})
    snapshot = ({})
  }
  Component.onDestruction: {
    destroying = true
    restart.stop()
  }

  Process {
    id: watcher
    command: ["stdbuf", "-oL", "rfkill", "event"]
    running: root.active && !root.restartPending && !root.destroying
    onStarted: {
      // Each new process reports a complete fresh snapshot. Keep the last
      // known state until that snapshot arrives, including failed retries.
      root.snapshot = ({})
      root.snapshotReceived = false
    }
    stdout: SplitParser {
      onRead: function(line) {
        if (!root.active || root.destroying) return
        root.snapshot = Model.rfkillBluetoothEvent(root.snapshot, line)
        root.snapshotReceived = true
        root.blocks = root.snapshot
      }
    }
    onExited: {
      if (!root.active || root.destroying) return
      root.restartPending = true
      restart.interval = root.retryDelay
      root.retryDelay = Math.min(root.retryDelay * 2, root.maximumRetryDelay)
      restart.restart()
    }
  }
  Timer {
    id: restart
    onTriggered: root.restartPending = false
  }
  Timer {
    interval: 5000
    running: root.active && watcher.running
    onTriggered: {
      root.retryDelay = 500
      // An open event stream with no switches produces no snapshot lines.
      if (!root.snapshotReceived) root.blocks = ({})
    }
  }
}
