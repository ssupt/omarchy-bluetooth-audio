import QtQuick
import "Model.js" as Model

// Connection-edge tracker and connect-time routing state machine. Keeping it
// outside Panel makes the background behavior independent from whether the
// popout UI is open and prevents UI cursor state from leaking into policy
// retries.
Item {
  id: engine

  required property var controller
  property bool preferencesReady: false
  property bool automaticRetries: true

  property bool connectionBaselineReady: false
  property var connectionStates: ({})
  property var deferredConnections: ({})
  property var pendingApplications: ({})

  readonly property int maximumAttempts: 90
  readonly property int stableTicksBeforeSwitch: 8
  readonly property int switchConfirmationTicks: 12
  readonly property int maximumSwitchAttempts: 3
  readonly property bool hasPending: Object.keys(pendingApplications).length > 0
  property bool profileSwitchBusy: false
  property string activeProfileSwitchKey: ""
  property string activeProfileSwitchAddress: ""

  signal refreshRequested()
  signal profileSwitchRequested(string key, string address, string profile)
  // The coordinator publishes its authoritative work queue to the mirrored
  // panel instances. Those shadows make an in-flight policy recoverable if a
  // monitor (and therefore the current coordinator item) disappears.
  signal applicationsPublished(var applications)

  function clone(value) {
    return Model.cloneMap(value)
  }

  function initializeDevices(devices) {
    var observation = Model.observeDeviceConnections({}, devices, false)
    connectionStates = observation.states
    connectionBaselineReady = true
  }

  function observeDevices(devices) {
    var observation = Model.observeDeviceConnections(
      connectionStates, devices, connectionBaselineReady)
    connectionStates = observation.states
    // Device bindings can change while the component is still being built.
    // Keep those observations as baseline only; Panel explicitly enables edge
    // delivery from Component.onCompleted once startup state is authoritative.
    if (!connectionBaselineReady) return
    for (var i = 0; i < observation.connected.length; i++)
      queueConnection(observation.connected[i].address)
  }

  function queueConnection(address) {
    var key = Model.normalizedAddress(address)
    if (key === "") return

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
    applicationsPublished(queued)
    refreshRequested()
  }

  function adoptApplications(applications) {
    var adopted = {}
    for (var key in applications || {})
      adopted[key] = clone(applications[key])
    pendingApplications = adopted
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

  function audioNodeSignature(node) {
    if (!node) return ""
    var id = node.id !== undefined && node.id !== null ? String(node.id) : ""
    return id + ":" + String(node.name || "")
  }

  function requestProfileSwitch(key, state, duplex) {
    if (!state || !state.address || !duplex || !duplex.value) return false
    if (profileSwitchBusy || controller.audioProfileChangeBusy) return false

    activeProfileSwitchKey = String(key)
    activeProfileSwitchAddress = String(state.address)
    profileSwitchBusy = true
    profileSwitchRequested(String(key), String(state.address), String(duplex.value))
    return true
  }

  function finishProfileSwitch(key, exitCode) {
    if (String(key) !== activeProfileSwitchKey) return

    profileSwitchBusy = false
    activeProfileSwitchKey = ""
    var address = activeProfileSwitchAddress
    activeProfileSwitchAddress = ""
    if (exitCode === 2) {
      console.warn("bluetooth-audio: policy profile is active for "
        + address + ", but its preference could not be saved")
    } else if (exitCode !== 0) {
      console.warn("bluetooth-audio: policy profile switch failed for "
        + address + " exit " + exitCode)
      var entry = pendingApplications[key]
      if (entry && entry.switchRequested) {
        var pending = clone(pendingApplications)
        if (Number(entry.switchAttempts || 0) >= maximumSwitchAttempts) {
          delete pending[key]
        } else {
          pending[key] = withPatch(entry, {
            switchRequested: false,
            switchWaitTicks: 0,
            stableTicks: 0
          })
        }
        pendingApplications = pending
        applicationsPublished(pending)
      }
    }
    refreshRequested()
  }

  function applyPending() {
    var keys = Object.keys(pendingApplications)
    if (keys.length === 0) return
    // Every monitor retains a shadow queue, but only one is allowed to mutate
    // global PipeWire state. The guard is evaluated on every tick so a
    // surviving mirror takes over without a stale declarative binding.
    if (typeof controller.isAudioPolicyCoordinator === "function"
        && !controller.isAudioPolicyCoordinator()) return
    // Manual mode changes and policy changes on sibling monitors recreate the
    // same global card endpoints. Do not route against their transient nodes.
    if (controller.audioProfileChangeBusy || controller.deviceActionBusy
        || controller.devicePropertyBusy) return

    var next = {}
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      var entry = pendingApplications[key]
      var device = controller.deviceByAddress(key)
      if (!device || !device.connected) continue

      // Preferences can change while this queue is waiting for PipeWire to
      // expose a card or endpoint. Re-read the policy before every mutation so
      // selecting Manual cancels stale work and changing policy cannot apply
      // the choice that happened to be captured at connection time.
      var configuredPolicy = Model.deviceAudioPolicy(
        controller.audioPreferences, key)
      if (configuredPolicy === "manual") continue
      if (configuredPolicy !== entry.policy)
        entry = { policy: configuredPolicy, attempts: 0 }

      if (typeof controller.pendingAction === "function"
          && controller.pendingAction(key) !== "") {
        next[key] = entry
        continue
      }

      // Do not consume the policy deadline or touch an endpoint that the safe
      // transition helper is still muting/restoring. A slow helper is bounded
      // internally and receives a fresh confirmation window after it exits.
      if (entry.switchRequested && profileSwitchBusy
          && activeProfileSwitchKey === key) {
        next[key] = entry
        continue
      }

      var attempts = Number(entry.attempts || 0) + 1
      var expired = attempts >= maximumAttempts
      entry = withPatch(entry, { attempts: attempts })

      var sink = controller.bluetoothAudioSink(device)
      if (entry.policy === "output") {
        if (sink) controller.setDefaultAudioSink(sink)
        else if (attempts < maximumAttempts) next[key] = entry
        continue
      }

      var sinkSignature = audioNodeSignature(sink)
      if (sink && (!entry.outputApplied
          || entry.outputSinkSignature !== sinkSignature)) {
        controller.setDefaultAudioSink(sink)
        entry = withPatch(entry, {
          outputApplied: true,
          outputSinkSignature: sinkSignature
        })
      }

      var state = controller.audioProfileState(key)
      if (!state) {
        if (attempts < maximumAttempts) next[key] = entry
        continue
      }

      if (Model.audioProfileHasInput(state, state.activeProfile)) {
        var source = controller.bluetoothAudioSource(device)
        if (sink && source && entry.outputApplied) {
          controller.setDefaultAudioSource(source)
          continue
        }
        if (attempts < maximumAttempts) next[key] = entry
        continue
      }

      // Prefer the user's remembered microphone mode. If WirePlumber does not
      // restore it during the stability grace period, request that exact mode
      // instead of waiting until the policy silently expires.
      var duplex = Model.preferredDuplexProfileOption(
        controller.audioPreferences, key, state)
      if (!duplex) {
        // A microphone policy degrades to output-only for hardware that has no
        // input profile. If its sink is still being created, keep waiting.
        if (!sink && attempts < maximumAttempts) next[key] = entry
        continue
      }

      var signature = String(state.activeProfile || "")
      var listed = state.profiles || []
      for (var p = 0; p < listed.length; p++)
        signature += "," + String(listed[p] && listed[p].value || "")
      if (signature !== entry.cardSignature) {
        if (!expired)
          next[key] = withPatch(entry, { cardSignature: signature, stableTicks: 0 })
        continue
      }

      if (entry.switchRequested) {
        var waitTicks = Number(entry.switchWaitTicks || 0) + 1
        if (waitTicks < switchConfirmationTicks && !expired) {
          next[key] = withPatch(entry, { switchWaitTicks: waitTicks })
        } else if (Number(entry.switchAttempts || 0) < maximumSwitchAttempts
            && attempts < maximumAttempts) {
          // The command exited successfully but the card never reported the
          // requested mode. Clear the in-flight marker and retry after another
          // stability window; audio-profile-set itself is idempotent.
          next[key] = withPatch(entry, {
            switchRequested: false,
            switchWaitTicks: 0,
            stableTicks: 0
          })
        }
        continue
      }

      var stableTicks = Number(entry.stableTicks || 0) + 1
      if (stableTicks < stableTicksBeforeSwitch) {
        if (!expired) next[key] = withPatch(entry, { stableTicks: stableTicks })
        continue
      }

      var switchAttempts = Number(entry.switchAttempts || 0)
      if (switchAttempts >= maximumSwitchAttempts || expired) continue
      if (requestProfileSwitch(key, state, duplex)) {
        console.info("bluetooth-audio: connect policy switching "
          + key + " to " + duplex.value)
        next[key] = withPatch(entry, {
          switchRequested: true,
          switchWaitTicks: 0,
          switchAttempts: switchAttempts + 1
        })
        continue
      }
      if (attempts < maximumAttempts)
        next[key] = withPatch(entry, { stableTicks: stableTicks })
    }

    pendingApplications = next
    applicationsPublished(next)
  }

  Timer {
    interval: 500
    running: engine.automaticRetries && engine.hasPending
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      engine.refreshRequested()
      engine.applyPending()
    }
  }
}
