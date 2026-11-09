import QtQuick

// The widget's mark: three workspaces side by side. No icon font has this shape.
Row {
  id: mark

  property color color: "white"

  spacing: 1

  Repeater {
    model: 3

    Rectangle {
      width: 4.5
      height: 4.5
      color: mark.color
    }
  }
}
