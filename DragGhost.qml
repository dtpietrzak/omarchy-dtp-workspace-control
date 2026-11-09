import QtQuick
import qs.Commons
import qs.Commons as Commons

// What's being dragged from a card, under the pointer. It fills its window, so
// the item can be drawn anywhere on the screen.
Item {
  id: ghost

  property Item source: null
  // Where the pointer is, and the spot on the item it was picked up by.
  property point position: Qt.point(0, 0)
  property point grab: Qt.point(0, 0)
  property real itemScale: 1

  anchors.fill: parent
  visible: !!source

  ShaderEffectSource {
    sourceItem: ghost.source
    hideSource: true
    width: ghost.source ? ghost.source.width : 0
    height: ghost.source ? ghost.source.height : 0
    x: ghost.position.x - ghost.grab.x
    y: ghost.position.y - ghost.grab.y
    // Small and see-through, so the workspace it's over can be seen. It shrinks
    // toward the spot it was picked up by, which stays under the pointer. Just
    // under 30%, because Hyprland blurs behind anything above that on glassy.
    opacity: 0.29
    transform: Scale {
      origin.x: ghost.grab.x
      origin.y: ghost.grab.y
      xScale: ghost.itemScale
      yScale: ghost.itemScale
    }
  }

  // Its border, drawn apart so it stays thin and solid at any size and opacity.
  Rectangle {
    x: ghost.position.x - ghost.grab.x * ghost.itemScale
    y: ghost.position.y - ghost.grab.y * ghost.itemScale
    width: ghost.source ? ghost.source.width * ghost.itemScale : 0
    height: ghost.source ? ghost.source.height * ghost.itemScale : 0
    radius: Math.min(Style.cornerRadius, height / 2)
    color: "transparent"
    border.width: 1
    border.color: Commons.Color.accent
  }
}
