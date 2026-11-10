import QtQuick

// The app list's mark: three rows, each a dot and a line. Drawn the same way
// as the dock's apps button, at bar size.
Column {
  id: mark

  property color color: "white"

  spacing: 1.25

  Repeater {
    model: 3

    Row {
      spacing: 1.5

      Rectangle {
        width: 2.5
        height: 2.5
        radius: 0.75
        color: mark.color
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 6
        height: 1.25
        radius: height / 2
        color: mark.color
      }
    }
  }
}
