import QtQuick

// The app list's mark: three rows, each a dot and a line of the same thickness. Drawn the same way
// as the dock's apps button, at bar size.
Column {
  id: mark

  property color color: "white"

  spacing: 1.75

  Repeater {
    model: 3

    Row {
      spacing: 1.5

      Rectangle {
        width: 2
        height: 2
        radius: 0.5
        color: mark.color
      }

      // As thick as the dot and level with it.
      Rectangle {
        width: 6
        height: 2
        radius: 0.5
        color: mark.color
      }
    }
  }
}
