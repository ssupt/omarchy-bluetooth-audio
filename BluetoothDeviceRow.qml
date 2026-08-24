import QtQuick
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Two-line device row. The controller owns live BlueZ/PipeWire objects and
// operations; this delegate only projects their state and emits user intent.
CursorSurface {
  id: row

  required property var controller
  required property var dev
  required property int rowIndex
  required property string sectionName
  required property bool isDiscovered

  readonly property bool isConnected: dev && dev.connected
  readonly property int devState: dev && dev.state !== undefined ? dev.state : -1
  readonly property string action: controller.pendingAction(dev ? dev.address : "")
  readonly property var actionFailure: controller.deviceActionFailure(dev ? dev.address : "")
  readonly property string actionFailureMessage: actionFailure
    ? String(actionFailure.message || "") : ""
  readonly property string recoveryAction: controller.recoveryAction(dev ? dev.address : "")
  readonly property bool recoveryVisible: recoveryAction !== ""
  readonly property bool cancellingPair: controller.deviceActionCancelRequested
    && controller.activeDeviceAction && dev
    && Model.normalizedAddress(controller.activeDeviceAction.address)
      === Model.normalizedAddress(dev.address)
  readonly property string actionTooltip: {
    if (!dev) return ""
    if (isConnected) return "Disconnect"
    if (isDiscovered) return "Pair"
    return "Connect"
  }

  readonly property var profileState: controller.audioProfileState(dev ? dev.address : "")
  readonly property var profileOptions: Model.audioProfileOptions(profileState)
  readonly property bool profileMenuAvailable: controller.audioProfileActionAvailable(dev)
  readonly property string pendingProfileName: {
    if (!controller.pendingAudioProfile || !dev) return ""
    return controller.pendingAudioProfile.address === Model.normalizedAddress(dev.address)
      ? String(controller.pendingAudioProfile.profile || "") : ""
  }
  readonly property string currentProfileName: Model.currentAudioProfile(
    controller.audioPreferences, dev ? dev.address : "", profileOptions,
    profileState ? profileState.activeProfile : "", pendingProfileName)
  readonly property string activeCodec: Model.audioProfileCodec(
    profileState, profileState ? profileState.activeProfile : "")
  readonly property var deviceAudioSink: controller.bluetoothAudioSink(dev)
  readonly property var deviceAudioSource: controller.activeAudioProfileHasInput(
    dev ? dev.address : "") ? controller.bluetoothAudioSource(dev) : null
  readonly property bool useAudioAvailable: isConnected && !!deviceAudioSink
  readonly property bool usingForAudio: useAudioAvailable
    && (controller.defaultAudioSink
      ? Model.sameAudioNode(deviceAudioSink, controller.defaultAudioSink)
      : String(deviceAudioSink.name || "") === controller.currentAudioSinkName)

  readonly property bool rowSelected: controller.cursorActive
    && controller.focusSection === sectionName && controller.selectedIndex === rowIndex
  readonly property bool showDetailsButton: !recoveryVisible
    && (rowMouse.containsMouse || rowSelected)
  readonly property bool showUseAudioButton: !recoveryVisible && useAudioAvailable
    && (rowMouse.containsMouse || rowSelected)

  hasCursor: rowSelected && controller.focusedAction === ""
  current: isConnected
  foreground: controller.bar.foreground
  fill: controller.hoverFill
  currentFill: controller.selectedFill

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
    if (action === "connecting" || devState === 3 || dev.pairing === true)
      return "Connecting…"
    return ""
  }

  readonly property color statusColor: {
    if (actionFailureMessage !== "" || (dev && dev.blocked)) return controller.bar.urgent
    if (isConnected || action !== "" || devState === 3 || dev.pairing === true)
      return controller.bar.foreground
    return Qt.darker(controller.bar.foreground, 1.5)
  }

  implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: row.dev ? Qt.PointingHandCursor : Qt.ArrowCursor

    onContainsMouseChanged: if (containsMouse) {
      controller.cursorActive = true
      controller.focusSection = row.sectionName
      controller.selectedIndex = row.rowIndex
      controller.focusedAction = ""
    }

    onClicked: function(mouse) {
      var device = controller.deviceFor(row)
      if (!device) return
      if (mouse.button === Qt.RightButton) controller.openDeviceDetails(device)
      else if (row.isConnected) controller.disconnectDevice(device)
      else controller.connectDevice(device)
    }
  }

  PanelToolTip {
    visible: row.actionTooltip !== "" && rowMouse.containsMouse
      && controller.focusedAction === ""
    text: row.actionTooltip
    fontFamily: controller.bar.fontFamily
  }

  Item {
    id: rowContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    implicitHeight: Math.max(deviceIcon.implicitHeight, info.implicitHeight,
      profileDropdown.implicitHeight, detailsButton.implicitHeight,
      useAudioButton.implicitHeight, recoveryButton.implicitHeight)

    BluetoothDeviceIcon {
      id: deviceIcon
      width: Style.space(26)
      height: Style.space(26)
      iconName: row.dev ? String(row.dev.icon || "") : ""
      deviceName: row.dev ? String(row.dev.name || row.dev.deviceName || "") : ""
      connected: row.isConnected
      foreground: row.statusColor
      fontFamily: controller.bar.fontFamily
      iconSize: Style.font.heading
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: info
      spacing: Style.space(1)
      anchors.left: deviceIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: useAudioButton.visible ? useAudioButton.left
        : (detailsButton.visible ? detailsButton.left
        : (profileDropdown.visible ? profileDropdown.left
        : (recoveryButton.visible ? recoveryButton.left : parent.right)))
      anchors.rightMargin: profileDropdown.visible || detailsButton.visible
        || useAudioButton.visible || recoveryButton.visible ? Style.space(8) : 0
      anchors.verticalCenter: parent.verticalCenter

      Text {
        text: controller.deviceDisplayName(row.dev) || "Device"
        color: controller.bar.foreground
        font.family: controller.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width
      }
      Text {
        visible: row.statusText !== ""
        text: row.statusText
        color: row.statusColor
        font.family: controller.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }

    AudioDropdown {
      id: profileDropdown
      width: Style.spacing.controlHeight
      anchors.right: recoveryButton.visible ? recoveryButton.left : parent.right
      anchors.rightMargin: recoveryButton.visible ? Style.space(6) : 0
      anchors.verticalCenter: parent.verticalCenter
      visible: row.profileMenuAvailable && !row.recoveryVisible
      rowHeight: Style.spacing.controlHeight
      popupRowHeight: Style.space(36)
      popupDirection: {
        var position = controller.bar ? controller.bar.position : "left"
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
      hasCursor: row.rowSelected && controller.focusedAction === "profile"
      enabled: !controller.audioProfileChangeBusy
      opacity: enabled ? 1 : 0.5
      foreground: controller.bar.foreground
      fontFamily: controller.bar.fontFamily

      onHovered: function(isHovered) {
        if (!isHovered) {
          if (rowMouse.containsMouse && controller.focusedAction === "profile")
            controller.focusedAction = ""
          return
        }
        controller.cursorActive = true
        controller.focusSection = row.sectionName
        controller.selectedIndex = row.rowIndex
        controller.focusedAction = "profile"
      }
      onChanged: function(profile) { controller.setAudioProfile(row.dev.address, profile) }
      onPopupOpenChanged: {
        if (popupOpen) controller.closeAudioProfileMenus(row.rowIndex)
        controller.audioProfileMenuOpen = popupOpen
        if (!popupOpen) controller.restorePanelFocus()
      }
    }

    PanelActionButton {
      id: detailsButton
      anchors.right: profileDropdown.visible ? profileDropdown.left
        : (recoveryButton.visible ? recoveryButton.left : parent.right)
      anchors.rightMargin: profileDropdown.visible || recoveryButton.visible ? Style.space(6) : 0
      anchors.verticalCenter: parent.verticalCenter
      visible: row.showDetailsButton
      iconText: "󰒓"
      tooltipText: "Device details"
      foreground: controller.bar.foreground
      hoverColor: controller.bar.foreground
      fontFamily: controller.bar.fontFamily
      hasCursor: row.rowSelected && controller.focusedAction === "details"
      onHovered: function(isHovered) {
        if (!isHovered) {
          if (rowMouse.containsMouse && controller.focusedAction === "details")
            controller.focusedAction = ""
          return
        }
        controller.cursorActive = true
        controller.focusSection = row.sectionName
        controller.selectedIndex = row.rowIndex
        controller.focusedAction = "details"
      }
      onClicked: {
        var device = controller.deviceFor(row)
        if (device) controller.openDeviceDetails(device)
      }
    }

    PanelActionButton {
      id: useAudioButton
      anchors.right: detailsButton.visible ? detailsButton.left
        : (profileDropdown.visible ? profileDropdown.left
        : (recoveryButton.visible ? recoveryButton.left : parent.right))
      anchors.rightMargin: detailsButton.visible || profileDropdown.visible
        || recoveryButton.visible ? Style.space(6) : 0
      anchors.verticalCenter: parent.verticalCenter
      visible: row.showUseAudioButton
      iconText: row.usingForAudio ? "󰄬" : "󰓃"
      tooltipText: row.usingForAudio ? "Default audio device"
        : (row.deviceAudioSource ? "Use for audio input and output" : "Use for audio output")
      foreground: row.usingForAudio
        ? Style.selectedStateColor(controller.bar.foreground, Color.accent)
        : controller.bar.foreground
      hoverColor: controller.bar.foreground
      fontFamily: controller.bar.fontFamily
      hasCursor: row.rowSelected && controller.focusedAction === "audio"
      onHovered: function(isHovered) {
        if (!isHovered) {
          if (rowMouse.containsMouse && controller.focusedAction === "audio")
            controller.focusedAction = ""
          return
        }
        controller.cursorActive = true
        controller.focusSection = row.sectionName
        controller.selectedIndex = row.rowIndex
        controller.focusedAction = "audio"
      }
      onClicked: {
        var device = controller.deviceFor(row)
        if (device) controller.useDeviceForAudio(device)
      }
    }

    PanelActionButton {
      id: recoveryButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: row.recoveryVisible
      enabled: row.recoveryAction === "cancel" || !controller.deviceActionBusy
      iconText: row.recoveryAction === "cancel" ? "󰅙" : "󰑐"
      tooltipText: row.recoveryAction === "cancel" ? "Cancel pairing"
        : (row.actionFailureMessage !== ""
          ? "Retry · " + row.actionFailureMessage : "Retry")
      foreground: controller.bar.foreground
      hoverColor: row.recoveryAction === "retry" ? controller.bar.urgent
        : controller.bar.foreground
      fontFamily: controller.bar.fontFamily
      hasCursor: row.rowSelected && controller.focusedAction === row.recoveryAction
      onHovered: function(isHovered) {
        if (!isHovered) {
          if (rowMouse.containsMouse && controller.focusedAction === row.recoveryAction)
            controller.focusedAction = ""
          return
        }
        controller.cursorActive = true
        controller.focusSection = row.sectionName
        controller.selectedIndex = row.rowIndex
        controller.focusedAction = row.recoveryAction
      }
      onClicked: {
        var device = controller.deviceFor(row)
        if (!device) return
        if (row.recoveryAction === "cancel") controller.cancelPairing(device)
        else controller.retryDeviceAction(device)
      }
    }
  }

  function toggleProfileMenu() { profileDropdown.toggle() }
  function closeProfileMenu() { profileDropdown.close() }

  onProfileMenuAvailableChanged: if (!profileMenuAvailable) closeProfileMenu()
  onRecoveryVisibleChanged: if (recoveryVisible) closeProfileMenu()
  onRecoveryActionChanged: if (rowSelected
    && (controller.focusedAction === "retry" || controller.focusedAction === "cancel")
    && controller.focusedAction !== recoveryAction) controller.focusedAction = ""
  Component.onDestruction: if (profileDropdown.popupOpen)
    controller.audioProfileMenuOpen = false
}
