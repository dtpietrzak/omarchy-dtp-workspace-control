import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A band along the bottom of the screen with one mini view per workspace.
// hypr/workspace-control.lua reports four finger vertical swipes as custom
// Hyprland events; everything else happens here.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Share of the way the panel has to travel for a release to commit.
  readonly property real commitAt: 0.2
  readonly property int slots: 10

  // 0 is off the bottom of the screen, 1 is resting in place.
  property real progress: 0
  property bool opened: false

  property bool swiping: false
  property real swipeBase: 0
  property var scr: null

  readonly property bool shown: progress > 0 || opened || settle.running

  readonly property int sw: scr ? scr.width : 0
  readonly property int sh: scr ? scr.height : 0
  readonly property var monitor: scr ? Hyprland.monitorFor(scr) : null
  readonly property int activeId: monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1

  function blockOf(id) { return Math.floor((id - 1) / slots) }
  function slotOf(id) { return (id - 1) % slots + 1 }

  // The same list the bar shows: the first five of this monitor's own, any of
  // the rest that exist, then workspaces visiting from an unplugged monitor.
  readonly property var workspaceIds: {
    if (activeId <= 0) return []
    var block = blockOf(activeId)
    var base = block * slots
    var ids = [base + 1, base + 2, base + 3, base + 4, base + 5]
    var guests = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id <= 0) continue
      if (blockOf(id) === block) {
        if (ids.indexOf(id) === -1) ids.push(id)
      } else if (values[i].monitor && monitor && values[i].monitor.name === monitor.name) {
        guests.push(id)
      }
    }
    ids.sort(function(a, b) { return a - b })
    guests.sort(function(a, b) { return a - b })
    return ids.concat(guests)
  }

  readonly property int bandPadding: Style.spacing.huge
  readonly property int cardGap: Style.spacing.xxl
  readonly property int cardW: {
    var count = Math.max(1, workspaceIds.length)
    var fit = (sw - bandPadding * 2 - cardGap * (count - 1)) / count
    return Math.max(1, Math.floor(Math.min(sw * 0.2, fit)))
  }
  readonly property int cardH: sw > 0 ? Math.round(cardW * sh / sw) : 1
  readonly property int bandH: cardH + bandPadding * 2
  // Where the band stops: on the bottom edge, or on top of a bar that is there.
  // Hyprland reports the space a bottom bar reserves, and 0 for a bar elsewhere.
  readonly property int bottomGap: {
    var ipc = monitor ? monitor.lastIpcObject : null
    return ipc && ipc.reserved ? ipc.reserved[3] : 0
  }
  readonly property real restY: sh - bandH - bottomGap
  readonly property real travel: Math.max(1, sh - restY)

  // Window being dragged, and the cursor in window coordinates.
  property Item dragTile: null
  property point dragPos: Qt.point(0, 0)
  property int hoverId: -1

  NumberAnimation {
    id: settle
    target: root
    property: "progress"
    easing.type: Easing.OutCubic
  }

  function animateTo(value, ms) {
    settle.stop()
    settle.from = progress
    settle.to = value
    settle.duration = Style.duration(ms)
    settle.start()
  }

  function ensureScreen() {
    if (!shown || !scr) scr = panel.focusedScreen()
    syncWindows()
  }

  function open() {
    ensureScreen()
    opened = true
    animateTo(1, 220)
  }

  function close() {
    // Whatever is showing now has to survive the keyboard going back.
    if (opened) holdWorkspace(activeId)
    opened = false
    dragTile = null
    hoverId = -1
    animateTo(0, 140)
  }

  function toggle() {
    if (opened) close()
    else open()
  }

  function swipeBegin() {
    ensureScreen()
    settle.stop()
    swiping = true
    swipeBase = progress
  }

  function swipeMove(pixels) {
    if (!swiping) return
    // Fingers moving up report a negative delta.
    progress = Math.max(0, Math.min(1, swipeBase - pixels / travel))
  }

  function swipeEnd(cancelled) {
    if (!swiping) return
    swiping = false
    var moved = progress - swipeBase
    if (opened) {
      if (!cancelled && -moved >= commitAt) close()
      else open()
    } else {
      if (!cancelled && moved >= commitAt) open()
      else close()
    }
  }

  function jump(id) {
    close()
    holdWorkspace(id)
  }

  // Closing the panel makes Hyprland refocus the window that had the keyboard,
  // more than once, and that switches to that window's workspace. So the switch
  // waits for the panel's surface to close, and goes last.
  function holdWorkspace(id) {
    heldId = id
    handBack.restart()
  }

  function goToHeld() {
    handBack.stop()
    var id = heldId
    heldId = -1
    if (id <= 0) return
    if (blockOf(id) === blockOf(activeId) && monitor) {
      Hyprland.dispatch('o.workspaces.focus(' + slotOf(id) + ', "' + monitor.name + '")')
    } else {
      Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })')
    }
  }

  // 1-9 are those slots on this monitor and 0 is slot 10, as with Super+number.
  function pressNumber(key) {
    var slot = key === Qt.Key_0 ? 10 : key - Qt.Key_0
    var id = blockOf(activeId) * slots + slot
    if (workspaceIds.indexOf(id) !== -1) jump(id)
  }

  function windowAddress(toplevel) {
    var address = String(toplevel && toplevel.address || "")
    if (address !== "" && address.indexOf("0x") !== 0) address = "0x" + address
    return /^0x[0-9a-f]+$/i.test(address) ? address : ""
  }

  function moveWindow(toplevel, id) {
    var address = windowAddress(toplevel)
    if (address === "") return
    Hyprland.dispatch('hl.dsp.window.move({ workspace = "' + id + '", follow = false, window = "address:' + address + '" })')
    // A moved window keeps its old place in the stack, so it has to be raised.
    Hyprland.dispatch('hl.dsp.window.alter_zorder({ mode = "top", window = "address:' + address + '" })')
    refresh.restart()
  }

  function syncWindows() {
    Hyprland.refreshToplevels()
    if (stackReader.running) refresh.restart()
    else stackReader.running = true
  }

  // Address -> position in Hyprland's stack, bottom first. Only hyprctl's window
  // list is in stacking order.
  property var stackOrder: ({})

  Process {
    id: stackReader
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var clients = JSON.parse(text)
          var order = {}
          for (var i = 0; i < clients.length; i++) order[clients[i].address] = i
          root.stackOrder = order
        } catch (e) {
          console.warn("workspace control: could not read the window stack:", e)
        }
      }
    }
  }

  function windowsOn(id) {
    var values = Hyprland.toplevels.values
    var found = []
    for (var i = 0; i < values.length; i++) {
      if (values[i].workspace && values[i].workspace.id === id) found.push(values[i])
    }
    return found
  }

  function cardAt(x, y) {
    var point = cards.mapFromItem(panel.contentItem, x, y)
    var card = cards.childAt(point.x, point.y)
    return card && card.wsId !== undefined ? card : null
  }

  // The mini view of the topmost real window at this screen position.
  function tileAt(x, y) {
    if (!monitor) return null
    var px = x + monitor.x
    var py = y + monitor.y
    var best = null
    for (var c = 0; c < cards.children.length; c++) {
      var card = cards.children[c]
      if (card.wsId !== activeId) continue
      for (var i = 0; i < card.tiles.count; i++) {
        var tile = card.tiles.itemAt(i)
        if (!tile || !tile.placed) continue
        var at = tile.ipc.at
        var size = tile.ipc.size
        if (px < at[0] || py < at[1] || px >= at[0] + size[0] || py >= at[1] + size[1]) continue
        if (!best || tile.z > best.z) best = tile
      }
    }
    return best
  }

  function dragTo(tile, x, y) {
    dragTile = tile
    dragPos = Qt.point(x, y)
    var card = cardAt(x, y)
    hoverId = card ? card.wsId : -1
  }

  // Ending a drag on the touchpad also sends a click at the drop point, a
  // millisecond after the release. It must not count as clicking that spot.
  property real droppedAt: 0
  function justDropped() { return Date.now() - droppedAt < 200 }

  function clickWorkspace(id) {
    if (!justDropped()) jump(id)
  }

  function drop() {
    droppedAt = Date.now()
    var tile = dragTile
    var target = hoverId
    dragTile = null
    hoverId = -1
    if (tile && target > 0 && target !== tile.wsId) moveWindow(tile.modelData, target)
  }

  property int heldId: -1
  readonly property string layerNamespace: "dtpietrzak-workspacecontrol"

  // In case the close event never arrives.
  Timer {
    id: handBack
    interval: 500
    onTriggered: root.goToHeld()
  }

  Timer {
    id: refresh
    interval: 40
    onTriggered: root.syncWindows()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "custom") {
        var data = String(event.data)
        if (data === "dtpwc:begin") root.swipeBegin()
        else if (data.indexOf("dtpwc:move ") === 0) root.swipeMove(Number(data.slice(11)))
        else if (data.indexOf("dtpwc:end ") === 0) root.swipeEnd(data.slice(10) === "1")
        return
      }
      if (event.name === "closelayer" && String(event.data) === root.layerNamespace) {
        root.goToHeld()
        return
      }
      if (!root.shown) return
      switch (event.name) {
      case "openwindow": case "closewindow": case "movewindowv2": case "activewindowv2":
      case "changefloatingmode": case "fullscreen": case "workspacev2":
        refresh.restart()
      }
    }
  }

  OverlayWindow {
    id: panel
    shown: root.shown
    // OnDemand takes the keyboard without the pointer grab Exclusive brings.
    shownKeyboardFocus: root.opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: root.layerNamespace

    Item {
      anchors.fill: parent
      focus: true
      Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9
            && (event.modifiers & ~Qt.KeypadModifier) === 0) {
          root.pressNumber(event.key)
          event.accepted = true
        }
      }

      // Everything outside the band, above it and below it.
      Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.35 * root.progress
      }
      // The panel covers the desktop, so a real window can't be grabbed directly.
      // A press on one starts the same drag as its mini view. A click closes.
      MouseArea {
        anchors.fill: parent
        property Item pressedTile: null
        property point pressPoint

        onPressed: mouse => {
          pressPoint = Qt.point(mouse.x, mouse.y)
          pressedTile = root.tileAt(mouse.x, mouse.y)
        }
        onPositionChanged: mouse => {
          if (!pressedTile) return
          var dx = mouse.x - pressPoint.x
          var dy = mouse.y - pressPoint.y
          if (root.dragTile !== pressedTile && dx * dx + dy * dy < 36) return
          root.dragTo(pressedTile, mouse.x, mouse.y)
        }
        onReleased: {
          pressedTile = null
          if (root.dragTile) root.drop()
          else if (containsMouse && !root.justDropped()) root.close()
        }
        onCanceled: {
          pressedTile = null
          root.dragTile = null
          root.hoverId = -1
        }
      }

      Rectangle {
        id: band
        width: parent.width
        height: root.bandH
        y: root.sh + (root.restY - root.sh) * root.progress
        color: Util.alpha(Commons.Color.background, 0.94)

        // Keeps a click between two cards from closing the panel.
        MouseArea { anchors.fill: parent }

        Row {
          id: cards
          anchors.centerIn: parent
          spacing: root.cardGap

          Repeater {
            model: ScriptModel { values: root.workspaceIds }

            delegate: Rectangle {
              id: card
              required property var modelData
              readonly property int wsId: modelData
              property alias tiles: tileRepeater
              readonly property bool active: wsId === root.activeId
              readonly property bool hovered: root.hoverId === wsId && !!root.dragTile && root.dragTile.wsId !== wsId

              width: root.cardW
              height: root.cardH
              clip: true
              radius: Style.cornerRadius
              color: hovered ? Style.selectedAccentFill : (cardMouse.containsMouse ? Style.hoverFill : Style.normalFill)
              border.width: Math.max(1, Style.space(2))
              border.color: hovered || active ? Commons.Color.accent : Style.normalBorderColor

              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clickWorkspace(card.wsId)
              }

              Repeater {
                id: tileRepeater
                model: ScriptModel { values: root.windowsOn(card.wsId) }

                delegate: Item {
                  id: tile
                  required property var modelData
                  readonly property int wsId: card.wsId
                  readonly property var ipc: modelData.lastIpcObject || ({})
                  readonly property real ratio: root.sw > 0 ? root.cardW / root.sw : 0
                  readonly property int stackIndex: root.stackOrder[root.windowAddress(modelData)] || 0
                  readonly property bool placed: !!ipc.at && !!ipc.size && !ipc.hidden
                  readonly property string appClass: String(ipc["class"] || modelData.title || "?")

                  visible: placed
                  x: placed ? (ipc.at[0] - (root.monitor ? root.monitor.x : 0)) * ratio : 0
                  y: placed ? (ipc.at[1] - (root.monitor ? root.monitor.y : 0)) * ratio : 0
                  width: placed ? Math.max(2, ipc.size[0] * ratio) : 0
                  height: placed ? Math.max(2, ipc.size[1] * ratio) : 0
                  z: (ipc.floating ? 1000 : 0) + stackIndex

                  Component.onDestruction: if (root.dragTile === tile) root.dragTile = null

                  Rectangle {
                    anchors.fill: parent
                    color: Commons.Color.background
                    border.width: 1
                    border.color: Style.normalBorderColor
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !shot.hasContent
                    textFormat: Text.PlainText
                    text: tile.appClass.split(".").pop().slice(0, 1).toUpperCase()
                    color: Commons.Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Math.max(Style.font.caption, Math.min(tile.height * 0.5, Style.font.heading))
                  }

                  ScreencopyView {
                    id: shot
                    anchors.fill: parent
                    captureSource: root.shown ? tile.modelData.wayland : null
                    live: true
                    constraintSize: Qt.size(Math.ceil(tile.width * 2), Math.ceil(tile.height * 2))
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                    property point pressPoint

                    function inWindow(mouse) {
                      return mapToItem(panel.contentItem, mouse.x, mouse.y)
                    }

                    onPressed: mouse => pressPoint = Qt.point(mouse.x, mouse.y)
                    onPositionChanged: mouse => {
                      var dx = mouse.x - pressPoint.x
                      var dy = mouse.y - pressPoint.y
                      if (root.dragTile !== tile && dx * dx + dy * dy < 36) return
                      var point = inWindow(mouse)
                      root.dragTo(tile, point.x, point.y)
                    }
                    onReleased: {
                      if (root.dragTile === tile) root.drop()
                      else if (containsMouse) root.clickWorkspace(card.wsId)
                    }
                    onCanceled: if (root.dragTile === tile) root.dragTile = null
                  }
                }
              }

              Text {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Style.spacing.md
                z: 2000
                textFormat: Text.PlainText
                text: root.blockOf(card.wsId) === root.blockOf(root.activeId) ? root.slotOf(card.wsId) : card.wsId
                color: card.active ? Commons.Color.accent : Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: card.active
              }
            }
          }
        }
      }

      // The window under the cursor while it is being dragged.
      ShaderEffectSource {
        visible: !!root.dragTile
        sourceItem: root.dragTile
        hideSource: true
        width: root.dragTile ? root.dragTile.width : 0
        height: root.dragTile ? root.dragTile.height : 0
        x: root.dragPos.x - width / 2
        y: root.dragPos.y - height / 2
        opacity: 0.9
      }
    }
  }
}
