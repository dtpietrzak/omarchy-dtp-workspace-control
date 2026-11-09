import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Commons as Commons

// A preview of one workspace and a list of its windows. The list comes from
// live data and is there at once. The preview's space is held for it, and it
// fades in once Hyprland has said where the windows are and their first frames
// have arrived.
Item {
  id: root

  property int workspaceId: -1
  property var monitor: null
  property real screenWidth: 0
  property real screenHeight: 0
  property bool previewOnTop: true

  // What drags report positions in.
  property Item dragSpace: null
  // The thumbnail or list row being dragged.
  property Item dragItem: null

  signal windowChosen(var toplevel)
  signal dragMoved(real x, real y)
  signal dragDropped(var toplevel, int fromId)
  signal dragCanceled()

  // Where the item was picked up, so it stays under the pointer at that spot.
  property point grabPoint: Qt.point(0, 0)

  function moveDrag(area, item, mouse, pressPoint) {
    var dx = mouse.x - pressPoint.x
    var dy = mouse.y - pressPoint.y
    if (dragItem !== item && dx * dx + dy * dy < 36) return
    if (dragItem !== item) grabPoint = pressPoint
    dragItem = item
    var point = area.mapToItem(dragSpace, mouse.x, mouse.y)
    dragMoved(point.x, point.y)
  }

  // True when this release ended a drag rather than being a click.
  function endDrag(item) {
    if (dragItem !== item) return false
    dragDropped(item.modelData, workspaceId)
    dragItem = null
    return true
  }

  function cancelDrag(item) {
    if (dragItem !== item) return
    dragCanceled()
    dragItem = null
  }

  WorkspaceApps { id: workspaceApps }

  // Address -> Hyprland's own record of the window, plus its place in the stack.
  property var clients: ({})
  property bool clientsKnown: false
  property bool previewReady: false
  // Thumbnail under the pointer. It keeps full opacity and every other one dims.
  property Item hoverTile: null

  readonly property int iconSize: Math.round(Style.font.body * 1.5)
  readonly property int edge: Style.spacing.md

  // Topmost first, once Hyprland has said what the stack is.
  readonly property var windows: {
    var known = clients
    var values = Hyprland.toplevels.values
    var found = []
    for (var i = 0; i < values.length; i++) {
      if (values[i].workspace && values[i].workspace.id === workspaceId) found.push(values[i])
    }
    function place(toplevel) {
      var client = known[workspaceApps.windowAddress(toplevel)]
      return client ? client.stackIndex : 0
    }
    return found.sort(function(a, b) { return place(b) - place(a) })
  }

  function load() {
    if (!reader.running) reader.running = true
    giveUp.restart()
  }

  function checkPreview() {
    if (!clientsKnown || previewReady) return
    for (var i = 0; i < tiles.count; i++) {
      var tile = tiles.itemAt(i)
      if (!tile || (tile.placed && !tile.hasContent)) return
    }
    previewReady = true
  }

  onWorkspaceIdChanged: {
    previewReady = false
    clientsKnown = false
    load()
  }
  Component.onCompleted: load()

  Process {
    id: reader
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var list = JSON.parse(text)
          var next = {}
          for (var i = 0; i < list.length; i++) {
            list[i].stackIndex = i
            next[list[i].address] = list[i]
          }
          root.clients = next
          root.clientsKnown = true
          Qt.callLater(root.checkPreview)
        } catch (e) {
          console.warn("workspace control: could not read the windows:", e)
        }
      }
    }
  }

  // Better a preview with a window still blank than none at all.
  Timer {
    id: giveUp
    interval: 1000
    onTriggered: root.previewReady = root.clientsKnown
  }

  readonly property int gap: 4

  implicitHeight: previewFrame.height + gap + windowRows.height

  Item {
    anchors.fill: parent

    Rectangle {
      id: previewFrame
      y: root.previewOnTop ? 0 : windowRows.height + root.gap
      width: parent.width
      height: root.screenWidth > 0 ? Math.round(width * root.screenHeight / root.screenWidth) : 0
      radius: Style.cornerRadius
      color: Style.normalFill
      border.width: Style.spacing.hairline
      border.color: Style.normalBorderColor

      Item {
        id: preview
        anchors.fill: parent
        readonly property real ratio: root.screenWidth > 0 ? width / root.screenWidth : 0

        opacity: root.previewReady ? 1 : 0
        Behavior on opacity {
          NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
        }

        Repeater {
          id: tiles
          model: ScriptModel { values: root.windows }
          onItemAdded: Qt.callLater(root.checkPreview)

          delegate: Item {
            id: tile
            required property var modelData
            readonly property var client: root.clients[workspaceApps.windowAddress(modelData)] || null
            readonly property bool placed: !!client && !client.hidden
            readonly property bool hasContent: shot.hasContent
            readonly property real dragScale: 0.2

            onHasContentChanged: root.checkPreview()
            Component.onDestruction: {
              if (root.hoverTile === tile) root.hoverTile = null
              root.cancelDrag(tile)
            }

            visible: placed
            x: placed ? (client.at[0] - (root.monitor ? root.monitor.x : 0)) * preview.ratio : 0
            y: placed ? (client.at[1] - (root.monitor ? root.monitor.y : 0)) * preview.ratio : 0
            width: placed ? Math.max(2, client.size[0] * preview.ratio) : 0
            height: placed ? Math.max(2, client.size[1] * preview.ratio) : 0
            z: placed ? (client.floating ? 1000 : 0) + client.stackIndex : 0
            opacity: root.hoverTile && root.hoverTile !== tile ? 0.5 : 1
            Behavior on opacity {
              NumberAnimation { duration: Style.duration(300); easing.type: Easing.OutCubic }
            }

            ClippingRectangle {
              anchors.fill: parent
              color: Commons.Color.background
              radius: Style.cornerRadius

              ScreencopyView {
                id: shot
                anchors.fill: parent
                captureSource: tile.modelData.wayland
                live: true
                constraintSize: Qt.size(Math.ceil(tile.width * 2), Math.ceil(tile.height * 2))
              }
            }

            Rectangle {
              anchors.fill: parent
              visible: root.hoverTile === tile
              color: "transparent"
              radius: Style.cornerRadius
              border.width: 1
              border.color: Commons.Color.accent
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
              property point pressPoint
              onContainsMouseChanged: if (!containsMouse && root.hoverTile === tile) root.hoverTile = null
              onPressed: mouse => pressPoint = Qt.point(mouse.x, mouse.y)
              onPositionChanged: mouse => {
                if (pressed) root.moveDrag(this, tile, mouse, pressPoint)
                else root.hoverTile = tile
              }
              onReleased: {
                if (!root.endDrag(tile) && containsMouse) root.windowChosen(tile.modelData)
              }
              onCanceled: root.cancelDrag(tile)
            }
          }
        }
      }
    }

    Column {
      id: windowRows
      y: root.previewOnTop ? previewFrame.height + root.gap : 0
      width: parent.width

      Repeater {
        model: ScriptModel { values: root.windows }

        delegate: Item {
          id: row
          required property var modelData
          readonly property string appId: workspaceApps.appIdOf(modelData)
          readonly property real dragScale: 0.5

          Component.onDestruction: root.cancelDrag(row)

          width: parent ? parent.width : 0
          height: Math.max(root.iconSize, title.implicitHeight) + root.edge

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            // A row being dragged leaves the card, so it brings a backing along.
            color: root.dragItem === row ? Commons.Color.background
              : rowMouse.containsMouse || closeButton.hovered ? Style.hoverFill : "transparent"
            border.width: rowMouse.containsMouse || closeButton.hovered ? 1 : 0
            border.color: Commons.Color.accent
          }

          AppMark {
            id: icon
            anchors.left: parent.left
            anchors.leftMargin: root.edge
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
              if (!root.endDrag(row) && containsMouse) root.windowChosen(row.modelData)
            }
            onCanceled: root.cancelDrag(row)
          }

          CloseButton {
            id: closeButton
            anchors.right: parent.right
            anchors.rightMargin: root.edge / 2
            anchors.verticalCenter: parent.verticalCenter
            size: root.iconSize
            onClicked: workspaceApps.closeWindow(row.modelData)
          }
        }
      }
    }
  }
}
