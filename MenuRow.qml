import QtQuick
import qs.Commons
import qs.Commons as Commons

// One choice in the bar button's popover: an icon and a label.
Item {
  id: row

  property string label: ""
  // A dim note at the far end, such as the shortcut for this choice.
  property string hint: ""
  property string fontFamily: Style.font.family
  // The icon, drawn centered in its slot.
  default property alias icon: iconSlot.data

  readonly property int edge: Style.spacing.md
  readonly property int iconSize: Math.round(Style.font.body * 1.5)

  signal clicked()

  implicitWidth: text.implicitWidth + iconSize + edge * 3
    + (hint !== "" ? hintText.implicitWidth + edge * 2 : 0)
  implicitHeight: Math.max(iconSize, text.implicitHeight) + edge

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: mouse.containsMouse ? Style.hoverFill : "transparent"
    border.width: mouse.containsMouse ? 1 : 0
    border.color: Commons.Color.accent
  }

  Item {
    id: iconSlot
    anchors.left: parent.left
    anchors.leftMargin: row.edge
    anchors.verticalCenter: parent.verticalCenter
    width: row.iconSize
    height: row.iconSize
  }

  Text {
    id: text
    anchors.left: iconSlot.right
    anchors.leftMargin: row.edge
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: row.label
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  Text {
    id: hintText
    visible: row.hint !== ""
    anchors.right: parent.right
    anchors.rightMargin: row.edge
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: row.hint
    color: Commons.Color.foreground
    opacity: 0.4
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.clicked()
  }
}
