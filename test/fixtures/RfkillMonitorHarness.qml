import QtQuick
import Quickshell

ShellRoot {
  id: harness
  property string scenario: Quickshell.env("RFKILL_SCENARIO")
  property int stage: 0
  property bool sawBlocked: false
  property double settledAt: 0

  function check(value, message) {
    if (value) return true
    console.error(message)
    Qt.exit(1)
    return false
  }

  RfkillMonitor {
    id: monitor
    onSoftwareBlockedChanged: if (softwareBlocked) harness.sawBlocked = true
  }

  Timer {
    interval: 20
    running: true
    repeat: true
    onTriggered: {
      if (harness.stage === 0) {
        if (harness.scenario === "cap") monitor.retryDelay = monitor.maximumRetryDelay
        monitor.active = true
        harness.stage = 1
      } else if (harness.stage === 1) {
        if (harness.scenario === "cap") {
          if (!monitor.restartPending) return
          if (!harness.check(monitor.retryDelay === monitor.maximumRetryDelay,
              "Watcher retries exceeded their delay cap")) return
        } else if (harness.scenario === "recover") {
          if (!monitor.blocks[3]) {
            if (harness.sawBlocked && !harness.check(monitor.softwareBlocked,
                "Watcher failure discarded the known software block")) return
            return
          }
          if (!harness.check(harness.sawBlocked && !monitor.softwareBlocked
              && monitor.blocks[3].hard && !monitor.blocks[2],
              "Restart did not replace stale switch IDs with the hardware-blocked snapshot")) return
        } else if (harness.scenario === "empty") {
          if (!harness.sawBlocked || monitor.softwareBlocked) return
          if (!harness.check(Object.keys(monitor.blocks).length === 0,
              "Empty snapshot retained stale radio state")) return
        } else if (harness.scenario === "adapter") {
          if (!monitor.softwareBlocked) return
        }
        monitor.active = false
        harness.settledAt = Date.now()
        harness.stage = 2
      } else if (harness.stage === 2 && Date.now() - harness.settledAt > 700) {
        if (!harness.check(!monitor.running && !monitor.restartPending
            && Object.keys(monitor.blocks).length === 0,
            "Disabled watcher retained state or restarted")) return
        if (harness.scenario === "adapter") {
          monitor.active = true
          harness.stage = 3
        } else {
          console.info("PASS: rfkill monitor " + harness.scenario)
          Qt.quit()
        }
      } else if (harness.stage === 3 && monitor.softwareBlocked) {
        if (!harness.check(monitor.running, "Watcher did not restart when the adapter disappeared")) return
        console.info("PASS: rfkill monitor " + harness.scenario)
        Qt.quit()
      }
    }
  }
  Timer {
    interval: 9000
    running: true
    onTriggered: { console.error("Rfkill monitor scenario timed out: " + harness.scenario); Qt.exit(1) }
  }
}
