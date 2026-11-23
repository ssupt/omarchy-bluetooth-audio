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
  property bool sharedOwner: false

  property bool connectionBaselineReady: false
  property var connectionStates: ({})
  property var deferredConnections: ({})
  property var pendingApplications: ({})
  property var terminalOutcomes: ({})
  property var manualProfileConnections: ({})
  property var defaultErrors: ({})

  readonly property int maximumAttempts: 90
  readonly property int stableTicksBeforeSwitch: 8
  readonly property int switchConfirmationTicks: 12
  readonly property int maximumSwitchAttempts: 3
  readonly property bool hasPending: Object.keys(pendingApplications).length > 0
  property bool profileSwitchBusy: false
  readonly property string defaultError: {
    for (var key in defaultErrors) {
      if (defaultErrors[key]) return String(defaultErrors[key])
    }
    return ""
  }
  property int profileSwitchSequence: 0
  property int activeProfileSwitchId: 0
  property string activeProfileSwitchKey: ""
  property string activeProfileSwitchAddress: ""

  signal refreshRequested()
  signal profileSwitchRequested(string key, string address, string profile, int operationId)
  // The coordinator publishes its authoritative work queue to the mirrored
  // panel instances. Those shadows make an in-flight policy recoverable if a
  // monitor (and therefore the current coordinator item) disappears.
  signal applicationsPublished(var applications)

  function clone(value) {
    return Model.cloneMap(value)
  }

  function setDefaultError(key, message) {
    var text = String(message || "")
    var next = clone(defaultErrors)
    if (text !== "") next[key] = text
    else delete next[key]
    defaultErrors = next
  }

  function pruneConnectionMaps(states) {
    var manuals = {}
    var manualChanged = false
    for (var manualKey in manualProfileConnections) {
      if (states[manualKey] === true) manuals[manualKey] = true
      else manualChanged = true
    }
    if (manualChanged) manualProfileConnections = manuals

    var terminals = {}
    var terminalChanged = false
    for (var terminalKey in terminalOutcomes) {
      if (states[terminalKey] === true) terminals[terminalKey] = terminalOutcomes[terminalKey]
      else terminalChanged = true
    }
    if (terminalChanged) terminalOutcomes = terminals

    var errors = {}
    var errorsChanged = false
    for (var errorKey in defaultErrors) {
      if (states[errorKey] === true) errors[errorKey] = defaultErrors[errorKey]
      else errorsChanged = true
    }
    if (errorsChanged) defaultErrors = errors
  }

  function clearConnectionTrackers(key) {
    if (manualProfileConnections[key]) {
      var manuals = clone(manualProfileConnections)
      delete manuals[key]
      manualProfileConnections = manuals
    }
    if (terminalOutcomes[key]) {
      var terminals = clone(terminalOutcomes)
      delete terminals[key]
      terminalOutcomes = terminals
    }
    if (defaultErrors[key]) setDefaultError(key, "")
  }

  function noteManualProfileSelection(address) {
    var key = Model.normalizedAddress(address)
    if (key === "") return
    var manuals = clone(manualProfileConnections)
    manuals[key] = true
    manualProfileConnections = manuals
    var entry = pendingApplications[key]
    if (entry) {
      var pending = clone(pendingApplications)
      pending[key] = withPatch(entry, {
        manualProfileOverride: true,
        switchRequested: false,
        switchWaitTicks: 0,
        stableTicks: 0
      })
      pendingApplications = pending
      applicationsPublished(pending)
    }
  }

  function recordTerminalOutcome(key, entry, message) {
    var text = String(message || "Bluetooth audio default outcome is unknown")
    setDefaultError(key, text)
    var terminals = clone(terminalOutcomes)
    terminals[key] = {
      policy: entry ? String(entry.policy || "") : "",
      defaultUnknown: true,
      message: text
    }
    terminalOutcomes = terminals
  }

  function initializeDevices(devices) {
    var observation = Model.observeDeviceConnections({}, devices, false)
    connectionStates = observation.states
    pruneConnectionMaps(observation.states)
    connectionBaselineReady = true
  }

  function observeDevices(devices) {
    var observation = Model.observeDeviceConnections(
      connectionStates, devices, connectionBaselineReady)
    connectionStates = observation.states
    pruneConnectionMaps(observation.states)
    // Device bindings can change while the component is still being built.
    // Keep those observations as baseline only; Panel explicitly enables edge
    // delivery from Component.onCompleted once startup state is authoritative.
    if (!connectionBaselineReady) return
    for (var i = 0; i < observation.connected.length; i++) {
      clearConnectionTrackers(observation.connected[i].key)
      queueConnection(observation.connected[i].address)
    }
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
    if (key === "" || pendingApplications[key] || terminalOutcomes[key]) return
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

  function defaultMatches(direction, node) {
    var current = direction === "output"
      ? controller.defaultAudioSink : controller.defaultAudioSource
    return !!current && !!node
      && String(current.name || "") === String(node.name || "")
      && String(current.id || "") === String(node.id || "")
  }

  function advanceDefault(key, entry, direction, node, requests) {
    if (!node) return { entry: entry, confirmed: false, terminal: false }
    var attemptField = direction === "input" ? "inputDefaultAttempts" : "outputDefaultAttempts"
    var signature = audioNodeSignature(node)
    if (entry.defaultRequested) {
      if (!entry.defaultResult)
        return { entry: entry, confirmed: false, terminal: false }
      if (entry.defaultRequested !== direction || entry.defaultSignature !== signature) {
        entry = withPatch(entry, { defaultRequested: "", defaultResult: "",
          defaultSignature: "", defaultWaitTicks: 0 })
      } else if (defaultMatches(direction, node)) {
        var confirmedPatch = { defaultRequested: "", defaultResult: "",
          defaultSignature: "", defaultWaitTicks: 0 }
        confirmedPatch[attemptField] = 0
        entry = withPatch(entry, confirmedPatch)
        return { entry: entry, confirmed: true, terminal: false }
      } else {
        var waited = Number(entry.defaultWaitTicks || 0) + 1
        if (waited < switchConfirmationTicks)
          return { entry: withPatch(entry, { defaultWaitTicks: waited }), confirmed: false, terminal: false }
        entry = withPatch(entry, { defaultRequested: "", defaultResult: "",
          defaultSignature: "", defaultWaitTicks: 0 })
      }
    }
    if (defaultMatches(direction, node)) {
      var matchedPatch = {}
      matchedPatch[attemptField] = 0
      return { entry: withPatch(entry, matchedPatch), confirmed: true, terminal: false }
    }
    var usedAttempts = Number(entry[attemptField] || 0)
    if (usedAttempts >= maximumSwitchAttempts) {
      return {
        entry: entry, confirmed: false, terminal: true,
        error: "Could not confirm the Bluetooth audio default"
      }
    }
    var requestPatch = { defaultRequested: direction,
      defaultSignature: signature, defaultResult: "", defaultWaitTicks: 0 }
    requestPatch[attemptField] = usedAttempts + 1
    entry = withPatch(entry, requestPatch)
    requests.push({ key: key, direction: direction, node: node, signature: signature })
    return { entry: entry, confirmed: false, terminal: false }
  }

  function finishDefaultSwitch(key, direction, signature, result, failure) {
    var entry = pendingApplications[key]
    if (!entry || entry.defaultRequested !== direction
        || entry.defaultSignature !== signature) return
    var pending = clone(pendingApplications)
    var terminal = false
    if (failure) {
      var code = String(failure.code || "")
      if (failure.outcome === "rejected"
          && ["busy", "conflict", "unavailable", "stale_node", "stale_graph"].indexOf(code) !== -1) {
        pending[key] = withPatch(entry, { defaultRequested: "", defaultResult: "",
          defaultSignature: "", defaultWaitTicks: 0 })
      } else {
        recordTerminalOutcome(key, entry,
          String(failure.message || "Bluetooth audio default outcome is unknown"))
        delete pending[key]
        terminal = true
      }
    } else {
      var outcome = String(result && result.outcome || "")
      if (outcome === "persistence_failed")
        setDefaultError(key, String(result.message || "Audio default changed, but its preference could not be saved"))
      pending[key] = withPatch(entry, { defaultResult: outcome || "unconfirmed" })
    }
    pendingApplications = pending
    applicationsPublished(pending)
    if (!terminal) refreshRequested()
  }

  function requestProfileSwitch(key, state, duplex) {
    if (!state || !state.address || !duplex || !duplex.value) return false
    if (profileSwitchBusy || controller.audioProfileChangeBusy) return false

    var operationId = ++profileSwitchSequence
    activeProfileSwitchId = operationId
    activeProfileSwitchKey = String(key)
    activeProfileSwitchAddress = String(state.address)
    profileSwitchBusy = true
    profileSwitchRequested(String(key), String(state.address), String(duplex.value), operationId)
    return true
  }

  function finishProfileSwitch(key, exitCode, operationId) {
    if (String(key) !== activeProfileSwitchKey) return
    if (operationId !== undefined && Number(operationId) !== activeProfileSwitchId) return

    profileSwitchBusy = false
    activeProfileSwitchId = 0
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
    if (keys.length === 0 || !preferencesReady) return
    // Every monitor retains a shadow queue, but only one is allowed to mutate
    // global PipeWire state. The guard is evaluated on every tick so a
    // surviving mirror takes over without a stale declarative binding.
    if (!sharedOwner && typeof controller.isAudioPolicyCoordinator === "function"
        && !controller.isAudioPolicyCoordinator()) return
    // Manual mode changes and policy changes on sibling monitors recreate the
    // same global card endpoints. Do not route against their transient nodes.
    if (controller.audioProfileChangeBusy || controller.deviceActionBusy
        || controller.devicePropertyBusy || controller.manualAudioBusy) return

    var next = {}
    var defaultRequests = []
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
      if (configuredPolicy === "manual") {
        if (defaultErrors[key]) setDefaultError(key, "")
        continue
      }
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
      if (entry.defaultUnknown) {
        recordTerminalOutcome(key, entry, defaultErrors[key] || defaultError)
        continue
      }
      if (entry.defaultRequested && !entry.defaultResult) {
        next[key] = entry
        continue
      }

      var attempts = Number(entry.attempts || 0) + 1
      var expired = attempts >= maximumAttempts
      entry = withPatch(entry, { attempts: attempts })

      var sink = controller.bluetoothAudioSink(device)
      if (entry.policy === "output") {
        var output = advanceDefault(key, entry, "output", sink, defaultRequests)
        if (output.terminal) {
          recordTerminalOutcome(key, entry, output.error)
          continue
        }
        if (!output.confirmed && (sink || attempts < maximumAttempts)) next[key] = output.entry
        continue
      }

      var sinkSignature = audioNodeSignature(sink)
      if (sink && (!entry.outputApplied
          || entry.outputSinkSignature !== sinkSignature)) {
        var outputChange = advanceDefault(key, entry, "output", sink, defaultRequests)
        entry = outputChange.entry
        if (outputChange.terminal) {
          recordTerminalOutcome(key, entry, outputChange.error)
          continue
        }
        if (!outputChange.confirmed) {
          next[key] = entry
          continue
        }
        entry = withPatch(entry, { outputApplied: true,
          outputSinkSignature: sinkSignature })
      }

      var state = controller.audioProfileState(key)
      if (!state) {
        if (attempts < maximumAttempts) next[key] = entry
        continue
      }

      if (Model.audioProfileHasInput(state, state.activeProfile)) {
        var source = controller.bluetoothAudioSource(device)
        if (sink && source && entry.outputApplied) {
          var inputChange = advanceDefault(key, entry, "input", source, defaultRequests)
          if (inputChange.terminal) {
            recordTerminalOutcome(key, entry, inputChange.error)
            continue
          }
          if (!inputChange.confirmed) next[key] = inputChange.entry
          continue
        }
        if (attempts < maximumAttempts) next[key] = entry
        continue
      }

      // A manual mode selection lasts for the current connection; retire the
      // automatic profile switch and re-arm it on the next connection.
      if (entry.manualProfileOverride || manualProfileConnections[key]) {
        if (!sink && attempts < maximumAttempts) next[key] = entry
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
    for (var requestIndex = 0; requestIndex < defaultRequests.length; requestIndex++) {
      var request = defaultRequests[requestIndex]
      var callback = (function(item) {
        return function(result, failure) {
          engine.finishDefaultSwitch(item.key, item.direction,
            item.signature, result, failure)
        }
      })(request)
      var accepted = request.direction === "output"
        ? controller.setDefaultAudioSink(request.node, callback)
        : controller.setDefaultAudioSource(request.node, callback)
      if (!accepted) callback(null, {
        code: "unavailable", outcome: "rejected",
        message: "Bluetooth audio endpoint disappeared"
      })
    }
  }

  Timer {
    interval: 500
    running: engine.automaticRetries && engine.hasPending && engine.preferencesReady
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      engine.refreshRequested()
      engine.applyPending()
    }
  }
}
