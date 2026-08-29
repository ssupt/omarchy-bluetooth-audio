import QtQuick
import QtQuick.Controls
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

  // Normalized address -> "connecting" | "disconnecting" | "forgetting".
  // The plugin-local helper reports command failures; this map keeps the
  // panel responsive while successful operations propagate through BlueZ.
  property var pendingActions: ({})
  // Normalized address -> helper operation (pair/connect/disconnect/forget).
  // Kept separately from the user-facing progress label so a successful
  // command whose state never arrives can become an actionable retry.
  property var pendingActionKinds: ({})
  // Normalized address -> wall-clock confirmation deadline. A deadline belongs
  // to one operation; starting work for another device must not keep the first
  // row spinning forever.
  property var pendingActionDeadlines: ({})
  readonly property int pendingActionTimeoutMs: 20000
  // Normalized address -> { action, message }. Failures stay attached to the
  // device row until the user retries or live BlueZ state proves the action
  // completed after all.
  property var deviceActionFailures: ({})
  property var activeDeviceAction: null
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
  property string devicePropertyStderr: ""
  property string devicePropertyError: ""
  property var pendingAudioPolicy: null

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
  readonly property string audioPolicyPreferencesPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/bluetooth-audio-policies.json"
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
  property var sharedAudioPreferences: Model.parseAudioPreferences("")
  property var audioPolicyOverrides: ({})
  readonly property var audioPreferences: Model.mergeAudioPreferences(
    sharedAudioPreferences, audioPolicyOverrides)
  property bool sharedAudioPreferencesReady: false
  property bool audioPolicyOverridesReady: false
  readonly property bool audioPreferencesReady: sharedAudioPreferencesReady
    && audioPolicyOverridesReady
  readonly property var audioPluginRegistry: bar && bar.shell ? bar.shell.pluginRegistry : null
  property bool audioControlInstalled: false
  onAudioPluginRegistryChanged: Qt.callLater(function() { root.refreshAudioControlInstalled() })
  onAudioControlInstalledChanged: {
    if (!audioControlInstalled && headerIndex === 0) headerIndex = 1
    if (audioControlInstalled) audioControlAliasSyncTimer.restart()
  }

  // BlueZ owns pairing and connection state; PipeWire owns the audio card's
  // active profile and therefore the codec/microphone mode offered here.
  property var audioProfiles: ({})
  property string sharedAudioPreferencesError: ""
  property string audioPolicyPreferencesError: ""
  property string audioPreferenceWriteError: ""
  readonly property string audioPreferencesError: sharedAudioPreferencesError !== ""
    ? sharedAudioPreferencesError : (audioPolicyPreferencesError !== ""
      ? audioPolicyPreferencesError : audioPreferenceWriteError)
  property string audioProfileReadError: ""
  property string audioProfileSetError: ""
  property string audioProfileSetStderr: ""
  readonly property string audioProfileError: audioProfileSetError !== ""
    ? audioProfileSetError : (audioProfileReadError !== ""
      ? audioProfileReadError : audioPreferencesError)
  property var pendingAudioProfile: null
  property var unconfirmedAudioProfile: null
  // Kept until Process exits even if PipeWire confirms early. Confirmation
  // proves the hardware state, not that the wrapper persisted the preference.
  property var activeAudioProfileOperation: null
  property bool audioProfileMenuOpen: false
  readonly property bool userAudioProfileChangeBusy: audioProfileSetProc.running
    || audioProfileSetProc.collecting || pendingAudioProfile !== null
  readonly property bool audioProfileCommandBusy: audioProfileSetProc.running
    || audioProfileSetProc.collecting || policyEngine.profileSwitchBusy
  readonly property bool localAudioProfileChangeBusy: userAudioProfileChangeBusy
    || policyEngine.profileSwitchBusy
  // PipeWire cards are global while this widget is mirrored per monitor. Read
  // every mirror's local command state so a manual selection in the open panel
  // cannot race an automatic switch owned by a different panel instance.
  readonly property bool audioProfileChangeBusy: {
    if (!bar || typeof bar.moduleWidgets !== "function")
      return localAudioProfileChangeBusy
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i].localAudioProfileChangeBusy === true) return true
    return localAudioProfileChangeBusy
  }
  readonly property bool audioProfilesNeeded: connectedDevices.length > 0
    && (opened || policyEngine.hasPending || pendingAudioProfile !== null)

  function pluginScript(name) {
    var url = String(Qt.resolvedUrl("scripts/" + name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function audioControlScript(name) {
    return audioControlManifestPath.replace(/\/manifest\.json$/, "") + "/scripts/" + name
  }

  // The name this panel displays for a device. With the companion enabled
  // its alias wins — the two plugins must agree on one label per device —
  // falling back to the BlueZ alias. Node names are tried live first, then all
  // saved keys carrying this device's address. PipeWire changes the exact
  // bluez_output/bluez_input spelling between profiles and versions, so a
  // guessed suffix would leave disconnected endpoints behind.
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
    var savedKeys = Model.deviceAliasKeysForAddress(audioControlAliases, address)
    for (var savedIndex = 0; savedIndex < savedKeys.length; savedIndex++)
      if (keys.indexOf(savedKeys[savedIndex]) === -1) keys.push(savedKeys[savedIndex])
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
    && (Model.isAudioDevice(String(deviceDetailsRow.icon || ""),
        String(deviceDetailsRow.name || "") + " "
          + String(deviceDetailsRow.deviceName || ""))
      || !!bluetoothAudioSink(deviceDetailsRow))
  readonly property var deviceDetailsStops: !deviceDetailsRow ? []
    : Model.deviceDetailsStops(deviceDetailsIsAudio, deviceDetailsForgetAvailable)
  // Keep process ownership separate from state confirmation. BlueZ can publish
  // the requested value just before busctl exits; clearing the pending object at
  // that point must not allow a second command to reuse the running Process.
  readonly property bool localDevicePropertyBusy: devicePropertyProc.running
    || devicePropertyProc.collecting || pendingDeviceProperty !== null
  readonly property bool devicePropertyBusy: {
    if (!bar || typeof bar.moduleWidgets !== "function")
      return localDevicePropertyBusy
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i].localDevicePropertyBusy === true) return true
    return localDevicePropertyBusy
  }
  readonly property bool audioPolicyPreferenceBusy: pendingAudioPolicy !== null
  readonly property bool localDeviceActionBusy: deviceActionProc.running
    || deviceActionProc.collecting
  readonly property bool hasPendingDeviceActions: {
    if (Object.keys(pendingActions).length > 0) return true
    if (!bar || typeof bar.moduleWidgets !== "function") return false
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i] !== root
          && Object.keys(items[i].pendingActions || {}).length > 0) return true
    return false
  }
  readonly property bool deviceActionBusy: {
    if (!bar || typeof bar.moduleWidgets !== "function") return localDeviceActionBusy
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i].localDeviceActionBusy === true) return true
    return localDeviceActionBusy
  }
  readonly property bool deviceDetailsActionBusy: !!activeDeviceAction
    && Model.normalizedAddress(activeDeviceAction.address)
      === Model.normalizedAddress(deviceDetailsAddress)
  readonly property bool deviceDetailsControlsBusy: devicePropertyBusy
    || audioPolicyPreferenceBusy || deviceDetailsActionBusy
    || pendingAction(deviceDetailsAddress) !== ""
    || deviceActionBusy || audioProfileChangeBusy
  readonly property string deviceDetailsBusyText: devicePropertyBusy
    ? "Saving device setting…"
    : (audioPolicyPreferenceBusy ? "Saving audio policy…"
      : "Bluetooth operation in progress…")
  onDeviceDetailsStopsChanged: if (deviceDetailsOpen)
    setDeviceDetailsCursor(deviceDetailsIndex)
  onDeviceDetailsRowChanged: confirmDevicePropertyIfReached()
  onAudioControlAliasesChanged: if (deviceDetailsRow && !pendingDeviceProperty)
    deviceDetailsView.updateNameIfIdle(String(deviceDisplayName(deviceDetailsRow)
      || deviceDetailsRow.deviceName || ""))

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
    sharedAudioPreferencesError = Model.isAudioPreferencesDocument(raw)
      ? "" : "Audio preferences contain invalid JSON"
    sharedAudioPreferences = Model.parseAudioPreferences(raw)
    sharedAudioPreferencesReady = true
    if (sharedAudioPreferencesError === "") audioPreferenceWriteError = ""
  }

  function loadAudioPolicyOverrides(raw) {
    audioPolicyPreferencesError = Model.isAudioPreferencesDocument(raw)
      ? "" : "Bluetooth audio policies contain invalid JSON"
    audioPolicyOverrides = Model.parseAudioPolicyOverrides(raw)
    audioPolicyOverridesReady = true
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
      if (Model.bluetoothSinkMatchesDevice(
          sinks[i], device, connectedDevices)) return sinks[i]
    }
    return null
  }

  function bluetoothAudioSource(device) {
    var sources = audioSources()
    for (var i = 0; i < sources.length; i++) {
      if (Model.bluetoothSourceMatchesDevice(
          sources[i], device, connectedDevices)) return sources[i]
    }
    return null
  }

  function audioUseActionAvailable(device) {
    return !audioProfileChangeBusy && !deviceActionBusy && !devicePropertyBusy
      && !!device && device.connected
      && pendingAction(device.address) === ""
      && !!bluetoothAudioSink(device)
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

  function deviceAudioPolicy(address) {
    if (pendingAudioPolicy
        && Model.normalizedAddress(pendingAudioPolicy.address)
          === Model.normalizedAddress(address))
      return pendingAudioPolicy.policy
    return Model.deviceAudioPolicy(audioPreferences, address)
  }

  function setDeviceAudioPolicy(policy) {
    if (!deviceDetailsAddress || pendingAudioPolicy
        || Model.audioPolicyOrder().indexOf(policy) < 0) return
    pendingAudioPolicy = {
      address: String(deviceDetailsAddress),
      policy: String(policy)
    }
    devicePropertyError = ""
    audioPolicyPreferenceProc.command = [
      pluginScript("audio-preferences"),
      "set-policy",
      String(deviceDetailsAddress),
      String(policy)
    ]
    audioPolicyPreferenceProc.prepare()
    audioPolicyPreferenceProc.running = true
  }

  function applyAudioPolicyOverride(address, policy) {
    var key = Model.normalizedAddress(address)
    if (key === "") return
    var next = cloneMap(audioPolicyOverrides)
    // Keep "manual" as an explicit tombstone until every legacy writer has
    // stopped publishing policies in the shared audio-preferences document.
    next[key] = String(policy)
    audioPolicyOverrides = next
    audioPolicyOverridesReady = true
    audioPolicyPreferencesError = ""
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
      return "Leaves audio routing unchanged when this device connects."
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
    if (saved !== "" && !Model.audioProfileHasInput(state, saved))
      return "Connects in “" + duplex.label
        + "” so the microphone is available; this becomes the device's audio mode while the policy is selected."
    return "Makes this device the default output and input the next time it connects."
  }

  function refreshAudioProfiles() {
    if (!audioProfilesNeeded || audioProfilesProc.running
        || audioProfilesProc.collecting) return
    audioProfilesProc.prepare()
    audioProfilesProc.running = true
  }

  function updateAudioProfiles(raw) {
    // A read started before the last disconnect can finish afterwards. Do not
    // repopulate stale card state once there are no live Bluetooth devices.
    if (connectedDevices.length === 0) {
      audioProfiles = ({})
      audioProfileReadError = ""
      return
    }
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
    if (audioProfileChangeBusy || deviceActionBusy || devicePropertyBusy
        || pendingAction(address) !== "" || !address || !profile) return
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
    activeAudioProfileOperation = pendingAudioProfile
    audioProfileSetError = ""
    audioProfileSetProc.command = [
      pluginScript("bluetooth-audio-profile-set"),
      String(address),
      String(profile)
    ]
    audioProfileSetProc.prepare()
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
    if (!device || audioProfileChangeBusy || deviceActionBusy || devicePropertyBusy
        || pendingAction(device.address) !== "") return
    var sink = bluetoothAudioSink(device)
    if (!sink) return
    setDefaultAudioSink(sink)

    // High-fidelity Bluetooth profiles expose output only. Communication
    // profiles also expose a matching microphone; when present, selecting the
    // device for audio makes that source the default as well.
    // A live, non-monitor PipeWire source is stronger evidence than the
    // asynchronously refreshed profile inventory. This keeps a click during
    // card discovery from routing output but overlooking an available mic.
    var source = bluetoothAudioSource(device)
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
    var local = Model.pendingAction(pendingActions, address)
    if (local !== "" || !bar || typeof bar.moduleWidgets !== "function") return local
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++) {
      if (!items[i] || items[i] === root) continue
      var sibling = Model.pendingAction(items[i].pendingActions, address)
      if (sibling !== "") return sibling
    }
    return ""
  }

  function adoptPendingAction(address, action, operation, deadline) {
    var key = Model.normalizedAddress(address)
    if (key === "") return
    pendingActions = Model.withPendingAction(pendingActions, address, action)
    pendingActionKinds = Model.withPendingAction(
      pendingActionKinds, address, action ? String(operation || "") : "")
    var deadlines = cloneMap(pendingActionDeadlines)
    if (action)
      deadlines[key] = Number(deadline || 0) > 0
        ? Number(deadline) : Date.now() + pendingActionTimeoutMs
    else
      delete deadlines[key]
    pendingActionDeadlines = deadlines
  }

  function setPendingAction(address, action, operation) {
    var deadline = action ? Date.now() + pendingActionTimeoutMs : 0
    adoptPendingAction(address, action, operation, deadline)
    if (!bar || typeof bar.moduleWidgets !== "function") return
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i] !== root
          && typeof items[i].adoptPendingAction === "function")
        items[i].adoptPendingAction(address, action, operation, deadline)
  }

  function deviceActionFailure(address) {
    var local = Model.deviceActionFailure(deviceActionFailures, address)
    if (local || !bar || typeof bar.moduleWidgets !== "function") return local
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++) {
      if (!items[i] || items[i] === root) continue
      var sibling = Model.deviceActionFailure(items[i].deviceActionFailures, address)
      if (sibling) return sibling
    }
    return null
  }

  function adoptDeviceActionFailure(address, action, message) {
    deviceActionFailures = Model.withDeviceActionFailure(
      deviceActionFailures, address, action, message)
  }

  function setDeviceActionFailure(address, action, message) {
    adoptDeviceActionFailure(address, action, message)
    if (!bar || typeof bar.moduleWidgets !== "function") return
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i] !== root
          && typeof items[i].adoptDeviceActionFailure === "function")
        items[i].adoptDeviceActionFailure(address, action, message)
  }

  function deviceActionOwner(address, action) {
    var normalized = Model.normalizedAddress(address)
    var items = bar && typeof bar.moduleWidgets === "function"
      ? (bar.moduleWidgets(moduleName) || []) : [root]
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      var active = item ? item.activeDeviceAction : null
      if (active && Model.normalizedAddress(active.address) === normalized
          && (!action || active.action === action)) return item
    }
    return null
  }

  function pairingCancellationPending(address) {
    var owner = deviceActionOwner(address, "pair")
    return !!owner && owner.deviceActionCancelRequested === true
  }

  function adoptInterruptedDeviceAction(operation) {
    if (!operation || !operation.address) return
    adoptPendingAction(operation.address, "", "")
    var device = deviceByAddress(operation.address)
    if (!Model.deviceActionReachedState(operation.action, device))
      adoptDeviceActionFailure(operation.address, operation.action,
        "The Bluetooth operation was interrupted. Try again.")
  }

  function adoptInterruptedAudioProfile(operation) {
    if (!operation || !operation.address || !operation.profile) return
    var device = deviceByAddress(operation.address)
    if (!device || !device.connected) return
    pendingAudioProfile = {
      address: Model.normalizedAddress(operation.address),
      profile: String(operation.profile)
    }
    unconfirmedAudioProfile = pendingAudioProfile
    activeAudioProfileOperation = null
    audioProfileSetError = ""
    audioProfilePendingTimeout.restart()
    audioProfileRefreshTimer.restart()
  }

  function adoptInterruptedDeviceProperty(operation) {
    if (!operation || !operation.address || pendingDeviceProperty) return false
    pendingDeviceProperty = cloneMap(operation)
    devicePropertyStderr = ""
    devicePropertyConfirmTimer.restart()
    return true
  }

  function recoveryAction(address) {
    var owner = deviceActionOwner(address, "pair")
    if (owner && !owner.deviceActionCancelRequested)
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
    if (!device || !device.address || deviceActionBusy || devicePropertyBusy
        || audioProfileChangeBusy
        || pendingAction(device.address) !== "") return
    setDeviceActionFailure(device.address, "", "")
    deviceActionCancelRequested = false
    activeDeviceAction = {
      address: String(device.address),
      action: String(action),
      pending: String(pending)
    }
    setPendingAction(device.address, pending, action)
    deviceActionProc.command = deviceCommand(action, device.address)
    deviceActionProc.prepare()
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

  function restorePanelFocus() {
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
      deviceDetailsView.reset(details
        ? (root.deviceDisplayName(details) || String(details.deviceName || "")) : "")
      keyCatcher.forceActiveFocus()
    })
  }

  function closeDeviceDetails() {
    if (!deviceDetailsOpen) return
    forgetConfirmationOpen = false
    devicePropertyError = ""
    deviceDetailsView.clearNameFocus()
    deviceDetailsAddress = ""
    deviceDetailsIndex = 0
    reselectFocusedDevice()
    restorePanelFocus()
  }

  function setDeviceDetailsCursor(index) {
    var stops = deviceDetailsStops
    if (!stops || stops.length === 0) {
      deviceDetailsIndex = 0
      return
    }

    var target = Number(index)
    if (stops.indexOf(target) < 0) {
      target = stops[stops.length - 1]
      for (var i = 0; i < stops.length; i++) {
        if (stops[i] >= index) { target = stops[i]; break }
      }
    }
    deviceDetailsIndex = target
    Qt.callLater(function() { deviceDetailsView.ensureCursorVisible() })
  }

  function moveDeviceDetailsCursor(delta) {
    var stops = deviceDetailsStops
    if (!stops || stops.length === 0) return
    var position = stops.indexOf(deviceDetailsIndex)
    if (position < 0) position = 0
    position = Math.max(0, Math.min(stops.length - 1, position + delta))
    setDeviceDetailsCursor(stops[position])
  }

  function detailsStopAvailable(index) {
    return deviceDetailsStops.indexOf(index) >= 0
  }

  function beginDeviceRename() {
    if (!deviceDetailsRow || deviceDetailsControlsBusy) return
    deviceDetailsView.beginRename(String(root.deviceDisplayName(deviceDetailsRow)
      || deviceDetailsRow.deviceName || ""))
  }

  function cancelDeviceRename() {
    var details = deviceDetailsRow
    deviceDetailsView.finishRename(details
      ? (root.deviceDisplayName(details) || String(details.deviceName || "")) : "")
    restorePanelFocus()
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
      if (propertyName === "name") syncAudioControlAliases(device.address, String(value))
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
      value: value,
      expected: expected,
      errorMessage: String(errorMessage)
    }
    devicePropertyError = ""
    devicePropertyProc.command = devicePropertyCommand(
      propertyName, details.dbusPath, value)
    devicePropertyProc.prepare()
    devicePropertyProc.running = true
  }

  // With the companion plugin enabled, a rename must also land in its
  // device-alias store so the Advanced Audio window shows the same label.
  // That store keys by PipeWire node name. Update both live nodes and saved
  // address-matching keys: an input can disappear in A2DP mode while its old
  // alias remains in the store, then return when a duplex codec is selected.
  // An empty alias deletes those entries, matching restore-original-name.
  function syncAudioControlAliases(address, alias) {
    if (!audioControlInstalled || !address) return
    var device = deviceByAddress(address)
    if (!device) return

    var names = []
    function addName(name) {
      var value = String(name || "")
      if (value !== "" && names.indexOf(value) === -1) names.push(value)
    }
    var sink = bluetoothAudioSink(device)
    if (sink && sink.name) addName(sink.name)
    var source = bluetoothAudioSource(device)
    if (source && source.name) addName(source.name)
    var savedNames = Model.deviceAliasKeysForAddress(audioControlAliases, address)
    for (var savedIndex = 0; savedIndex < savedNames.length; savedIndex++)
      addName(savedNames[savedIndex])

    var target = String(alias)
    for (var i = 0; i < names.length; i++) {
      if (String(audioControlAliases[names[i]] || "") === target) continue
      Quickshell.execDetached([
        audioControlScript("audio-app-rules"),
        "set-alias",
        names[i],
        target
      ])
    }
  }

  // A profile switch can create an input long after the Bluetooth rename was
  // committed. Reconcile newly materialized endpoints from BlueZ's persistent
  // Alias; the companion file watcher makes this idempotent after each write.
  function reconcileAudioControlAliases() {
    if (!audioControlInstalled || !isAudioPolicyCoordinator()) return
    var values = connectedDevices || []
    for (var i = 0; i < values.length; i++) {
      var device = values[i]
      var alias = String(device && device.name || "").trim()
      var original = String(device && device.deviceName || "").trim()
      if (alias !== "" && alias !== original)
        syncAudioControlAliases(device.address, alias)
    }
  }

  function commitDeviceRename() {
    var device = deviceByAddress(deviceDetailsAddress)
    if (!device || deviceDetailsControlsBusy) return
    var requested = deviceDetailsView.renameText().trim()
    var expected = requested !== "" ? requested : String(device.deviceName || "").trim()
    deviceDetailsView.finishRename(expected)
    updateDeviceProperty("name", requested, expected, "Could not rename this device.")
    restorePanelFocus()
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

    if (matches && operation.propertyName === "name")
      syncAudioControlAliases(operation.address, String(operation.value))

    if (Model.normalizedAddress(deviceDetailsAddress)
        !== Model.normalizedAddress(operation.address)) return
    devicePropertyError = matches ? ""
      : (device ? operation.errorMessage : "This device is no longer available.")
    if (operation.propertyName === "name" && deviceDetailsRow)
      deviceDetailsView.updateNameIfIdle(String(root.deviceDisplayName(deviceDetailsRow)
        || deviceDetailsRow.deviceName || ""))
  }

  function confirmDevicePropertyIfReached() {
    var operation = pendingDeviceProperty
    if (!operation) return
    var device = deviceByAddress(operation.address)
    if (!device
        || liveDeviceProperty(device, operation.propertyName) !== operation.expected) return
    devicePropertyConfirmTimer.stop()
    confirmDeviceProperty()
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
    if (deviceDetailsControlsBusy || deviceActionBusy || pendingAction(address) !== "") return
    if (device && device.address
        && Model.normalizedAddress(device.address) !== Model.normalizedAddress(deviceDetailsAddress))
      openDeviceDetails(device)
    if (!deviceDetailsForgetAvailable && !device) return
    forgetConfirmationOpen = true
    deviceDetailsView.resetConfirmation()
  }

  function cancelForgetConfirmation() {
    forgetConfirmationOpen = false
    restorePanelFocus()
  }

  function confirmForgetDevice() {
    if (deviceDetailsControlsBusy || deviceActionBusy) return
    var device = deviceByAddress(deviceDetailsAddress)
    forgetConfirmationOpen = false
    closeDeviceDetails()
    if (device) forgetDevice(device)
  }

  function retryDeviceAction(device) {
    if (!device || !device.address || deviceActionBusy) return
    var failure = deviceActionFailure(device.address)
    if (!failure) return
    if (failure.action === "pair" || failure.action === "connect") connectDevice(device)
    else if (failure.action === "disconnect") disconnectDevice(device)
    else if (failure.action === "forget") forgetDevice(device)
  }

  function cancelPairing(device) {
    if (!device || !device.address) return
    var owner = deviceActionOwner(device.address, "pair")
    if (!owner) return
    if (owner !== root) {
      owner.cancelPairing(device)
      return
    }

    deviceActionCancelRequested = true
    setPendingAction(device.address, "")
    setDeviceActionFailure(device.address, "", "")
    if (typeof device.cancelPair === "function") device.cancelPair()
    if (deviceActionProc.running) deviceActionProc.signal(15)
  }

  // Bar widgets are mirrored per monitor. Only the first live mirror applies
  // automatic routing, otherwise every monitor would race the same profile and
  // default-device commands for a single connection.
  function isAudioPolicyCoordinator() {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++)
      if (items[i]) return items[i] === root
    return true
  }

  // Keep the coordinator's policy queue replicated across monitor widgets.
  // Engine adoption is deliberately silent, preventing publication loops.
  function publishAudioPolicyApplications(applications) {
    if (!isAudioPolicyCoordinator() || !bar
        || typeof bar.moduleWidgets !== "function") return
    var items = bar.moduleWidgets(moduleName) || []
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (item && item !== root
          && typeof item.adoptAudioPolicyApplications === "function")
        item.adoptAudioPolicyApplications(applications)
    }
  }

  function adoptAudioPolicyApplications(applications) {
    policyEngine.adoptApplications(applications)
  }

  function audioPolicyApplicationsSnapshot() {
    return policyEngine.pendingApplications
  }

  function adoptExistingAudioPolicyApplications() {
    if (!bar || typeof bar.moduleWidgets !== "function") return
    var items = bar.moduleWidgets(moduleName) || []
    var merged = {}
    var current = policyEngine.pendingApplications || {}
    for (var currentKey in current)
      merged[currentKey] = cloneMap(current[currentKey])
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (!item || item === root
          || typeof item.audioPolicyApplicationsSnapshot !== "function") continue
      var applications = item.audioPolicyApplicationsSnapshot() || {}
      for (var key in applications)
        if (!merged[key]) merged[key] = cloneMap(applications[key])
    }
    if (Object.keys(merged).length > 0) policyEngine.adoptApplications(merged)
  }

  function syncPendingActions() {
    var next = cloneMap(pendingActions)
    var completed = []

    for (var address in next) {
      var found = null

      for (var i = 0; i < devices.length; i++) {
        var d = devices[i]
        if (d && Model.normalizedAddress(d.address) === address) {
          found = d
          break
        }
      }

      var operation = String(pendingActionKinds[address] || "")
      if (operation !== "" && Model.deviceActionReachedState(operation, found))
        completed.push(address)
    }

    for (var completedIndex = 0; completedIndex < completed.length; completedIndex++)
      setPendingAction(completed[completedIndex], "", "")

    var failures = cloneMap(deviceActionFailures)
    var recovered = []
    for (var failureAddress in failures) {
      var failure = failures[failureAddress]
      var failedDevice = null
      for (var j = 0; j < devices.length; j++) {
        if (devices[j] && Model.normalizedAddress(devices[j].address) === failureAddress) {
          failedDevice = devices[j]
          break
        }
      }
      if (failure && Model.deviceActionReachedState(failure.action, failedDevice))
        recovered.push(failureAddress)
    }
    for (var recoveredIndex = 0; recoveredIndex < recovered.length; recoveredIndex++)
      setDeviceActionFailure(recovered[recoveredIndex], "", "")
  }

  function pendingActionTimeoutMessage(action) {
    if (action === "pair" || action === "connect")
      return "The Bluetooth command finished, but the device did not connect."
    if (action === "disconnect")
      return "The Bluetooth command finished, but the device stayed connected."
    if (action === "forget")
      return "The Bluetooth command finished, but the device was not forgotten."
    return "The Bluetooth command finished, but its state did not update."
  }

  function expirePendingActions() {
    syncPendingActions()
    var actions = pendingActions
    var kinds = pendingActionKinds
    var deadlines = pendingActionDeadlines
    var now = Date.now()
    var expired = []
    for (var address in actions) {
      if (Number(deadlines[address] || 0) > now) continue
      // A helper owns its row until it exits; its success path starts a fresh
      // confirmation deadline and its failure path clears the pending state.
      if (deviceActionOwner(address)) continue
      var action = String(kinds[address] || "")
      if (action !== "")
        setDeviceActionFailure(address, action, pendingActionTimeoutMessage(action))
      expired.push(address)
    }
    for (var expiredIndex = 0; expiredIndex < expired.length; expiredIndex++)
      setPendingAction(expired[expiredIndex], "", "")
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
    if (recovery !== "") return [recovery, "details"]
    if (focusSection === "connected" && audioUseActionAvailable(dev)) actions.push("audio")
    actions.push("details")
    if (focusSection === "connected" && !audioProfileChangeBusy
        && audioProfileActionAvailable(dev)) actions.push("profile")
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
      else if (sectionVisible("discovered")) { focusSection = "discovered"; selectedIndex = 0 }
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
      updateFocusedAddress()
      return
    }

    var sections = ["connected", "known", "discovered"]
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s]
      if (!sectionVisible(section)) continue
      var list = devicesForSection(section)
      for (var i = 0; i < list.length; i++) {
        if (list[i] && Model.normalizedAddress(list[i].address)
            === Model.normalizedAddress(focusedDeviceAddress)) {
          focusSection = section
          selectedIndex = i
          clampCursor()
          updateFocusedAddress()
          return
        }
      }
    }

    clampCursor()
    // The selected numeric index can remain unchanged when its old device is
    // removed and another row slides into that slot. Refresh the stable key
    // explicitly because no onSelectedIndexChanged signal fires in that case.
    updateFocusedAddress()
  }

  onSelectedIndexChanged: { focusedAction = ""; updateFocusedAddress() }
  onFocusSectionChanged: { focusedAction = ""; updateFocusedAddress() }
  onConnectedDevicesChanged: {
    reselectFocusedDevice()
    syncPendingActions()
    policyEngine.observeDevices(devices)
    var expectedProfile = pendingAudioProfile || unconfirmedAudioProfile
    if (expectedProfile) {
      var expectedDevice = deviceByAddress(expectedProfile.address)
      if (!expectedDevice || !expectedDevice.connected) {
        pendingAudioProfile = null
        unconfirmedAudioProfile = null
        activeAudioProfileOperation = null
        audioProfilePendingTimeout.stop()
        audioProfileSetError = connectedDevices.length > 0
          ? "The Bluetooth audio device disconnected before its mode was confirmed" : ""
      }
    }
    if (connectedDevices.length === 0) {
      audioProfiles = ({})
      audioProfileReadError = ""
      audioProfileSetError = ""
      pendingAudioProfile = null
      unconfirmedAudioProfile = null
      audioProfilePendingTimeout.stop()
    }
    else if (audioProfilesNeeded) audioProfileRefreshTimer.restart()
    audioControlAliasSyncTimer.restart()
  }
  onKnownDevicesChanged: {
    reselectFocusedDevice()
    syncPendingActions()
    policyEngine.observeDevices(devices)
  }
  onDiscoveredDevicesChanged: {
    reselectFocusedDevice()
    syncPendingActions()
    policyEngine.observeDevices(devices)
  }
  onVisibleSectionsChanged: clampCursor()
  onPipewireNodesChanged: {
    if (audioProfilesNeeded) audioProfileSettleTimer.restart()
    audioControlAliasSyncTimer.restart()
    if (focusedAction === "audio"
        && !audioUseActionAvailable(deviceAt(focusSection, selectedIndex))) focusedAction = ""
  }
  onAudioProfileChangeBusyChanged: {
    if (focusedAction === "profile" && audioProfileChangeBusy) focusedAction = ""
    else if (focusedAction === "audio"
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
      focusSection = "header"
      selectedIndex = 0
      focusedAction = ""
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

  // A destroyed instance cannot wait for child processes or BlueZ discovery
  // confirmations. Hand interrupted operations and discovery debt to surviving
  // mirrors; only write StopDiscovery directly when this is the final item.
  Component.onDestruction: {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    var interruptedProfile = activeAudioProfileOperation
      || pendingAudioProfile || unconfirmedAudioProfile
    var propertyHandedOff = false
    for (var actionIndex = 0; actionIndex < items.length; actionIndex++) {
      var actionSibling = items[actionIndex]
      if (!actionSibling || actionSibling === root) continue
      for (var pendingAddress in pendingActions)
        if (typeof actionSibling.adoptPendingAction === "function")
          actionSibling.adoptPendingAction(pendingAddress,
            pendingActions[pendingAddress], pendingActionKinds[pendingAddress],
            pendingActionDeadlines[pendingAddress])
      for (var failureAddress in deviceActionFailures)
        if (typeof actionSibling.adoptDeviceActionFailure === "function") {
          var failure = deviceActionFailures[failureAddress]
          if (failure)
            actionSibling.adoptDeviceActionFailure(failureAddress,
              failure.action, failure.message)
        }
      if (activeDeviceAction && !deviceActionCancelRequested
          && typeof actionSibling.adoptInterruptedDeviceAction === "function")
        actionSibling.adoptInterruptedDeviceAction(activeDeviceAction)
      if (interruptedProfile
          && typeof actionSibling.adoptInterruptedAudioProfile === "function")
        actionSibling.adoptInterruptedAudioProfile(interruptedProfile)
      if (!propertyHandedOff && pendingDeviceProperty
          && typeof actionSibling.adoptInterruptedDeviceProperty === "function") {
        propertyHandedOff = actionSibling.adoptInterruptedDeviceProperty(
          pendingDeviceProperty) === true
      }
    }

    if (!owesDiscoveryStop) return
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root) { items[i].owesDiscoveryStop = true; return }
    }
    if (adapter !== null && adapter.discovering) adapter.discovering = false
  }

  Component.onCompleted: {
    refreshAudioControlInstalled()
    policyEngine.initializeDevices(devices)
    // Preserve policies written by versions that stored them in the shared
    // audio document before a schema-normalizing companion writer can drop the
    // unknown field. The migration is locked and idempotent across monitors.
    audioPolicyMigrationProc.running = true
    // A monitor can be added while another mirror owns an in-flight connect
    // policy. Adopt its shadow before this item can become the first/coordinator
    // widget, otherwise a change in module ordering could strand that queue.
    Qt.callLater(function() { root.adoptExistingAudioPolicyApplications() })
  }

  Connections {
    target: root.audioPluginRegistry
    function onPluginsChanged() { root.refreshAudioControlInstalled() }
  }

  FileView {
    id: audioPreferencesView
    path: root.audioPreferencesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadAudioPreferences(text())
    onLoadFailed: root.loadAudioPreferences("")
    onFileChanged: reload()
  }

  Process {
    id: audioPolicyPreferenceProc
    property bool collecting: false
    property bool stderrComplete: false
    property bool exitComplete: false
    property int resultCode: 0
    property string resultStderr: ""

    function prepare() {
      collecting = true
      stderrComplete = false
      exitComplete = false
      resultCode = 0
      resultStderr = ""
    }

    function finishCollection() {
      if (!collecting || !stderrComplete || !exitComplete) return
      var operation = root.pendingAudioPolicy
      var code = resultCode
      var message = resultStderr
      collecting = false
      stderrComplete = false
      exitComplete = false
      root.pendingAudioPolicy = null
      if (!operation) return

      if (code === 0) {
        root.applyAudioPolicyOverride(operation.address, operation.policy)
        audioPolicyPreferencesView.reload()
        return
      }
      if (Model.normalizedAddress(root.deviceDetailsAddress)
          === Model.normalizedAddress(operation.address))
        root.devicePropertyError = message
          || "Could not save this device's audio policy."
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        audioPolicyPreferenceProc.resultStderr = String(text || "").trim()
        audioPolicyPreferenceProc.stderrComplete = true
        audioPolicyPreferenceProc.finishCollection()
      }
    }
    onExited: function(exitCode) {
      resultCode = exitCode
      exitComplete = true
      finishCollection()
    }
  }

  FileView {
    id: audioPolicyPreferencesView
    path: root.audioPolicyPreferencesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadAudioPolicyOverrides(text())
    onLoadFailed: root.loadAudioPolicyOverrides("")
    onFileChanged: reload()
  }

  Process {
    id: audioPolicyMigrationProc
    command: [root.pluginScript("audio-preferences"), "migrate-policies"]
    onExited: function(exitCode) {
      if (exitCode === 0) audioPolicyPreferencesView.reload()
    }
  }

  FileView {
    path: root.audioControlRulesPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.audioControlAliases = Model.parseDeviceAliases(text())
      audioControlAliasSyncTimer.restart()
    }
    onLoadFailed: root.audioControlAliases = ({})
    onFileChanged: reload()
  }

  Process {
    id: deviceActionProc
    property bool collecting: false
    property bool stderrComplete: false
    property bool exitComplete: false
    property int resultCode: 0

    function prepare() {
      collecting = true
      stderrComplete = false
      exitComplete = false
      resultCode = 0
      root.deviceActionStderr = ""
    }

    function finishCollection() {
      if (!collecting || !stderrComplete || !exitComplete) return
      var operation = root.activeDeviceAction
      var code = resultCode
      collecting = false
      stderrComplete = false
      exitComplete = false
      if (!operation) return

      if (root.deviceActionCancelRequested) {
        root.setPendingAction(operation.address, "")
        root.setDeviceActionFailure(operation.address, "", "")
      } else if (code !== 0) {
        root.setPendingAction(operation.address, "")
        root.setDeviceActionFailure(
          operation.address,
          operation.action,
          root.deviceActionStderr || root.defaultDeviceActionError(operation.action))
      } else {
        root.setDeviceActionFailure(operation.address, "", "")
      }

      root.activeDeviceAction = null
      root.deviceActionCancelRequested = false
      root.syncPendingActions()
      // A long pairing helper can consume most of the timer that started with
      // the command. Give BlueZ a full confirmation window after helper success
      // on every monitor instead of timing out moments after the process exits.
      if (code === 0 && root.pendingAction(operation.address) !== "")
        root.setPendingAction(operation.address, operation.pending, operation.action)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.deviceActionStderr = String(text || "").trim()
        deviceActionProc.stderrComplete = true
        deviceActionProc.finishCollection()
      }
    }
    onExited: function(exitCode) {
      resultCode = exitCode
      exitComplete = true
      finishCollection()
    }
  }

  Process {
    id: devicePropertyProc
    property bool collecting: false
    property bool stderrComplete: false
    property bool exitComplete: false
    property int resultCode: 0

    function prepare() {
      collecting = true
      stderrComplete = false
      exitComplete = false
      resultCode = 0
      root.devicePropertyStderr = ""
    }

    function finishCollection() {
      if (!collecting || !stderrComplete || !exitComplete) return
      var operation = root.pendingDeviceProperty
      var code = resultCode
      collecting = false
      stderrComplete = false
      exitComplete = false
      if (!operation) return

      var liveDevice = root.deviceByAddress(operation.address)
      if (liveDevice && root.liveDeviceProperty(liveDevice, operation.propertyName)
          === operation.expected) {
        // A timed-out D-Bus client can still have delivered the write. Live
        // BlueZ state is authoritative, so do not turn an applied change into
        // a sticky failure merely because the helper exited non-zero.
        root.confirmDeviceProperty()
        return
      }

      if (code !== 0) {
        root.pendingDeviceProperty = null
        if (Model.normalizedAddress(root.deviceDetailsAddress)
            === Model.normalizedAddress(operation.address)) {
          root.devicePropertyError = root.devicePropertyStderr || operation.errorMessage
          // Renames are shown optimistically while the helper runs. If BlueZ
          // rejects the write, put the field back in sync with the live object
          // instead of leaving an unapplied alias on screen beside the error.
          if (operation.propertyName === "name" && root.deviceDetailsRow)
            deviceDetailsView.updateNameIfIdle(String(
              root.deviceDisplayName(root.deviceDetailsRow)
                || root.deviceDetailsRow.deviceName || ""))
        }
      } else {
        devicePropertyConfirmTimer.restart()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.devicePropertyStderr = String(text || "").trim()
        devicePropertyProc.stderrComplete = true
        devicePropertyProc.finishCollection()
      }
    }
    onExited: function(exitCode) {
      resultCode = exitCode
      exitComplete = true
      finishCollection()
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

  Timer {
    id: audioControlAliasSyncTimer
    interval: 150
    repeat: false
    onTriggered: root.reconcileAudioControlAliases()
  }

  Process {
    id: audioProfilesProc
    command: [root.pluginScript("bluetooth-audio-profiles")]
    property bool collecting: false
    property bool outputComplete: false
    property bool exitComplete: false
    property int resultCode: 0
    property string resultOutput: ""

    function prepare() {
      collecting = true
      outputComplete = false
      exitComplete = false
      resultCode = 0
      resultOutput = ""
    }

    function finishCollection() {
      if (!collecting || !outputComplete || !exitComplete) return
      var code = resultCode
      var output = resultOutput
      collecting = false
      outputComplete = false
      exitComplete = false
      if (code === 0)
        root.updateAudioProfiles(output)
      else if (root.opened && root.connectedDevices.length > 0)
        root.audioProfileReadError = "Could not read Bluetooth audio modes"
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        audioProfilesProc.resultOutput = String(text || "")
        audioProfilesProc.outputComplete = true
        audioProfilesProc.finishCollection()
      }
    }
    onExited: function(exitCode) {
      resultCode = exitCode
      exitComplete = true
      finishCollection()
    }
  }

  Process {
    id: audioProfileSetProc
    property bool collecting: false
    property bool stderrComplete: false
    property bool exitComplete: false
    property int resultCode: 0

    function prepare() {
      collecting = true
      stderrComplete = false
      exitComplete = false
      resultCode = 0
      root.audioProfileSetStderr = ""
    }

    function finishCollection() {
      if (!collecting || !stderrComplete || !exitComplete) return
      var operation = root.activeAudioProfileOperation
      var code = resultCode
      collecting = false
      stderrComplete = false
      exitComplete = false
      root.activeAudioProfileOperation = null
      // The target can disappear while the helper is running, or a live card
      // refresh can be superseded by a disconnect. Such a result is stale; an
      // early profile confirmation alone does not clear process ownership,
      // because exit 2 can still report a failed preference write.
      if (!operation) {
        audioProfilePendingTimeout.stop()
        audioProfileSettleTimer.restart()
        return
      }
      if (code !== 0 && code !== 2) {
        root.audioProfileSetError = root.audioProfileSetStderr
          || "Could not change the Bluetooth audio mode"
        root.pendingAudioProfile = null
        root.unconfirmedAudioProfile = null
        audioProfilePendingTimeout.stop()
      } else {
        root.audioProfileSetError = ""
        if (code === 2 && root.audioPreferencesError === "")
          root.audioPreferenceWriteError = "Audio mode is active, but its preference could not be saved"
        if (root.pendingAudioProfile || root.unconfirmedAudioProfile)
          audioProfilePendingTimeout.restart()
        else
          audioProfilePendingTimeout.stop()
      }
      audioProfileSettleTimer.restart()
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.audioProfileSetStderr = String(text || "").trim()
        audioProfileSetProc.stderrComplete = true
        audioProfileSetProc.finishCollection()
      }
    }
    onExited: function(exitCode) {
      resultCode = exitCode
      exitComplete = true
      finishCollection()
    }
  }

  BluetoothAudioPolicyEngine {
    id: policyEngine
    controller: root
    preferencesReady: root.audioPreferencesReady
    onRefreshRequested: audioProfileRefreshTimer.restart()
    onApplicationsPublished: function(applications) {
      root.publishAudioPolicyApplications(applications)
    }
    onProfileSwitchRequested: function(key, address, profile) {
      policyProfileSwitchProc.key = key
      policyProfileSwitchProc.command = [
        root.pluginScript("bluetooth-audio-profile-set"),
        address,
        profile
      ]
      policyProfileSwitchProc.running = true
    }
  }

  Process {
    id: policyProfileSwitchProc
    property string key: ""
    onExited: function(exitCode) {
      if (exitCode === 2 && root.audioPreferencesError === "")
        root.audioPreferenceWriteError = "Audio mode is active, but its preference could not be saved"
      policyEngine.finishProfileSwitch(key, exitCode)
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
    running: root.audioProfilesNeeded && !root.audioProfileMenuOpen
      && !root.audioProfileCommandBusy
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

  Timer {
    id: pendingTimeout
    interval: 500
    running: Object.keys(root.pendingActions).length > 0
    repeat: true
    onTriggered: root.expirePendingActions()
  }

  // The helper reports the D-Bus result directly. After it succeeds, give
  // Quickshell time to receive BlueZ's PropertiesChanged signal and verify
  // that the projected value settled as requested.
  Timer {
    id: devicePropertyConfirmTimer
    // A synchronous D-Bus reply can still precede Quickshell's projected
    // PropertiesChanged update. Live changes short-circuit this wait through
    // onDeviceDetailsRowChanged; four seconds is only the failure deadline.
    interval: 4000
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
    if (!adapter || deviceActionBusy || devicePropertyBusy || hasPendingDeviceActions
        || audioProfileChangeBusy) return
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
      ? deviceDetailsView.implicitHeight : column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.audioProfileMenuOpen || deviceDetailsView.editingName
      onMoveRequested: function(dx, dy) {
        if (root.forgetConfirmationOpen) {
          deviceDetailsView.toggleConfirmationSelection()
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
          if (!deviceDetailsView.confirmSelected) root.cancelForgetConfirmation()
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
          deviceDetailsView.toggleConfirmationSelection()
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
              enabled: !root.deviceActionBusy && !root.devicePropertyBusy
                && !root.hasPendingDeviceActions
                && !root.audioProfileChangeBusy
              opacity: enabled ? 1 : 0.55
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
            BluetoothDeviceRow {
              required property var modelData
              required property int index
              width: connectedList.width
              controller: root
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

              BluetoothDeviceRow {
                width: parent.width
                controller: root
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

      BluetoothDeviceDetails {
        id: deviceDetailsView
        anchors.fill: parent
        visible: root.deviceDetailsOpen
        controller: root
      }
    }
  }

}
