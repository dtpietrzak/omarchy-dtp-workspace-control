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
  // The item stays where it is while this copy of it is carried. Otherwise it
  // is hidden for as long as it is.
  property bool keepSource: false
  // How far the copy has given way to something else that shows where the
  // item is going, 0 to 1. It fades out as it does.
  property real fade: 0
  // How far it has shrunk toward its dragging size, 0 to 1. At full size it is
  // solid, since it stands for the real window; it turns see-through only as
  // it shrinks.
  readonly property real shrunk: {
    var small = source && source.dragScale !== undefined ? source.dragScale : 0.2
    return small < 1 ? Math.max(0, Math.min(1, (1 - itemScale) / (1 - small))) : 1
  }

  // While set, the item at full size is kept inside this rect, the way its
  // window is kept on the screen. Let go of it and the item slides back to
  // the spot under the pointer it was picked up by.
  property rect bounds: Qt.rect(0, 0, 0, 0)
  readonly property bool bounded: bounds.width > 0 && bounds.height > 0
  // How much of the item is kept showing inside the bounds when it hangs off
  // their sides or bottom, and how far below their top its own top is kept.
  // Negative keeps the whole item inside.
  property real keepShowing: -1
  property real keepTop: 0
  // While it is kept to the bounds, how solid the part of it inside them is,
  // and the part that hangs outside.
  property real solid: 1
  property real faint: 1
  // How far that has taken hold, 0 to 1, so it comes and goes without a jump.
  property real split: bounded ? 1 : 0
  Behavior on split {
    NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic }
  }
  // The bounds, remembered while that fades back out.
  property rect splitArea: Qt.rect(0, 0, 0, 0)
  // How solid it is carried, before any of that.
  readonly property real carriedOpacity: (1 - (1 - 0.29) * shrunk) * (1 - fade)
  readonly property real outsideOpacity: carriedOpacity * (1 + (faint - 1) * split)
  readonly property real outsideBorder: (1 - fade) * (1 + (faint - 1) * split)
  // What a second copy drawn over the first adds, to come to this much.
  function added(under, wanted) {
    return under < 1 ? Math.max(0, 1 - (1 - wanted) / (1 - under)) : 0
  }
  // How far it is held off the pointer by the bounds.
  property real offsetX: 0
  property real offsetY: 0

  function keepInside() {
    // Read from bounds itself: when bounds is cleared, this runs before
    // bounded has caught up, and would clamp to an empty rect at the corner.
    if (!(bounds.width > 0 && bounds.height > 0) || !source) return
    slideBack.stop()
    var left = position.x - grab.x, top = position.y - grab.y
    var least = Qt.point(bounds.x, bounds.y)
    var most = Qt.point(bounds.x + bounds.width - source.width, bounds.y + bounds.height - source.height)
    if (keepShowing >= 0) {
      least = Qt.point(bounds.x + keepShowing - source.width, bounds.y + keepTop)
      most = Qt.point(bounds.x + bounds.width - keepShowing, bounds.y + bounds.height - keepShowing)
    }
    offsetX = Math.max(least.x, Math.min(most.x, left)) - left
    offsetY = Math.max(least.y, Math.min(most.y, top)) - top
  }
  onPositionChanged: keepInside()
  onBoundsChanged: {
    if (bounds.width > 0 && bounds.height > 0) splitArea = bounds
    keepInside()
  }
  onBoundedChanged: if (!bounded && (offsetX !== 0 || offsetY !== 0)) slideBack.restart()
  onSourceChanged: {
    slideBack.stop()
    offsetX = 0
    offsetY = 0
  }

  ParallelAnimation {
    id: slideBack
    NumberAnimation { target: ghost; property: "offsetX"; to: 0; duration: Style.duration(180); easing.type: Easing.OutCubic }
    NumberAnimation { target: ghost; property: "offsetY"; to: 0; duration: Style.duration(180); easing.type: Easing.OutCubic }
  }

  anchors.fill: parent
  visible: !!source

  ShaderEffectSource {
    id: copy
    sourceItem: ghost.source
    hideSource: !ghost.keepSource
    width: ghost.source ? ghost.source.width : 0
    height: ghost.source ? ghost.source.height : 0
    x: ghost.position.x - ghost.grab.x + ghost.offsetX
    y: ghost.position.y - ghost.grab.y + ghost.offsetY
    // Small and see-through, so the workspace it's over can be seen. It shrinks
    // toward the spot it was picked up by, which stays under the pointer. Just
    // under 30%, because Hyprland blurs behind anything above that on glassy.
    opacity: ghost.outsideOpacity
    transform: Scale {
      origin.x: ghost.grab.x
      origin.y: ghost.grab.y
      xScale: ghost.itemScale
      yScale: ghost.itemScale
    }
  }

  // Its border, drawn apart so it stays thin and solid at any size and opacity.
  Rectangle {
    id: outline
    x: ghost.position.x - ghost.grab.x * ghost.itemScale + ghost.offsetX
    y: ghost.position.y - ghost.grab.y * ghost.itemScale + ghost.offsetY
    width: ghost.source ? ghost.source.width * ghost.itemScale : 0
    height: ghost.source ? ghost.source.height * ghost.itemScale : 0
    radius: Math.min(Style.cornerRadius, height / 2)
    color: "transparent"
    border.width: 1
    border.color: Commons.Color.accent
    opacity: ghost.outsideBorder
  }

  // The part of it inside the bounds, drawn again over the above so that the
  // two come to how solid it is there.
  Item {
    visible: ghost.split > 0 && !!ghost.source
    x: ghost.splitArea.x
    y: ghost.splitArea.y
    width: ghost.splitArea.width
    height: ghost.splitArea.height
    clip: true

    ShaderEffectSource {
      sourceItem: ghost.source
      x: copy.x - ghost.splitArea.x
      y: copy.y - ghost.splitArea.y
      width: copy.width
      height: copy.height
      opacity: ghost.added(ghost.outsideOpacity, ghost.carriedOpacity * (1 + (ghost.solid - 1) * ghost.split))
      transform: Scale {
        origin.x: ghost.grab.x
        origin.y: ghost.grab.y
        xScale: ghost.itemScale
        yScale: ghost.itemScale
      }
    }

    Rectangle {
      x: outline.x - ghost.splitArea.x
      y: outline.y - ghost.splitArea.y
      width: outline.width
      height: outline.height
      radius: outline.radius
      color: "transparent"
      border.width: 1
      border.color: Commons.Color.accent
      opacity: ghost.added(ghost.outsideBorder, (1 - ghost.fade) * (1 + (ghost.solid - 1) * ghost.split))
    }
  }
}
