import QtQuick
import qs.Commons
import "Model.js" as Model

// Device-type glyph rendered with the panel font for crisp themed icons.
Item {
  id: icon

  property string iconName: ""
  property string deviceName: ""
  property bool connected: false
  property color foreground: Color.foreground
  property real iconSize: Style.font.heading
  property string fontFamily: Style.font.family

  implicitWidth: Style.space(26)
  implicitHeight: Style.space(26)

  Text {
    anchors.centerIn: parent
    text: Model.deviceIconGlyph(icon.iconName, icon.deviceName, icon.connected)
    color: icon.foreground
    font.family: icon.fontFamily
    font.pixelSize: icon.iconSize
  }
}
