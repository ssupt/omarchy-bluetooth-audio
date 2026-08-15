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

  // Address -> "connecting" | "disconnecting" | "forgetting".
  // The actual Bluetooth sequencing lives in bin/omarchy-bluetooth-device;
  // this map only keeps the panel responsive while BlueZ catches up.
  property var pendingActions: ({})

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

  // BlueZ owns pairing and connection state; PipeWire owns the audio card's
  // active profile and therefore the codec/microphone mode offered here.
  property var audioProfiles: ({})
  property string audioProfileReadError: ""
  property string audioProfileSetError: ""
  readonly property string audioProfileError: audioProfileSetError !== ""
    ? audioProfileSetError : audioProfileReadError
  property var pendingAudioProfile: null
  property bool audioProfileMenuOpen: false

  function pluginScript(name) {
    var url = String(Qt.resolvedUrl("scripts/" + name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function deviceLabel(device) {
    return Model.deviceLabel(device)
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
  // Empty selects the device row. Connected audio rows add explicit default-
  // audio and preferred-mode actions alongside the existing forget action.
  property string focusedAction: ""  // "" | "audio" | "forget" | "profile"
  property bool cursorActive: false

  // Stable identity for the focused device. Devices move between sections as
  // they connect, disconnect, pair, or get forgotten, so follow the BlueZ
  // address across section changes instead of preserving a stale row index.
  property string focusedDeviceAddress: ""

  // "header" is a virtual section for the hero Bluetooth on/off toggle; it
  // sits above the device sections so the adapter can be toggled by keyboard
  // even when it is off and no device rows exist.
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
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

  // Live BlueZ device behind a row. Rows carry primitives only, so actions
  // resolve the backend object here rather than holding a wrapper that can
  // dangle mid-incubation. `devices` is already the raw device array (see the
  // property declaration), so it is iterated directly.
  function deviceFor(row) {
    if (!row || !row.dev) return null
    var addr = row.dev.address || ""
    var devs = devices || []
    for (var i = 0; i < devs.length; i++) {
      if ((devs[i].address || "") === addr) return devs[i]
    }
    return null
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
      if (node && node.isSource && !node.isStream) sources.push(node)
    }
    return sources
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
    return !!device && device.connected && audioProfileOptions(device.address).length > 1
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

      if (pendingAudioProfile) {
        var state = Model.audioProfileState(parsed, pendingAudioProfile.address)
        if (state && String(state.activeProfile || "") === pendingAudioProfile.profile) {
          pendingAudioProfile = null
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
    Pipewire.preferredDefaultAudioSink = sink
    if (sink.id !== undefined && sink.name) {
      Quickshell.execDetached([
        "omarchy-audio-output-set-default",
        String(sink.id),
        String(sink.name)
      ])
    }
  }

  function setDefaultAudioSource(source) {
    if (!source) return
    Pipewire.preferredDefaultAudioSource = source
    if (source.id !== undefined && source.name) {
      Quickshell.execDetached([
        "omarchy-audio-input-set-default",
        String(source.id),
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
    return Model.pendingAction(pendingActions, address)
  }

  function setPendingAction(address, action) {
    if (!address) return
    pendingActions = Model.withPendingAction(pendingActions, address, action)
    if (action) pendingTimeout.restart()
  }

  function deviceCommand(action, address) {
    return ["omarchy-bluetooth-device", action, address]
  }

  function runDeviceAction(device, action, pending) {
    if (!device || !device.address) return
    setPendingAction(device.address, pending)
    Quickshell.execDetached(deviceCommand(action, device.address))
  }

  function connectDevice(device) {
    if (!device || device.connected) return
    if (device.paired || device.bonded || device.trusted) runDeviceAction(device, "connect", "connecting")
    else runDeviceAction(device, "pair", "connecting")
  }

  function disconnectDevice(device) {
    if (!device || !device.address) return
    if (!device.connected) return
    setPendingAction(device.address, "disconnecting")
    if (device.disconnect) device.disconnect()
    Quickshell.execDetached(deviceCommand("disconnect", device.address))
  }

  function forgetDevice(device) {
    if (!device || !device.address) return
    runDeviceAction(device, "forget", "forgetting")
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
          || (action === "forgetting" && (!found || (!found.paired && !found.bonded && !found.trusted)))) {
        delete next[address]
        changed = true
      }
    }

    if (changed) pendingActions = next
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

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    focusedAction = ""
  }

  function focusedRowActions() {
    var actions = []
    if (focusSection !== "known" && focusSection !== "connected") return actions
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev || !dev.address) return actions
    if (focusSection === "connected" && audioUseActionAvailable(dev)) actions.push("audio")
    actions.push("forget")
    if (focusSection === "connected" && audioProfileActionAvailable(dev)) actions.push("profile")
    return actions
  }

  function moveCursorH(delta) {
    if (!cursorActive) { cursorActive = true; return }
    var actions = focusedRowActions()
    if (actions.length === 0) return
    var index = focusedAction === "" ? -1 : actions.indexOf(focusedAction)
    if (delta > 0 && index < actions.length - 1) focusedAction = actions[index + 1]
    else if (delta < 0) focusedAction = index > 0 ? actions[index - 1] : ""
  }

  function activateCursor() {
    if (focusSection === "header") {
      toggleBluetooth()
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
    if (focusedAction === "forget") {
      deleteSelected()
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

  // 'x' forgets remembered devices. For connected devices this first
  // disconnects, then removes the BlueZ pairing record via omarchy-bluetooth-device.
  function deleteSelected() {
    if (focusSection !== "known" && focusSection !== "connected") return
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev) return
    forgetDevice(dev)
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
      cursorActive = false
      audioProfileRefreshTimer.restart()
    } else {
      closeAudioProfileMenus(-1)
      audioProfileMenuOpen = false
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
    if (connectedDevices.length === 0) audioProfiles = ({})
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
        audioProfilePendingTimeout.stop()
      } else {
        root.audioProfileSetError = ""
        audioProfilePendingTimeout.restart()
      }
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

  Timer {
    id: pendingTimeout
    interval: 20000
    repeat: false
    onTriggered: root.pendingActions = ({})
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.audioProfileMenuOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.cursorActive) root.deleteSelected()
      onTextKey: function(t) {
        if (t === "b" || t === "B") root.toggleBluetooth()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: Bluetooth icon · status ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

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

          // Compact on/off switch on the trailing edge of the hero, and the
          // header's only cursor target.
          ToggleSwitch {
            id: powerSwitch
            visible: !!root.adapter
            checked: !!root.adapter && root.adapter.enabled
            hasCursor: root.headerHasCursor
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onHovered: function(on) { if (on) root.setHeaderCursor() }
            onToggled: root.toggleBluetooth()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.toggleHint
              fontFamily: root.bar.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: powerSwitch.visible ? powerSwitch.width + Style.space(12) : 0
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
    readonly property string actionTooltip: {
      if (!dev) return ""
      if (isConnected) return "Disconnect"
      if (isDiscovered) return "Pair"
      return "Connect"
    }

    readonly property var profileState: root.audioProfileState(dev ? dev.address : "")
    readonly property var profileOptions: Model.audioProfileOptions(profileState)
    readonly property bool profileMenuAvailable: isConnected && profileOptions.length > 1
    readonly property string pendingProfileName: {
      if (!root.pendingAudioProfile || !dev) return ""
      return root.pendingAudioProfile.address === Model.normalizedAddress(dev.address)
        ? String(root.pendingAudioProfile.profile || "") : ""
    }
    readonly property string currentProfileName: pendingProfileName !== ""
      ? pendingProfileName : String(profileState ? profileState.activeProfile || "" : "")
    readonly property string activeCodec: Model.audioProfileCodec(profileState, currentProfileName)
    readonly property var deviceAudioSink: root.bluetoothAudioSink(dev)
    readonly property var deviceAudioSource: root.bluetoothAudioSource(dev)
    readonly property bool useAudioAvailable: isConnected && !!deviceAudioSink
    readonly property bool usingForAudio: useAudioAvailable
      && Model.sameAudioNode(deviceAudioSink, root.defaultAudioSink)

    readonly property bool rowSelected: root.cursorActive && root.focusSection === sectionName && root.selectedIndex === rowIndex
    readonly property bool forgetAvailable: (sectionName === "known" || sectionName === "connected") && !isDiscovered
    readonly property bool showForgetButton: forgetAvailable && (rowMouse.containsMouse || rowSelected)
    readonly property bool showUseAudioButton: useAudioAvailable && (rowMouse.containsMouse || rowSelected)

    hasCursor: rowSelected && root.focusedAction === ""
    current: isConnected
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    readonly property string statusText: {
      if (!dev) return ""
      if (action === "forgetting") return "Forgetting…"
      if (action === "disconnecting" || devState === 2) return "Disconnecting…"
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
          if (row.isConnected) root.disconnectDevice(dev)
          else if (!row.isDiscovered) root.forgetDevice(dev)
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
        profileDropdown.implicitHeight, forgetBtn.implicitHeight, useAudioBtn.implicitHeight)

      Text {
        id: deviceIcon
        text: row.isConnected ? "󰂱" : "󰂯"
        color: row.statusColor
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: deviceIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: useAudioBtn.visible ? useAudioBtn.left
          : (forgetBtn.visible ? forgetBtn.left
          : (profileDropdown.visible ? profileDropdown.left : parent.right))
        anchors.rightMargin: profileDropdown.visible || forgetBtn.visible || useAudioBtn.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: root.deviceLabel(row.dev) || "Device"
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
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: row.profileMenuAvailable
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
        id: forgetBtn
        anchors.right: profileDropdown.visible ? profileDropdown.left : parent.right
        anchors.rightMargin: profileDropdown.visible ? Style.space(6) : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showForgetButton
        iconText: "󰅙"
        tooltipText: "Forget"
        foreground: root.bar.foreground
        hoverColor: root.bar.foreground
        fontFamily: root.bar.fontFamily
        hasCursor: row.rowSelected && root.focusedAction === "forget"
        onHovered: function(isHovered) {
          if (!isHovered) {
            if (rowMouse.containsMouse && root.focusedAction === "forget") root.focusedAction = ""
            return
          }
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.focusedAction = "forget"
        }
        onClicked: {
          var dev = root.deviceFor(row)
          if (!dev) return
          root.forgetDevice(dev)
        }
      }

      PanelActionButton {
        id: useAudioBtn
        anchors.right: forgetBtn.visible ? forgetBtn.left
          : (profileDropdown.visible ? profileDropdown.left : parent.right)
        anchors.rightMargin: forgetBtn.visible || profileDropdown.visible ? Style.space(6) : 0
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
    }

    function toggleProfileMenu() { profileDropdown.toggle() }
    function closeProfileMenu() { profileDropdown.close() }

    onProfileMenuAvailableChanged: if (!profileMenuAvailable) closeProfileMenu()
    Component.onDestruction: if (profileDropdown.popupOpen) root.audioProfileMenuOpen = false
  }
}
