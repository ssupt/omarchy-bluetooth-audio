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
  property int audioForgetGeneration: 0
  property var audioForgetAttempts: ({})
  property var audioForgetRetryAt: ({})
  property var audioForgetFailures: ({})
  readonly property int maximumAudioForgetAttempts: 4
  readonly property string audioForgetError: {
    var addresses = Object.keys(audioForgetFailures)
    if (addresses.length === 0) return ""
    var failure = audioForgetFailures[addresses[0]]
    return "Could not remove saved audio data for a forgotten Bluetooth device: "
      + String(failure.message || "Audio cleanup failed")
  }
  property var deviceActions: ({})
  property var deviceActionResults: ({})
  property var manualAudioSelection: null
  property string manualAudioError: ""
  property int manualAudioSequence: 0
  readonly property bool manualAudioBusy: manualAudioSelection !== null
  property var manualProfileOperation: null
  property var manualProfileResult: null
  property int manualProfileSequence: 0
  readonly property bool manualProfileBusy: manualProfileOperation !== null
  readonly property string manualProfileError: {
    var result = manualProfileResult
    if (!result) return ""
    if (result.outcome === "persistence_failed")
      return "Audio mode is active, but its preference could not be saved"
    if (result.outcome === "unknown")
      return "Bluetooth audio mode may have changed: "
        + String(result.message || "the final result could not be confirmed")
    if (result.outcome === "rejected")
      return String(result.message || "Could not change the Bluetooth audio mode")
    return ""
  }
  signal deviceActionFinished(var operation, var result, var failure)
  readonly property var audioControlService: shell ? shell.serviceFor("ssupt.audio-control") : null
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  property alias policyEngine: sharedPolicy
  readonly property string executable: decodeURIComponent(
    String(Qt.resolvedUrl("bin/omarchy-bluetooth-service")).replace(/^file:\/\//, ""))

  onAudioControlServiceChanged: {
    interruptManualAudio()
    interruptAudioForgets()
    flushAudioForgets()
  }
  Connections {
    target: root.audioControlService
    function onReadyChanged() {
      if (!root.audioControlService.ready) root.interruptManualAudio()
      if (!root.audioControlService.ready) root.interruptAudioForgets()
      root.flushAudioForgets()
    }
  }

  function interruptAudioForgets() {
    var failures = Object.assign({}, audioForgetFailures)
    for (var address in audioForgetInFlight)
      failures[address] = {
        outcome: "unknown", message: "Audio service disconnected before cleanup was confirmed"
      }
    audioForgetFailures = failures
    audioForgetGeneration++
    audioForgetInFlight = ({})
    audioForgetRetryTimer.stop()
  }

  function interruptManualAudio() {
    var operation = manualAudioSelection
    if (!operation) return
    manualAudioSelection = null
    manualAudioError = operation.stage === "input"
      ? "Bluetooth output changed, but the microphone result could not be confirmed"
      : "Bluetooth output result could not be confirmed"
    if (operation.unsaved.length > 0)
      manualAudioError += "; output preference could not be saved"
  }

  function pluginScript(name) {
    return decodeURIComponent(String(Qt.resolvedUrl("scripts/" + name))
      .replace(/^file:\/\//, ""))
  }

  function setManualAudioProfile(address, profile) {
    if (manualProfileBusy || sharedPolicy.profileSwitchBusy || !address || !profile)
      return false
    var operation = {
      id: ++manualProfileSequence, address: String(address), profile: String(profile)
    }
    manualProfileResult = null
    manualProfileOperation = operation
    if (ready) {
      request("profile.set", { address: operation.address, profile: operation.profile },
        function(result, failure) {
          root.finishManualAudioProfile(operation.id, result, failure)
        })
    } else {
      manualProfileSetProc.command = [pluginScript("bluetooth-audio-profile-set"),
        operation.address, operation.profile]
      manualProfileSetProc.prepare(operation.id)
      manualProfileSetProc.running = true
    }
    return true
  }

  function finishManualAudioProfile(id, result, failure) {
    var operation = manualProfileOperation
    if (!operation || operation.id !== id) return
    var outcome = failure ? String(failure.outcome || "unknown")
      : String(result && result.outcome || "unknown")
    if (failure && outcome !== "rejected") outcome = "unknown"
    if (!failure && outcome !== "applied" && outcome !== "persistence_failed")
      outcome = "unknown"
    var message = String(failure && failure.message || result && result.message || "")
    manualProfileOperation = null
    manualProfileResult = {
      id: operation.id, address: operation.address, profile: operation.profile,
      outcome: outcome, message: message
    }
  }

  function selectDeviceAudio(address, output, input) {
    if (manualAudioBusy) return false
    var audio = audioControlService
    if (!audio || !audio.ready || !Array.isArray(audio.capabilities)
        || audio.capabilities.indexOf("default.compat") === -1) {
      manualAudioError = "Audio service is unavailable"
      return false
    }
    if (!output || !output.name || !Number.isInteger(output.id)) {
      manualAudioError = "Bluetooth output is unavailable"
      return false
    }
    if (input && (!input.name || !Number.isInteger(input.id))) {
      manualAudioError = "Bluetooth microphone is unavailable"
      return false
    }
    var operation = {
      id: ++manualAudioSequence, address: String(address), stage: "output",
      output: output, input: input, unsaved: []
    }
    manualAudioError = ""
    manualAudioSelection = operation
    sendManualAudioDefault(operation, "output")
    return true
  }

  function sendManualAudioDefault(operation, direction) {
    var target = direction === "output" ? operation.output : operation.input
    audioControlService.request("default.compat", {
      direction: direction, id: target.id, name: target.name,
      previous: target.previous
    }, function(result, failure) {
      root.finishManualAudioDefault(operation.id, direction, result, failure)
    })
  }

  function finishManualAudioDefault(id, direction, result, failure) {
    var operation = manualAudioSelection
    if (!operation || operation.id !== id || operation.stage !== direction) return
    var outcome = String(result && result.outcome || "")
    if (failure || (outcome !== "applied" && outcome !== "persistence_failed")) {
      var detail = String(failure && failure.message || "Audio service did not confirm the change")
      var uncertain = failure && failure.outcome === "unknown"
      if (direction === "output") {
        manualAudioError = (uncertain ? "Bluetooth output may have changed: "
          : "Could not select Bluetooth output: ") + detail
      } else {
        manualAudioError = "Bluetooth output changed, but the microphone "
          + (uncertain ? "result is unknown: " : "could not be selected: ") + detail
        if (operation.unsaved.length > 0)
          manualAudioError += "; output preference could not be saved"
      }
      manualAudioSelection = null
      return
    }
    var unsaved = operation.unsaved.slice()
    if (outcome === "persistence_failed") unsaved.push(direction)
    if (direction === "output" && operation.input) {
      var next = Object.assign({}, operation, { stage: "input", unsaved: unsaved })
      manualAudioSelection = next
      sendManualAudioDefault(next, "input")
      return
    }
    manualAudioSelection = null
    if (unsaved.length > 0)
      manualAudioError = "Bluetooth audio is active, but the " + unsaved.join(" and ")
        + " preference could not be saved"
  }

  function forgetAudioRoutes(address) {
    var key = String(address || "")
    if (key === "") return
    if (pendingAudioForgets.indexOf(key) === -1)
      pendingAudioForgets = pendingAudioForgets.concat([key])
    else if (!audioForgetFailures[key]) return
    var failures = Object.assign({}, audioForgetFailures)
    delete failures[key]
    audioForgetFailures = failures
    var attempts = Object.assign({}, audioForgetAttempts)
    delete attempts[key]
    audioForgetAttempts = attempts
    flushAudioForgets()
  }

  function actionKey(address) {
    return String(address || "").toLowerCase().replace(/[:_-]/g, "")
  }

  function startDeviceAction(action, address, pendingState) {
    var key = actionKey(address)
    if (key === "" || Object.keys(deviceActions).length > 0) return false
    var operation = {
      action: String(action), address: String(address),
      pending: String(pendingState), cancelled: false, requestId: ""
    }
    var actions = Object.assign({}, deviceActions)
    actions[key] = operation
    deviceActions = actions
    var results = Object.assign({}, deviceActionResults)
    delete results[key]
    deviceActionResults = results
    var id = request("device.action", { action: operation.action, address: operation.address },
      function(result, failure) {
        // The service survives every panel. Successful forget cleanup belongs
        // here even when the initiating widget disappeared mid-command.
        if (!failure && result && result.outcome === "applied"
            && operation.action === "forget")
          root.forgetAudioRoutes(operation.address)
        var current = Object.assign({}, root.deviceActions)
        var completedOperation = Object.assign({}, operation, {
          cancelled: !!(current[key] && current[key].cancelled)
        })
        delete current[key]
        root.deviceActions = current
        var completed = Object.assign({}, root.deviceActionResults)
        completed[key] = {
          action: operation.action,
          message: failure && !completedOperation.cancelled
            ? String(failure.message || "Bluetooth operation failed") : "",
          outcome: failure ? String(failure.outcome || "unknown") : "applied"
        }
        root.deviceActionResults = completed
        root.deviceActionFinished(completedOperation, result, failure)
      })
    if (id) {
      operation.requestId = id
      actions = Object.assign({}, deviceActions)
      actions[key] = operation
      deviceActions = actions
    }
    return id !== ""
  }

  function cancelDeviceAction(address) {
    var key = actionKey(address)
    var operation = deviceActions[key]
    if (!operation) return false
    var next = Object.assign({}, deviceActions)
    next[key] = Object.assign({}, operation, { cancelled: true })
    deviceActions = next
    request("device.cancel", { address: operation.address, requestId: operation.requestId })
    return true
  }

  function flushAudioForgets() {
    var audio = audioControlService
    if (!audio || !audio.ready || !Array.isArray(audio.capabilities)
        || audio.capabilities.indexOf("devices.forget") === -1) return
    for (var i = 0; i < pendingAudioForgets.length; i++) {
      var address = pendingAudioForgets[i]
      if (audioForgetInFlight[address] || audioForgetFailures[address]) continue
      if (audioForgetRetryAt[address] > Date.now()) continue
      if (audioForgetRetryAt[address]) {
        var due = Object.assign({}, audioForgetRetryAt)
        delete due[address]
        audioForgetRetryAt = due
      }
      sendAudioForget(audio, address)
    }
    scheduleAudioForgetRetry()
  }

  function scheduleAudioForgetRetry() {
    var nextAt = 0
    for (var address in audioForgetRetryAt) {
      if (pendingAudioForgets.indexOf(address) === -1 || audioForgetInFlight[address]
          || audioForgetFailures[address]) continue
      if (!nextAt || audioForgetRetryAt[address] < nextAt)
        nextAt = audioForgetRetryAt[address]
    }
    if (!nextAt) {
      audioForgetRetryTimer.stop()
      return
    }
    audioForgetRetryTimer.interval = Math.max(1, nextAt - Date.now())
    audioForgetRetryTimer.restart()
  }

  function sendAudioForget(audio, address) {
    var inflight = Object.assign({}, audioForgetInFlight)
    inflight[address] = true
    audioForgetInFlight = inflight
    var attempts = Object.assign({}, audioForgetAttempts)
    attempts[address] = (attempts[address] || 0) + 1
    audioForgetAttempts = attempts
    var generation = audioForgetGeneration
    audio.request("devices.forget", { address: address }, function(_result, failure) {
      if (root.audioForgetGeneration !== generation || root.audioControlService !== audio)
        return
      var next = Object.assign({}, root.audioForgetInFlight)
      delete next[address]
      root.audioForgetInFlight = next
      if (failure) {
        if (failure.outcome === "rejected"
            && (failure.code === "busy" || failure.code === "not_ready")
            && root.audioForgetAttempts[address] < root.maximumAudioForgetAttempts) {
          var retryAt = Object.assign({}, root.audioForgetRetryAt)
          retryAt[address] = Date.now()
            + 500 * Math.pow(2, root.audioForgetAttempts[address] - 1)
          root.audioForgetRetryAt = retryAt
          root.scheduleAudioForgetRetry()
          return
        }
        var failures = Object.assign({}, root.audioForgetFailures)
        failures[address] = {
          outcome: String(failure.outcome || "unknown"),
          message: String(failure.message || "Audio cleanup failed")
        }
        root.audioForgetFailures = failures
        console.warn("Could not remove forgotten Bluetooth audio routes: " + failures[address].message)
      } else {
        root.pendingAudioForgets = root.pendingAudioForgets.filter(function(value) {
          return value !== address
        })
        var remaining = Object.assign({}, root.audioForgetAttempts)
        delete remaining[address]
        root.audioForgetAttempts = remaining
        remaining = Object.assign({}, root.audioForgetRetryAt)
        delete remaining[address]
        root.audioForgetRetryAt = remaining
        remaining = Object.assign({}, root.audioForgetFailures)
        delete remaining[address]
        root.audioForgetFailures = remaining
      }
      root.scheduleAudioForgetRetry()
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
  Process {
    id: manualProfileSetProc
    property int operationId: 0
    property bool collecting: false
    property bool stderrComplete: false
    property bool exitComplete: false
    property int resultCode: 0
    property string resultMessage: ""

    function prepare(id) {
      operationId = id
      collecting = true
      stderrComplete = false
      exitComplete = false
      resultCode = 0
      resultMessage = ""
    }

    function finishCollection() {
      if (!collecting || !stderrComplete || !exitComplete) return
      collecting = false
      if (resultCode === 0)
        root.finishManualAudioProfile(operationId, { outcome: "applied" }, null)
      else if (resultCode === 2)
        root.finishManualAudioProfile(operationId,
          { outcome: "persistence_failed", message: resultMessage }, null)
      else
        root.finishManualAudioProfile(operationId, null, {
          outcome: "rejected", code: "helper_failed",
          message: resultMessage || "Could not change the Bluetooth audio mode"
        })
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        manualProfileSetProc.resultMessage = String(text || "").trim()
        manualProfileSetProc.stderrComplete = true
        manualProfileSetProc.finishCollection()
      }
    }
    onExited: function(exitCode) {
      resultCode = exitCode
      exitComplete = true
      finishCollection()
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
    id: audioForgetRetryTimer
    repeat: false
    onTriggered: root.flushAudioForgets()
  }
  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.pending).length > 0
    onTriggered: root.expirePending(Date.now())
  }
}
