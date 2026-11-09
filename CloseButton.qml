import QtQuick
import qs.Commons
import qs.Commons as Commons

// The × at the end of a window's row in a list.
Rectangle {
  id: button

  property int size: 16
  readonly property bool hovered: mouse.containsMouse

  signal clicked()

  width: size
  height: size
  radius: Style.cornerRadius
  color: hovered ? Style.hoverFill : "transparent"

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: "×"
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Math.round(button.size * 0.85)
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: button.clicked()
  }
}
