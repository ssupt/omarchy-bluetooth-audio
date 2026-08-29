function deviceLabel(device) {
  if (!device) return ""
  // BlueZ exposes the user-editable Alias through Quickshell's `name` and
  // the hardware-reported name through `deviceName`. Prefer the alias so a
  // rename is reflected consistently in labels, sorting, and audio matching.
  return String(device.name || device.deviceName || "").trim()
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
  return normalizedAddress(value) !== ""
}

function normalizedAddress(value) {
  var text = String(value || "").trim().toLowerCase()
  if (/^[0-9a-f]{12}$/.test(text)) return text
  if (/^[0-9a-f]{2}(?:[:_-][0-9a-f]{2}){5}$/.test(text))
    return text.replace(/[:_-]/g, "")
  return ""
}

function textContainsAddress(value, address) {
  var expected = normalizedAddress(address)
  if (expected === "") return false

  // The final group of a Bluetooth service UUID is twelve hex digits and can
  // otherwise masquerade as a raw MAC (for example 00805f9b34fb). Remove full
  // UUID tokens before scanning node metadata for device identities.
  var text = String(value || "").replace(
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ig, " ")
  var matcher = /(^|[^0-9a-f])([0-9a-f]{12}|[0-9a-f]{2}(?:[:_-][0-9a-f]{2}){5})(?=$|[^0-9a-f])/ig
  var match
  while ((match = matcher.exec(text)) !== null) {
    if (normalizedAddress(match[2]) === expected) return true
  }
  return false
}

function textContainsAnyAddress(value) {
  var text = String(value || "").replace(
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ig, " ")
  return /(^|[^0-9a-f])([0-9a-f]{12}|[0-9a-f]{2}(?:[:_-][0-9a-f]{2}){5})(?=$|[^0-9a-f])/i.test(text)
}

function normalizedIdentity(value) {
  // Treat ASCII punctuation the way PipeWire does when it turns labels into
  // node metadata, but retain non-ASCII letters instead of making names such
  // as “Écouteurs” or “耳机” impossible to match on legacy nodes without an
  // explicit Bluetooth address.
  return String(value || "").trim().toLowerCase()
    .replace(/[\x00-\x2f\x3a-\x40\x5b-\x60\x7b-\x7f]+/g, " ").trim()
}

function safeStoredIdentifier(value, maximum) {
  return typeof value === "string" && value.length > 0 && value.length <= maximum
    && !/[\x00-\x1f\x7f-\x9f\u200e\u200f\u2028-\u202e\u2066-\u2069]/.test(value)
}

function parseAudioPreferences(raw) {
  var parsed
  var text = String(raw || "{}")
  if (text.length > 1048576) text = "{}"
  try {
    parsed = JSON.parse(text)
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
    if (key !== "" && safeStoredIdentifier(profile, 160)) profiles[key] = profile
  }

  var rawPolicies = parsed.bluetoothAudioPolicies
  if (!rawPolicies || typeof rawPolicies !== "object" || Array.isArray(rawPolicies)) rawPolicies = {}
  var policies = {}
  for (var policyAddress in rawPolicies) {
    var policyKey = normalizedAddress(policyAddress)
    var policy = rawPolicies[policyAddress]
    if (policyKey !== "" && isValidAudioPolicy(policy)) policies[policyKey] = policy
  }

  return {
    version: 1,
    defaults: {
      output: safeStoredIdentifier(defaults.output, 160) ? defaults.output : "",
      input: safeStoredIdentifier(defaults.input, 160) ? defaults.input : ""
    },
    bluetoothProfiles: profiles,
    bluetoothAudioPolicies: policies
  }
}

// Connect-policy overrides live in a plugin-owned sidecar because compatible
// audio-preference writers are allowed to normalize the shared schema and may
// discard fields they do not understand. "manual" is retained here as an
// explicit tombstone so it can override a legacy automatic policy still found
// in the shared file.
function parseAudioPolicyOverrides(raw) {
  var parsed
  var text = String(raw || "{}")
  if (text.length > 1048576) text = "{}"
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}
  var rawPolicies = parsed.bluetoothAudioPolicies
  if (!rawPolicies || typeof rawPolicies !== "object" || Array.isArray(rawPolicies)) rawPolicies = {}

  var policies = {}
  for (var address in rawPolicies) {
    var key = normalizedAddress(address)
    var policy = rawPolicies[address]
    if (key !== "" && (policy === "manual" || isValidAudioPolicy(policy)))
      policies[key] = policy
  }
  return policies
}

function mergeAudioPreferences(shared, policyOverrides) {
  var source = shared && typeof shared === "object"
    ? shared : parseAudioPreferences("")
  var profiles = cloneMap(source.bluetoothProfiles || {})
  var policies = cloneMap(source.bluetoothAudioPolicies || {})
  var overrides = policyOverrides && typeof policyOverrides === "object"
    ? policyOverrides : {}

  for (var address in overrides) {
    if (overrides[address] === "manual") delete policies[address]
    else if (isValidAudioPolicy(overrides[address])) policies[address] = overrides[address]
  }
  return {
    version: 1,
    defaults: {
      output: String(source.defaults && source.defaults.output || ""),
      input: String(source.defaults && source.defaults.input || "")
    },
    bluetoothProfiles: profiles,
    bluetoothAudioPolicies: policies
  }
}

function isAudioPreferencesDocument(raw) {
  var text = String(raw || "").trim()
  if (text === "") return true
  if (text.length > 1048576) return false
  try {
    var parsed = JSON.parse(text)
    return !!parsed && typeof parsed === "object" && !Array.isArray(parsed)
  } catch (e) {
    return false
  }
}

// "manual" is the absence of a policy and is deliberately not stored: an
// absent entry and an explicit manual choice must behave identically.
function isValidAudioPolicy(policy) {
  return policy === "output" || policy === "output-mic"
}

function audioPolicyOrder() {
  return ["manual", "output", "output-mic"]
}

function deviceAudioPolicy(preferences, address) {
  var policies = preferences && preferences.bluetoothAudioPolicies
  var policy = policies ? policies[normalizedAddress(address)] : ""
  return isValidAudioPolicy(policy) ? policy : "manual"
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
  if (!device) return false
  var candidates = [device.name, device.deviceName]
  for (var i = 0; i < candidates.length; i++) {
    var label = String(candidates[i] || "").trim()
    if (label !== "" && !isUuidLike(label) && !isAddressLike(label)) return true
  }
  return false
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function isAudioSource(node) {
  if (!node || node.isSink || node.isStream || !node.audio) return false
  var name = String(node.name || "")
  if (/\.monitor$/i.test(name)) return false

  var props = nodeProps(node)
  return String(props["media.class"] || "") !== "Audio/Sink"
}

function identityLabelIsAmbiguous(label, device, peers) {
  var values = toArray(peers)
  if (values.length < 2) return false
  var address = normalizedAddress(device ? device.address : "")

  for (var i = 0; i < values.length; i++) {
    var peer = values[i]
    if (!peer || peer === device) continue
    var peerAddress = normalizedAddress(peer.address)
    if (address !== "" && peerAddress === address) continue
    if (normalizedIdentity(peer.name) === label
        || normalizedIdentity(peer.deviceName) === label) return true
  }
  return false
}

function bluetoothNodeMatchesDevice(node, device, direction, peers) {
  if (!node || node.isStream || !device) return false
  if (direction === "sink" && !node.isSink) return false
  if (direction === "source" && !isAudioSource(node)) return false

  var address = normalizedAddress(device.address)
  var props = nodeProps(node)
  var fields = [
    node.name,
    node.description,
    node.nickname,
    node.nick,
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
  ]
  var carriesAddress = false
  for (var field = 0; field < fields.length; field++) {
    if (isUuidLike(fields[field])) continue
    if (textContainsAddress(fields[field], address)) return true
    if (textContainsAnyAddress(fields[field])) carriesAddress = true
  }

  // An explicit address belongs to exactly one device. Never let a generic
  // model name (for example two identical headsets) override a mismatching
  // address and route audio to whichever node happens to be listed first.
  if (carriesAddress) return false

  // PipeWire may retain the hardware name after the user assigns a BlueZ
  // alias, so match either label when node metadata genuinely lacks an
  // address. Compare complete normalized fields rather than substrings: a
  // device called "Buds" must not claim a node called "Buds Pro". If two live
  // devices share the same label, fail closed because name-only metadata
  // cannot identify which one owns the endpoint.
  var labels = [normalizedIdentity(device.name), normalizedIdentity(device.deviceName)]
  for (var i = 0; i < labels.length; i++) {
    var label = labels[i]
    if (label === "") continue
    for (var candidate = 0; candidate < fields.length; candidate++)
      if (normalizedIdentity(fields[candidate]) === label
          && !identityLabelIsAmbiguous(label, device, peers)) return true
  }
  return false
}

function bluetoothSinkMatchesDevice(node, device, peers) {
  return bluetoothNodeMatchesDevice(node, device, "sink", peers)
}

function bluetoothSourceMatchesDevice(node, device, peers) {
  return bluetoothNodeMatchesDevice(node, device, "source", peers)
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

// Best microphone-capable mode, in the priority order pactl reported. An
// output-mic connect policy falls back to this when the remembered mode is
// output-only; null means the hardware offers no input at all.
function duplexProfileOption(state) {
  if (!state || !Array.isArray(state.profiles)) return null
  for (var i = 0; i < state.profiles.length; i++) {
    var profile = state.profiles[i]
    if (!profile) continue
    var value = String(profile.value || profile.name || "")
    if (value !== "" && (profile.hasInput === true || Number(profile.sources || 0) > 0))
      return { value: value, label: String(profile.label || profile.description || value) }
  }
  return null
}

function preferredDuplexProfileOption(preferences, address, state) {
  if (!state) return null
  var profiles = Array.isArray(state.profiles) ? state.profiles : []
  var saved = preferredAudioProfile(preferences, address, audioProfileOptions(state), "")
  if (saved !== "" && audioProfileHasInput(state, saved)) {
    for (var i = 0; i < profiles.length; i++) {
      var profile = profiles[i]
      if (!profile || String(profile.value || profile.name || "") !== saved) continue
      return {
        value: saved,
        label: String(profile.label || profile.description || saved)
      }
    }
  }
  return duplexProfileOption(state)
}

// Whether connect-time audio policies make sense at all. PipeWire card
// state only exists while connected, so offline decisions rely on BlueZ's
// coarse icon class first and the same label hints the glyph picker uses
// for devices that report a generic icon.
function isAudioDevice(iconName, name) {
  var icon = String(iconName || "").toLowerCase().trim()
  if (icon.indexOf("audio") !== -1) return true

  var label = String(name || "").toLowerCase().trim()
  var hints = ["headset", "headphone", "earbud", "earphone", "airpod",
    "buds", "momentum", "speaker", "soundbar"]
  for (var i = 0; i < hints.length; i++) {
    if (label.indexOf(hints[i]) !== -1) return true
  }
  return false
}

// Aliases stored by omarchy-audio-control: { devices: { aliases: { <node-name>: <label> } } }.
// Flattened defensively so a malformed companion file degrades to no aliases
// instead of breaking labels here.
function parseDeviceAliases(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || "{}"))
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}

  var devices = parsed.devices
  if (!devices || typeof devices !== "object" || Array.isArray(devices)) devices = {}
  var rawAliases = devices.aliases
  if (!rawAliases || typeof rawAliases !== "object" || Array.isArray(rawAliases)) rawAliases = {}

  var aliases = {}
  for (var node in rawAliases) {
    var label = rawAliases[node]
    var trimmed = typeof label === "string" ? label.trim() : ""
    if (safeStoredIdentifier(node, 160) && safeStoredIdentifier(trimmed, 80))
      aliases[node] = trimmed
  }
  return aliases
}

// PipeWire node names are not stable across Bluetooth profiles or versions:
// outputs and inputs may use different separators and numeric suffixes. Match
// saved companion aliases by the embedded device address instead of guessing a
// particular bluez_output/bluez_input spelling.
function deviceAliasKeysForAddress(aliases, address) {
  if (normalizedAddress(address) === "" || !aliases
      || typeof aliases !== "object" || Array.isArray(aliases)) return []

  var keys = []
  for (var node in aliases) {
    if (safeStoredIdentifier(node, 160) && textContainsAddress(node, address))
      keys.push(node)
  }
  return keys
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
    dbusPath: d.dbusPath || "",
    name: d.name || "",
    deviceName: d.deviceName || "",
    icon: d.icon || "",
    connected: !!d.connected,
    state: d.state !== undefined ? d.state : -1,
    paired: !!d.paired,
    bonded: !!d.bonded,
    trusted: !!d.trusted,
    blocked: !!d.blocked,
    wakeAllowed: !!d.wakeAllowed,
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
    if (!d) continue
    // Anonymous discovery noise is not useful, but a connected or remembered
    // device must remain reachable even when BlueZ only exposes its address.
    // Otherwise users cannot disconnect, unblock, or forget it.
    if (!hasHumanName(d) && !d.connected && !d.paired && !d.bonded
        && !d.trusted && !d.blocked) continue
    if (d.connected) connected.push(d)
    // Keep blocked devices reachable even if they are not paired or trusted;
    // otherwise the only control that can unblock them disappears as soon as
    // discovery stops.
    else if (d.paired || d.bonded || d.trusted || d.blocked) known.push(d)
    else discovered.push(d)
  }

  return {
    connected: sortedByLabel(connected),
    known: sortedByLabel(known),
    discovered: sortedByLabel(discovered)
  }
}

// Tracks actual disconnected -> connected edges without treating devices that
// are already connected when the shell starts as new connections. Missing
// devices are dropped so discovery churn cannot grow this map forever; once
// the startup baseline is ready, a connected reappearance is itself an edge.
function observeDeviceConnections(previous, devices, includeNewConnections) {
  var before = previous && typeof previous === "object" ? previous : {}
  var values = toArray(devices)
  var states = {}
  var connected = []

  for (var i = 0; i < values.length; i++) {
    var device = values[i]
    var key = normalizedAddress(device ? device.address : "")
    if (key === "") continue
    var isConnected = !!device.connected
    var wasObserved = Object.prototype.hasOwnProperty.call(before, key)
    if (isConnected && (before[key] === false || (!!includeNewConnections && !wasObserved)))
      connected.push({ key: key, address: String(device.address) })
    states[key] = isConnected
  }

  return { states: states, connected: connected }
}

// Device-detail cursor stops use stable semantic indices. Audio policy is an
// optional middle row and Forget is an optional final row, so callers must not
// treat the indices as a contiguous 0..count-1 range.
function deviceDetailsStops(isAudio, canForget) {
  var stops = [0]
  if (isAudio) stops.push(1)
  stops.push(2, 3, 4)
  if (canForget) stops.push(5)
  return stops
}

function cloneMap(map) {
  var next = ({})
  for (var key in map || {}) next[key] = map[key]
  return next
}

function pendingAction(actions, address) {
  var key = normalizedAddress(address)
  return key !== "" && actions && actions[key] ? actions[key] : ""
}

function withPendingAction(actions, address, action) {
  var next = cloneMap(actions)
  var key = normalizedAddress(address)
  if (key === "") return next
  if (action) next[key] = action
  else delete next[key]
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
  if (action === "disconnect") return !device || !device.connected
  if (action === "forget")
    return !device || (!device.paired && !device.bonded && !device.trusted && !device.blocked)
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

function deviceIconGlyph(iconName, name, isConnected) {
  var icon = String(iconName || "").toLowerCase().trim()
  var label = String(name || "").toLowerCase().trim()

  if (icon.indexOf("headset") !== -1 || icon.indexOf("headphone") !== -1
      || icon.indexOf("earbud") !== -1
      || label.indexOf("buds") !== -1 || label.indexOf("headphone") !== -1
      || label.indexOf("headset") !== -1 || label.indexOf("airpod") !== -1
      || label.indexOf("earbud") !== -1 || label.indexOf("earphone") !== -1
      || label.indexOf("momentum") !== -1) {
    return "󰋋"
  }
  if (icon.indexOf("video-display") !== -1 || icon.indexOf("tv") !== -1 || icon.indexOf("display") !== -1
      || label.indexOf("tv") !== -1 || label.indexOf("googletv") !== -1 || label.indexOf("mitv") !== -1
      || label.indexOf("monitor") !== -1 || label.indexOf("display") !== -1) {
    return "󰍹"
  }
  if (icon.indexOf("speaker") !== -1 || icon.indexOf("audio-card") !== -1
      || label.indexOf("speaker") !== -1 || label.indexOf("soundbar") !== -1
      || label.indexOf("audio") !== -1) {
    return "󰓃"
  }
  if (icon.indexOf("keyboard") !== -1 || label.indexOf("keyboard") !== -1 || label.indexOf("keychron") !== -1) {
    return "󰌌"
  }
  if (icon.indexOf("mouse") !== -1 || label.indexOf("mouse") !== -1 || label.indexOf("trackball") !== -1) {
    return "󰍽"
  }
  if (icon.indexOf("gaming") !== -1 || icon.indexOf("gamepad") !== -1 || icon.indexOf("joystick") !== -1
      || label.indexOf("controller") !== -1 || label.indexOf("gamepad") !== -1 || label.indexOf("dualsense") !== -1
      || label.indexOf("xbox") !== -1) {
    return "󰊴"
  }
  if (icon.indexOf("tablet") !== -1 || icon.indexOf("touchpad") !== -1
      || label.indexOf("tablet") !== -1 || label.indexOf("touchpad") !== -1) {
    return "󰓶"
  }
  if (icon.indexOf("phone") !== -1 || icon.indexOf("smartphone") !== -1 || icon.indexOf("telephony") !== -1
      || label.indexOf("phone") !== -1 || label.indexOf("iphone") !== -1 || label.indexOf("galaxy s") !== -1
      || label.indexOf("pixel") !== -1) {
    return "󰏲"
  }
  if (icon.indexOf("computer") !== -1 || icon.indexOf("laptop") !== -1 || icon.indexOf("desktop") !== -1
      || label.indexOf("macbook") !== -1 || label.indexOf("thinkpad") !== -1 || label.indexOf("laptop") !== -1) {
    return "󰌢"
  }
  if (icon.indexOf("camera") !== -1 || icon.indexOf("webcam") !== -1) {
    return "󰄀"
  }
  if (icon.indexOf("watch") !== -1 || icon.indexOf("wearable") !== -1 || label.indexOf("watch") !== -1) {
    return "󰖉"
  }
  if (icon.indexOf("printer") !== -1) {
    return "󰐪"
  }
  if (icon.indexOf("scanner") !== -1) {
    return "󰚫"
  }
  if (icon.indexOf("network") !== -1 || icon.indexOf("wireless") !== -1 || icon.indexOf("modem") !== -1) {
    return "󰖩"
  }
  return isConnected ? "󰂱" : "󰂯"
}

if (typeof module !== "undefined") {
  module.exports = {
    deviceLabel: deviceLabel,
    toArray: toArray,
    isUuidLike: isUuidLike,
    isAddressLike: isAddressLike,
    normalizedAddress: normalizedAddress,
    textContainsAddress: textContainsAddress,
    textContainsAnyAddress: textContainsAnyAddress,
    parseAudioPreferences: parseAudioPreferences,
    parseAudioPolicyOverrides: parseAudioPolicyOverrides,
    mergeAudioPreferences: mergeAudioPreferences,
    isAudioPreferencesDocument: isAudioPreferencesDocument,
    isValidAudioPolicy: isValidAudioPolicy,
    audioPolicyOrder: audioPolicyOrder,
    deviceAudioPolicy: deviceAudioPolicy,
    preferredAudioProfile: preferredAudioProfile,
    currentAudioProfile: currentAudioProfile,
    preferredAudioNodeName: preferredAudioNodeName,
    currentAudioNodeName: currentAudioNodeName,
    hasHumanName: hasHumanName,
    nodeProps: nodeProps,
    isAudioSource: isAudioSource,
    bluetoothSinkMatchesDevice: bluetoothSinkMatchesDevice,
    bluetoothSourceMatchesDevice: bluetoothSourceMatchesDevice,
    sameAudioNode: sameAudioNode,
    audioProfileState: audioProfileState,
    audioProfileOptions: audioProfileOptions,
    audioProfileCodec: audioProfileCodec,
    audioProfileHasInput: audioProfileHasInput,
    duplexProfileOption: duplexProfileOption,
    preferredDuplexProfileOption: preferredDuplexProfileOption,
    isAudioDevice: isAudioDevice,
    sortedByLabel: sortedByLabel,
    deviceRow: deviceRow,
    deviceLists: deviceLists,
    observeDeviceConnections: observeDeviceConnections,
    deviceDetailsStops: deviceDetailsStops,
    cloneMap: cloneMap,
    pendingAction: pendingAction,
    withPendingAction: withPendingAction,
    deviceActionFailure: deviceActionFailure,
    withDeviceActionFailure: withDeviceActionFailure,
    deviceActionReachedState: deviceActionReachedState,
    parseDeviceAliases: parseDeviceAliases,
    deviceAliasKeysForAddress: deviceAliasKeysForAddress,
    visibleSections: visibleSections,
    sectionDevices: sectionDevices,
    deviceIconGlyph: deviceIconGlyph
  }
}
