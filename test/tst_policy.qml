import QtQuick
import QtTest
import ".." as Plugin

TestCase {
  id: testCase
  name: "BluetoothAudioPolicyEngine"

  property var engine: null

  QtObject {
    id: mockController

    property var audioPreferences: ({
      bluetoothProfiles: {},
      bluetoothAudioPolicies: {}
    })
    property bool userAudioProfileChangeBusy: false
    property bool audioProfileChangeBusy: false
    property bool deviceActionBusy: false
    property bool devicePropertyBusy: false
    property string pendingDeviceAction: ""
    property bool coordinator: true
    property var device: ({
      address: "00:11:22:33:44:55",
      connected: true
    })
    property var sinkNode: null
    property var sourceNode: null
    property var profileState: null
    property int sinkCalls: 0
    property int sourceCalls: 0

    function reset() {
      audioPreferences = {
        bluetoothProfiles: {},
        bluetoothAudioPolicies: {}
      }
      userAudioProfileChangeBusy = false
      audioProfileChangeBusy = false
      deviceActionBusy = false
      devicePropertyBusy = false
      pendingDeviceAction = ""
      coordinator = true
      device = { address: "00:11:22:33:44:55", connected: true }
      sinkNode = null
      sourceNode = null
      profileState = null
      sinkCalls = 0
      sourceCalls = 0
    }

    function isAudioPolicyCoordinator() { return coordinator }
    function deviceByAddress(address) { return device }
    function bluetoothAudioSink(deviceValue) { return sinkNode }
    function bluetoothAudioSource(deviceValue) { return sourceNode }
    function audioProfileState(address) { return profileState }
    function pendingAction(address) { return pendingDeviceAction }
    function setDefaultAudioSink(sink) { sinkCalls += 1 }
    function setDefaultAudioSource(source) { sourceCalls += 1 }
  }

  Component {
    id: engineComponent
    Plugin.BluetoothAudioPolicyEngine {
      controller: mockController
      preferencesReady: true
      automaticRetries: false
    }
  }

  function init() {
    mockController.reset()
    engine = engineComponent.createObject(testCase)
    verify(engine !== null)
  }

  function cleanup() {
    if (engine) engine.destroy()
    engine = null
  }

  function queue(policy) {
    mockController.audioPreferences = {
      bluetoothProfiles: {},
      bluetoothAudioPolicies: { "001122334455": policy }
    }
    engine.queueReadyConnection("00:11:22:33:44:55")
  }

  function outputOnlyState() {
    return {
      address: "00:11:22:33:44:55",
      activeProfile: "a2dp-sink-aac",
      profiles: [
        { value: "a2dp-sink-aac", label: "High fidelity · AAC", hasInput: false },
        { value: "headset-head-unit-msbc", label: "Headset + microphone · mSBC", hasInput: true }
      ]
    }
  }

  function advanceToProfileSwitch() {
    for (var i = 0; i < 9; i++) engine.applyPending()
  }

  function test_startupConnectionsAreBaselineButLaterNewDevicesAreEdges() {
    mockController.audioPreferences = {
      bluetoothProfiles: {},
      bluetoothAudioPolicies: { "001122334455": "output" }
    }
    engine.initializeDevices([mockController.device])
    compare(Object.keys(engine.pendingApplications).length, 0)

    var later = { address: "AA:BB:CC:DD:EE:FF", connected: true }
    mockController.audioPreferences = {
      bluetoothProfiles: {},
      bluetoothAudioPolicies: { "aabbccddeeff": "output" }
    }
    engine.observeDevices([mockController.device, later])
    compare(engine.pendingApplications["aabbccddeeff"].policy, "output")
  }

  function test_microphonePolicyCanSwitchAnOffCardWithoutASink() {
    queue("output-mic")
    mockController.profileState = outputOnlyState()
    mockController.profileState.activeProfile = "off"

    advanceToProfileSwitch()

    compare(engine.pendingApplications["001122334455"].switchAttempts, 1)
    compare(mockController.sinkCalls, 0)
  }

  function test_outputPolicyWaitsForSinkWithoutProfileInventory() {
    queue("output")
    engine.applyPending()
    compare(mockController.sinkCalls, 0)
    verify(engine.pendingApplications["001122334455"] !== undefined)

    mockController.sinkNode = { id: 1, name: "bluez_output.test" }
    engine.applyPending()
    compare(mockController.sinkCalls, 1)
    compare(Object.keys(engine.pendingApplications).length, 0)
  }

  function test_microphonePolicyDegradesToOutputForOutputOnlyHardware() {
    queue("output-mic")
    mockController.profileState = {
      address: "00:11:22:33:44:55",
      activeProfile: "a2dp-sink-aac",
      profiles: [
        { value: "a2dp-sink-aac", label: "High fidelity · AAC", hasInput: false }
      ]
    }
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }

    engine.applyPending()
    compare(mockController.sinkCalls, 1)
    compare(mockController.sourceCalls, 0)
    verify(!engine.profileSwitchBusy)
    compare(Object.keys(engine.pendingApplications).length, 0)
  }

  function test_failedProfileSwitchBecomesRetryable() {
    queue("output-mic")
    mockController.profileState = outputOnlyState()
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }

    advanceToProfileSwitch()
    verify(engine.profileSwitchBusy)
    engine.finishProfileSwitch("001122334455", 1)
    verify(!engine.profileSwitchBusy)
    compare(engine.pendingApplications["001122334455"].switchRequested, false)
    compare(engine.pendingApplications["001122334455"].switchAttempts, 1)

    advanceToProfileSwitch()
    verify(engine.profileSwitchBusy)
    engine.finishProfileSwitch("001122334455", 1)
    verify(!engine.profileSwitchBusy)
    compare(engine.pendingApplications["001122334455"].switchRequested, false)
    compare(engine.pendingApplications["001122334455"].switchAttempts, 2)
  }

  function test_unsavedPreferenceDoesNotRepeatSuccessfulHardwareSwitch() {
    queue("output-mic")
    mockController.profileState = outputOnlyState()
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }

    advanceToProfileSwitch()
    verify(engine.profileSwitchBusy)
    engine.finishProfileSwitch("001122334455", 2)

    verify(!engine.profileSwitchBusy)
    compare(engine.pendingApplications["001122334455"].switchRequested, true)
    compare(engine.pendingApplications["001122334455"].switchAttempts, 1)
  }

  function test_confirmationWindowStartsAfterHelperExit() {
    queue("output-mic")
    mockController.profileState = outputOnlyState()
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }

    advanceToProfileSwitch()
    verify(engine.profileSwitchBusy)
    var attemptsBefore = engine.pendingApplications["001122334455"].attempts
    for (var i = 0; i < 20; i++) engine.applyPending()

    compare(engine.pendingApplications["001122334455"].switchRequested, true)
    compare(Number(engine.pendingApplications["001122334455"].switchWaitTicks || 0), 0)
    compare(engine.pendingApplications["001122334455"].attempts, attemptsBefore)
  }

  function test_inputNeverCompletesBeforeOutputExists() {
    queue("output-mic")
    mockController.profileState = outputOnlyState()
    mockController.profileState.activeProfile = "headset-head-unit-msbc"
    mockController.sourceNode = { id: 2, name: "bluez_input.test" }

    engine.applyPending()
    compare(mockController.sourceCalls, 0)
    verify(engine.pendingApplications["001122334455"] !== undefined)

    mockController.sinkNode = { id: 1, name: "bluez_output.test" }
    engine.applyPending()
    compare(mockController.sinkCalls, 1)
    compare(mockController.sourceCalls, 1)
    compare(Object.keys(engine.pendingApplications).length, 0)
  }

  function test_recreatedProfileSinkIsRoutedBeforeInputCompletes() {
    queue("output-mic")
    mockController.profileState = outputOnlyState()
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }
    engine.applyPending()
    compare(mockController.sinkCalls, 1)

    mockController.profileState.activeProfile = "headset-head-unit-msbc"
    mockController.sinkNode = null
    mockController.sourceNode = { id: 2, name: "bluez_input.test" }
    engine.applyPending()
    compare(mockController.sourceCalls, 0)
    verify(engine.pendingApplications["001122334455"] !== undefined)

    mockController.sinkNode = { id: 3, name: "bluez_output.test" }
    engine.applyPending()
    compare(mockController.sinkCalls, 2)
    compare(mockController.sourceCalls, 1)
    compare(Object.keys(engine.pendingApplications).length, 0)
  }

  function test_shadowQueueWaitsUntilThisMirrorBecomesCoordinator() {
    mockController.coordinator = false
    queue("output")
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }

    engine.applyPending()
    compare(mockController.sinkCalls, 0)
    verify(engine.pendingApplications["001122334455"] !== undefined)

    mockController.coordinator = true
    engine.applyPending()
    compare(mockController.sinkCalls, 1)
    compare(Object.keys(engine.pendingApplications).length, 0)
  }

  function test_profileSwitchWaitsForGlobalManualCommand() {
    queue("output-mic")
    mockController.profileState = outputOnlyState()
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }
    mockController.audioProfileChangeBusy = true

    advanceToProfileSwitch()
    verify(!engine.profileSwitchBusy)
    verify(engine.pendingApplications["001122334455"] !== undefined)

    mockController.audioProfileChangeBusy = false
    advanceToProfileSwitch()
    verify(engine.profileSwitchBusy)
  }

  function test_routingWaitsForBluetoothDeviceMutation() {
    queue("output")
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }
    mockController.deviceActionBusy = true

    engine.applyPending()
    compare(mockController.sinkCalls, 0)
    verify(engine.pendingApplications["001122334455"] !== undefined)

    mockController.deviceActionBusy = false
    engine.applyPending()
    compare(mockController.sinkCalls, 1)
    compare(Object.keys(engine.pendingApplications).length, 0)
  }

  function test_routingWaitsForDeviceStateConfirmation() {
    queue("output")
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }
    mockController.pendingDeviceAction = "disconnecting"

    engine.applyPending()
    compare(mockController.sinkCalls, 0)
    verify(engine.pendingApplications["001122334455"] !== undefined)

    mockController.pendingDeviceAction = ""
    engine.applyPending()
    compare(mockController.sinkCalls, 1)
    compare(Object.keys(engine.pendingApplications).length, 0)
  }

  function test_pendingApplicationUsesLatestPolicyBeforeRouting() {
    queue("output")
    engine.applyPending()
    verify(engine.pendingApplications["001122334455"] !== undefined)

    mockController.audioPreferences = {
      bluetoothProfiles: {},
      bluetoothAudioPolicies: {}
    }
    mockController.sinkNode = { id: 1, name: "bluez_output.test" }
    engine.applyPending()

    compare(mockController.sinkCalls, 0)
    compare(Object.keys(engine.pendingApplications).length, 0)
  }
}
