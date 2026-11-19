import QtQuick
import QtQuick.Shapes
import qs.Commons

// The favorite star beside an app: faded grey, white under the pointer, gold
// once the app is a favorite. Clicking it toggles the favorite. The same file
// ships in omarchy-dtp-app-list and omarchy-dtp-menu.
Item {
  id: star

  property bool favorited: false
  property real size: Style.font.body
  // Extra room around the star that still takes the click.
  property real hitMargin: Math.round(star.size / 3)
  readonly property bool hovered: mouse.containsMouse

  readonly property color idleColor: Qt.rgba(0.62, 0.62, 0.62, 0.45)
  readonly property color hoverColor: "#ffffff"
  readonly property color goldColor: "#f5c211"
  readonly property color tint: star.favorited ? star.goldColor : star.hovered ? star.hoverColor : star.idleColor

  signal toggled()

  width: size
  height: size

  // Ten points around the middle, alternating outer and inner radius, from
  // the top point clockwise. Pulled down a little so it sits optically level
  // with text beside it.
  readonly property var points: {
    var list = []
    var cx = star.width / 2
    var cy = star.height / 2 + star.height * 0.04
    var outer = star.width / 2
    var inner = outer * 0.45
    for (var i = 0; i <= 10; i++) {
      var r = i % 2 === 0 ? outer : inner
      var a = -Math.PI / 2 + i * Math.PI / 5
      list.push(Qt.point(cx + r * Math.cos(a), cy + r * Math.sin(a)))
    }
    return list
  }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: star.tint
      Behavior on fillColor { ColorAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
      PathPolyline { path: star.points }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    anchors.margins: -star.hitMargin
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: function(event) {
      event.accepted = true
      star.toggled()
    }
  }
}
