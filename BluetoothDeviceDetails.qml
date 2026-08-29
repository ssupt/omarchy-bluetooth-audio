import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Device-details page and confirmation overlay. Public methods keep focus and
// scroll mechanics here while Panel owns Bluetooth operations and state.
Item {
  id: details

  required property var controller

  implicitHeight: detailsColumn.implicitHeight
  readonly property bool editingName: nameField.activeFocus
  readonly property bool confirmSelected: forgetDialog.selectedIndex === 1

  function reset(name) {
    nameField.text = String(name || "")
    scroll.contentY = 0
  }

  function beginRename(name) {
    nameField.text = String(name || "")
    nameField.selectAll()
    nameField.forceActiveFocus()
  }

  function finishRename(name) {
    nameField.text = String(name || "")
    nameField.focus = false
  }

  function renameText() {
    return String(nameField.text || "")
  }

  function updateNameIfIdle(name) {
    if (!nameField.activeFocus) nameField.text = String(name || "")
  }

  function clearNameFocus() {
    nameField.focus = false
  }

  function ensureCursorVisible() {
    scroll.ensureCursorVisible()
  }

  function resetConfirmation() {
    forgetDialog.selectedIndex = 0
  }

  function toggleConfirmationSelection() {
    forgetDialog.selectedIndex = forgetDialog.selectedIndex === 0 ? 1 : 0
  }

  Flickable {
    id: scroll
    anchors.fill: parent
    contentWidth: width
    contentHeight: detailsColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height

    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    function cursorItem() {
      if (controller.deviceDetailsIndex === controller.detailsRenameIndex) return nameField
      if (controller.deviceDetailsIndex === controller.detailsAudioPolicyIndex) return policyManualButton
      if (controller.deviceDetailsIndex === controller.detailsTrustedIndex) return trustedToggle
      if (controller.deviceDetailsIndex === controller.detailsBlockedIndex) return blockedToggle
      if (controller.deviceDetailsIndex === controller.detailsWakeIndex) return wakeToggle
      if (controller.deviceDetailsIndex === controller.detailsForgetIndex) return forgetButton
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
      width: scroll.width
      spacing: Style.space(12)

      Item {
        width: parent.width
        implicitHeight: Math.max(backButton.implicitHeight,
          deviceIcon.height, heading.implicitHeight)

        Button {
          id: backButton
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "←"
          tooltipText: "Back to Bluetooth devices"
          foreground: controller.bar.foreground
          fontFamily: controller.bar.fontFamily
          fontSize: Style.font.heading
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(2)
          onClicked: controller.closeDeviceDetails()
        }

        BluetoothDeviceIcon {
          id: deviceIcon
          anchors.left: backButton.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(34)
          height: Style.space(34)
          iconName: controller.deviceDetailsRow ? controller.deviceDetailsRow.icon : ""
          deviceName: controller.deviceDetailsRow
            ? String(controller.deviceDetailsRow.name || "") + " "
              + String(controller.deviceDetailsRow.deviceName || "") : ""
          connected: controller.deviceDetailsRow
            ? controller.deviceDetailsRow.connected : false
          foreground: controller.deviceDetailsRow && controller.deviceDetailsRow.blocked
            ? controller.bar.urgent : controller.bar.foreground
          fontFamily: controller.bar.fontFamily
          iconSize: Style.font.display
        }

        Column {
          id: heading
          anchors.left: deviceIcon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            width: parent.width
            text: controller.deviceDetailsRow
              ? (controller.deviceDisplayName(controller.deviceDetailsRow)
                || "Bluetooth device") : "Device unavailable"
            color: controller.bar.foreground
            font.family: controller.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: !controller.deviceDetailsRow ? "NO LONGER VISIBLE"
              : controller.deviceDetailsRow.blocked ? "BLOCKED"
              : controller.deviceDetailsRow.connected ? "CONNECTED"
              : (controller.deviceDetailsRow.paired
                || controller.deviceDetailsRow.bonded) ? "PAIRED" : "AVAILABLE"
            color: controller.deviceDetailsRow && controller.deviceDetailsRow.blocked
              ? controller.bar.urgent : Qt.darker(controller.bar.foreground, 1.4)
            font.family: controller.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.0
            elide: Text.ElideRight
          }
        }
      }

      PanelSeparator { foreground: controller.bar.foreground }

      Text {
        visible: !controller.deviceDetailsRow
        width: parent.width
        text: "This Bluetooth device disappeared. It may be out of range or no longer remembered."
        color: Qt.darker(controller.bar.foreground, 1.4)
        font.family: controller.bar.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Column {
        visible: !!controller.deviceDetailsRow
        width: parent.width
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "DEVICE NAME"
          foreground: controller.bar.foreground
          fontFamily: controller.bar.fontFamily
        }

        TextField {
          id: nameField
          width: parent.width
          enabled: !!controller.deviceDetailsRow && !controller.deviceDetailsControlsBusy
          opacity: enabled ? 1 : 0.55
          placeholderText: controller.deviceDetailsRow
            ? String(controller.deviceDetailsRow.deviceName || "Device name") : "Device name"
          foreground: controller.bar.foreground
          accent: Color.accent
          font.family: controller.bar.fontFamily
          font.pixelSize: Style.font.body
          hasCursor: !activeFocus && controller.deviceDetailsOpen
            && !controller.forgetConfirmationOpen
            && controller.deviceDetailsIndex === controller.detailsRenameIndex

          onHoveredChanged: if (hovered)
            controller.setDeviceDetailsCursor(controller.detailsRenameIndex)
          onActiveFocusChanged: if (activeFocus)
            controller.setDeviceDetailsCursor(controller.detailsRenameIndex)
          onAccepted: controller.commitDeviceRename()
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              controller.cancelDeviceRename()
              event.accepted = true
            }
          }
        }

        Text {
          width: parent.width
          text: "Press Enter to rename. Leave empty to restore the device's original name."
          color: Qt.darker(controller.bar.foreground, 1.5)
          font.family: controller.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Column {
        visible: !!controller.deviceDetailsRow && controller.deviceDetailsIsAudio
        width: parent.width
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "AUDIO ON CONNECT"
          foreground: controller.bar.foreground
          fontFamily: controller.bar.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          readonly property string activePolicy:
            controller.deviceAudioPolicy(controller.deviceDetailsAddress)

          Button {
            id: policyManualButton
            selected: parent.activePolicy === "manual"
            text: "Manual"
            fontSize: Style.font.caption
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(2)
            foreground: controller.bar.foreground
            accent: Color.accent
            fontFamily: controller.bar.fontFamily
            enabled: !!controller.deviceDetailsRow && !controller.deviceDetailsControlsBusy
            opacity: enabled ? 1 : 0.55
            hasCursor: controller.deviceDetailsOpen && !controller.forgetConfirmationOpen
              && controller.deviceDetailsIndex === controller.detailsAudioPolicyIndex && selected
            onHovered: function(on) { if (on)
              controller.setDeviceDetailsCursor(controller.detailsAudioPolicyIndex) }
            onClicked: {
              controller.setDeviceDetailsCursor(controller.detailsAudioPolicyIndex)
              controller.setDeviceAudioPolicy("manual")
            }
          }

          Button {
            id: policyOutputButton
            selected: parent.activePolicy === "output"
            text: "Output"
            fontSize: Style.font.caption
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(2)
            foreground: controller.bar.foreground
            accent: Color.accent
            fontFamily: controller.bar.fontFamily
            enabled: !!controller.deviceDetailsRow && !controller.deviceDetailsControlsBusy
            opacity: enabled ? 1 : 0.55
            hasCursor: controller.deviceDetailsOpen && !controller.forgetConfirmationOpen
              && controller.deviceDetailsIndex === controller.detailsAudioPolicyIndex && selected
            onHovered: function(on) { if (on)
              controller.setDeviceDetailsCursor(controller.detailsAudioPolicyIndex) }
            onClicked: {
              controller.setDeviceDetailsCursor(controller.detailsAudioPolicyIndex)
              controller.setDeviceAudioPolicy("output")
            }
          }

          Button {
            id: policyMicButton
            selected: parent.activePolicy === "output-mic"
            text: "Output + Mic"
            fontSize: Style.font.caption
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(2)
            foreground: controller.bar.foreground
            accent: Color.accent
            fontFamily: controller.bar.fontFamily
            enabled: !!controller.deviceDetailsRow && !controller.deviceDetailsControlsBusy
            opacity: enabled ? 1 : 0.55
            hasCursor: controller.deviceDetailsOpen && !controller.forgetConfirmationOpen
              && controller.deviceDetailsIndex === controller.detailsAudioPolicyIndex && selected
            onHovered: function(on) { if (on)
              controller.setDeviceDetailsCursor(controller.detailsAudioPolicyIndex) }
            onClicked: {
              controller.setDeviceDetailsCursor(controller.detailsAudioPolicyIndex)
              controller.setDeviceAudioPolicy("output-mic")
            }
          }
        }

        Text {
          width: parent.width
          text: controller.connectPolicyHint
          color: Qt.darker(controller.bar.foreground, 1.5)
          font.family: controller.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Toggle {
        id: trustedToggle
        visible: !!controller.deviceDetailsRow
        width: parent.width
        label: "Trusted"
        description: "Permit this device to reconnect without asking for authorization."
        checked: !!controller.deviceDetailsRow && controller.deviceDetailsRow.trusted
        enabled: !controller.deviceDetailsControlsBusy
        opacity: enabled ? 1 : 0.55
        foreground: controller.bar.foreground
        accent: Color.accent
        fontFamily: controller.bar.fontFamily
        hasCursor: controller.deviceDetailsOpen && !controller.forgetConfirmationOpen
          && controller.deviceDetailsIndex === controller.detailsTrustedIndex
        onHovered: function(on) { if (on)
          controller.setDeviceDetailsCursor(controller.detailsTrustedIndex) }
        onClicked: {
          controller.setDeviceDetailsCursor(controller.detailsTrustedIndex)
          controller.updateDeviceBoolean("trusted", !checked,
            "Could not update whether this device is trusted.")
        }
      }

      Toggle {
        id: blockedToggle
        visible: !!controller.deviceDetailsRow
        width: parent.width
        label: "Blocked"
        description: "Prevent connections from this device. Blocking also disconnects it."
        checked: !!controller.deviceDetailsRow && controller.deviceDetailsRow.blocked
        enabled: !controller.deviceDetailsControlsBusy
        opacity: enabled ? 1 : 0.55
        foreground: controller.bar.foreground
        accent: Color.accent
        fontFamily: controller.bar.fontFamily
        hasCursor: controller.deviceDetailsOpen && !controller.forgetConfirmationOpen
          && controller.deviceDetailsIndex === controller.detailsBlockedIndex
        onHovered: function(on) { if (on)
          controller.setDeviceDetailsCursor(controller.detailsBlockedIndex) }
        onClicked: {
          controller.setDeviceDetailsCursor(controller.detailsBlockedIndex)
          controller.updateDeviceBoolean("blocked", !checked,
            "Could not update whether this device is blocked.")
        }
      }

      Toggle {
        id: wakeToggle
        visible: !!controller.deviceDetailsRow
        width: parent.width
        label: "Allow wake"
        description: "Let this device wake the computer when the device and adapter support it."
        checked: !!controller.deviceDetailsRow && controller.deviceDetailsRow.wakeAllowed
        enabled: !controller.deviceDetailsControlsBusy
        opacity: enabled ? 1 : 0.55
        foreground: controller.bar.foreground
        accent: Color.accent
        fontFamily: controller.bar.fontFamily
        hasCursor: controller.deviceDetailsOpen && !controller.forgetConfirmationOpen
          && controller.deviceDetailsIndex === controller.detailsWakeIndex
        onHovered: function(on) { if (on)
          controller.setDeviceDetailsCursor(controller.detailsWakeIndex) }
        onClicked: {
          controller.setDeviceDetailsCursor(controller.detailsWakeIndex)
          controller.updateDeviceBoolean("wakeAllowed", !checked,
            "Could not change wake permission. This device or adapter may not support it.")
        }
      }

      Column {
        visible: !!controller.deviceDetailsRow
        width: parent.width
        spacing: Style.space(3)

        PanelSectionHeader {
          text: "MAC ADDRESS"
          foreground: controller.bar.foreground
          fontFamily: controller.bar.fontFamily
        }

        Text {
          width: parent.width
          text: controller.deviceDetailsRow
            ? String(controller.deviceDetailsRow.address || "—") : "—"
          color: controller.bar.foreground
          font.family: controller.bar.fontFamily
          font.pixelSize: Style.font.body
          font.letterSpacing: 0.8
          elide: Text.ElideRight
        }
      }

      Text {
        visible: controller.deviceDetailsControlsBusy
        width: parent.width
        text: controller.deviceDetailsBusyText
        color: Qt.darker(controller.bar.foreground, 1.4)
        font.family: controller.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: controller.devicePropertyError !== ""
        width: parent.width
        text: controller.devicePropertyError
        color: controller.bar.urgent
        font.family: controller.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Button {
        id: forgetButton
        visible: controller.deviceDetailsForgetAvailable
        width: parent.width
        text: "Forget device"
        iconText: "󰅙"
        leftAlign: true
        bordered: true
        enabled: !controller.deviceDetailsControlsBusy && !controller.deviceActionBusy
        opacity: enabled ? 1 : 0.55
        foreground: controller.bar.urgent
        accent: controller.bar.urgent
        fontFamily: controller.bar.fontFamily
        hasCursor: controller.deviceDetailsOpen && !controller.forgetConfirmationOpen
          && controller.deviceDetailsIndex === controller.detailsForgetIndex
        onHovered: function(on) { if (on)
          controller.setDeviceDetailsCursor(controller.detailsForgetIndex) }
        onClicked: {
          controller.setDeviceDetailsCursor(controller.detailsForgetIndex)
          controller.requestForgetConfirmation()
        }
      }
    }
  }

  ConfirmDialog {
    id: forgetDialog
    anchors.fill: parent
    z: 20
    opened: controller.forgetConfirmationOpen
    message: "Forget “" + (controller.deviceDetailsRow
      ? (controller.deviceDisplayName(controller.deviceDetailsRow) || "this device")
      : "this device") + "”? You will need to pair it again before reconnecting."
    cancelText: "Cancel"
    confirmText: "Forget"
    background: Color.popups.background
    foreground: controller.bar.foreground
    onCanceled: controller.cancelForgetConfirmation()
    onConfirmed: controller.confirmForgetDevice()
  }
}
