import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
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
    var ids = []
    for (var n = 1; n <= prefs.panelWorkspaces; n++) ids.push(base + n)
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
  readonly property int bandH: cardH + bandPadding + labels.implicitHeight + Style.spacing.md * 2
  // Where the band stops: on the bottom edge, or on top of a bar that is there.
  // Hyprland reports the space a bottom bar reserves, and 0 for a bar elsewhere.
  readonly property int bottomGap: {
    var ipc = monitor ? monitor.lastIpcObject : null
    return ipc && ipc.reserved ? ipc.reserved[3] : 0
  }
  readonly property real restY: sh - bandH - bottomGap
  // The band's background follows the bar's: opaque, glassy or none.
  readonly property color bandColor: workspaceApps.barBackground(shell ? shell.barConfig : null)
  readonly property real travel: Math.max(1, sh - restY)

  // Window being dragged, and the cursor in window coordinates.
  property Item dragTile: null
  property point dragPos: Qt.point(0, 0)
  property int hoverId: -1
  // Mini view under the pointer. It and the one being dragged stay at full
  // opacity with a border, and every other mini view dims.
  property Item hoverTile: null
  readonly property Item highlightTile: dragTile || hoverTile
  // Card under the pointer, when it isn't on one of the card's windows.
  property int hoverCardId: -1
  // Pointer is on the floating window list, or on the way up to it.
  readonly property bool overList: listHover.hovered || reachHover.hovered
  readonly property int pointedId: {
    if (dragTile) return -1
    if (hoverTile) return hoverTile.wsId
    if (hoverCardId > 0) return hoverCardId
    return overList ? listId : -1
  }
  // Follows the pointer, but lets go late so a wandering path between a card and
  // its list doesn't lose the list.
  property int listId: -1
  onPointedIdChanged: followPointer()
  onDragTileChanged: followPointer()
  function followPointer() {
    if (dragTile && dragTile.listRow) {
      // The row being dragged lives in the list, which has to stay.
      listLinger.stop()
    } else if (pointedId > 0) {
      listLinger.stop()
      listId = pointedId
    } else {
      listLinger.restart()
    }
  }
  // The workspace set for selection, which every other one fades behind. A drag
  // grabs the pointer, so during one the drag's position decides.
  readonly property int selectedId: dragTile || minimizedDrag ? hoverId : listId
  readonly property int fadeMs: 700

  // The selected workspace's windows, topmost first.
  readonly property var listWindows: {
    var order = stackOrder
    return windowsOn(listId).sort(function(a, b) {
      return (order[workspaceApps.windowAddress(b)] || 0) - (order[workspaceApps.windowAddress(a)] || 0)
    })
  }

  Timer {
    id: listLinger
    interval: 400
    onTriggered: root.listId = -1
  }

  WorkspaceApps { id: workspaceApps }
  WorkspaceSettings { id: prefs }

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
    popup = ""
    reorderLabel = null
    reorderInsert = -1
    hoverId = -1
    hoverTile = null
    hoverCardId = -1
    listLinger.stop()
    listId = -1
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
    var address = heldWindow
    heldId = -1
    heldWindow = ""
    if (id <= 0) return
    if (blockOf(id) === blockOf(activeId) && monitor) {
      workspaceApps.dispatchWithoutWarp('o.workspaces.focus(' + slotOf(id) + ', "' + monitor.name + '")')
    } else {
      workspaceApps.dispatchWithoutWarp('hl.dsp.focus({ workspace = "' + id + '" })')
    }
    workspaceApps.focusAddress(address)
  }

  // The swipe and the layer rules, which Hyprland forgets on every reload.
  function setUpHyprland() {
    var path = decodeURIComponent(String(Qt.resolvedUrl("hypr/workspace-control.lua")).replace(/^file:\/\//, ""))
    Hyprland.dispatch('(function() dofile(' + JSON.stringify(path) + ') end)')
  }

  Component.onCompleted: setUpHyprland()

  // 1-9 are those slots on this monitor and 0 is slot 10, as with Super+number.
  function pressNumber(key) {
    var slot = key === Qt.Key_0 ? 10 : key - Qt.Key_0
    var id = blockOf(activeId) * slots + slot
    if (workspaceIds.indexOf(id) !== -1) jump(id)
  }

  // The card open above the row, from the buttons at its ends: "settings",
  // "minimized", or none.
  property string popup: ""
  function togglePopup(name) { popup = popup === name ? "" : name }

  // A minimized window being dragged onto a workspace.
  readonly property Item minimizedDrag: minimizedPopup.item ? minimizedPopup.item.dragItem : null
  property point minimizedDragPos: Qt.point(0, 0)
  onMinimizedDragChanged: if (!minimizedDrag) hoverId = -1

  // Hotkeys and the swipe are registered with Hyprland, so changing them takes a
  // reload. A moment's wait lets the setting reach the file first.
  Timer {
    id: reloadForSetting
    interval: 200
    onTriggered: Quickshell.execDetached(["hyprctl", "reload"])
  }

  // The workspace being dragged along the row by its number, and where it would land.
  property Item reorderLabel: null
  readonly property int reorderId: reorderLabel ? reorderLabel.modelData : -1
  readonly property Item reorderCard: {
    for (var i = 0; reorderLabel && i < cards.children.length; i++) {
      if (cards.children[i].wsId === reorderId) return cards.children[i]
    }
    return null
  }
  property int reorderInsert: -1
  property point reorderPos: Qt.point(0, 0)
  property real reorderGrabX: 0
  property real reorderMarkerX: 0

  // The monitor's own cards, in row order. Only these can trade places.
  function ownCards() {
    var found = []
    for (var i = 0; i < cards.children.length; i++) {
      var card = cards.children[i]
      if (card.wsId !== undefined && blockOf(card.wsId) === blockOf(activeId)) found.push(card)
    }
    return found.sort(function(a, b) { return a.x - b.x })
  }

  function moveReorder(label, point) {
    if (blockOf(label.modelData) !== blockOf(activeId)) return
    reorderLabel = label
    reorderPos = point
    var own = ownCards()
    var index = own.length
    for (var i = 0; i < own.length; i++) {
      var left = cards.mapToItem(panel.contentItem, own[i].x, 0).x
      if (point.x < left + own[i].width / 2) {
        index = i
        break
      }
    }
    reorderInsert = index
    var gap = cardGap / 2
    reorderMarkerX = index < own.length
      ? cards.mapToItem(panel.contentItem, own[index].x, 0).x - gap
      : cards.mapToItem(panel.contentItem, own[own.length - 1].x + own[own.length - 1].width, 0).x + gap
  }

  function finishReorder() {
    var id = reorderId
    var insert = reorderInsert
    reorderLabel = null
    reorderInsert = -1
    droppedAt = Date.now()
    var ids = ownCards().map(function(card) { return card.wsId })
    var from = ids.indexOf(id)
    // Dropped back where it started.
    if (from < 0 || insert === from || insert === from + 1) return
    Hyprland.dispatch("(function() dtpwc_reorder({" + ids.join(",") + "}, " + (from + 1) + ", " + (insert + 1) + ") end)")
    refresh.restart()
  }

  function moveWindow(toplevel, id) {
    workspaceApps.moveWindow(toplevel, id)
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

  // Jump to a window's workspace and bring that window to the front there.
  function clickWindow(id, toplevel) {
    if (justDropped()) return
    jump(id)
    heldWindow = workspaceApps.windowAddress(toplevel)
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
  property string heldWindow: ""
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
      if (event.name === "configreloaded") {
        root.setUpHyprland()
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
          if (root.popup !== "") root.popup = ""
          else root.close()
          event.accepted = true
        } else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9
            && (event.modifiers & ~Qt.KeypadModifier) === 0) {
          root.pressNumber(event.key)
          event.accepted = true
        }
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
        color: root.bandColor

        // Keeps a click between two cards from closing the panel.
        MouseArea {
          anchors.fill: parent
          onClicked: root.popup = ""
        }

        // Each workspace's number, centered above its card. The cards clip their
        // contents, so the numbers are their own row.
        Row {
          id: labels
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: cards.top
          anchors.bottomMargin: Style.spacing.md
          spacing: root.cardGap

          Repeater {
            model: ScriptModel { values: root.workspaceIds }

            delegate: Item {
              id: label
              required property var modelData
              readonly property bool active: modelData === root.activeId

              opacity: root.reorderLabel === label ? 0.35 : (root.selectedId > 0 && root.selectedId !== modelData ? 0.5 : 1)
              Behavior on opacity {
                enabled: !root.reorderLabel
                NumberAnimation { duration: Style.duration(root.fadeMs); easing.type: Easing.OutCubic }
              }
              width: root.cardW
              // Only as tall as the number, so the icons don't make the band taller.
              implicitHeight: number.implicitHeight

              // Grab the number and icons to move this workspace along the row.
              MouseArea {
                anchors.fill: parent
                cursorShape: root.reorderLabel === label ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property point pressPoint

                onPressed: mouse => pressPoint = Qt.point(mouse.x, mouse.y)
                onPositionChanged: mouse => {
                  if (!pressed) return
                  var dx = mouse.x - pressPoint.x
                  var dy = mouse.y - pressPoint.y
                  if (root.reorderLabel !== label && dx * dx + dy * dy < 36) return
                  if (root.reorderLabel !== label) root.reorderGrabX = pressPoint.x
                  root.moveReorder(label, mapToItem(panel.contentItem, mouse.x, mouse.y))
                }
                onReleased: if (root.reorderLabel === label) root.finishReorder()
                onCanceled: {
                  if (root.reorderLabel === label) root.reorderLabel = null
                }
              }

              // The number and its icons are centered over the card as one unit.
              Row {
                anchors.centerIn: parent
                spacing: Style.space(4)

                Text {
                  id: number
                  textFormat: Text.PlainText
                  text: root.blockOf(label.modelData) === root.blockOf(root.activeId) ? root.slotOf(label.modelData) : label.modelData
                  color: label.active ? Commons.Color.accent : Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: label.active
                }

                Repeater {
                  model: workspaceApps.appsIn(root.windowsOn(label.modelData))

                  AppMark {
                    required property var modelData
                    source: modelData.source
                    letter: modelData.letter
                    size: number.implicitHeight
                    letterColor: Commons.Color.foreground
                  }
                }
              }
            }
          }
        }

        Row {
          id: cards
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: root.bandPadding
          spacing: root.cardGap

          Repeater {
            model: ScriptModel { values: root.workspaceIds }

            delegate: Rectangle {
              id: card
              required property var modelData
              readonly property int wsId: modelData
              property alias tiles: tileRepeater
              readonly property bool active: wsId === root.activeId
              readonly property bool hovered: root.hoverId === wsId && (!!root.minimizedDrag || (!!root.dragTile && root.dragTile.wsId !== wsId))
              readonly property bool selected: root.selectedId === wsId

              Component.onDestruction: if (root.hoverCardId === wsId) root.hoverCardId = -1

              opacity: root.reorderId === wsId ? 0.35 : (root.selectedId > 0 && !selected ? 0.5 : 1)
              Behavior on opacity {
                enabled: root.reorderId <= 0
                NumberAnimation { duration: Style.duration(root.fadeMs); easing.type: Easing.OutCubic }
              }
              width: root.cardW
              height: root.cardH
              clip: true
              radius: Style.cornerRadius
              color: hovered ? Style.selectedAccentFill : (selected ? Style.hoverFill : Style.normalFill)
              border.width: active || selected ? Math.max(1, Style.space(2)) : Style.spacing.hairline
              border.color: hovered || active ? Commons.Color.accent : Style.normalBorderColor

              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                function markHovered() { if (root.opened) root.hoverCardId = card.wsId }
                onContainsMouseChanged: {
                  if (containsMouse) markHovered()
                  else if (root.hoverCardId === card.wsId) root.hoverCardId = -1
                }
                onPositionChanged: markHovered()
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
                  readonly property int stackIndex: root.stackOrder[workspaceApps.windowAddress(modelData)] || 0
                  readonly property bool placed: !!ipc.at && !!ipc.size && !ipc.hidden
                  readonly property string appClass: String(ipc["class"] || modelData.title || "?")

                  visible: placed
                  x: placed ? (ipc.at[0] - (root.monitor ? root.monitor.x : 0)) * ratio : 0
                  y: placed ? (ipc.at[1] - (root.monitor ? root.monitor.y : 0)) * ratio : 0
                  width: placed ? Math.max(2, ipc.size[0] * ratio) : 0
                  height: placed ? Math.max(2, ipc.size[1] * ratio) : 0
                  z: (ipc.floating ? 1000 : 0) + stackIndex
                  // Only inside the selected workspace. Every other one fades as a
                  // whole, and dimming its windows as well would compound.
                  opacity: root.highlightTile && root.highlightTile !== tile && root.selectedId === wsId ? 0.5 : 1
                  Behavior on opacity {
                    NumberAnimation { duration: Style.duration(root.fadeMs); easing.type: Easing.OutCubic }
                  }

                  Component.onDestruction: {
                    if (root.dragTile === tile) root.dragTile = null
                    if (root.hoverTile === tile) root.hoverTile = null
                  }

                  Rectangle {
                    anchors.fill: parent
                    color: Commons.Color.background
                    radius: Style.cornerRadius
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

                  ClippingRectangle {
                    anchors.fill: parent
                    color: "transparent"
                    radius: Style.cornerRadius

                    ScreencopyView {
                      id: shot
                      anchors.fill: parent
                      captureSource: root.shown ? tile.modelData.wayland : null
                      live: true
                      constraintSize: Qt.size(Math.ceil(tile.width * 2), Math.ceil(tile.height * 2))
                    }
                  }

                  Rectangle {
                    anchors.fill: parent
                    visible: root.highlightTile === tile
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

                    function inWindow(mouse) {
                      return mapToItem(panel.contentItem, mouse.x, mouse.y)
                    }

                    onContainsMouseChanged: if (!containsMouse && root.hoverTile === tile) root.hoverTile = null
                    onPressed: mouse => pressPoint = Qt.point(mouse.x, mouse.y)
                    onPositionChanged: mouse => {
                      if (!pressed) {
                        if (root.opened) root.hoverTile = tile
                        return
                      }
                      var dx = mouse.x - pressPoint.x
                      var dy = mouse.y - pressPoint.y
                      if (root.dragTile !== tile && dx * dx + dy * dy < 36) return
                      var point = inWindow(mouse)
                      root.dragTo(tile, point.x, point.y)
                    }
                    onReleased: {
                      if (root.dragTile === tile) root.drop()
                      else if (containsMouse) root.clickWindow(tile.wsId, tile.modelData)
                    }
                    onCanceled: if (root.dragTile === tile) root.dragTile = null
                  }
                }
              }

            }
          }
        }
      }

      // Settings and the minimized windows, just past the two ends of the number row.
      CloseButton {
        x: cards.x - Style.space(12)
        y: band.y + labels.y + (labels.height - height) / 2
        size: labels.implicitHeight
        glyph: "\uf013"
        glyphScale: 0.9
        restingOpacity: 0.29
        onClicked: root.togglePopup("settings")
      }

      CloseButton {
        x: cards.x + cards.width - width + Style.space(12)
        y: band.y + labels.y + (labels.height - height) / 2
        size: labels.implicitHeight
        glyph: "󰇘"
        opacity: workspaceApps.minimizedWindows.length > 0 ? 1 : 0.5
        onClicked: root.togglePopup("minimized")
      }

      // What those buttons open, floating above the row so the band keeps its size.
      Rectangle {
        id: popupCard
        readonly property int edge: Style.spacing.md

        visible: root.opened && root.popup !== ""
        width: (root.popup === "settings" ? settingsPopup.width : minimizedPopup.width) + edge
        height: (root.popup === "settings" ? settingsPopup.height : minimizedPopup.height) + edge
        // Sits on the band, against the screen edge nearest its button.
        x: root.popup === "settings" ? 0 : root.sw - width
        y: band.y - height
        color: workspaceApps.cardBackground(root.shell ? root.shell.barConfig : null)
        topLeftRadius: root.popup === "minimized" ? Style.cornerRadius : 0
        topRightRadius: root.popup === "settings" ? Style.cornerRadius : 0

        // Keeps a click on the card from closing the panel.
        MouseArea { anchors.fill: parent }

        Loader {
          id: settingsPopup
          x: popupCard.edge / 2
          y: popupCard.edge / 2
          active: root.popup === "settings"
          sourceComponent: SettingsPane {
            settings: prefs
            onReloadNeeded: reloadForSetting.restart()
          }
        }

        Loader {
          id: minimizedPopup
          x: popupCard.edge / 2
          y: popupCard.edge / 2
          active: root.popup === "minimized"
          sourceComponent: MinimizedList {
            windows: workspaceApps.minimizedWindows
            dragSpace: panel.contentItem
            onRestore: function(toplevel) {
              if (root.justDropped()) return
              root.popup = ""
              workspaceApps.restoreWindow(toplevel, root.activeId)
              refresh.restart()
            }
            onClose: function(toplevel) { workspaceApps.closeWindow(toplevel) }
            onDragMoved: function(x, y) {
              root.minimizedDragPos = Qt.point(x, y)
              var card = root.cardAt(x, y)
              root.hoverId = card ? card.wsId : -1
            }
            onDragDropped: function(toplevel) {
              root.droppedAt = Date.now()
              if (root.hoverId > 0) root.moveWindow(toplevel, root.hoverId)
              root.hoverId = -1
            }
            onDragCanceled: root.hoverId = -1
          }
        }
      }

      DragGhost {
        source: root.minimizedDrag
        position: root.minimizedDragPos
        grab: minimizedPopup.item ? minimizedPopup.item.grabPoint : Qt.point(0, 0)
        itemScale: 0.5
      }

      // Holds the list open while the pointer is near it or crossing the space
      // down to its card. It only watches, so clicks here still reach the panel.
      Item {
        readonly property int reach: Style.spacing.huge * 2
        readonly property real leftEdge: Math.min(windowList.x, windowList.cardCenter - root.cardW / 2) - reach
        readonly property real rightEdge: Math.max(windowList.x + windowList.width, windowList.cardCenter + root.cardW / 2) + reach

        visible: windowList.visible
        x: leftEdge
        width: rightEdge - leftEdge
        y: windowList.y - reach
        height: band.y + cards.y - y

        HoverHandler { id: reachHover }
      }

      // The selected workspace's windows, floating above its card so the band
      // keeps its size.
      Rectangle {
        id: windowList
        readonly property real cardCenter: cards.x + root.workspaceIds.indexOf(root.listId) * (root.cardW + root.cardGap) + root.cardW / 2
        readonly property int edge: Style.spacing.md
        readonly property int iconSize: Math.round(Style.font.body * 1.5)

        visible: root.opened && root.popup === "" && !root.reorderLabel && (!root.dragTile || !!root.dragTile.listRow) && root.listWindows.length > 0
        width: Math.min(root.sw * 0.4, rows.implicitWidth + edge)
        height: rows.implicitHeight + edge
        x: Math.max(edge, Math.min(root.sw - width - edge, cardCenter - width / 2))
        y: band.y - height - edge
        color: workspaceApps.cardBackground(root.shell ? root.shell.barConfig : null)
        radius: Style.cornerRadius
        border.width: Style.spacing.hairline
        border.color: Style.normalBorderColor

        HoverHandler { id: listHover }

        // Keeps a click between two rows from closing the panel.
        MouseArea { anchors.fill: parent }

        ColumnLayout {
          id: rows
          anchors.fill: parent
          anchors.margins: windowList.edge / 2
          spacing: 0

          Repeater {
            model: ScriptModel { values: root.listWindows }

            delegate: Item {
              id: row
              required property var modelData
              readonly property string appId: workspaceApps.appIdOf(modelData)
              // What a drag needs, the same as a mini view has.
              readonly property bool listRow: true
              readonly property int wsId: root.listId
              property real grabX: 0

              Component.onDestruction: if (root.dragTile === row) root.dragTile = null

              Layout.fillWidth: true
              implicitWidth: title.implicitWidth + windowList.iconSize * 2 + windowList.edge * 4
              implicitHeight: Math.max(windowList.iconSize, title.implicitHeight) + windowList.edge

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                // A row being dragged leaves the list, so it brings a backing along.
                color: root.dragTile === row ? Commons.Color.background
                  : rowMouse.containsMouse || closeButton.hovered ? Style.hoverFill : "transparent"
                border.width: root.dragTile === row || rowMouse.containsMouse || closeButton.hovered ? 1 : 0
                border.color: Commons.Color.accent
              }

              AppMark {
                id: icon
                anchors.left: parent.left
                anchors.leftMargin: windowList.edge
                anchors.verticalCenter: parent.verticalCenter
                size: windowList.iconSize
                source: workspaceApps.iconFor(row.appId)
                letter: workspaceApps.letterFor(row.appId)
                letterColor: Commons.Color.foreground
              }

              Text {
                id: title
                anchors.left: icon.right
                anchors.leftMargin: windowList.edge
                anchors.right: closeButton.left
                anchors.rightMargin: windowList.edge
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

                onPressed: mouse => {
                  pressPoint = Qt.point(mouse.x, mouse.y)
                  row.grabX = mouse.x
                }
                onPositionChanged: mouse => {
                  if (!pressed) return
                  var dx = mouse.x - pressPoint.x
                  var dy = mouse.y - pressPoint.y
                  if (root.dragTile !== row && dx * dx + dy * dy < 36) return
                  var point = mapToItem(panel.contentItem, mouse.x, mouse.y)
                  root.dragTo(row, point.x, point.y)
                }
                onReleased: {
                  if (root.dragTile === row) root.drop()
                  else if (containsMouse) root.clickWindow(root.listId, row.modelData)
                }
                onCanceled: if (root.dragTile === row) root.dragTile = null
              }

              CloseButton {
                id: closeButton
                anchors.right: parent.right
                anchors.rightMargin: windowList.edge / 2
                anchors.verticalCenter: parent.verticalCenter
                size: windowList.iconSize
                onClicked: workspaceApps.closeWindow(row.modelData)
              }
            }
          }
        }
      }

      // Where the workspace being dragged would land.
      Rectangle {
        visible: !!root.reorderLabel && root.reorderInsert >= 0
        x: root.reorderMarkerX - width / 2
        y: band.y + cards.y
        width: 2
        height: root.cardH
        radius: 1
        color: Commons.Color.accent
      }

      // The workspace itself and its number and icons, following the pointer
      // along the row.
      ShaderEffectSource {
        visible: !!root.reorderCard
        sourceItem: root.reorderCard
        width: root.cardW
        height: root.cardH
        x: root.reorderPos.x - root.reorderGrabX
        y: band.y + cards.y
        opacity: 0.8
      }

      ShaderEffectSource {
        visible: !!root.reorderLabel
        sourceItem: root.reorderLabel
        width: root.reorderLabel ? root.reorderLabel.width : 0
        height: root.reorderLabel ? root.reorderLabel.height : 0
        x: root.reorderPos.x - root.reorderGrabX
        y: band.y + labels.y
        opacity: 0.8
      }

      // The window under the cursor while it is being dragged.
      ShaderEffectSource {
        visible: !!root.dragTile
        sourceItem: root.dragTile
        hideSource: true
        width: root.dragTile ? root.dragTile.width : 0
        height: root.dragTile ? root.dragTile.height : 0
        // A wide list row keeps hold of the spot it was picked up by.
        x: root.dragPos.x - (root.dragTile && root.dragTile.listRow ? root.dragTile.grabX : width / 2)
        y: root.dragPos.y - height / 2
        opacity: 0.9
      }
    }
  }
}
