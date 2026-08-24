import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Connection-edge tracker and connect-time routing state machine. Keeping it
// outside Panel makes the background behavior independent from whether the
// popout UI is open and prevents UI cursor state from leaking into policy
// retries.
Item {
  id: engine

  required property var controller
  property bool preferencesReady: false

  property var connectionStates: ({})
  property var deferredConnections: ({})
  property var pendingApplications: ({})

  readonly property bool hasPending: Object.keys(pendingApplications).length > 0
  readonly property bool profileSwitchBusy: profileSwitchProc.running

  signal refreshRequested()

  function clone(value) {
    return Model.cloneMap(value)
  }

  function observeDevices(devices) {
    var observation = Model.observeDeviceConnections(connectionStates, devices)
    connectionStates = observation.states
    for (var i = 0; i < observation.connected.length; i++)
      queueConnection(observation.connected[i].address)
  }

  function queueConnection(address) {
    var key = Model.normalizedAddress(address)
    if (key === "" || (typeof controller.isAudioPolicyCoordinator === "function"
        && !controller.isAudioPolicyCoordinator())) return

    if (!preferencesReady) {
      var deferred = clone(deferredConnections)
      deferred[key] = String(address)
      deferredConnections = deferred
      return
    }
    queueReadyConnection(address)
  }

  function queueReadyConnection(address) {
    var key = Model.normalizedAddress(address)
    if (key === "" || pendingApplications[key]) return
    var policy = Model.deviceAudioPolicy(controller.audioPreferences, address)
    if (policy === "manual") return

    var queued = clone(pendingApplications)
    queued[key] = { policy: policy, attempts: 0 }
    pendingApplications = queued
    refreshRequested()
  }

  function flushDeferredConnections() {
    if (!preferencesReady) return
    var deferred = deferredConnections
    deferredConnections = ({})
    for (var key in deferred) queueReadyConnection(deferred[key])
  }

  onPreferencesReadyChanged: if (preferencesReady) flushDeferredConnections()

  function withPatch(entry, patch) {
    var next = clone(entry)
    for (var field in patch) next[field] = patch[field]
    return next
  }

  function requestProfileSwitch(state, duplex) {
    if (!state || !state.address || !duplex || !duplex.value) return false
    if (profileSwitchProc.running || controller.userAudioProfileChangeBusy) return false

    profileSwitchProc.address = String(state.address)
    profileSwitchProc.command = [
      controller.pluginScript("bluetooth-audio-profile-set"),
      String(state.address),
      String(duplex.value)
    ]
    profileSwitchProc.running = true
    return true
  }

  function applyPending() {
    var keys = Object.keys(pendingApplications)
    if (keys.length === 0) return

    var next = {}
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      var entry = pendingApplications[key]
      var attempts = Number(entry.attempts || 0) + 1
      entry = withPatch(entry, { attempts: attempts })

      var device = controller.deviceByAddress(key)
      if (!device || !device.connected) continue

      var sink = controller.bluetoothAudioSink(device)
      if (!sink) {
        // An off or incomplete profile may never expose a sink. Keep retries
        // bounded so the background timer cannot run for the whole session.
        if (attempts < 60) next[key] = entry
        continue
      }

      if (entry.policy === "output") {
        controller.setDefaultAudioSink(sink)
        continue
      }

      if (!entry.outputApplied) controller.setDefaultAudioSink(sink)

      var state = controller.audioProfileState(key)
      if (!state) {
        if (attempts < 16)
          next[key] = withPatch(entry, { outputApplied: true })
        continue
      }

      if (Model.audioProfileHasInput(state, state.activeProfile)) {
        var source = controller.bluetoothAudioSource(device)
        if (source) {
          controller.setDefaultAudioSource(source)
          continue
        }
        if (attempts < 60)
          next[key] = withPatch(entry, { outputApplied: true })
        continue
      }

      var duplex = Model.duplexProfileOption(state)
      if (!duplex) continue

      // WirePlumber may still be restoring a saved duplex profile. Waiting for
      // that profile avoids replacing the user's remembered microphone mode.
      var saved = Model.preferredAudioProfile(controller.audioPreferences, key,
        Model.audioProfileOptions(state), "")
      if (saved !== "" && Model.audioProfileHasInput(state, saved)) {
        if (attempts < 60)
          next[key] = withPatch(entry, { outputApplied: true })
        continue
      }

      var signature = String(state.activeProfile || "")
      var listed = state.profiles || []
      for (var p = 0; p < listed.length; p++)
        signature += "," + String(listed[p] && listed[p].value || "")
      if (signature !== entry.cardSignature) {
        next[key] = withPatch(entry, { cardSignature: signature, stableTicks: 0 })
        continue
      }

      var stableTicks = Number(entry.stableTicks || 0) + 1
      if (stableTicks < 8) {
        next[key] = withPatch(entry, { stableTicks: stableTicks })
        continue
      }

      if (!entry.switchRequested && requestProfileSwitch(state, duplex)) {
        console.info("bluetooth-audio: connect policy switching "
          + key + " to " + duplex.value)
        next[key] = withPatch(entry, {
          outputApplied: true,
          switchRequested: true
        })
        continue
      }
      if (attempts < 60)
        next[key] = withPatch(entry, { outputApplied: true })
    }

    pendingApplications = next
  }

  Process {
    id: profileSwitchProc
    property string address: ""

    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("bluetooth-audio: policy profile switch failed for "
          + address + " exit " + exitCode)
      engine.refreshRequested()
    }
  }

  Timer {
    interval: 500
    running: engine.hasPending
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      engine.refreshRequested()
      engine.applyPending()
    }
  }
}
