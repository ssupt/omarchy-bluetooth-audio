import QtQuick
import QtQuick.Window
import Quickshell
import MODEL_URL as Model

ShellRoot {
  id: root
  property string pluginRoot: ROOT_URL
  property string server: SERVER_URL
  property var labels: []
  function payload(path) { return '<img src="' + server + '/' + path + '"> Speaker & <b>name</b>' }
  property var device: ({name: payload("device"), deviceName: "Headphones",
    address: "00:11:22:33:44:55", icon: "audio-headset", state: 0,
    connected: false, paired: false, bonded: false, blocked: false, trusted: false,
    wakeAllowed: false, batteryAvailable: false})
  property var controller: ({
    bar: {foreground: "white", urgent: "red", fontFamily: "sans-serif", position: "left"},
    audioPreferences: {}, pendingAudioProfile: null, defaultAudioSink: null,
    currentAudioSinkName: "", cursorActive: false, focusSection: "discovered",
    selectedIndex: 0, focusedAction: "", hoverFill: "transparent", selectedFill: "gray",
    audioProfileChangeBusy: false, deviceActionBusy: false, devicePropertyBusy: false,
    deviceDetailsRow: device, deviceDetailsAddress: device.address,
    deviceDetailsOpen: true, deviceDetailsIsAudio: true, deviceDetailsIndex: 0,
    deviceDetailsControlsBusy: false, deviceDetailsForgetAvailable: true,
    deviceDetailsBusyText: "", devicePropertyError: payload("error"),
    connectPolicyHint: "Manual selection", forgetConfirmationOpen: true,
    detailsRenameIndex: 0, detailsAudioPolicyIndex: 1, detailsTrustedIndex: 2,
    detailsBlockedIndex: 3, detailsWakeIndex: 4, detailsForgetIndex: 5,
    deviceDisplayName: function(dev) { return Model.deviceLabel(dev) },
    pendingAction: function() { return "" }, deviceActionFailure: function() { return null },
    recoveryAction: function() { return "" }, pairingCancellationPending: function() { return false },
    audioProfileState: function() { return null }, audioProfileActionAvailable: function() { return false },
    bluetoothAudioSink: function() { return null }, bluetoothAudioSource: function() { return null },
    audioUseActionAvailable: function() { return false }, restorePanelFocus: function() {},
    deviceAudioPolicy: function() { return "manual" }
  })
  function create(path, parent, properties) {
    var component = Qt.createComponent(pluginRoot + path)
    if (component.status !== Component.Ready) {
      console.error(component.errorString()); Qt.exit(1); return null
    }
    var item = component.createObject(parent, properties)
    if (!item) { console.error("Could not create", path); Qt.exit(1) }
    return item
  }
  function expectLabel(item, text) { labels.push({item: item, text: text}) }
  function containsLabel(item, text) {
    var pending = [item], seen = []
    while (pending.length) {
      var next = pending.pop()
      if (!next || seen.indexOf(next) !== -1) continue
      seen.push(next)
      if (next.textFormat !== undefined && next.text === text) return true
      var children = next.data || next.children || []
      for (var i = 0; i < children.length; i++) pending.push(children[i])
      if (next.contentItem) pending.push(next.contentItem)
    }
    return false
  }
  Window {
    width: 900; height: 700; visible: true
    Column {
      id: rows
      width: parent.width
      Text { text: '<img src="' + root.server + '/control">'; textFormat: Text.AutoText }
    }
    Component.onCompleted: {
      var row = root.create("BluetoothDeviceRow.qml", rows, {controller: root.controller, dev: root.device,
        rowIndex: 0, sectionName: "discovered", isDiscovered: true})
      root.expectLabel(row, root.payload("device"))
      var details = root.create("BluetoothDeviceDetails.qml", rows, {width: 900, height: 450, controller: root.controller})
      root.expectLabel(details, root.payload("device"))
      root.expectLabel(details, root.payload("error"))
      var dropdown = root.create("AudioDropdown.qml", rows, {
        width: 800, label: root.payload("dropdown-header"), value: "selected",
        options: [{value: "selected", label: root.payload("dropdown-option")}]
      })
      root.expectLabel(dropdown, root.payload("dropdown-header"))
      root.expectLabel(dropdown, root.payload("dropdown-option"))
    }
  }
  Timer {
    interval: 1500; running: true
    onTriggered: {
      for (var i = 0; i < root.labels.length; i++) {
        if (!root.containsLabel(root.labels[i].item, root.labels[i].text)) {
          console.error("Original label was lost", root.labels[i].text); Qt.exit(1); return
        }
      }
      console.log("TEXT_RENDERING_READY"); Qt.quit()
    }
  }
}
