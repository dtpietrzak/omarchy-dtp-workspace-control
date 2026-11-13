import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Commons as Commons

// Where a carried window would land: its outline, with the window itself
// showing faintly inside.
Item {
  id: box

  // The spot, in the parent's coordinates, as anything with x, y, width and
  // height. Nothing is shown without one.
  property var spot: null
  property var toplevel: null

  visible: !!spot
  x: spot ? spot.x : 0
  y: spot ? spot.y : 0
  width: spot ? spot.width : 0
  height: spot ? spot.height : 0

  ClippingRectangle {
    anchors.fill: parent
    color: "transparent"
    radius: outline.radius

    // Only captured while the box is up.
    Loader {
      anchors.fill: parent
      active: box.visible && !!box.toplevel && !!box.toplevel.wayland
      sourceComponent: ScreencopyView {
        captureSource: box.toplevel.wayland
        live: true
        opacity: 0.5
        constraintSize: Qt.size(Math.ceil(box.width), Math.ceil(box.height))
      }
    }
  }

  // Drawn apart so it stays thin and solid over the picture.
  Rectangle {
    id: outline
    anchors.fill: parent
    radius: Math.min(Style.cornerRadius, height / 2)
    color: "transparent"
    border.width: 1
    border.color: Commons.Color.accent
  }
}
