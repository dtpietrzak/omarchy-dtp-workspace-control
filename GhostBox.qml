import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Commons as Commons

// Where a carried window would land: its outline, with the window itself
// showing faintly inside, and on the screen a likeness of its title bar on top.
Item {
  id: box

  // The spot, in the parent's coordinates, as anything with x, y, width and
  // height. Nothing is shown without one.
  property var spot: null
  property var toplevel: null
  // The settings, for a box that shows the title bar hyprbars would put on
  // the window: above it, as tall and in the colors it is set to. Left out
  // for a box with none, as on a card.
  property var titleBars: null
  readonly property int barHeight: titleBars ? titleBars.titleBarHeight : 0

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

  // As faint as the window under it. Without the buttons, which Hyprland
  // has no way to ask after.
  Rectangle {
    visible: box.barHeight > 0
    y: -box.barHeight
    width: parent.width
    height: box.barHeight
    topLeftRadius: outline.radius
    topRightRadius: outline.radius
    color: box.titleBars ? box.titleBars.titleBarColor : "transparent"
    opacity: 0.5

    Text {
      readonly property int inset: box.titleBars ? box.titleBars.titleBarPadding : 0
      anchors.fill: parent
      anchors.leftMargin: inset
      anchors.rightMargin: inset
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: box.titleBars && box.titleBars.titleBarTextAlign === "left" ? Text.AlignLeft : Text.AlignHCenter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: box.toplevel && box.toplevel.title ? box.toplevel.title : ""
      color: box.titleBars ? box.titleBars.titleBarTextColor : "white"
      font.family: box.titleBars && box.titleBars.titleBarFont !== "" ? box.titleBars.titleBarFont : Style.font.family
      font.pointSize: box.titleBars ? Math.max(1, box.titleBars.titleBarTextSize) : 10
    }
  }

  // Drawn apart so it stays thin and solid over the picture. Around the title
  // bar too, when there is one.
  Rectangle {
    id: outline
    y: -box.barHeight
    width: parent.width
    height: parent.height + box.barHeight
    radius: Math.min(Style.cornerRadius, height / 2)
    color: "transparent"
    border.width: 1
    border.color: Commons.Color.accent
  }
}
