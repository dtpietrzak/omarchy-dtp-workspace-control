import QtQuick
import Quickshell.Widgets
import qs.Commons

// An app's icon, or its first letter if it has no icon anywhere.
Item {
  id: mark

  property string source: ""
  property string letter: ""
  property int size: 16
  property color letterColor: "white"
  property string fontFamily: Style.font.family

  width: size
  height: size

  IconImage {
    id: icon
    anchors.fill: parent
    implicitSize: mark.size
    source: mark.source
  }

  Text {
    anchors.centerIn: parent
    visible: icon.status !== Image.Ready
    textFormat: Text.PlainText
    text: mark.letter
    color: mark.letterColor
    font.family: mark.fontFamily
    font.pixelSize: Style.font.body
  }
}
