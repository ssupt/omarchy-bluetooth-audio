import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth

// One backend connection for all Bluetooth bar widgets. A widget may be
// destroyed when a monitor changes without cancelling an admitted command.
Item {
  id: root
  property var shell: null
  property var manifest: null
  property bool ready: false
  property bool destroying: false
  property string error: ""
  property int sequence: 0
  property string buffer: ""
  property var pending: ({})
  property var expired: ({})
  property var panels: []
  property var controller: null
  property var pendingAudioForgets: []
  property var audioForgetInFlight: ({})
  readonly property var audioControlService: shell ? shell.serviceFor("ssupt.audio-control") : null
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  property alias policyEngine: sharedPolicy
  readonly property string executable: decodeURIComponent(
    String(Qt.resolvedUrl("bin/omarchy-bluetooth-service")).replace(/^file:\/\//, ""))

  onAudioControlServiceChanged: {
    audioForgetInFlight = ({})
    flushAudioForgets()
  }
  Connections {
    target: root.audioControlService
    function onReadyChanged() { root.flushAudioForgets() }
  }

  function forgetAudioRoutes(address) {
    var key = String(address || "")
    if (key === "" || pendingAudioForgets.indexOf(key) !== -1) return
    pendingAudioForgets = pendingAudioForgets.concat([key]).slice(-32)
    flushAudioForgets()
  }

  function flushAudioForgets() {
    var audio = audioControlService
    if (!audio || !audio.ready || !Array.isArray(audio.capabilities)
        || audio.capabilities.indexOf("devices.forget") === -1) return
    for (var i = 0; i < pendingAudioForgets.length; i++) {
      var address = pendingAudioForgets[i]
      if (audioForgetInFlight[address]) continue
      sendAudioForget(audio, address)
    }
  }

  function sendAudioForget(audio, address) {
    var inflight = Object.assign({}, audioForgetInFlight)
    inflight[address] = true
    audioForgetInFlight = inflight
    audio.request("devices.forget", { address: address }, function(_result, failure) {
      var next = Object.assign({}, root.audioForgetInFlight)
      delete next[address]
      root.audioForgetInFlight = next
      if (failure) {
        console.warn("Could not remove forgotten Bluetooth audio routes: " + failure.message)
      } else {
        root.pendingAudioForgets = root.pendingAudioForgets.filter(function(value) {
          return value !== address
        })
      }
    })
  }

  function failPending(message) {
    var current = pending
    pending = ({})
    for (var key in current) {
      var item = current[key]
      if (item.callback) item.callback(null, {
        code: "disconnected", message: message, outcome: "unknown"
      })
    }
  }

  function registerPanel(panel) {
    if (!panel) return
    var next = panels.slice()
    if (next.indexOf(panel) === -1) next.push(panel)
    panels = next
    if (!controller) controller = panel
  }

  function unregisterPanel(panel) {
    var next = panels.filter(function(item) { return item && item !== panel })
    panels = next
    if (controller === panel) controller = next.length > 0 ? next[0] : null
  }

  function request(method, params, callback) {
    if (!backend.running || (!ready && method !== "hello")) {
      if (callback) callback(null, {
        code: "not_ready", message: "Bluetooth service is unavailable", outcome: "rejected"
      })
      return ""
    }
    if (Object.keys(pending).length >= 32) {
      if (callback) callback(null, {
        code: "busy", message: "Too many Bluetooth commands are pending", outcome: "rejected"
      })
      return ""
    }
    var id = "qml-" + (++sequence)
    var next = ({})
    for (var key in pending) next[key] = pending[key]
    next[id] = { callback: callback || null, started: Date.now(), method: method }
    pending = next
    backend.write(JSON.stringify({ version: 1, id: id, method: method, params: params || {} }) + "\n")
    return id
  }

  function consume(chunk) {
    buffer += String(chunk)
    var end = buffer.indexOf("\n")
    while (end >= 0) {
      if (end > 1048576) {
        error = "Bluetooth service sent an oversized response"
        backend.running = false
        return
      }
      var line = buffer.substring(0, end)
      buffer = buffer.substring(end + 1)
      var reply
      try { reply = JSON.parse(line) } catch (_error) {
        error = "Bluetooth service sent an invalid response"
        backend.running = false
        return
      }
      if (!reply || reply.version !== 1 || !reply.id
          || ((reply.result === undefined) === (reply.error === undefined))) {
        error = "Bluetooth service protocol mismatch"
        backend.running = false
        return
      }
      if (!pending[reply.id]) {
        // A queued command may finish after its UI deadline. Its outcome was
        // already reported as unknown; a late reply must not restart the service.
        if (!expired[reply.id]) {
          error = "Bluetooth service protocol mismatch"
          backend.running = false
          return
        }
        var remaining = ({})
        for (var oldId in expired) if (oldId !== reply.id) remaining[oldId] = true
        expired = remaining
        end = buffer.indexOf("\n")
        continue
      }
      var item = pending[reply.id]
      var next = ({})
      for (var key in pending) if (key !== reply.id) next[key] = pending[key]
      pending = next
      if (item.callback) item.callback(reply.result || null, reply.error || null)
      end = buffer.indexOf("\n")
    }
    if (buffer.length > 1048576) {
      error = "Bluetooth service sent an oversized response"
      backend.running = false
    }
  }

  function expirePending(now) {
    var current = pending
    var next = ({})
    var retired = ({})
    var timedOut = []
    for (var oldId in expired) retired[oldId] = true
    for (var key in current) {
      var item = current[key]
      if (now - item.started < 60000) next[key] = item
      else {
        retired[key] = true
        timedOut.push(item)
      }
    }
    var ids = Object.keys(retired)
    while (ids.length > 64) delete retired[ids.shift()]
    pending = next
    expired = retired
    for (var i = 0; i < timedOut.length; i++) {
      if (timedOut[i].callback) timedOut[i].callback(null, {
        code: "timeout", message: "Bluetooth command outcome is unknown", outcome: "unknown"
      })
    }
  }

  function handshake() {
    request("hello", {}, function(result, failure) {
      if (failure || !result || result.name !== "omarchy-bluetooth-service"
          || result.protocolVersion !== 1) {
        error = "Bluetooth service protocol mismatch"
        backend.running = false
        return
      }
      ready = true
      error = ""
    })
  }

  onDevicesChanged: sharedPolicy.observeDevices(devices)
  Component.onCompleted: {
    sharedPolicy.initializeDevices(devices)
    launchTimer.start()
  }
  Component.onDestruction: {
    destroying = true
    launchTimer.stop()
    reconnectTimer.stop()
    backend.running = false
    failPending("Bluetooth service stopped")
  }

  Process {
    id: backend
    command: [root.executable, "--stdio"]
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consume(chunk) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { console.warn("Bluetooth service:", String(chunk).slice(0, 1024)) }
    }
    onStarted: root.handshake()
    onExited: {
      root.ready = false
      root.buffer = ""
      root.expired = ({})
      root.failPending("Bluetooth service disconnected; check the operation's live state")
      if (!root.destroying && !reconnectTimer.running) reconnectTimer.start()
    }
  }
  BluetoothAudioPolicyEngine {
    id: sharedPolicy
    controller: root.controller
    preferencesReady: !!root.controller && root.controller.audioPreferencesReady
    automaticRetries: !!root.controller && root.ready
    sharedOwner: true
    onRefreshRequested: {
      if (root.controller) root.controller.refreshAudioProfiles()
    }
    onProfileSwitchRequested: function(key, address, profile) {
      root.request("profile.set", { address: address, profile: profile },
        function(result, failure) {
          var code = failure ? 1
            : result && result.outcome === "persistence_failed" ? 2 : 0
          if (code === 2 && root.controller && root.controller.audioPreferencesError === "")
            root.controller.audioPreferenceWriteError =
              "Audio mode is active, but its preference could not be saved"
          sharedPolicy.finishProfileSwitch(key, code)
        })
    }
  }
  Timer {
    id: launchTimer
    interval: 1
    onTriggered: if (!root.destroying) backend.running = true
  }
  Timer {
    id: reconnectTimer
    interval: 5000
    onTriggered: if (!root.destroying) backend.running = true
  }
  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.pending).length > 0
    onTriggered: root.expirePending(Date.now())
  }
}
