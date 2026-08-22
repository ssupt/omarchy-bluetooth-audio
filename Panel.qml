import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.bluetooth"
  ipcTarget: "omarchy.bluetooth"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the toggleBluetooth method below.
  manageIpc: false

  // Address -> "connecting" | "disconnecting" | "forgetting".
  // The plugin-local helper reports command failures; this map keeps the
  // panel responsive while successful operations propagate through BlueZ.
  property var pendingActions: ({})
  // Normalized address -> { action, message }. Failures stay attached to the
  // device row until the user retries or live BlueZ state proves the action
  // completed after all.
  property var deviceActionFailures: ({})
  property var activeDeviceAction: null
  property var lastExitedDeviceAction: null
  property string deviceActionStderr: ""
  property bool deviceActionCancelRequested: false

  // Device details deliberately retain only a stable address plus primitive
  // projections. Renaming can re-sort a row, blocking can move it between
  // sections, and forgetting destroys the BlueZ QObject altogether.
  property string deviceDetailsAddress: ""
  property int deviceDetailsIndex: 0
  // Cursor stops inside the details page. The audio-policy row sits between
  // the name field and the toggles; indices are named because inserting or
  // reordering stops silently breaks every literal elsewhere.
  readonly property int detailsRenameIndex: 0
  readonly property int detailsAudioPolicyIndex: 1
  readonly property int detailsTrustedIndex: 2
  readonly property int detailsBlockedIndex: 3
  readonly property int detailsWakeIndex: 4
  readonly property int detailsForgetIndex: 5
  property bool forgetConfirmationOpen: false
  property var pendingDeviceProperty: null
  property var lastExitedDeviceProperty: null
  property string devicePropertyStderr: ""
  property string devicePropertyError: ""

  // Connect-time audio policies. policyWatchedConnections is the set of
  // addresses seen connected by the previous diff, so a device entering the
  // connected list queues its stored policy exactly once per connection —
  // battery or alias churn that merely rewrites the list must not re-trigger
  // it. pendingPolicyApplications holds normalized address -> policy while
  // the device's PipeWire endpoints are still appearing.
  property var policyWatchedConnections: ({})
  property var pendingPolicyApplications: ({})
  property int policyApplicationAttempts: 0

  readonly property var adapter: Bluetooth.defaultAdapter

  // True while this instance owes BlueZ a StopDiscovery: set when it starts
  // discovery (or opens onto a session already running) and cleared once
  // discovery is confirmed down after close. Ownership, not state — BlueZ's
  // Discovering property also reflects sessions other clients hold, which are
  // never this panel's to stop.
  property bool owesDiscoveryStop: false
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var pipewireNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var defaultAudioSink: Pipewire.defaultAudioSink
  readonly property var defaultAudioSource: Pipewire.defaultAudioSource
  readonly property string audioPreferencesPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/audio-preferences.json"
  }
  readonly property string audioControlManifestPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/plugins/ssupt.audio-control/manifest.json"
  }
  readonly property string audioControlRulesPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/audio-rules.json"
  }
  property var audioControlAliases: ({})
  property var audioPreferences: Model.parseAudioPreferences("")
  readonly property var audioPluginRegistry: bar && bar.shell ? bar.shell.pluginRegistry : null
  property bool audioControlInstalled: false
  onAudioPluginRegistryChanged: Qt.callLater(function() { root.refreshAudioControlInstalled() })
  onAudioControlInstalledChanged: if (!audioControlInstalled && headerIndex === 0) headerIndex = 1

  // BlueZ owns pairing and connection state; PipeWire owns the audio card's
  // active profile and therefore the codec/microphone mode offered here.
  property var audioProfiles: ({})
  property string audioProfileReadError: ""
  property string audioProfileSetError: ""
  readonly property string audioProfileError: audioProfileSetError !== ""
    ? audioProfileSetError : audioProfileReadError
  property var pendingAudioProfile: null
  property var unconfirmedAudioProfile: null
  property bool audioProfileMenuOpen: false

  function pluginScript(name) {
    var url = String(Qt.resolvedUrl("scripts/" + name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function audioControlScript(name) {
    return audioControlManifestPath.replace(/\/manifest\.json$/, "") + "/scripts/" + name
  }

  function deviceLabel(device) {
    return Model.deviceLabel(device)
  }

  // The name this panel displays for a device. With the companion enabled
  // its alias wins — the two plugins must agree on one label per device —
  // falling back to the BlueZ alias. Node names are tried live first, then
  // derived from the address so renamed-but-disconnected devices still
  // resolve (bluez_output pairs use underscores and a .1 suffix, sources
  // keep colons).
  function audioControlAliasFor(address) {
    if (!audioControlInstalled || !address) return ""
    var keys = []
    var device = deviceByAddress(address)
    if (device) {
      var sink = bluetoothAudioSink(device)
      if (sink && sink.name) keys.push(String(sink.name))
      var source = bluetoothAudioSource(device)
      if (source && source.name) keys.push(String(source.name))
    }
    var mac = String(address).trim().toUpperCase().replace(/[^0-9A-F]/g, "")
    if (mac.length === 12) {
      keys.push("bluez_output." + mac.match(/../g).join("_") + ".1")
      keys.push("bluez_input." + String(address).trim())
    }
    for (var i = 0; i < keys.length; i++) {
      var alias = audioControlAliases[keys[i]]
      if (alias) return String(alias)
    }
    return ""
  }

  function deviceDisplayName(device) {
    if (!device) return ""
    var alias = audioControlAliasFor(device.address)
    return alias !== "" ? alias : Model.deviceLabel(device)
  }

  function isUuidLike(value) {
    return Model.isUuidLike(value)
  }

  function isAddressLike(value) {
    return Model.isAddressLike(value)
  }

  function hasHumanName(device) {
    return Model.hasHumanName(device)
  }

  readonly property var deviceGroups: Model.deviceLists(devices)
  readonly property var connectedDevices: deviceGroups.connected || []
  readonly property var knownDevices: deviceGroups.known || []
  readonly property var discoveredDevices: deviceGroups.discovered || []

  readonly property string icon: {
    if (!adapter) return ""
    if (!adapter.enabled) return "󰂲"
    if (connectedDevices.length > 0) return "󰂱"
    return "󰂯"
  }

  property int phraseIndex: 0
  readonly property var activePhrases: [
    "Untangling wires",
    "Streaming vikings",
    "Pairing mysteries",
    "Herding headsets",
    "Taming radios",
    "Summoning speakers",
    "Wrangling codecs",
    "Polishing packets"
  ]
  readonly property bool rotatingPhrases: adapter && adapter.enabled
  readonly property string heroStatusText: {
    if (!adapter) return "No adapter"
    if (!adapter.enabled) return "Turned Off"
    return activePhrases[phraseIndex % activePhrases.length]
  }

  // Single cursor model shared by keyboard and mouse. Sections:
  //   "connected"  — currently connected devices; Enter disconnects.
  //   "known"      — remembered devices; Enter connects.
  //   "discovered" — unremembered devices visible while scanning; Enter connects.
  // Visuals always come from CursorSurface (hasCursor / current),
  // never from containsMouse. Mouse hover updates root cursor state too,
  // guaranteeing one highlight on screen.
  property string focusSection: "connected"
  property int selectedIndex: 0
  // Empty selects the device row. Rows expose details, while connected audio
  // devices add explicit default-audio and preferred-mode actions.
  property string focusedAction: ""  // "" | "audio" | "details" | "profile" | "retry" | "cancel"
  property bool cursorActive: false
  property int headerIndex: 1

  // Stable identity for the focused device. Devices move between sections as
  // they connect, disconnect, pair, or get forgotten, so follow the BlueZ
  // address across section changes instead of preserving a stale row index.
  property string focusedDeviceAddress: ""

  // "header" is a virtual horizontal section for companion settings + power.
  // It sits above the device sections so the adapter can still be toggled by
  // keyboard when it is off and no device rows exist.
  readonly property bool settingsHeaderHasCursor: cursorActive && focusSection === "header" && headerIndex === 0
  readonly property bool powerHeaderHasCursor: cursorActive && focusSection === "header" && headerIndex === 1
  readonly property string toggleHint: root.adapter && root.adapter.enabled ? "Turn Bluetooth off" : "Turn Bluetooth on"

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : "transparent"

  function sectionCount(section) {
    if (section === "connected") return connectedDevices.length
    if (section === "known") return knownDevices.length
    if (section === "discovered") return discoveredDevices.length
    return 0
  }

  function sectionVisible(section) {
    if (section === "connected") return connectedDevices.length > 0
    if (section === "known") return knownDevices.length > 0
    if (section === "discovered") return adapter && adapter.discovering && discoveredDevices.length > 0
    return false
  }

  readonly property var visibleSections: {
    return Model.visibleSections(deviceGroups, adapter && adapter.discovering)
  }

  function devicesForSection(section) {
    return Model.sectionDevices(deviceGroups, section)
  }

  // The scrollable half of the panel — remembered devices, then whatever the
  // scan turned up — flattened into one model so a ListView can own the
  // viewport. Each entry carries the section it came from, which is what lets
  // the delegate and the cursor keep working in section-relative terms.
  readonly property var scrollRows: {
    var rows = []
    for (var k = 0; k < knownDevices.length; k++)
      rows.push({ dev: Model.deviceRow(knownDevices[k]), section: "known", indexInSection: k })
    if (sectionVisible("discovered"))
      for (var d = 0; d < discoveredDevices.length; d++)
        rows.push({ dev: Model.deviceRow(discoveredDevices[d]), section: "discovered", indexInSection: d })
    return rows
  }

  // Connected devices render above the scroll area; same primitives-only
  // projection so those delegates never hold Device QObject wrappers either.
  readonly property var connectedRows: {
    var rows = []
    for (var i = 0; i < connectedDevices.length; i++)
      rows.push(Model.deviceRow(connectedDevices[i]))
    return rows
  }

  readonly property var deviceDetailsRow: {
    var address = Model.normalizedAddress(deviceDetailsAddress)
    if (address === "") return null
    var devs = devices || []
    for (var i = 0; i < devs.length; i++) {
      if (devs[i] && Model.normalizedAddress(devs[i].address) === address)
        return Model.deviceRow(devs[i])
    }
    return null
  }
  readonly property bool deviceDetailsOpen: deviceDetailsAddress !== ""
  readonly property bool deviceDetailsForgetAvailable: !!deviceDetailsRow
    && (deviceDetailsRow.connected || deviceDetailsRow.paired
      || deviceDetailsRow.bonded || deviceDetailsRow.trusted
      || deviceDetailsRow.blocked)
  // Policies target audio hardware; judged from BlueZ's icon class because
  // PipeWire card state only exists while connected.
  readonly property bool deviceDetailsIsAudio: !!deviceDetailsRow
    && Model.isAudioDevice(String(deviceDetailsRow.icon || ""),
      String(deviceDetailsRow.name || deviceDetailsRow.deviceName || ""))
  readonly property int deviceDetailsActionCount: !deviceDetailsRow ? 0
    : (deviceDetailsForgetAvailable ? 6 : 5) - (deviceDetailsIsAudio ? 0 : 1)
  readonly property bool devicePropertyBusy: pendingDeviceProperty !== null
  readonly property bool deviceDetailsActionBusy: !!activeDeviceAction
    && Model.normalizedAddress(activeDeviceAction.address)
      === Model.normalizedAddress(deviceDetailsAddress)
  readonly property bool deviceDetailsControlsBusy: devicePropertyBusy
    || deviceDetailsActionBusy || pendingAction(deviceDetailsAddress) !== ""
  onDeviceDetailsActionCountChanged: if (deviceDetailsOpen)
    setDeviceDetailsCursor(deviceDetailsIndex)

  // Live BlueZ device behind a row. Rows carry primitives only, so actions
  // resolve the backend object here rather than holding a wrapper that can
  // dangle mid-incubation. `devices` is already the raw device array (see the
  // property declaration), so it is iterated directly.
  function deviceByAddress(address) {
    var normalized = Model.normalizedAddress(address)
    if (normalized === "") return null
    var devs = devices || []
    for (var i = 0; i < devs.length; i++) {
      if (devs[i] && Model.normalizedAddress(devs[i].address) === normalized) return devs[i]
    }
    return null
  }

  function deviceFor(row) {
    return row && row.dev ? deviceByAddress(row.dev.address) : null
  }

  // Flat position of the keyboard cursor, or -1 while it sits on the hero or
  // in the connected list (both of which live outside the scroll area).
  readonly property int scrollRowIndex: {
    if (focusSection !== "known" && focusSection !== "discovered") return -1
    for (var i = 0; i < scrollRows.length; i++)
      if (scrollRows[i].section === focusSection && scrollRows[i].indexInSection === selectedIndex) return i
    return -1
  }

  // A row opens a section when it is the first of its kind in the flat list.
  function scrollSectionTitle(index) {
    var rows = scrollRows
    if (index < 0 || index >= rows.length) return ""
    if (index > 0 && rows[index - 1].section === rows[index].section) return ""
    return rows[index].section === "known" ? "PAIRED" : "AVAILABLE"
  }

  function audioSinks() {
    var sinks = []
    for (var i = 0; i < pipewireNodes.length; i++) {
      var node = pipewireNodes[i]
      if (node && node.isSink && !node.isStream) sinks.push(node)
    }
    return sinks
  }

  function audioSources() {
    var sources = []
    for (var i = 0; i < pipewireNodes.length; i++) {
      var node = pipewireNodes[i]
      if (Model.isAudioSource(node)) sources.push(node)
    }
    return sources
  }

  readonly property string currentAudioSinkName: Model.currentAudioNodeName(
    audioPreferences, "output", defaultAudioSink, audioSinks())

  function loadAudioPreferences(raw) {
    audioPreferences = Model.parseAudioPreferences(raw)
  }

  function refreshAudioControlInstalled() {
    if (audioPluginRegistry && audioPluginRegistry.installedPlugins
        && typeof audioPluginRegistry.isEnabled === "function") {
      audioControlInstalled = !!audioPluginRegistry.installedPlugins["ssupt.audio-control"]
        && audioPluginRegistry.isEnabled("ssupt.audio-control")
      return
    }
    if (!audioControlCheckProc.running) audioControlCheckProc.running = true
  }

  function bluetoothAudioSink(device) {
    var sinks = audioSinks()
    for (var i = 0; i < sinks.length; i++) {
      if (Model.bluetoothSinkMatchesDevice(sinks[i], device)) return sinks[i]
    }
    return null
  }

  function bluetoothAudioSource(device) {
    var sources = audioSources()
    for (var i = 0; i < sources.length; i++) {
      if (Model.bluetoothSourceMatchesDevice(sources[i], device)) return sources[i]
    }
    return null
  }

  function audioUseActionAvailable(device) {
    return !!device && device.connected && !!bluetoothAudioSink(device)
  }

  function audioProfileState(address) {
    return Model.audioProfileState(audioProfiles, address)
  }

  function audioProfileOptions(address) {
    return Model.audioProfileOptions(audioProfileState(address))
  }

  function audioProfileActionAvailable(device) {
    if (!device || !device.connected) return false
    var state = audioProfileState(device.address)
    var options = Model.audioProfileOptions(state)
    if (options.length > 1) return true
    return options.length === 1
      && String(state ? state.activeProfile || "" : "") !== String(options[0].value)
  }

  function audioProfileHasInput(address) {
    var state = audioProfileState(address)
    return Model.audioProfileHasInput(state, state ? state.activeProfile : "")
  }

  function deviceAudioPolicy(address) {
    return Model.deviceAudioPolicy(audioPreferences, address)
  }

  // The write is detached and fast; FileView's change watcher reloads the
  // file and every policy binding re-evaluates from disk state.
  // "manual" must pass here even though it is never stored: selecting it
  // removes the stored entry instead of adding one.
  function setDeviceAudioPolicy(policy) {
    if (!deviceDetailsAddress || Model.audioPolicyOrder().indexOf(policy) < 0) return
    Quickshell.execDetached([
      pluginScript("audio-preferences"),
      "set-policy",
      String(deviceDetailsAddress),
      String(policy)
    ])
  }

  function stepDeviceAudioPolicy(delta) {
    if (!deviceDetailsAddress) return
    var order = Model.audioPolicyOrder()
    var index = order.indexOf(deviceAudioPolicy(deviceDetailsAddress))
    if (index < 0) index = 0
    index = ((index + delta) % order.length + order.length) % order.length
    setDeviceAudioPolicy(order[index])
  }

  // What AUDIO ON CONNECT will actually do, given the device's real
  // capabilities and remembered mode. Only a live card can answer whether a
  // microphone exists at all, so disconnected devices get capability-neutral
  // copy instead of claims the state cannot back.
  readonly property string connectPolicyHint: {
    if (!deviceDetailsRow) return ""
    var policy = deviceAudioPolicy(deviceDetailsAddress)
    if (policy === "manual")
      return "Applied the next time this device connects."
    if (policy === "output")
      return "Makes this device the default output the next time it connects."

    var state = audioProfileState(deviceDetailsAddress)
    if (!state)
      return "Makes this device the default output and input the next time it connects."
    var duplex = Model.duplexProfileOption(state)
    if (!duplex)
      return "This device has no modes with a microphone; only its output is used on connect."
    var saved = Model.preferredAudioProfile(audioPreferences, deviceDetailsAddress,
      Model.audioProfileOptions(state), "")
    if (saved !== "" && !audioProfileHasInput(state, saved))
      return "Connects in “" + duplex.label
        + "” so the microphone is available; this becomes the device's audio mode while the policy is selected."
    return "Makes this device the default output and input the next time it connects."
  }

  function refreshAudioProfiles() {
    if (!opened || connectedDevices.length === 0 || audioProfilesProc.running) return
    audioProfilesProc.running = true
  }

  function updateAudioProfiles(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
        throw new Error("invalid profile state")
      audioProfiles = parsed
      audioProfileReadError = ""

      var expected = pendingAudioProfile || unconfirmedAudioProfile
      if (expected) {
        var state = Model.audioProfileState(parsed, expected.address)
        if (state && String(state.activeProfile || "") === expected.profile) {
          pendingAudioProfile = null
          unconfirmedAudioProfile = null
          audioProfileSetError = ""
          audioProfilePendingTimeout.stop()
        }
      }
    } catch (e) {
      audioProfiles = ({})
      audioProfileReadError = "Could not read Bluetooth audio modes"
    }
  }

  function setAudioProfile(address, profile) {
    if (audioProfileSetProc.running || pendingAudioProfile || !address || !profile) return
    var options = audioProfileOptions(address)
    var available = false
    for (var i = 0; i < options.length; i++) {
      if (String(options[i].value) === String(profile)) {
        available = true
        break
      }
    }
    if (!available) return

    pendingAudioProfile = {
      address: Model.normalizedAddress(address),
      profile: String(profile)
    }
    unconfirmedAudioProfile = pendingAudioProfile
    audioProfileSetError = ""
    audioProfileSetProc.command = [
      pluginScript("bluetooth-audio-profile-set"),
      String(address),
      String(profile)
    ]
    audioProfileSetProc.running = true
  }

  function closeAudioProfileMenus(exceptIndex) {
    if (!connectedRepeater) return
    for (var i = 0; i < connectedRepeater.count; i++) {
      if (i === exceptIndex) continue
      var row = connectedRepeater.itemAt(i)
      if (row) row.closeProfileMenu()
    }
  }

  function setDefaultAudioSink(sink) {
    if (!sink) return
    var previousSinkName = defaultAudioSink && defaultAudioSink.name
      ? String(defaultAudioSink.name) : ""
    Pipewire.preferredDefaultAudioSink = sink
    if (sink.id !== undefined && sink.name) {
      var command = audioControlInstalled
        ? [audioControlScript("audio-output-set-default"), String(sink.id),
            String(sink.name), previousSinkName]
        : ["omarchy-audio-output-set-default", String(sink.id), String(sink.name)]
      Quickshell.execDetached(command)
      Quickshell.execDetached([
        pluginScript("audio-preferences"),
        "set-default",
        "output",
        String(sink.name)
      ])
    }
  }

  function setDefaultAudioSource(source) {
    if (!source) return
    var previousSourceName = defaultAudioSource && defaultAudioSource.name
      ? String(defaultAudioSource.name) : ""
    Pipewire.preferredDefaultAudioSource = source
    if (source.id !== undefined && source.name) {
      var command = audioControlInstalled
        ? [audioControlScript("audio-input-set-default"), String(source.id),
            String(source.name), previousSourceName]
        : ["omarchy-audio-input-set-default", String(source.id), String(source.name)]
      Quickshell.execDetached(command)
      Quickshell.execDetached([
        pluginScript("audio-preferences"),
        "set-default",
        "input",
        String(source.name)
      ])
    }
  }

  function useDeviceForAudio(device) {
    if (!device) return
    var sink = bluetoothAudioSink(device)
    if (!sink) return
    setDefaultAudioSink(sink)

    // High-fidelity Bluetooth profiles expose output only. Communication
    // profiles also expose a matching microphone; when present, selecting the
    // device for audio makes that source the default as well.
    var source = audioProfileHasInput(device.address) ? bluetoothAudioSource(device) : null
    if (source) setDefaultAudioSource(source)
  }

  function deviceAt(section, index) {
    var list = devicesForSection(section)
    return index >= 0 && index < list.length ? list[index] : null
  }

  function cloneMap(map) {
    return Model.cloneMap(map)
  }

  function pendingAction(address) {
    return Model.pendingAction(pendingActions, address)
  }

  function setPendingAction(address, action) {
    if (!address) return
    pendingActions = Model.withPendingAction(pendingActions, address, action)
    if (action) pendingTimeout.restart()
  }

  function deviceActionFailure(address) {
    return Model.deviceActionFailure(deviceActionFailures, address)
  }

  function setDeviceActionFailure(address, action, message) {
    deviceActionFailures = Model.withDeviceActionFailure(
      deviceActionFailures, address, action, message)
  }

  function recoveryAction(address) {
    if (activeDeviceAction
        && Model.normalizedAddress(activeDeviceAction.address) === Model.normalizedAddress(address)
        && activeDeviceAction.action === "pair" && !deviceActionCancelRequested)
      return "cancel"
    return deviceActionFailure(address) ? "retry" : ""
  }

  function deviceCommand(action, address) {
    return [pluginScript("bluetooth-device-action"), action, address]
  }

  function devicePropertyCommand(propertyName, dbusPath, value) {
    return [pluginScript("bluetooth-device-property"), propertyName, dbusPath,
      typeof value === "boolean" ? (value ? "true" : "false") : String(value)]
  }

  function defaultDeviceActionError(action) {
    if (action === "pair") return "Could not pair with the device"
    if (action === "connect") return "Could not connect to the device"
    if (action === "disconnect") return "Could not disconnect the device"
    if (action === "forget") return "Could not forget the device"
    return "The Bluetooth operation failed"
  }

  function runDeviceAction(device, action, pending) {
    if (!device || !device.address || deviceActionProc.running) return
    setDeviceActionFailure(device.address, "", "")
    lastExitedDeviceAction = null
    deviceActionStderr = ""
    deviceActionCancelRequested = false
    activeDeviceAction = {
      address: String(device.address),
      action: String(action),
      pending: String(pending)
    }
    setPendingAction(device.address, pending)
    deviceActionProc.command = deviceCommand(action, device.address)
    deviceActionProc.running = true
  }

  function connectDevice(device) {
    if (!device || device.connected) return
    if (device.paired || device.bonded || device.trusted) runDeviceAction(device, "connect", "connecting")
    else runDeviceAction(device, "pair", "connecting")
  }

  function disconnectDevice(device) {
    if (!device || !device.address) return
    if (!device.connected) return
    runDeviceAction(device, "disconnect", "disconnecting")
  }

  function forgetDevice(device) {
    if (!device || !device.address) return
    runDeviceAction(device, "forget", "forgetting")
  }

  function openDeviceDetails(device) {
    if (!device || !device.address) return
    closeAudioProfileMenus(-1)
    audioProfileMenuOpen = false
    deviceDetailsAddress = String(device.address)
    focusedDeviceAddress = String(device.address)
    deviceDetailsIndex = 0
    forgetConfirmationOpen = false
    devicePropertyError = ""
    Qt.callLater(function() {
      if (!root.deviceDetailsOpen) return
      var details = root.deviceDetailsRow
      detailsNameField.text = details
        ? (root.deviceDisplayName(details) || String(details.deviceName || "")) : ""
      detailsScroll.contentY = 0
      keyCatcher.forceActiveFocus()
    })
  }

  function closeDeviceDetails() {
    if (!deviceDetailsOpen) return
    forgetConfirmationOpen = false
    devicePropertyError = ""
    if (detailsNameField.activeFocus) detailsNameField.focus = false
    deviceDetailsAddress = ""
    deviceDetailsIndex = 0
    reselectFocusedDevice()
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function setDeviceDetailsCursor(index) {
    var count = deviceDetailsActionCount
    if (count <= 0) {
      deviceDetailsIndex = 0
      return
    }
    deviceDetailsIndex = Math.max(0, Math.min(count - 1, index))
    Qt.callLater(function() { detailsScroll.ensureCursorVisible() })
  }

  function moveDeviceDetailsCursor(delta) {
    if (deviceDetailsActionCount <= 0) return
    var target = deviceDetailsIndex + delta
    // The policy row is hidden for non-audio devices; step over the hole
    // instead of letting the cursor rest on an invisible stop.
    var guard = 0
    while (target >= 0 && target < deviceDetailsActionCount
        && !detailsStopAvailable(target) && guard++ < 6)
      target += delta
    setDeviceDetailsCursor(target)
  }

  function detailsStopAvailable(index) {
    return index !== detailsAudioPolicyIndex || deviceDetailsIsAudio
  }

  function beginDeviceRename() {
    if (!deviceDetailsRow || deviceDetailsControlsBusy) return
    detailsNameField.text = String(root.deviceDisplayName(deviceDetailsRow)
      || deviceDetailsRow.deviceName || "")
    detailsNameField.selectAll()
    detailsNameField.forceActiveFocus()
  }

  function cancelDeviceRename() {
    var details = deviceDetailsRow
    detailsNameField.text = details
      ? (root.deviceDisplayName(details) || String(details.deviceName || "")) : ""
    detailsNameField.focus = false
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function liveDeviceProperty(device, propertyName) {
    if (!device) return undefined
    if (propertyName === "name") return String(device.name || device.deviceName || "").trim()
    if (propertyName === "trusted") return !!device.trusted
    if (propertyName === "blocked") return !!device.blocked
    if (propertyName === "wakeAllowed") return !!device.wakeAllowed
    return undefined
  }

  function updateDeviceProperty(propertyName, value, expected, errorMessage) {
    if (deviceDetailsControlsBusy) return
    var device = deviceByAddress(deviceDetailsAddress)
    if (!device) {
      devicePropertyError = "This device is no longer available."
      return
    }

    if (liveDeviceProperty(device, propertyName) === expected) {
      devicePropertyError = ""
      return
    }

    var details = deviceDetailsRow
    if (!details || !details.dbusPath) {
      devicePropertyError = "Could not find this device's BlueZ object."
      return
    }

    pendingDeviceProperty = {
      address: String(device.address),
      dbusPath: String(details.dbusPath),
      propertyName: String(propertyName),
      expected: expected,
      errorMessage: String(errorMessage)
    }
    lastExitedDeviceProperty = null
    devicePropertyStderr = ""
    devicePropertyError = ""
    devicePropertyProc.command = devicePropertyCommand(
      propertyName, details.dbusPath, value)
    devicePropertyProc.running = true
  }

  // With the companion plugin enabled, a rename must also land in its
  // device-alias store so the Advanced Audio window shows the same label.
  // That store keys by PipeWire node name, so only live endpoints can be
  // mirrored — the same devices its own rename flow operates on. An empty
  // alias deletes the entries, matching the restore-original-name behavior
  // of the BlueZ write above.
  function syncAudioControlAliases(address, alias) {
    if (!audioControlInstalled || !address) return
    var device = deviceByAddress(address)
    if (!device) return

    var names = []
    var sink = bluetoothAudioSink(device)
    if (sink && sink.name) names.push(String(sink.name))
    var source = bluetoothAudioSource(device)
    if (source && source.name) names.push(String(source.name))

    for (var i = 0; i < names.length; i++)
      Quickshell.execDetached([
        audioControlScript("audio-app-rules"),
        "set-alias",
        names[i],
        String(alias)
      ])
  }

  function commitDeviceRename() {
    var device = deviceByAddress(deviceDetailsAddress)
    if (!device || deviceDetailsControlsBusy) return
    var requested = String(detailsNameField.text || "").trim()
    var expected = requested !== "" ? requested : String(device.deviceName || "").trim()
    detailsNameField.text = expected
    detailsNameField.focus = false
    updateDeviceProperty("name", requested, expected, "Could not rename this device.")
    syncAudioControlAliases(device.address, requested)
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function updateDeviceBoolean(propertyName, value, errorMessage) {
    updateDeviceProperty(propertyName, !!value, !!value, errorMessage)
  }

  function confirmDeviceProperty() {
    var operation = pendingDeviceProperty
    if (!operation) return
    var device = deviceByAddress(operation.address)
    var matches = device
      && liveDeviceProperty(device, operation.propertyName) === operation.expected
    pendingDeviceProperty = null

    if (Model.normalizedAddress(deviceDetailsAddress)
        !== Model.normalizedAddress(operation.address)) return
    devicePropertyError = matches ? ""
      : (device ? operation.errorMessage : "This device is no longer available.")
    if (operation.propertyName === "name" && deviceDetailsRow && !detailsNameField.activeFocus)
      detailsNameField.text = String(root.deviceDisplayName(deviceDetailsRow)
      || deviceDetailsRow.deviceName || "")
  }

  function activateDeviceDetailsCursor() {
    if (!deviceDetailsRow || deviceDetailsControlsBusy) return
    if (deviceDetailsIndex === detailsRenameIndex) beginDeviceRename()
    else if (deviceDetailsIndex === detailsAudioPolicyIndex
        && detailsStopAvailable(detailsAudioPolicyIndex))
      stepDeviceAudioPolicy(1)
    else if (deviceDetailsIndex === detailsTrustedIndex)
      updateDeviceBoolean("trusted", !deviceDetailsRow.trusted,
        "Could not update whether this device is trusted.")
    else if (deviceDetailsIndex === detailsBlockedIndex)
      updateDeviceBoolean("blocked", !deviceDetailsRow.blocked,
        "Could not update whether this device is blocked.")
    else if (deviceDetailsIndex === detailsWakeIndex)
      updateDeviceBoolean("wakeAllowed", !deviceDetailsRow.wakeAllowed,
        "Could not change wake permission. This device or adapter may not support it.")
    else if (deviceDetailsIndex === detailsForgetIndex && deviceDetailsForgetAvailable)
      requestForgetConfirmation()
  }

  function requestForgetConfirmation(device) {
    var address = device && device.address ? String(device.address) : deviceDetailsAddress
    if (devicePropertyBusy || deviceActionProc.running || pendingAction(address) !== "") return
    if (device && device.address
        && Model.normalizedAddress(device.address) !== Model.normalizedAddress(deviceDetailsAddress))
      openDeviceDetails(device)
    if (!deviceDetailsForgetAvailable && !device) return
    forgetConfirmationOpen = true
    forgetDialog.selectedIndex = 0
  }

  function cancelForgetConfirmation() {
    forgetConfirmationOpen = false
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmForgetDevice() {
    if (devicePropertyBusy || deviceActionProc.running) return
    var device = deviceByAddress(deviceDetailsAddress)
    forgetConfirmationOpen = false
    closeDeviceDetails()
    if (device) forgetDevice(device)
  }

  function retryDeviceAction(device) {
    if (!device || !device.address || deviceActionProc.running) return
    var failure = deviceActionFailure(device.address)
    if (!failure) return
    if (failure.action === "pair" || failure.action === "connect") connectDevice(device)
    else if (failure.action === "disconnect") disconnectDevice(device)
    else if (failure.action === "forget") forgetDevice(device)
  }

  function cancelPairing(device) {
    if (!device || !device.address || !activeDeviceAction
        || activeDeviceAction.action !== "pair"
        || Model.normalizedAddress(activeDeviceAction.address) !== Model.normalizedAddress(device.address)) return

    deviceActionCancelRequested = true
    setPendingAction(device.address, "")
    setDeviceActionFailure(device.address, "", "")
    if (typeof device.cancelPair === "function") device.cancelPair()
    if (deviceActionProc.running) deviceActionProc.signal(15)
  }

  // Diff the connected list against the previous pass. Devices already
  // connected when the panel first sees them — including everything restored
  // before the shell started — are marked watched without queueing, so a
  // policy never fires for a connection the user did not just make.
  function queuePolicyApplications(list) {
    var watched = {}
    var queued = cloneMap(pendingPolicyApplications)
    var changed = false

    for (var i = 0; i < list.length; i++) {
      var device = list[i]
      if (!device || !device.address) continue
      var key = Model.normalizedAddress(device.address)
      watched[key] = true
      if (policyWatchedConnections[key] || queued[key]) continue
      var policy = Model.deviceAudioPolicy(audioPreferences, device.address)
      if (policy !== "manual") {
        queued[key] = { policy: policy }
        changed = true
      }
    }

    policyWatchedConnections = watched
    if (changed) {
      pendingPolicyApplications = queued
      policyApplicationAttempts = 0
    }
  }

  // Persisted switch used by output-mic policies when the remembered mode
  // is output-only. Deliberately bluetooth-audio-profile-set and not the
  // raw card write: the policy replaces the remembered codec outright, so
  // every store — this plugin's preferences, WirePlumber's device memory,
  // and the live card — converges on the microphone mode instead of leaving
  // a stale output-only preference behind that restores it right back.
  function issuePolicyProfileSwitch(state, duplex) {
    if (!state || !state.address || !duplex || !duplex.value) return false
    if (policyProfileProc.running || audioProfileSetProc.running || pendingAudioProfile)
      return false
    policyProfileProc.address = String(state.address || "")
    policyProfileProc.command = [
      pluginScript("bluetooth-audio-profile-set"),
      String(state.address),
      String(duplex.value)
    ]
    policyProfileProc.running = true
    return true
  }

  function applyPendingAudioPolicies() {
    var keys = Object.keys(pendingPolicyApplications)
    if (keys.length === 0) return
    policyApplicationAttempts += 1

    var next = {}
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      var entry = pendingPolicyApplications[key]
      var device = deviceByAddress(key)
      if (!device || !device.connected) continue

      // Keyboards and mice never grow a PipeWire card; stop holding this
      // timer open for hardware that cannot satisfy any audio policy.
      var state = audioProfileState(key)
      if (!state) {
        if (policyApplicationAttempts < 16) next[key] = entry
        continue
      }

      var sink = bluetoothAudioSink(device)
      if (!sink) { next[key] = entry; continue }

      if (entry.policy === "output") {
        if (!entry.outputApplied) setDefaultAudioSink(sink)
        continue
      }

      // Output-mic policy: the device must come up in a microphone-capable
      // mode. A remembered output-only codec is replaced through the
      // persisted selection path — one write everywhere, nothing left
      // behind that would restore the old mode right back.
      if (!entry.outputApplied) setDefaultAudioSink(sink)

      if (audioProfileHasInput(key)) {
        var source = bluetoothAudioSource(device)
        if (source && !entry.sourceApplied) {
          setDefaultAudioSource(source)
          continue
        }
        if (!source && policyApplicationAttempts < 60) {
          next[key] = policyEntry(entry, { outputApplied: true })
          continue
        }
        continue
      }

      var duplex = Model.duplexProfileOption(state)
      if (!duplex) continue

      // A remembered duplex mode means WirePlumber is about to restore it
      // on its own — wait rather than duplicate the write.
      var saved = Model.preferredAudioProfile(audioPreferences, key,
        Model.audioProfileOptions(state), "")
      if (saved !== "" && audioProfileHasInput(state, saved)) {
        if (policyApplicationAttempts < 60)
          next[key] = policyEntry(entry, { outputApplied: true })
        continue
      }

      // The bluez5 monitor spends the first seconds of a connection applying
      // its bluez5.auto-connect properties — commonly A2DP-only, per system
      // configuration — and tears down any headset mode selected inside that
      // window before re-picking the A2DP codec. Wait until the card's
      // profile state stops changing, then switch exactly once.
      var signature = String(state.activeProfile || "")
      var listed = state.profiles || []
      for (var p = 0; p < listed.length; p++)
        signature += "," + String(listed[p] && listed[p].value || "")
      if (signature !== entry.cardSignature) {
        next[key] = policyEntry(entry, { cardSignature: signature, stableTicks: 0 })
        continue
      }
      var stableTicks = (entry.stableTicks || 0) + 1
      if (stableTicks < 8) {
        next[key] = policyEntry(entry, { cardSignature: signature, stableTicks: stableTicks })
        continue
      }

      if (!entry.switchRequested && issuePolicyProfileSwitch(state, duplex)) {
        console.info("bluetooth-audio: connect policy switching "
          + key + " to " + duplex.value)
        next[key] = policyEntry(entry, { outputApplied: true, switchRequested: true })
        continue
      }
      if (policyApplicationAttempts < 60)
        next[key] = policyEntry(entry, { outputApplied: true })
    }

    pendingPolicyApplications = next
  }

  // Entries are replaced wholesale each tick instead of mutated: cloneMap
  // copies by reference, so in-place edits would leak between ticks.
  function policyEntry(entry, patch) {
    var next = { policy: entry.policy }
    if (entry.outputApplied) next.outputApplied = true
    if (entry.sourceApplied) next.sourceApplied = true
    if (entry.switchRequested) next.switchRequested = true
    if (entry.cardSignature !== undefined) next.cardSignature = entry.cardSignature
    if (entry.stableTicks !== undefined) next.stableTicks = entry.stableTicks
    for (var field in patch) next[field] = patch[field]
    return next
  }

  function syncPendingActions() {
    var next = cloneMap(pendingActions)
    var changed = false

    for (var address in next) {
      var action = next[address]
      var found = null

      for (var i = 0; i < devices.length; i++) {
        var d = devices[i]
        if (d && d.address === address) {
          found = d
          break
        }
      }

      var finishedConnecting = action === "connecting" && found && found.connected
      if (finishedConnecting
          || (action === "disconnecting" && found && !found.connected)
          || (action === "forgetting" && (!found
            || (!found.paired && !found.bonded && !found.trusted && !found.blocked)))) {
        delete next[address]
        changed = true
      }
    }

    if (changed) pendingActions = next

    var nextFailures = cloneMap(deviceActionFailures)
    var failuresChanged = false
    for (var failureAddress in nextFailures) {
      var failure = nextFailures[failureAddress]
      var failedDevice = null
      for (var j = 0; j < devices.length; j++) {
        if (devices[j] && Model.normalizedAddress(devices[j].address) === failureAddress) {
          failedDevice = devices[j]
          break
        }
      }
      if (failure && Model.deviceActionReachedState(failure.action, failedDevice)) {
        delete nextFailures[failureAddress]
        failuresChanged = true
      }
    }
    if (failuresChanged) deviceActionFailures = nextFailures
  }

  // j/k navigates the hero toggle ("header") and the device sections
  // row-by-row.
  function moveCursor(delta) {
    var sections = visibleSections
    if (focusSection === "header") {
      if (delta > 0 && sections && sections.length > 0) {
        focusSection = sections[0]; selectedIndex = 0; focusedAction = ""
      }
      return
    }
    if (!sections || sections.length === 0) { focusSection = "header"; focusedAction = ""; return }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = 0; focusedAction = ""; return }

    var idx = selectedIndex
    var max = sectionCount(focusSection) - 1

    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; focusedAction = ""; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = 0
        focusedAction = ""
      }
    } else {
      if (idx > 0) { selectedIndex = idx - 1; focusedAction = ""; return }
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        selectedIndex = sectionCount(focusSection) - 1
        focusedAction = ""
      } else {
        focusSection = "header"; focusedAction = ""
      }
    }
  }

  function setHeaderCursor(index) {
    cursorActive = true
    focusSection = "header"
    headerIndex = audioControlInstalled ? Math.max(0, Math.min(1, index)) : 1
    focusedAction = ""
  }

  function focusedRowActions() {
    var actions = []
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev || !dev.address) return actions
    var recovery = recoveryAction(dev.address)
    if (recovery !== "") return [recovery]
    if (focusSection === "connected" && audioUseActionAvailable(dev)) actions.push("audio")
    actions.push("details")
    if (focusSection === "connected" && audioProfileActionAvailable(dev)) actions.push("profile")
    return actions
  }

  function moveCursorH(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection === "header") {
      headerIndex = audioControlInstalled
        ? Math.max(0, Math.min(1, headerIndex + delta)) : 1
      return
    }
    var actions = focusedRowActions()
    if (actions.length === 0) return
    var index = focusedAction === "" ? -1 : actions.indexOf(focusedAction)
    if (delta > 0 && index < actions.length - 1) focusedAction = actions[index + 1]
    else if (delta < 0) focusedAction = index > 0 ? actions[index - 1] : ""
  }

  function activateCursor() {
    if (focusSection === "header") {
      if (headerIndex === 0 && audioControlInstalled) openAdvancedAudio()
      else toggleBluetooth()
      return
    }
    if (focusedAction === "retry") {
      retryDeviceAction(deviceAt(focusSection, selectedIndex))
      return
    }
    if (focusedAction === "cancel") {
      cancelPairing(deviceAt(focusSection, selectedIndex))
      return
    }
    if (focusedAction === "profile") {
      var row = connectedRepeater.itemAt(selectedIndex)
      if (row) row.toggleProfileMenu()
      return
    }
    if (focusedAction === "audio") {
      useDeviceForAudio(deviceAt(focusSection, selectedIndex))
      return
    }
    if (focusedAction === "details") {
      openDeviceDetails(deviceAt(focusSection, selectedIndex))
      return
    }

    if (focusSection === "connected" || focusSection === "known") {
      var dev = deviceAt(focusSection, selectedIndex)
      if (!dev) return
      if (dev.connected) disconnectDevice(dev)
      else connectDevice(dev)
      return
    }
    if (focusSection === "discovered") {
      var d = discoveredDevices[selectedIndex]
      if (!d) return
      connectDevice(d)
    }
  }

  // 'x' opens an explicit confirmation for remembered devices. For connected
  // devices the result-aware helper then disconnects before removing BlueZ's
  // pairing record.
  function deleteSelected() {
    if (focusSection !== "known" && focusSection !== "connected") return
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev) return
    requestForgetConfirmation(dev)
  }

  onOpenedChanged: {
    if (opened) {
      // Adopt a discovery session that is already running — a popout handoff
      // from another monitor, or one leaked by an instance that could not
      // finish its own stop — so this close settles it either way.
      if (adapter !== null && adapter.discovering) owesDiscoveryStop = true
      if (connectedDevices.length > 0) { focusSection = "connected"; selectedIndex = 0 }
      else if (knownDevices.length > 0) { focusSection = "known"; selectedIndex = 0 }
      else if (discoveredDevices.length > 0) { focusSection = "discovered"; selectedIndex = 0 }
      else { focusSection = "header" }
      focusedAction = ""
      headerIndex = 1
      cursorActive = false
      audioProfileRefreshTimer.restart()
    } else {
      closeAudioProfileMenus(-1)
      audioProfileMenuOpen = false
      forgetConfirmationOpen = false
      if (deviceDetailsOpen) closeDeviceDetails()
    }
  }

  // Another per-monitor instance of this widget whose panel is open, if any.
  // All instances share the default adapter, and switching the popout to a
  // different monitor closes one instance as it opens the next, so the
  // closing side has to leave the scan alone for the side still on screen.
  function openSibling() {
    if (!bar || typeof bar.moduleWidgets !== "function") return null
    var items = bar.moduleWidgets(moduleName)
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root && items[i].opened === true) return items[i]
    }
    return null
  }

  function updateFocusedAddress() {
    var d = deviceAt(focusSection, selectedIndex)
    focusedDeviceAddress = d ? (d.address || "") : ""
  }

  function reselectFocusedDevice() {
    if (focusedDeviceAddress === "") {
      clampCursor()
      return
    }

    var sections = ["connected", "known", "discovered"]
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s]
      if (!sectionVisible(section)) continue
      var list = devicesForSection(section)
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].address === focusedDeviceAddress) {
          focusSection = section
          selectedIndex = i
          clampCursor()
          return
        }
      }
    }

    clampCursor()
  }

  onSelectedIndexChanged: { focusedAction = ""; updateFocusedAddress() }
  onFocusSectionChanged: { focusedAction = ""; updateFocusedAddress() }
  onConnectedDevicesChanged: {
    reselectFocusedDevice()
    syncPendingActions()
    queuePolicyApplications(connectedDevices)
    if (connectedDevices.length === 0) {
      audioProfiles = ({})
      audioProfileReadError = ""
      audioProfileSetError = ""
      pendingAudioProfile = null
      unconfirmedAudioProfile = null
      audioProfilePendingTimeout.stop()
    }
    else if (opened) audioProfileRefreshTimer.restart()
  }
  onKnownDevicesChanged: { reselectFocusedDevice(); syncPendingActions() }
  onDiscoveredDevicesChanged: { reselectFocusedDevice(); syncPendingActions() }
  onVisibleSectionsChanged: clampCursor()
  onPipewireNodesChanged: {
    if (opened) audioProfileSettleTimer.restart()
    if (focusedAction === "audio"
        && !audioUseActionAvailable(deviceAt(focusSection, selectedIndex))) focusedAction = ""
  }
  onAudioProfilesChanged: if (focusedAction === "profile"
    && !audioProfileActionAvailable(deviceAt(focusSection, selectedIndex))) focusedAction = ""

  function clampCursor() {
    var sections = visibleSections
    // "header" is virtual and never appears in visibleSections, so it has to
    // be let through: toggling the adapter empties and refills the device
    // lists, and clamping would knock the cursor off the hero switch every
    // time it is used.
    if (focusSection === "header") return
    if (!sections || !sections.length) {
      selectedIndex = 0
      return
    }
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = 0
      return
    }
    var count = sectionCount(focusSection)
    if (count === 0) {
      // Section emptied out — bounce to the previous visible one.
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = Math.max(0, sectionCount(focusSection) - 1)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  visible: adapter !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // BlueZ rejects StartDiscovery while the adapter is still powering up, and
  // discovery can also time out on its own. While the panel is open, keep
  // nudging it back on so an enabled adapter is always scanning.
  Timer {
    id: discoveryRetry
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.adapter !== null && root.adapter.enabled && !root.adapter.discovering
    onTriggered: {
      root.owesDiscoveryStop = true
      root.adapter.discovering = true
    }
  }

  // The way back down. The BlueZ discovery session behind adapter.discovering
  // is held by quickshell's D-Bus connection, so nothing ends it at close:
  // without this timer, one visit to the panel left the radio in inquiry
  // until the next shell restart, starving A2DP audio on the same controller
  // into stutters.
  //
  // A timer bound to the confirmed state rather than a write at close time:
  // quickshell only forwards a discovering write that differs from the last
  // state BlueZ reported, so a stop issued while a just-fired StartDiscovery
  // is still awaiting confirmation would be swallowed and leak the session.
  // Binding to adapter.discovering means a confirmation landing at any point
  // after close re-arms the stop, and a reopen inside the first interval
  // keeps the scan running uninterrupted. Attempts are bounded so a session
  // some other BlueZ client keeps up cannot draw StopDiscovery fire forever.
  Timer {
    id: discoveryStop
    interval: 1000
    repeat: true
    property int attempts: 0
    running: !root.opened && root.owesDiscoveryStop && root.adapter !== null && root.adapter.discovering === true
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      // The scan now serves the open panel, so the debt moves with it — B may
      // have opened before BlueZ confirmed A's start, in which case B's own
      // open-time adoption saw nothing to adopt.
      var sibling = root.openSibling()
      if (sibling) {
        sibling.owesDiscoveryStop = true
        root.owesDiscoveryStop = false
        return
      }
      attempts += 1
      if (attempts > 3) { root.owesDiscoveryStop = false; return }
      root.adapter.discovering = false
    }
  }

  // The debt is settled the moment BlueZ reports discovery down — whether
  // because the stop above landed or the session ended some other way — so a
  // stale claim never touches a scan another client starts later. While the
  // panel is open, discoveryRetry re-incurs it as it restarts the scan.
  Connections {
    target: root.adapter
    function onDiscoveringChanged() {
      if (!root.adapter.discovering) root.owesDiscoveryStop = false
    }
  }

  // A destroyed instance cannot wait for BlueZ confirmations, so it hands any
  // debt to a surviving sibling — whose declarative stop catches even a start
  // confirmed after this object is gone — and only writes the stop directly
  // when it is the last one standing.
  Component.onDestruction: {
    if (!owesDiscoveryStop) return
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root) { items[i].owesDiscoveryStop = true; return }
    }
    if (adapter !== null && adapter.discovering) adapter.discovering = false
  }

  Component.onCompleted: refreshAudioControlInstalled()

  Connections {
    target: root.audioPluginRegistry
    function onPluginsChanged() { root.refreshAudioControlInstalled() }
  }

  FileView {
    path: root.audioPreferencesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadAudioPreferences(text())
    onLoadFailed: root.loadAudioPreferences("")
    onFileChanged: reload()
  }

  FileView {
    path: root.audioControlRulesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.audioControlAliases = Model.parseDeviceAliases(text())
    onLoadFailed: root.audioControlAliases = ({})
    onFileChanged: reload()
  }

  Process {
    id: deviceActionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        root.deviceActionStderr = message
        var operation = root.lastExitedDeviceAction
        var currentFailure = operation
          ? root.deviceActionFailure(operation.address) : null
        if (message !== "" && operation && currentFailure
            && currentFailure.action === operation.action)
          root.setDeviceActionFailure(operation.address, operation.action, message)
      }
    }
    onExited: function(exitCode) {
      var operation = root.activeDeviceAction
      if (!operation) return

      if (root.deviceActionCancelRequested) {
        root.setPendingAction(operation.address, "")
        root.setDeviceActionFailure(operation.address, "", "")
        root.lastExitedDeviceAction = null
      } else if (exitCode !== 0) {
        root.setPendingAction(operation.address, "")
        root.lastExitedDeviceAction = operation
        root.setDeviceActionFailure(
          operation.address,
          operation.action,
          root.deviceActionStderr || root.defaultDeviceActionError(operation.action))
      } else {
        root.setDeviceActionFailure(operation.address, "", "")
        root.lastExitedDeviceAction = null
      }

      root.activeDeviceAction = null
      root.deviceActionCancelRequested = false
      root.syncPendingActions()
    }
  }

  Process {
    id: devicePropertyProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        root.devicePropertyStderr = message
        var operation = root.lastExitedDeviceProperty
        if (message !== "" && operation
            && Model.normalizedAddress(root.deviceDetailsAddress)
              === Model.normalizedAddress(operation.address))
          root.devicePropertyError = message
      }
    }
    onExited: function(exitCode) {
      var operation = root.pendingDeviceProperty
      if (!operation) return

      if (exitCode !== 0) {
        root.lastExitedDeviceProperty = operation
        root.pendingDeviceProperty = null
        if (Model.normalizedAddress(root.deviceDetailsAddress)
            === Model.normalizedAddress(operation.address))
          root.devicePropertyError = root.devicePropertyStderr || operation.errorMessage
      } else {
        root.lastExitedDeviceProperty = null
        devicePropertyConfirmTimer.restart()
      }
    }
  }

  Process {
    id: audioControlCheckProc
    command: ["test", "-f", root.audioControlManifestPath]
    onExited: function(exitCode) {
      if (root.audioPluginRegistry && root.audioPluginRegistry.installedPlugins
          && typeof root.audioPluginRegistry.isEnabled === "function")
        root.refreshAudioControlInstalled()
      else
        root.audioControlInstalled = exitCode === 0
    }
  }

  Timer {
    interval: 10000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshAudioControlInstalled()
  }

  Process {
    id: audioProfilesProc
    command: [root.pluginScript("bluetooth-audio-profiles")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateAudioProfiles(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.opened && root.connectedDevices.length > 0)
        root.audioProfileReadError = "Could not read Bluetooth audio modes"
    }
  }

  Process {
    id: audioProfileSetProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.audioProfileSetError = "Could not change the Bluetooth audio mode"
        root.pendingAudioProfile = null
        root.unconfirmedAudioProfile = null
        audioProfilePendingTimeout.stop()
      } else {
        root.audioProfileSetError = ""
        audioProfilePendingTimeout.restart()
      }
      audioProfileSettleTimer.restart()
    }
  }

  // Background profile switch issued by an output-mic connect policy. Kept
  // separate from audioProfileSetProc so its outcome never writes the panel's
  // user-facing mode error: a failed policy quietly degrades to output-only,
  // and the details page explains why instead.
  Process {
    id: policyProfileProc
    property string address: ""
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("bluetooth-audio: policy profile switch failed for "
          + policyProfileProc.address + " exit " + exitCode)
      audioProfileSettleTimer.restart()
    }
  }

  Timer {
    id: audioProfileRefreshTimer
    interval: 100
    repeat: false
    onTriggered: root.refreshAudioProfiles()
  }

  Timer {
    id: audioProfileSettleTimer
    interval: 250
    repeat: false
    onTriggered: root.refreshAudioProfiles()
  }

  Timer {
    interval: 2000
    running: root.opened && root.connectedDevices.length > 0
      && !root.audioProfileMenuOpen && !audioProfileSetProc.running
    repeat: true
    onTriggered: root.refreshAudioProfiles()
  }

  Timer {
    id: audioProfilePendingTimeout
    interval: 4000
    repeat: false
    onTriggered: if (root.pendingAudioProfile) {
      root.pendingAudioProfile = null
      root.audioProfileSetError = "Could not confirm the Bluetooth audio mode"
    }
  }

  // Connect policies must apply with the panel closed — that is their whole
  // point — so this timer runs on the bar widget itself, not on panel state.
  Timer {
    id: audioPolicyApplyTimer
    interval: 500
    running: Object.keys(root.pendingPolicyApplications).length > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.applyPendingAudioPolicies()
  }

  Timer {
    id: pendingTimeout
    interval: 20000
    repeat: false
    onTriggered: {
      if (deviceActionProc.running) restart()
      else root.pendingActions = ({})
    }
  }

  // The helper reports the D-Bus result directly. After it succeeds, give
  // Quickshell time to receive BlueZ's PropertiesChanged signal and verify
  // that the projected value settled as requested.
  Timer {
    id: devicePropertyConfirmTimer
    interval: 1500
    repeat: false
    onTriggered: root.confirmDeviceProperty()
  }

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  // Not adapter.enabled: that writes BlueZ's Powered, which nothing persists, so
  // the adapter came back on at the next boot. omarchy-bluetooth-power moves the
  // rfkill soft block instead, which systemd-rfkill restores across reboots.
  // Powered still follows the block, so the switch and icon read it as before.
  //
  // Asking for a direction rather than a toggle: the helper runs detached and the
  // switch only moves once BlueZ catches up, so a second click inside that window
  // would re-read the old state and undo the first.
  function openAdvancedAudio() {
    if (!audioControlInstalled) return
    controller.hide()
    var payload = '{"tab":"bluetooth"}'
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon("ssupt.audio-control", payload)
    else
      Quickshell.execDetached([
        "omarchy-shell", "shell", "summon", "ssupt.audio-control", payload
      ])
  }

  function toggleBluetooth() {
    if (!adapter) return
    Quickshell.execDetached(["omarchy-bluetooth-power", adapter.enabled ? "off" : "on"])
  }

  IpcHandler {
    target: "omarchy.bluetooth"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function toggleBluetooth() { root.toggleBluetooth() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleBluetooth()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(root.deviceDetailsOpen
      ? detailsColumn.implicitHeight : column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.audioProfileMenuOpen || detailsNameField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (root.forgetConfirmationOpen) {
          forgetDialog.selectedIndex = forgetDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (root.deviceDetailsOpen) {
          if (dy !== 0) root.moveDeviceDetailsCursor(dy)
          else if (dx !== 0) {
            // Left/Right steps through the audio-policy options when the
            // cursor sits on that row; everywhere else they move stops.
            if (root.deviceDetailsIndex === root.detailsAudioPolicyIndex)
              root.stepDeviceAudioPolicy(dx)
            else
              root.moveDeviceDetailsCursor(dx)
          }
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: {
        if (root.forgetConfirmationOpen) {
          if (forgetDialog.selectedIndex === 0) root.cancelForgetConfirmation()
          else root.confirmForgetDevice()
        } else if (root.deviceDetailsOpen) root.activateDeviceDetailsCursor()
        else if (root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        if (root.forgetConfirmationOpen) root.cancelForgetConfirmation()
        else if (root.deviceDetailsOpen) root.closeDeviceDetails()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.forgetConfirmationOpen)
          forgetDialog.selectedIndex = forgetDialog.selectedIndex === 0 ? 1 : 0
        else if (root.deviceDetailsOpen) root.moveDeviceDetailsCursor(direction)
        else root.switchPanel(direction)
      }
      onDeleteRequested: {
        if (root.forgetConfirmationOpen) return
        if (root.deviceDetailsOpen) {
          if (root.deviceDetailsForgetAvailable) root.requestForgetConfirmation()
        } else if (root.cursorActive) root.deleteSelected()
      }
      onTextKey: function(t) {
        if (!root.deviceDetailsOpen && !root.forgetConfirmationOpen
            && (t === "b" || t === "B")) root.toggleBluetooth()
      }

      Column {
        id: column
        anchors.fill: parent
        visible: !root.deviceDetailsOpen
        spacing: Style.space(14)

        // ---------- Hero: Bluetooth icon · status ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

          // Status only — the switch owns toggling, mouse and keyboard alike.
          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.adapter && root.adapter.enabled ? 1.0 : 0.5
          }

          Row {
            id: heroActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Button {
              id: settingsAction
              visible: root.audioControlInstalled
              iconText: "󰒓"
              tooltipText: "Advanced audio · Bluetooth"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              iconSize: Style.font.subtitle * 1.5
              horizontalPadding: Style.space(5)
              verticalPadding: Style.space(2)
              hasCursor: root.settingsHeaderHasCursor
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function(on) { if (on) root.setHeaderCursor(0) }
              onClicked: root.openAdvancedAudio()
            }

            ToggleSwitch {
              id: powerSwitch
              visible: !!root.adapter
              checked: !!root.adapter && root.adapter.enabled
              hasCursor: root.powerHeaderHasCursor
              foreground: root.bar.foreground
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function(on) { if (on) root.setHeaderCursor(1) }
              onToggled: root.toggleBluetooth()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.toggleHint
                fontFamily: root.bar.fontFamily
              }
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: heroActions.width + Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Bluetooth"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // Scrollable device list — capped so a noisy neighborhood doesn't
        // grow the popup past the screen.
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          id: connectedList
          visible: root.connectedDevices.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CONNECTED"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            id: connectedRepeater
            model: root.connectedRows
            DeviceRow {
              required property var modelData
              required property int index
              width: connectedList.width
              dev: modelData
              rowIndex: index
              sectionName: "connected"
              isDiscovered: false
            }
          }
        }

        PanelSeparator {
          visible: root.connectedDevices.length > 0 && root.scrollRows.length > 0
          foreground: root.bar.foreground
        }

        // ListView, not a Flickable: it owns the scroll position, so it keeps
        // the current row visible on j/k, re-clamps itself when discovery
        // shortens the list, and — because Contain only moves when a row is
        // actually clipped — never lurches under a hovering mouse.
        ListView {
          id: deviceListView
          width: parent.width
          height: Math.min(contentHeight, Style.space(400))
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.scrollRows
          currentIndex: root.scrollRowIndex
          // Deferred by a turn. Called straight out of the signal the position
          // does not take — verified with the cursor six rows down and
          // contentY still 0 — because scrollRows is rebuilt every time
          // discovery reports, and swapping the model resets the view out from
          // under the call. Network's list is stable enough not to need this.
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: Item {
            required property var modelData
            required property int index
            readonly property string sectionTitle: root.scrollSectionTitle(index)

            width: ListView.view.width
            height: delegateColumn.implicitHeight

            Column {
              id: delegateColumn
              width: parent.width
              spacing: Style.space(10)

              PanelSeparator {
                visible: index > 0 && sectionTitle !== ""
                height: visible ? implicitHeight : 0
                foreground: root.bar.foreground
              }

              PanelSectionHeader {
                visible: sectionTitle !== ""
                height: visible ? implicitHeight : 0
                text: sectionTitle
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              DeviceRow {
                width: parent.width
                dev: modelData.dev
                rowIndex: modelData.indexInSection
                sectionName: modelData.section
                isDiscovered: modelData.section === "discovered"
              }
            }
          }
        }

        Text {
          visible: root.connectedDevices.length === 0 && root.scrollRows.length === 0
          text: !root.adapter ? "No Bluetooth adapter"
              : !root.adapter.enabled ? "Turn Bluetooth on to scan"
              : "Scanning for devices…"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Text {
          visible: root.audioProfileError !== ""
          text: root.audioProfileError
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }

      Flickable {
        id: detailsScroll
        anchors.fill: parent
        visible: root.deviceDetailsOpen
        contentWidth: width
        contentHeight: detailsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        function cursorItem() {
          if (root.deviceDetailsIndex === root.detailsRenameIndex) return detailsNameField
          if (root.deviceDetailsIndex === root.detailsAudioPolicyIndex) return policyManualButton
          if (root.deviceDetailsIndex === root.detailsTrustedIndex) return trustedToggle
          if (root.deviceDetailsIndex === root.detailsBlockedIndex) return blockedToggle
          if (root.deviceDetailsIndex === root.detailsWakeIndex) return wakeToggle
          if (root.deviceDetailsIndex === root.detailsForgetIndex) return forgetDeviceButton
          return null
        }

        function ensureCursorVisible() {
          var target = cursorItem()
          if (!target || !target.visible || height <= 0) return
          var point = target.mapToItem(detailsColumn, 0, 0)
          var margin = Style.space(8)
          if (point.y < contentY + margin) contentY = Math.max(0, point.y - margin)
          else if (point.y + target.height > contentY + height - margin)
            contentY = Math.min(Math.max(0, contentHeight - height),
              point.y + target.height - height + margin)
        }

        Column {
          id: detailsColumn
          width: detailsScroll.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: Math.max(backDetailsButton.implicitHeight,
              detailsDeviceIcon.height, detailsHeading.implicitHeight)

            Button {
              id: backDetailsButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "←"
              tooltipText: "Back to Bluetooth devices"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.heading
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(2)
              onClicked: root.closeDeviceDetails()
            }

            BluetoothDeviceIcon {
              id: detailsDeviceIcon
              anchors.left: backDetailsButton.right
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(34)
              height: Style.space(34)
              iconName: root.deviceDetailsRow ? root.deviceDetailsRow.icon : ""
              deviceName: root.deviceDetailsRow
                ? String(root.deviceDetailsRow.name || root.deviceDetailsRow.deviceName || "") : ""
              connected: root.deviceDetailsRow ? root.deviceDetailsRow.connected : false
              foreground: root.deviceDetailsRow && root.deviceDetailsRow.blocked
                ? root.bar.urgent : root.bar.foreground
              iconSize: Style.font.display
            }

            Column {
              id: detailsHeading
              anchors.left: detailsDeviceIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                width: parent.width
                text: root.deviceDetailsRow
                  ? (root.deviceDisplayName(root.deviceDetailsRow) || "Bluetooth device")
                  : "Device unavailable"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: !root.deviceDetailsRow ? "NO LONGER VISIBLE"
                  : root.deviceDetailsRow.blocked ? "BLOCKED"
                  : root.deviceDetailsRow.connected ? "CONNECTED"
                  : (root.deviceDetailsRow.paired || root.deviceDetailsRow.bonded) ? "PAIRED"
                  : "AVAILABLE"
                color: root.deviceDetailsRow && root.deviceDetailsRow.blocked
                  ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.0
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          Text {
            visible: !root.deviceDetailsRow
            width: parent.width
            text: "This Bluetooth device disappeared. It may be out of range or no longer remembered."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            visible: !!root.deviceDetailsRow
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "DEVICE NAME"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            TextField {
              id: detailsNameField
              width: parent.width
              enabled: !!root.deviceDetailsRow && !root.deviceDetailsControlsBusy
              opacity: enabled ? 1 : 0.55
              placeholderText: root.deviceDetailsRow
                ? String(root.deviceDetailsRow.deviceName || "Device name") : "Device name"
              foreground: root.bar.foreground
              accent: Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              hasCursor: !activeFocus && root.deviceDetailsOpen
                && !root.forgetConfirmationOpen && root.deviceDetailsIndex === root.detailsRenameIndex

              onHoveredChanged: if (hovered) root.setDeviceDetailsCursor(root.detailsRenameIndex)
              onActiveFocusChanged: if (activeFocus) root.setDeviceDetailsCursor(root.detailsRenameIndex)
              onAccepted: root.commitDeviceRename()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelDeviceRename()
                  event.accepted = true
                }
              }
            }

            Text {
              width: parent.width
              text: "Press Enter to rename. Leave empty to restore the device's original name."
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: !!root.deviceDetailsRow && root.deviceDetailsIsAudio
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "AUDIO ON CONNECT"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              readonly property string activePolicy: root.deviceAudioPolicy(root.deviceDetailsAddress)

              Button {
                id: policyManualButton
                selected: parent.activePolicy === "manual"
                text: "Manual"
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                foreground: root.bar.foreground
                accent: Color.accent
                fontFamily: root.bar.fontFamily
                enabled: !!root.deviceDetailsRow && !root.deviceDetailsControlsBusy
                opacity: enabled ? 1 : 0.55
                hasCursor: root.deviceDetailsOpen && !root.forgetConfirmationOpen
                  && root.deviceDetailsIndex === root.detailsAudioPolicyIndex && selected
                onHovered: function(on) { if (on) root.setDeviceDetailsCursor(root.detailsAudioPolicyIndex) }
                onClicked: {
                  root.setDeviceDetailsCursor(root.detailsAudioPolicyIndex)
                  root.setDeviceAudioPolicy("manual")
                }
              }

              Button {
                id: policyOutputButton
                selected: parent.activePolicy === "output"
                text: "Output"
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                foreground: root.bar.foreground
                accent: Color.accent
                fontFamily: root.bar.fontFamily
                enabled: !!root.deviceDetailsRow && !root.deviceDetailsControlsBusy
                opacity: enabled ? 1 : 0.55
                hasCursor: root.deviceDetailsOpen && !root.forgetConfirmationOpen
                  && root.deviceDetailsIndex === root.detailsAudioPolicyIndex && selected
                onHovered: function(on) { if (on) root.setDeviceDetailsCursor(root.detailsAudioPolicyIndex) }
                onClicked: {
                  root.setDeviceDetailsCursor(root.detailsAudioPolicyIndex)
                  root.setDeviceAudioPolicy("output")
                }
              }

              Button {
                id: policyMicButton
                selected: parent.activePolicy === "output-mic"
                text: "Output + Mic"
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                foreground: root.bar.foreground
                accent: Color.accent
                fontFamily: root.bar.fontFamily
                enabled: !!root.deviceDetailsRow && !root.deviceDetailsControlsBusy
                opacity: enabled ? 1 : 0.55
                hasCursor: root.deviceDetailsOpen && !root.forgetConfirmationOpen
                  && root.deviceDetailsIndex === root.detailsAudioPolicyIndex && selected
                onHovered: function(on) { if (on) root.setDeviceDetailsCursor(root.detailsAudioPolicyIndex) }
                onClicked: {
                  root.setDeviceDetailsCursor(root.detailsAudioPolicyIndex)
                  root.setDeviceAudioPolicy("output-mic")
                }
              }
            }

            Text {
              width: parent.width
              text: root.connectPolicyHint
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Toggle {
            id: trustedToggle
            visible: !!root.deviceDetailsRow
            width: parent.width
            label: "Trusted"
            description: "Permit this device to reconnect without asking for authorization."
            checked: !!root.deviceDetailsRow && root.deviceDetailsRow.trusted
            enabled: !root.deviceDetailsControlsBusy
            opacity: enabled ? 1 : 0.55
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
            hasCursor: root.deviceDetailsOpen && !root.forgetConfirmationOpen
              && root.deviceDetailsIndex === root.detailsTrustedIndex
            onHovered: function(on) { if (on) root.setDeviceDetailsCursor(root.detailsTrustedIndex) }
            onClicked: {
              root.setDeviceDetailsCursor(root.detailsTrustedIndex)
              root.updateDeviceBoolean("trusted", !checked,
                "Could not update whether this device is trusted.")
            }
          }

          Toggle {
            id: blockedToggle
            visible: !!root.deviceDetailsRow
            width: parent.width
            label: "Blocked"
            description: "Prevent connections from this device. Blocking also disconnects it."
            checked: !!root.deviceDetailsRow && root.deviceDetailsRow.blocked
            enabled: !root.deviceDetailsControlsBusy
            opacity: enabled ? 1 : 0.55
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
            hasCursor: root.deviceDetailsOpen && !root.forgetConfirmationOpen
              && root.deviceDetailsIndex === root.detailsBlockedIndex
            onHovered: function(on) { if (on) root.setDeviceDetailsCursor(root.detailsBlockedIndex) }
            onClicked: {
              root.setDeviceDetailsCursor(root.detailsBlockedIndex)
              root.updateDeviceBoolean("blocked", !checked,
                "Could not update whether this device is blocked.")
            }
          }

          Toggle {
            id: wakeToggle
            visible: !!root.deviceDetailsRow
            width: parent.width
            label: "Allow wake"
            description: "Let this device wake the computer when the device and adapter support it."
            checked: !!root.deviceDetailsRow && root.deviceDetailsRow.wakeAllowed
            enabled: !root.deviceDetailsControlsBusy
            opacity: enabled ? 1 : 0.55
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
            hasCursor: root.deviceDetailsOpen && !root.forgetConfirmationOpen
              && root.deviceDetailsIndex === root.detailsWakeIndex
            onHovered: function(on) { if (on) root.setDeviceDetailsCursor(root.detailsWakeIndex) }
            onClicked: {
              root.setDeviceDetailsCursor(root.detailsWakeIndex)
              root.updateDeviceBoolean("wakeAllowed", !checked,
                "Could not change wake permission. This device or adapter may not support it.")
            }
          }

          Column {
            visible: !!root.deviceDetailsRow
            width: parent.width
            spacing: Style.space(3)

            PanelSectionHeader {
              text: "MAC ADDRESS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Text {
              width: parent.width
              text: root.deviceDetailsRow ? String(root.deviceDetailsRow.address || "—") : "—"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.letterSpacing: 0.8
              elide: Text.ElideRight
            }
          }

          Text {
            visible: root.deviceDetailsControlsBusy
            width: parent.width
            text: root.devicePropertyBusy ? "Saving device setting…" : "Bluetooth operation in progress…"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.devicePropertyError !== ""
            width: parent.width
            text: root.devicePropertyError
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            id: forgetDeviceButton
            visible: root.deviceDetailsForgetAvailable
            width: parent.width
            text: "Forget device"
            iconText: "󰅙"
            leftAlign: true
            bordered: true
            enabled: !root.devicePropertyBusy && !deviceActionProc.running
            opacity: enabled ? 1 : 0.55
            foreground: root.bar.urgent
            accent: root.bar.urgent
            fontFamily: root.bar.fontFamily
            hasCursor: root.deviceDetailsOpen && !root.forgetConfirmationOpen
              && root.deviceDetailsIndex === root.detailsForgetIndex
            onHovered: function(on) { if (on) root.setDeviceDetailsCursor(root.detailsForgetIndex) }
            onClicked: {
              root.setDeviceDetailsCursor(root.detailsForgetIndex)
              root.requestForgetConfirmation()
            }
          }
        }
      }

      ConfirmDialog {
        id: forgetDialog
        anchors.fill: parent
        z: 20
        opened: root.forgetConfirmationOpen
        message: "Forget “" + (root.deviceDetailsRow
          ? (root.deviceDisplayName(root.deviceDetailsRow) || "this device") : "this device")
          + "”? You will need to pair it again before reconnecting."
        cancelText: "Cancel"
        confirmText: "Forget"
        background: Color.popups.background
        foreground: root.bar.foreground
        onCanceled: root.cancelForgetConfirmation()
        onConfirmed: root.confirmForgetDevice()
      }
    }
  }

  // Device-type icon rendered with the panel's themed font glyphs for
  // maximum sharpness, visual consistency with the rest of the Omarchy shell,
  // and reliable high-contrast foreground colorization.
  component BluetoothDeviceIcon: Item {
    id: bluetoothIcon
    property string iconName: ""
    property string deviceName: ""
    property bool connected: false
    property color foreground: Color.foreground
    property real iconSize: Style.font.heading

    implicitWidth: Style.space(26)
    implicitHeight: Style.space(26)

    readonly property string glyph: Model.deviceIconGlyph(
      iconName, deviceName, connected)

    Text {
      anchors.centerIn: parent
      text: bluetoothIcon.glyph
      color: bluetoothIcon.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: bluetoothIcon.iconSize
    }
  }

  // Two-line device row showing name + live status. Pending state is owned
  // by the panel so it survives rows moving between sections.
  component DeviceRow: CursorSurface {
    id: row
    required property var dev
    required property int rowIndex
    required property string sectionName
    required property bool isDiscovered

    readonly property bool isConnected: dev && dev.connected
    readonly property int devState: dev && dev.state !== undefined ? dev.state : -1
    readonly property string action: root.pendingAction(dev ? dev.address : "")
    readonly property var actionFailure: root.deviceActionFailure(dev ? dev.address : "")
    readonly property string actionFailureMessage: actionFailure
      ? String(actionFailure.message || "") : ""
    readonly property string recoveryAction: root.recoveryAction(dev ? dev.address : "")
    readonly property bool recoveryVisible: recoveryAction !== ""
    readonly property bool cancellingPair: root.deviceActionCancelRequested
      && root.activeDeviceAction && dev
      && Model.normalizedAddress(root.activeDeviceAction.address) === Model.normalizedAddress(dev.address)
    readonly property string actionTooltip: {
      if (!dev) return ""
      if (isConnected) return "Disconnect"
      if (isDiscovered) return "Pair"
      return "Connect"
    }

    readonly property var profileState: root.audioProfileState(dev ? dev.address : "")
    readonly property var profileOptions: Model.audioProfileOptions(profileState)
    readonly property bool profileMenuAvailable: root.audioProfileActionAvailable(dev)
    readonly property string pendingProfileName: {
      if (!root.pendingAudioProfile || !dev) return ""
      return root.pendingAudioProfile.address === Model.normalizedAddress(dev.address)
        ? String(root.pendingAudioProfile.profile || "") : ""
    }
    readonly property string currentProfileName: Model.currentAudioProfile(
      root.audioPreferences, dev ? dev.address : "", profileOptions,
      profileState ? profileState.activeProfile : "", pendingProfileName)
    readonly property string activeCodec: Model.audioProfileCodec(
      profileState, profileState ? profileState.activeProfile : "")
    readonly property var deviceAudioSink: root.bluetoothAudioSink(dev)
    readonly property var deviceAudioSource: root.audioProfileHasInput(dev ? dev.address : "")
      ? root.bluetoothAudioSource(dev) : null
    readonly property bool useAudioAvailable: isConnected && !!deviceAudioSink
    readonly property bool usingForAudio: useAudioAvailable
      && (root.defaultAudioSink
        ? Model.sameAudioNode(deviceAudioSink, root.defaultAudioSink)
        : String(deviceAudioSink.name || "") === root.currentAudioSinkName)

    readonly property bool rowSelected: root.cursorActive && root.focusSection === sectionName && root.selectedIndex === rowIndex
    readonly property bool showDetailsButton: !recoveryVisible && (rowMouse.containsMouse || rowSelected)
    readonly property bool showUseAudioButton: !recoveryVisible && useAudioAvailable && (rowMouse.containsMouse || rowSelected)

    hasCursor: rowSelected && root.focusedAction === ""
    current: isConnected
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    readonly property string statusText: {
      if (!dev) return ""
      if (cancellingPair) return "Cancelling pairing…"
      if (action === "forgetting") return "Forgetting…"
      if (action === "disconnecting" || devState === 2) return "Disconnecting…"
      if (actionFailureMessage !== "") return actionFailureMessage
      if (dev.blocked) return "Blocked"
      if (isConnected) {
        var details = []
        if (usingForAudio) details.push("Default audio")
        if (activeCodec !== "") details.push(activeCodec)
        if (dev.batteryAvailable) details.push(Math.round(dev.battery * 100) + "%")
        if (details.length > 0) return details.join(" · ")
        return sectionName === "connected" ? "" : "Connected"
      }
      if (action === "connecting" || devState === 3 || dev.pairing === true) return "Connecting…"
      if (isDiscovered) return ""
      return ""
    }

    readonly property color statusColor: {
      if (actionFailureMessage !== "") return root.bar.urgent
      if (dev && dev.blocked) return root.bar.urgent
      if (isConnected) return root.bar.foreground
      if (action !== "" || devState === 3 || dev.pairing === true) return root.bar.foreground
      return Qt.darker(root.bar.foreground, 1.5)
    }

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: row.dev ? Qt.PointingHandCursor : Qt.ArrowCursor

      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = row.sectionName
        root.selectedIndex = row.rowIndex
        root.focusedAction = ""
      }

      onClicked: function(mouse) {
        var dev = root.deviceFor(row)
        if (!dev) return
        if (mouse.button === Qt.RightButton) {
          root.openDeviceDetails(dev)
          return
        }
        if (row.isConnected) root.disconnectDevice(dev)
        else root.connectDevice(dev)
      }
    }

    PanelToolTip {
      visible: row.actionTooltip !== "" && rowMouse.containsMouse && root.focusedAction === ""
      text: row.actionTooltip
      fontFamily: root.bar.fontFamily
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(deviceIcon.implicitHeight, info.implicitHeight,
        profileDropdown.implicitHeight, detailsBtn.implicitHeight,
        useAudioBtn.implicitHeight, recoveryBtn.implicitHeight)

      BluetoothDeviceIcon {
        id: deviceIcon
        width: Style.space(26)
        height: Style.space(26)
        iconName: row.dev ? String(row.dev.icon || "") : ""
        deviceName: row.dev ? String(row.dev.name || row.dev.deviceName || "") : ""
        connected: row.isConnected
        foreground: row.statusColor
        iconSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: deviceIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: useAudioBtn.visible ? useAudioBtn.left
          : (detailsBtn.visible ? detailsBtn.left
          : (profileDropdown.visible ? profileDropdown.left
          : (recoveryBtn.visible ? recoveryBtn.left : parent.right)))
        anchors.rightMargin: profileDropdown.visible || detailsBtn.visible
          || useAudioBtn.visible || recoveryBtn.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: root.deviceDisplayName(row.dev) || "Device"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          visible: row.statusText !== ""
          text: row.statusText
          color: row.statusColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      AudioDropdown {
        id: profileDropdown
        width: Style.spacing.controlHeight
        anchors.right: recoveryBtn.visible ? recoveryBtn.left : parent.right
        anchors.rightMargin: recoveryBtn.visible ? Style.space(6) : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: row.profileMenuAvailable && !row.recoveryVisible
        rowHeight: Style.spacing.controlHeight
        popupRowHeight: Style.space(36)
        popupDirection: {
          var position = root.bar ? root.bar.position : "left"
          if (position === "top") return "down"
          if (position === "bottom") return "up"
          return position === "right" ? "left" : "right"
        }
        popupSideAlignment: "center"
        popupAnchorHeight: row.height
        popupWidth: Style.space(300)
        popupGap: Style.space(6)
        chevronOnly: true
        triggerChrome: hasCursor
        tooltipText: "Preferred audio mode"
        value: row.currentProfileName
        options: row.profileOptions
        hasCursor: row.rowSelected && root.focusedAction === "profile"
        enabled: !audioProfileSetProc.running && !root.pendingAudioProfile
          && !policyProfileProc.running
        opacity: enabled ? 1 : 0.5
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily

        onHovered: function(isHovered) {
          if (!isHovered) {
            if (rowMouse.containsMouse && root.focusedAction === "profile") root.focusedAction = ""
            return
          }
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.focusedAction = "profile"
        }
        onChanged: function(profile) { root.setAudioProfile(row.dev.address, profile) }
        onPopupOpenChanged: {
          if (popupOpen) root.closeAudioProfileMenus(row.rowIndex)
          root.audioProfileMenuOpen = popupOpen
          if (!popupOpen && root.opened)
            Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
      }

      PanelActionButton {
        id: detailsBtn
        anchors.right: profileDropdown.visible ? profileDropdown.left
          : (recoveryBtn.visible ? recoveryBtn.left : parent.right)
        anchors.rightMargin: profileDropdown.visible || recoveryBtn.visible ? Style.space(6) : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showDetailsButton
        iconText: "󰒓"
        tooltipText: "Device details"
        foreground: root.bar.foreground
        hoverColor: root.bar.foreground
        fontFamily: root.bar.fontFamily
        hasCursor: row.rowSelected && root.focusedAction === "details"
        onHovered: function(isHovered) {
          if (!isHovered) {
            if (rowMouse.containsMouse && root.focusedAction === "details") root.focusedAction = ""
            return
          }
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.focusedAction = "details"
        }
        onClicked: {
          var dev = root.deviceFor(row)
          if (!dev) return
          root.openDeviceDetails(dev)
        }
      }

      PanelActionButton {
        id: useAudioBtn
        anchors.right: detailsBtn.visible ? detailsBtn.left
          : (profileDropdown.visible ? profileDropdown.left
          : (recoveryBtn.visible ? recoveryBtn.left : parent.right))
        anchors.rightMargin: detailsBtn.visible || profileDropdown.visible
          || recoveryBtn.visible ? Style.space(6) : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showUseAudioButton
        iconText: row.usingForAudio ? "󰄬" : "󰓃"
        tooltipText: row.usingForAudio ? "Default audio device"
          : (row.deviceAudioSource ? "Use for audio input and output" : "Use for audio output")
        foreground: row.usingForAudio
          ? Style.selectedStateColor(root.bar.foreground, Color.accent)
          : root.bar.foreground
        hoverColor: root.bar.foreground
        fontFamily: root.bar.fontFamily
        hasCursor: row.rowSelected && root.focusedAction === "audio"
        onHovered: function(isHovered) {
          if (!isHovered) {
            if (rowMouse.containsMouse && root.focusedAction === "audio") root.focusedAction = ""
            return
          }
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.focusedAction = "audio"
        }
        onClicked: {
          var dev = root.deviceFor(row)
          if (!dev) return
          root.useDeviceForAudio(dev)
        }
      }

      PanelActionButton {
        id: recoveryBtn
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: row.recoveryVisible
        enabled: row.recoveryAction === "cancel" || !deviceActionProc.running
        iconText: row.recoveryAction === "cancel" ? "󰅙" : "󰑐"
        tooltipText: row.recoveryAction === "cancel" ? "Cancel pairing"
          : (row.actionFailureMessage !== ""
            ? "Retry · " + row.actionFailureMessage : "Retry")
        foreground: root.bar.foreground
        hoverColor: row.recoveryAction === "retry" ? root.bar.urgent : root.bar.foreground
        fontFamily: root.bar.fontFamily
        hasCursor: row.rowSelected && root.focusedAction === row.recoveryAction
        onHovered: function(isHovered) {
          if (!isHovered) {
            if (rowMouse.containsMouse && root.focusedAction === row.recoveryAction)
              root.focusedAction = ""
            return
          }
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.focusedAction = row.recoveryAction
        }
        onClicked: {
          var dev = root.deviceFor(row)
          if (!dev) return
          if (row.recoveryAction === "cancel") root.cancelPairing(dev)
          else root.retryDeviceAction(dev)
        }
      }
    }

    function toggleProfileMenu() { profileDropdown.toggle() }
    function closeProfileMenu() { profileDropdown.close() }

    onProfileMenuAvailableChanged: if (!profileMenuAvailable) closeProfileMenu()
    onRecoveryVisibleChanged: if (recoveryVisible) closeProfileMenu()
    onRecoveryActionChanged: if (rowSelected
      && (root.focusedAction === "retry" || root.focusedAction === "cancel")
      && root.focusedAction !== recoveryAction) root.focusedAction = ""
    Component.onDestruction: if (profileDropdown.popupOpen) root.audioProfileMenuOpen = false
  }
}
