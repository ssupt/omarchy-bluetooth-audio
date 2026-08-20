function deviceLabel(device) {
  if (!device) return ""
  return String(device.deviceName || device.name || "").trim()
}

function toArray(values) {
  if (!values) return []
  if (Array.isArray(values)) return values.slice()

  var length = Number(values.length || 0)
  if (!isFinite(length) || length <= 0) return []

  var list = []
  for (var i = 0; i < length; i++) list.push(values[i])
  return list
}

function isUuidLike(value) {
  var text = String(value || "").trim()
  if (text === "") return false
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text)
    || /^[0-9a-f]{32}$/i.test(text)
    || /^0x[0-9a-f]{4,32}$/i.test(text)
    || /^0000[0-9a-f]{4}-0000-1000-8000-00805f9b34fb$/i.test(text)
}

function isAddressLike(value) {
  var text = String(value || "").trim()
  return /^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(text)
}

function normalizedAddress(value) {
  return String(value || "").trim().toLowerCase().replace(/[^0-9a-f]/g, "")
}

function parseAudioPreferences(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || "{}"))
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}

  var defaults = parsed.defaults
  if (!defaults || typeof defaults !== "object" || Array.isArray(defaults)) defaults = {}
  var rawProfiles = parsed.bluetoothProfiles
  if (!rawProfiles || typeof rawProfiles !== "object" || Array.isArray(rawProfiles)) rawProfiles = {}

  var profiles = {}
  for (var address in rawProfiles) {
    var key = normalizedAddress(address)
    var profile = rawProfiles[address]
    if (key !== "" && typeof profile === "string" && profile !== "") profiles[key] = profile
  }

  return {
    version: 1,
    defaults: {
      output: typeof defaults.output === "string" ? defaults.output : "",
      input: typeof defaults.input === "string" ? defaults.input : ""
    },
    bluetoothProfiles: profiles
  }
}

function preferredAudioProfile(preferences, address, options, activeProfile) {
  var profiles = preferences && preferences.bluetoothProfiles
  var saved = profiles ? String(profiles[normalizedAddress(address)] || "") : ""
  var values = options && typeof options.length === "number" ? options : []
  for (var i = 0; i < values.length; i++) {
    var value = values[i] && typeof values[i] === "object" ? values[i].value : values[i]
    if (String(value || "") === saved) return saved
  }
  return String(activeProfile || "")
}

// Pending and live PipeWire state are authoritative. A saved preference is a
// fallback for the short interval before card state becomes available, not a
// replacement for an active profile reported by PipeWire.
function currentAudioProfile(preferences, address, options, activeProfile, pendingProfile) {
  var pending = String(pendingProfile || "")
  if (pending !== "") return pending

  var active = String(activeProfile || "")
  if (active !== "") return active
  return preferredAudioProfile(preferences, address, options, "")
}

function preferredAudioNodeName(preferences, direction, liveNode, nodes) {
  var defaults = preferences && preferences.defaults
  var saved = defaults && (direction === "output" || direction === "input")
    ? String(defaults[direction] || "") : ""
  var values = nodes && typeof nodes.length === "number" ? nodes : []
  if (saved !== "") {
    for (var i = 0; i < values.length; i++)
      if (values[i] && String(values[i].name || "") === saved) return saved
  }
  return liveNode ? String(liveNode.name || "") : ""
}

function currentAudioNodeName(preferences, direction, liveNode, nodes) {
  var liveName = liveNode ? String(liveNode.name || "") : ""
  return liveName !== "" ? liveName
    : preferredAudioNodeName(preferences, direction, null, nodes)
}

function hasHumanName(device) {
  var label = deviceLabel(device)
  return label !== "" && !isUuidLike(label) && !isAddressLike(label)
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function nodeText(node) {
  var props = nodeProps(node)
  return [
    node ? node.name : "",
    node ? node.description : "",
    node ? node.nickname : "",
    node ? node.nick : "",
    props["node.name"],
    props["node.description"],
    props["node.nick"],
    props["device.name"],
    props["device.description"],
    props["device.product.name"],
    props["device.alias"],
    props["device.string"],
    props["api.bluez5.address"],
    props["bluez5.address"],
    props["media.name"]
  ].join(" ").toLowerCase()
}

function isAudioSource(node) {
  if (!node || node.isSink || node.isStream || !node.audio) return false
  var name = String(node.name || "")
  if (/\.monitor$/i.test(name)) return false

  var props = nodeProps(node)
  return String(props["media.class"] || "") !== "Audio/Sink"
}

function bluetoothNodeMatchesDevice(node, device, direction) {
  if (!node || node.isStream || !device) return false
  if (direction === "sink" && !node.isSink) return false
  if (direction === "source" && !isAudioSource(node)) return false

  var address = normalizedAddress(device.address)
  var text = nodeText(node)
  if (address !== "" && normalizedAddress(text).indexOf(address) !== -1) return true

  var label = deviceLabel(device).toLowerCase()
  return label !== "" && text.indexOf(label) !== -1
}

function bluetoothSinkMatchesDevice(node, device) {
  return bluetoothNodeMatchesDevice(node, device, "sink")
}

function bluetoothSourceMatchesDevice(node, device) {
  return bluetoothNodeMatchesDevice(node, device, "source")
}

function sameAudioNode(left, right) {
  if (!left || !right) return false
  if (left === right) return true

  if (left.id !== undefined && left.id !== null
      && right.id !== undefined && right.id !== null
      && String(left.id) === String(right.id)) return true

  var leftProps = nodeProps(left)
  var rightProps = nodeProps(right)
  var leftName = String(left.name || leftProps["node.name"] || "")
  var rightName = String(right.name || rightProps["node.name"] || "")
  return leftName !== "" && leftName === rightName
}

function audioProfileState(states, address) {
  var key = normalizedAddress(address)
  if (key === "" || !states || typeof states !== "object") return null
  var state = states[key]
  return state && typeof state === "object" ? state : null
}

function audioProfileOptions(state) {
  if (!state || !Array.isArray(state.profiles)) return []
  var options = []
  for (var i = 0; i < state.profiles.length; i++) {
    var profile = state.profiles[i]
    var value = profile ? String(profile.value || profile.name || "") : ""
    if (value === "") continue
    options.push({
      value: value,
      label: String(profile.label || profile.description || value)
    })
  }
  return options
}

function audioProfileCodec(state, profileName) {
  if (!state) return ""
  var name = String(profileName || state.activeProfile || "")
  var profiles = Array.isArray(state.profiles) ? state.profiles : []
  for (var i = 0; i < profiles.length; i++) {
    if (profiles[i] && String(profiles[i].value || profiles[i].name || "") === name)
      return String(profiles[i].codec || "")
  }
  return name === String(state.activeProfile || "") ? String(state.activeCodec || "") : ""
}

function audioProfileHasInput(state, profileName) {
  if (!state) return false
  var name = String(profileName || state.activeProfile || "")
  var profiles = Array.isArray(state.profiles) ? state.profiles : []
  for (var i = 0; i < profiles.length; i++) {
    var profile = profiles[i]
    if (!profile || String(profile.value || profile.name || "") !== name) continue
    return profile.hasInput === true || Number(profile.sources || 0) > 0
  }
  return false
}

function sortedByLabel(devices) {
  var list = toArray(devices)
  list.sort(function(a, b) { return deviceLabel(a).localeCompare(deviceLabel(b)) })
  return list
}

// Primitives-only projection of a BlueZ device for list-model rows. Holding
// the Device QObject in model data puts a live wrapper into every delegate's
// var property, and BlueZ churn (discovery timeouts, unpair) can destroy the
// object while a delegate is still incubating, which segfaults quickshell.
// Actions resolve the backend object via Panel.deviceFor().
function deviceRow(d) {
  if (!d) return null
  return {
    address: d.address || "",
    name: d.name || "",
    deviceName: d.deviceName || "",
    connected: !!d.connected,
    state: d.state !== undefined ? d.state : -1,
    batteryAvailable: !!d.batteryAvailable,
    battery: d.battery !== undefined ? d.battery : 0,
    pairing: !!d.pairing
  }
}

function deviceLists(devices) {
  var values = toArray(devices)
  var connected = []
  var known = []
  var discovered = []

  for (var i = 0; i < values.length; i++) {
    var d = values[i]
    if (!d || !hasHumanName(d)) continue
    if (d.connected) connected.push(d)
    else if (d.paired || d.bonded || d.trusted) known.push(d)
    else discovered.push(d)
  }

  return {
    connected: sortedByLabel(connected),
    known: sortedByLabel(known),
    discovered: sortedByLabel(discovered)
  }
}

function cloneMap(map) {
  var next = ({})
  for (var key in map || {}) next[key] = map[key]
  return next
}

function pendingAction(actions, address) {
  return address && actions && actions[address] ? actions[address] : ""
}

function withPendingAction(actions, address, action) {
  var next = cloneMap(actions)
  if (!address) return next
  if (action) next[address] = action
  else delete next[address]
  return next
}

function deviceActionFailure(failures, address) {
  var key = normalizedAddress(address)
  if (key === "" || !failures || typeof failures !== "object") return null
  var failure = failures[key]
  return failure && typeof failure === "object" ? failure : null
}

function withDeviceActionFailure(failures, address, action, message) {
  var next = cloneMap(failures)
  var key = normalizedAddress(address)
  if (key === "") return next
  if (action && message) next[key] = { action: String(action), message: String(message) }
  else delete next[key]
  return next
}

function deviceActionReachedState(action, device) {
  if (action === "pair" || action === "connect") return !!device && !!device.connected
  if (action === "disconnect") return !!device && !device.connected
  if (action === "forget")
    return !device || (!device.paired && !device.bonded && !device.trusted)
  return false
}

function visibleSections(lists, discovering) {
  var sections = []
  if (lists && lists.connected && lists.connected.length > 0) sections.push("connected")
  if (lists && lists.known && lists.known.length > 0) sections.push("known")
  if (discovering && lists && lists.discovered && lists.discovered.length > 0) sections.push("discovered")
  return sections
}

function sectionDevices(lists, section) {
  if (!lists) return []
  if (section === "connected") return lists.connected || []
  if (section === "known") return lists.known || []
  if (section === "discovered") return lists.discovered || []
  return []
}

if (typeof module !== "undefined") {
  module.exports = {
    deviceLabel: deviceLabel,
    toArray: toArray,
    isUuidLike: isUuidLike,
    isAddressLike: isAddressLike,
    normalizedAddress: normalizedAddress,
    parseAudioPreferences: parseAudioPreferences,
    preferredAudioProfile: preferredAudioProfile,
    currentAudioProfile: currentAudioProfile,
    preferredAudioNodeName: preferredAudioNodeName,
    currentAudioNodeName: currentAudioNodeName,
    hasHumanName: hasHumanName,
    nodeProps: nodeProps,
    nodeText: nodeText,
    isAudioSource: isAudioSource,
    bluetoothSinkMatchesDevice: bluetoothSinkMatchesDevice,
    bluetoothSourceMatchesDevice: bluetoothSourceMatchesDevice,
    sameAudioNode: sameAudioNode,
    audioProfileState: audioProfileState,
    audioProfileOptions: audioProfileOptions,
    audioProfileCodec: audioProfileCodec,
    audioProfileHasInput: audioProfileHasInput,
    sortedByLabel: sortedByLabel,
    deviceRow: deviceRow,
    deviceLists: deviceLists,
    cloneMap: cloneMap,
    pendingAction: pendingAction,
    withPendingAction: withPendingAction,
    deviceActionFailure: deviceActionFailure,
    withDeviceActionFailure: withDeviceActionFailure,
    deviceActionReachedState: deviceActionReachedState,
    visibleSections: visibleSections,
    sectionDevices: sectionDevices
  }
}
