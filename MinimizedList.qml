import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// The windows waiting on Omarchy's minimized workspace.
Item {
  id: root

  required property var windows

  // What drags report positions in.
  property Item dragSpace: null
  // The row being dragged, and the spot on it the pointer picked up.
  property Item dragItem: null
  property point grabPoint: Qt.point(0, 0)

  signal restore(var toplevel)
  signal close(var toplevel)
  signal dragMoved(real x, real y)
  signal dragDropped(var toplevel)
  signal dragCanceled()

  function moveDrag(area, item, mouse, pressPoint) {
    var dx = mouse.x - pressPoint.x
    var dy = mouse.y - pressPoint.y
    if (dragItem !== item && dx * dx + dy * dy < 36) return
    if (dragItem !== item) grabPoint = pressPoint
    dragItem = item
    var point = area.mapToItem(dragSpace, mouse.x, mouse.y)
    dragMoved(point.x, point.y)
  }

  function endDrag(item) {
    if (dragItem !== item) return false
    dragDropped(item.modelData)
    dragItem = null
    return true
  }

  function cancelDrag(item) {
    if (dragItem !== item) return
    dragCanceled()
    dragItem = null
  }

  WorkspaceApps { id: workspaceApps }

  readonly property int iconSize: Math.round(Style.font.body * 1.5)
  readonly property int edge: Style.spacing.md

  implicitWidth: Style.space(320)
  implicitHeight: windows.length > 0 ? rows.implicitHeight : empty.implicitHeight + edge

  Text {
    id: empty
    visible: root.windows.length === 0
    anchors.left: parent.left
    anchors.leftMargin: root.edge
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: "No minimized windows"
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  Column {
    id: rows
    width: parent.width

    Repeater {
      model: ScriptModel { values: root.windows }

      delegate: Item {
        id: row
        required property var modelData
        readonly property string appId: workspaceApps.appIdOf(modelData)
        readonly property bool hot: rowMouse.containsMouse || closeButton.hovered || restoreButton.hovered
        readonly property real dragScale: 0.5

        Component.onDestruction: root.cancelDrag(row)

        width: parent ? parent.width : 0
        height: Math.max(root.iconSize, title.implicitHeight) + root.edge

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          // A row being dragged leaves the card, so it brings a backing along.
          color: root.dragItem === row ? Commons.Color.background : row.hot ? Style.hoverFill : "transparent"
          border.width: row.hot ? 1 : 0
          border.color: Commons.Color.accent
        }

        AppMark {
          id: icon
          anchors.left: restoreButton.right
          anchors.leftMargin: root.edge / 2
          anchors.verticalCenter: parent.verticalCenter
          size: root.iconSize
          source: workspaceApps.iconFor(row.appId)
          letter: workspaceApps.letterFor(row.appId)
          letterColor: Commons.Color.foreground
        }

        Text {
          id: title
          anchors.left: icon.right
          anchors.leftMargin: root.edge
          anchors.right: closeButton.left
          anchors.rightMargin: root.edge
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: row.modelData.title || row.appId
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
          property point pressPoint
          onPressed: mouse => pressPoint = Qt.point(mouse.x, mouse.y)
          onPositionChanged: mouse => { if (pressed) root.moveDrag(this, row, mouse, pressPoint) }
          onReleased: {
            if (!root.endDrag(row) && containsMouse) root.restore(row.modelData)
          }
          onCanceled: root.cancelDrag(row)
        }

        CloseButton {
          id: restoreButton
          anchors.left: parent.left
          anchors.leftMargin: root.edge / 2
          anchors.verticalCenter: parent.verticalCenter
          size: root.iconSize
          glyph: "󰅃"
          onClicked: root.restore(row.modelData)
        }

        CloseButton {
          id: closeButton
          anchors.right: parent.right
          anchors.rightMargin: root.edge / 2
          anchors.verticalCenter: parent.verticalCenter
          size: root.iconSize
          onClicked: root.close(row.modelData)
        }
      }
    }
  }
}
