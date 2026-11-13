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
    // Before the drag is taken up, so a thumbnail picked up over the preview
    // never starts to shrink.
    carry(area, item, mouse)
    dragItem = item
    var point = area.mapToItem(dragSpace, mouse.x, mouse.y)
    dragMoved(point.x, point.y)
  }

  // True when this release ended a drag rather than being a click.
  function endDrag(item) {
    if (dragItem !== item) return false
    settleCarried(item)
    dropMoves = false
    dragDropped(item.modelData, workspaceId)
    dragItem = null
    overPreview = false
    onDesktop = false
    // Sent to another workspace, it stays hidden until it is there.
    if (dropMoves) rowHider.showAfterMove()
    else rowHider.show()
    dropMoves = false
    return true
  }

  function cancelDrag(item) {
    if (dragItem !== item) return
    settleCarried(item)
    dragCanceled()
    dragItem = null
    overPreview = false
    onDesktop = false
    rowHider.show()
  }

  // Over the preview, a floating window's real window goes where its thumbnail
  // is carried, the same spot on the screen as the thumbnail's spot in the
  // preview, and the thumbnail keeps its size. Off the preview it shrinks and
  // the window waits where it is, for a drop on a workspace to send it there.
  property bool overPreview: false
  // The preview, in the coordinates drags report in, which a thumbnail carried
  // over it is kept inside, as its window is kept on the screen.
  property rect previewArea: Qt.rect(0, 0, 0, 0)
  property var carried: null
  property var lastCarried: null

  // Hyprland's record of the window a thumbnail or a row is for, and that
  // window's thumbnail.
  function clientOf(item) {
    return item.client !== undefined ? item.client : (clients[workspaceApps.windowAddress(item.modelData)] || null)
  }
  function tileOf(toplevel) {
    for (var i = 0; i < tiles.count; i++) {
      var tile = tiles.itemAt(i)
      if (tile && tile.modelData === toplevel) return tile
    }
    return null
  }

  // A row carried over the preview, or out over the desktop, is carried as
  // its window's thumbnail, held by its middle, and from there on acts the
  // same as if the thumbnail had been picked up.
  property bool onDesktop: false
  readonly property Item ghostItem: {
    var item = dragItem
    if (!item || item.client !== undefined || (!overPreview && !onDesktop)) return item
    var tile = tileOf(item.modelData)
    return tile && tile.placed ? tile : item
  }
  readonly property point ghostGrab: ghostItem && ghostItem !== dragItem
    ? Qt.point(ghostItem.width / 2, ghostItem.height / 2) : grabPoint

  function carry(area, item, mouse) {
    var client = clientOf(item)
    var inPreview = area.mapToItem(preview, mouse.x, mouse.y)
    var inside = inPreview.x >= 0 && inPreview.y >= 0 && inPreview.x <= preview.width && inPreview.y <= preview.height
    overPreview = inside && !!client && !!client.floating && !!monitor && preview.ratio > 0
    if (!overPreview) return
    var corner = preview.mapToItem(dragSpace, 0, 0)
    previewArea = Qt.rect(corner.x, corner.y, preview.width, preview.height)
    var width = client.size[0], height = client.size[1]
    // A thumbnail by the spot it was picked up by, a row by its window's middle.
    var isRow = item.client === undefined
    var heldX = isRow ? width * preview.ratio / 2 : grabPoint.x
    var heldY = isRow ? height * preview.ratio / 2 : grabPoint.y
    raiseCarried(workspaceApps.windowAddress(item.modelData))
    carried = {
      address: workspaceApps.windowAddress(item.modelData),
      x: Math.round(monitor.x + Math.max(0, Math.min(screenWidth - width, (inPreview.x - heldX) / preview.ratio))),
      y: Math.round(monitor.y + Math.max(0, Math.min(screenHeight - height, (inPreview.y - heldY) / preview.ratio)))
    }
    if (!carryTimer.running) carryTimer.start()
  }

  // Where the drag is, as only whoever owns the card can tell. away is off
  // the card and onto the bar, headed for another workspace: there a row's
  // window leaves the screen, and its thumbnail the preview, to show it would
  // go. Over the card, where letting go leaves it be, it stays. boxed is while
  // a landing box on the screen stands in for a window that is on it, a
  // thumbnail's as much as a row's, which leaves the screen for that too.
  function setAway(away, boxed, overDesktop) {
    if (!dragItem) return
    onDesktop = overDesktop
    var isRow = dragItem.client === undefined
    if (boxed || (isRow && away)) rowHider.hide(workspaceApps.windowAddress(dragItem.modelData))
    else rowHider.show()
  }

  // A real window being carried is above every other window from the moment
  // it first moves, as it will be once it is let go. Once for each drag.
  property string raisedAddress: ""
  onDragItemChanged: if (!dragItem) raisedAddress = ""
  function raiseCarried(address) {
    if (address === "" || address === raisedAddress) return
    raisedAddress = address
    Hyprland.dispatch('hl.dsp.window.alter_zorder({ mode = "top", window = "address:' + address + '" })')
  }

  function sendCarried() {
    var move = carried
    carried = null
    if (!move || move.address === "") return
    lastCarried = move
    Hyprland.dispatch('hl.dsp.window.move({ x = ' + move.x + ', y = ' + move.y + ', window = "address:' + move.address + '" })')
  }

  // The last spot goes out at once, the thumbnail shows it until Hyprland
  // says the window is there, and the windows are read again.
  function settleCarried(item) {
    carryTimer.stop()
    sendCarried()
    var moved = item.client !== undefined ? item : tileOf(item.modelData)
    if (lastCarried && moved && lastCarried.address === workspaceApps.windowAddress(item.modelData))
      moved.movedTo = Qt.point(lastCarried.x, lastCarried.y)
    lastCarried = null
    rereadAfterMove.restart()
  }

  // Moves go out at most every 30ms, the latest spot each time.
  Timer {
    id: carryTimer
    interval: 30
    onTriggered: root.sendCarried()
  }

  Timer {
    id: rereadAfterMove
    interval: 80
    onTriggered: root.load()
  }

  WorkspaceApps { id: workspaceApps }
  WindowHider { id: rowHider }
  // Set by whoever handles dragDropped, when the drop sends the window to
  // another workspace.
  property bool dropMoves: false

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
            // Where a drag just sent the real window, until Hyprland says it is
            // there. Without it the thumbnail shows the old spot first.
            property var movedTo: null
            readonly property real atX: movedTo ? movedTo.x : (placed ? client.at[0] : 0)
            readonly property real atY: movedTo ? movedTo.y : (placed ? client.at[1] : 0)
            onClientChanged: if (movedTo && placed && Math.abs(client.at[0] - movedTo.x) < 2 && Math.abs(client.at[1] - movedTo.y) < 2) movedTo = null
            Timer {
              // In case Hyprland put it somewhere a little different.
              running: !!tile.movedTo
              interval: 1000
              onTriggered: tile.movedTo = null
            }

            onHasContentChanged: root.checkPreview()
            Component.onDestruction: {
              if (root.hoverTile === tile) root.hoverTile = null
              root.cancelDrag(tile)
            }

            // Out of the preview while its row is carried off onto the bar, and
            // after it is dropped on another workspace, until it has gone there.
            readonly property bool carriedAway: rowHider.address !== "" && rowHider.address === workspaceApps.windowAddress(tile.modelData)
            visible: placed && !carriedAway
            readonly property real freeX: placed ? (atX - (root.monitor ? root.monitor.x : 0)) * preview.ratio : 0
            readonly property real freeY: placed ? (atY - (root.monitor ? root.monitor.y : 0)) * preview.ratio : 0
            // Drawn wholly in the preview even when its window hangs off the screen.
            x: Math.max(0, Math.min(preview.width - width, freeX))
            y: Math.max(0, Math.min(preview.height - height, freeY))
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

          // Out of the list while it is carried as its window's thumbnail.
          opacity: root.dragItem === row && root.ghostItem !== row ? 0 : 1
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
