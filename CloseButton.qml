import QtQuick
import qs.Commons
import qs.Commons as Commons

// A small button on a window's row in a list: the × that closes it, by default.
Rectangle {
  id: button

  property int size: 16
  property real glyphScale: 1.1
  property real restingOpacity: 0.7
  property string glyph: "󰅖"
  readonly property bool hovered: mouse.containsMouse

  signal clicked()

  width: size
  height: size
  radius: Style.cornerRadius
  color: hovered ? Style.hoverFill : "transparent"

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: button.glyph
    color: Commons.Color.foreground
    opacity: button.hovered ? 1 : button.restingOpacity
    font.family: Style.font.family
    font.pixelSize: Math.round(button.size * button.glyphScale)
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: button.clicked()
  }
}
