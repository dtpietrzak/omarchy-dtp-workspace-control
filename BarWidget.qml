import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Chord.js" as Chord

// The panel's button, then a number for each workspace with a line under the
// one this monitor is showing.
BarWidget {
  id: root
  moduleName: "io.github.dtpietrzak.workspace-control"

  // Every monitor has ten workspaces of its own, which Hyprland numbers in a
  // block per monitor: 1-10, 11-20, and so on.
  readonly property int slots: 10
  readonly property int alwaysShown: prefs.barWorkspaces
  readonly property int entryGap: Style.space(6)
  readonly property color barForeground: bar ? bar.barForeground : Commons.Color.foreground

  readonly property var monitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }
  readonly property string monitorName: monitor ? monitor.name.replace(/[^A-Za-z0-9_.-]/g, "") : ""
  readonly property int activeId: monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1

  function blockOf(id) { return Math.floor((id - 1) / slots) }
  function slotOf(id) { return (id - 1) % slots + 1 }

  WorkspaceApps { id: workspaceApps }
  WorkspaceSettings { id: prefs }
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Connector -> block, from the file Hyprland keeps them in.
  property var blocks: ({})

  function readBlocks(text) {
    var next = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields.length >= 3 && fields[1] !== "") next[fields[1]] = parseInt(fields[0], 10)
    }
    blocks = next
  }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBlocks(text())
    onLoadFailed: root.readBlocks("")
  }

  // Until Hyprland has written the file, the workspace a monitor shows is in
  // its own block.
  readonly property int block: {
    var known = blocks[monitorName]
    if (known !== undefined) return known
    return activeId > 0 ? blockOf(activeId) : 0
  }

  // The monitor's first seven, any more of its own that are open, then any
  // visiting from an unplugged monitor.
  readonly property var workspaceIds: {
    var base = block * slots
    var ids = []
    for (var n = 1; n <= alwaysShown; n++) ids.push(base + n)
    var guests = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id <= 0) continue
      if (blockOf(id) === block) {
        if (ids.indexOf(id) === -1) ids.push(id)
      } else if (values[i].monitor && values[i].monitor.name === monitorName) {
        guests.push(id)
      }
    }
    ids.sort(function(a, b) { return a - b })
    guests.sort(function(a, b) { return a - b })
    return ids.concat(guests)
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  // The card that hovering a workspace brings up.
  property Item pointedEntry: null
  property Item peekEntry: null
  property bool peekOpen: false
  // Stays set while the card fades out, so its contents don't vanish first.
  property int peekId: -1

  function showPeek(entry) {
    if (menuOpen || appsOpen) return
    if (!prefs.hoverCards || !entry.occupied) {
      hidePeek()
      return
    }
    menuOpen = false
    peekEntry = entry
    peekId = entry.modelData
    peekOpen = true
    Qt.callLater(placePeek)
  }

  // Against the bar, starting `along` past the start of the item it belongs to.
  // The bar's window spans its screen, so a spot in it is a spot on the screen.
  function placeCard(card, target, width, height, along) {
    var window = root.QsWindow.window
    if (!target || !window || !window.contentItem) return
    var at = window.contentItem.mapFromItem(target, 0, 0)
    var position = bar ? bar.position : "top"
    var x = at.x + (vertical ? 0 : along)
    var y = at.y + (vertical ? along : 0)
    if (position === "bottom") y = at.y - height
    else if (position === "top") y = at.y + target.height
    else if (position === "left") x = at.x + target.width
    else x = at.x - width
    card.x = Math.round(Math.max(0, Math.min(x, peek.screenWidth - width)))
    card.y = Math.round(Math.max(0, Math.min(y, peek.screenHeight - height)))
  }

  // Lined up with the divider before the workspace, half a gap before its number.
  function placePeek() {
    placeCard(card, peekEntry, peek.cardWidth, peek.cardHeight, -entryGap / 2)
  }

  // The popover that right-clicking the button brings up.
  property bool menuOpen: false
  // The popover's choices, or the settings it opens into.
  property bool menuShowsSettings: false
  readonly property bool settingsOpen: menuOpen && menuShowsSettings
  // Or the minimized windows, which the ... button opens it to.
  property bool menuShowsMinimized: false

  readonly property var minimizedWindows: workspaceApps.minimizedWindows

  function toggleMinimized() {
    if (menuOpen && menuShowsMinimized) {
      menuOpen = false
      return
    }
    appsOpen = false
    hidePeek()
    peekTimer.stop()
    menuShowsSettings = false
    menuShowsMinimized = true
    menuOpen = true
    Qt.callLater(placeMenu)
    followMenu()
  }

  function restoreWindow(toplevel) {
    menuOpen = false
    workspaceApps.restoreWindow(toplevel, activeId)
  }

  // The app list that the apps button drops down, open until a click lands
  // anywhere else.
  property bool appsOpen: false

  function toggleApps() {
    if (appsOpen) {
      appsOpen = false
      return
    }
    hidePeek()
    menuOpen = false
    appsOpen = true
    Qt.callLater(placeApps)
  }

  // Its left edge on the divider in front of the widget.
  // With the button hidden, the widget's own leading edge.
  function placeApps() {
    if (appsButton.visible) placeCard(appsCard, appsButton, appsCard.width, appsCard.height, vertical ? 0 : -leadGap)
    else placeCard(appsCard, root, appsCard.width, appsCard.height, 0)
  }

  // The button the popover was opened from, which it hangs under.
  property Item menuAnchor: null

  // Right-clicking any of the widget's buttons brings this up.
  function openMenu(anchor) {
    menuAnchor = anchor || panelButton
    appsOpen = false
    hidePeek()
    peekTimer.stop()
    menuShowsSettings = false
    menuShowsMinimized = false
    menuOpen = true
    Qt.callLater(placeMenu)
    followMenu()
  }

  // On a horizontal bar, the icons in the popover line up with the button's.
  function placeMenu() {
    if (menuShowsMinimized) {
      placeCard(menuCard, moreButton, menuCard.width, menuCard.height, -entryGap / 2)
      return
    }
    var anchor = menuAnchor || panelButton
    var iconCenter = peek.sideEdge + settingsRow.edge + settingsRow.iconSize / 2
    placeCard(menuCard, anchor, menuCard.width, menuCard.height, vertical ? 0 : anchor.width / 2 - iconCenter)
  }

  // Gone a moment after the pointer has left both the button and the popover.
  function followMenu() {
    if (!menuOpen) return
    if (settingsOpen || peekDragItem || widgetHover.hovered || menuHover.hovered) menuTimer.stop()
    else menuTimer.restart()
  }

  Timer {
    id: menuTimer
    interval: 400
    onTriggered: if (!root.peekDragItem && !root.settingsOpen && !widgetHover.hovered && !menuHover.hovered) root.menuOpen = false
  }

  // Keeps the popover up while the pointer is anywhere on the widget.
  HoverHandler {
    id: widgetHover
    onHoveredChanged: root.followMenu()
  }

  // The bar lays a press handler over every widget for rearranging the bar, so a
  // widget never sees its own drags. This sits over that one, on just the
  // numbers: they reorder workspaces, and the button still moves the widget.
  readonly property Item barSlot: {
    for (var item = root.parent; item; item = item.parent) {
      if ("widgetWidth" in item && "panelOpen" in item) return item
    }
    return null
  }

  // The workspace being dragged along the row, and where it would land.
  property Item reorderEntry: null
  property int reorderInsert: -1
  property point reorderPos: Qt.point(0, 0)
  property point reorderGrab: Qt.point(0, 0)
  property point reorderMarker: Qt.point(0, 0)

  // The monitor's own workspaces, which are the ones that can trade places.
  function ownEntries() {
    var found = []
    for (var i = 0; i < entries.count; i++) {
      var entry = entries.itemAt(i)
      if (entry && blockOf(entry.modelData) === block) found.push(entry)
    }
    return found
  }

  // The position in the row a point falls before, in the row's own order.
  function insertIndexAt(point) {
    var own = ownEntries()
    for (var i = 0; i < own.length; i++) {
      var at = root.mapFromItem(own[i], 0, 0)
      var middle = vertical ? at.y + own[i].height / 2 : at.x + own[i].width / 2
      if ((vertical ? point.y : point.x) < middle) return i
    }
    return own.length
  }

  function updateReorder(point) {
    reorderPos = point
    var index = insertIndexAt(point)
    reorderInsert = index
    var own = ownEntries()
    var gap = entryGap / 2
    var anchor = index < own.length
      ? root.mapFromItem(own[index], 0, 0)
      : root.mapFromItem(own[own.length - 1], own[own.length - 1].width, own[own.length - 1].height)
    reorderMarker = vertical
      ? Qt.point(0, index < own.length ? anchor.y - gap : anchor.y + gap)
      : Qt.point(index < own.length ? anchor.x - gap : anchor.x + gap, 0)
  }

  function finishReorder() {
    var entry = reorderEntry
    var insert = reorderInsert
    reorderEntry = null
    reorderInsert = -1
    if (!entry) return
    droppedAt = Date.now()
    var own = ownEntries()
    var from = own.indexOf(entry)
    // Dropped back where it started.
    if (from < 0 || insert === from || insert === from + 1) return
    var ids = own.map(function(item) { return item.modelData })
    Hyprland.dispatch("(function() dtpwc_reorder({" + ids.join(",") + "}, " + (from + 1) + ", " + (insert + 1) + ") end)")
  }

  // Where the last of the apps and panel buttons that are shown ends.
  readonly property real buttonsEnd: {
    var last = panelButton.visible ? panelButton : appsButton.visible ? appsButton : null
    if (!last) return 0
    return vertical ? row.y + last.y + last.height : row.x + last.x + last.width
  }

  MouseArea {
    id: numbersDrag
    parent: root.barSlot || root
    z: 1000
    enabled: !!root.barSlot
    // Between the buttons and the ..., which the bar still handles.
    x: root.vertical ? 0 : root.buttonsEnd
    y: root.vertical ? root.buttonsEnd : 0
    width: parent.width - x - (root.vertical || !moreButton.visible ? 0 : moreButton.width + root.entryGap)
    height: parent.height - y - (root.vertical && moreButton.visible ? moreButton.height + root.entryGap : 0)
    acceptedButtons: Qt.LeftButton
    cursorShape: pressed && root.reorderEntry ? Qt.ClosedHandCursor : Qt.PointingHandCursor

    property Item pressedEntry: null
    property point pressPoint

    function inWidget(mouse) { return mapToItem(root, mouse.x, mouse.y) }

    onPressed: mouse => {
      pressPoint = Qt.point(mouse.x, mouse.y)
      var point = inWidget(mouse)
      var window = root.QsWindow.window
      var onScreen = window && window.contentItem ? mapToItem(window.contentItem, mouse.x, mouse.y) : Qt.point(0, 0)
      var id = root.workspaceAt(onScreen.x, onScreen.y)
      pressedEntry = null
      for (var i = 0; i < entries.count; i++) {
        var entry = entries.itemAt(i)
        if (entry && entry.modelData === id) pressedEntry = entry
      }
      if (pressedEntry) {
        pressedEntry.numberButton.heldButtons = Qt.LeftButton
        var at = root.mapFromItem(pressedEntry, 0, 0)
        root.reorderGrab = Qt.point(point.x - at.x, point.y - at.y)
      }
    }

    onPositionChanged: mouse => {
      if (!pressedEntry) return
      var dx = mouse.x - pressPoint.x
      var dy = mouse.y - pressPoint.y
      if (root.reorderEntry !== pressedEntry && dx * dx + dy * dy < 36) return
      if (root.blockOf(pressedEntry.modelData) !== root.block) return
      root.reorderEntry = pressedEntry
      root.hidePeek()
      root.updateReorder(inWidget(mouse))
    }

    onReleased: {
      var entry = pressedEntry
      pressedEntry = null
      if (entry) entry.numberButton.heldButtons = Qt.NoButton
      if (root.reorderEntry) root.finishReorder()
      else if (entry && containsMouse) root.focusWorkspace(entry.modelData)
    }

    onCanceled: {
      if (pressedEntry) pressedEntry.numberButton.heldButtons = Qt.NoButton
      pressedEntry = null
      root.reorderEntry = null
      root.reorderInsert = -1
    }
  }

  // The workspace following the pointer along the row.
  ShaderEffectSource {
    visible: !!root.reorderEntry
    z: 20
    sourceItem: root.reorderEntry
    width: root.reorderEntry ? root.reorderEntry.width : 0
    height: root.reorderEntry ? root.reorderEntry.height : 0
    x: root.vertical ? 0 : root.reorderPos.x - root.reorderGrab.x
    y: root.vertical ? root.reorderPos.y - root.reorderGrab.y : 0
    opacity: 0.8
  }

  // Where it would land.
  Rectangle {
    visible: !!root.reorderEntry && root.reorderInsert >= 0
    z: 19
    x: root.vertical ? Math.round((root.width - width) / 2) : root.reorderMarker.x - width / 2
    y: root.vertical ? root.reorderMarker.y - height / 2 : Math.round((root.height - height) / 2)
    width: root.vertical ? Style.space(14) : 2
    height: root.vertical ? 2 : Style.space(14)
    radius: 1
    color: Commons.Color.accent
  }

  // Hotkeys and the swipe are registered with Hyprland, so changing them takes a
  // reload. A moment's wait lets the setting reach the file first.
  Timer {
    id: reloadForSetting
    interval: 200
    onTriggered: if (root.bar) root.bar.run("hyprctl reload")
  }

  function togglePanel() {
    if (root.bar) root.bar.run("omarchy-shell shell call io.github.dtpietrzak.workspace-control toggle ''")
  }

  function hidePeek() {
    peekTimer.stop()
    peekOpen = false
  }

  // Not a popout of the bar's, which would mark the whole widget as having a
  // panel open. It still gives way to a real one.
  Connections {
    target: root.bar
    function onActivePopoutChanged() { if (root.bar.activePopout) root.hidePeek() }
  }

  // A window being dragged from the card, and where it would land.
  readonly property Item peekDragItem: dragSource ? dragSource.dragItem : null
  // The card a window is being dragged from, the hover card or the minimized list.
  readonly property Item dragSource: {
    if (peekContent.item && peekContent.item.dragItem) return peekContent.item
    if (minimizedLoader.item && minimizedLoader.item.dragItem) return minimizedLoader.item
    return null
  }
  property point peekDragPos: Qt.point(0, 0)
  property int dropTargetId: -1
  // A picked-up window eases down to its dragging size.
  property real peekDragScale: 1
  NumberAnimation {
    id: peekShrink
    target: root
    property: "peekDragScale"
    from: 1
    duration: Style.duration(200)
    easing.type: Easing.OutCubic
  }
  onPeekDragItemChanged: {
    if (peekDragItem) {
      // For where a drop on the desktop may put a window.
      prefs.readTitleBars()
      peekShrink.stop()
      peekDragScale = 1
      followPeekScale()
    }
    followPointer()
    followMenu()
  }

  // A thumbnail carried over its own preview keeps its size, as the real
  // window moves with it. Off the preview it shrinks to its dragging size.
  readonly property bool peekOverPreview: !!peekDragItem && dragSource === peekContent.item && !!peekContent.item && peekContent.item.overPreview
  onPeekOverPreviewChanged: followPeekScale()
  function followPeekScale() {
    if (!peekDragItem) return
    var to = peekOverPreview || peekOverDesktop ? 1 : peekDragItem.dragScale
    if (peekShrink.to === to && (peekShrink.running || peekDragScale === to)) return
    peekShrink.stop()
    peekShrink.from = peekDragScale
    peekShrink.to = to
    peekShrink.start()
  }

  // Set while a window from the hover card or the minimized list is carried
  // over the desktop: off the card it came from, off the bar, and so not on a
  // workspace number. There it grows back to full size, as it will on the screen.
  property bool peekOverDesktop: false
  onPeekOverDesktopChanged: followPeekScale()
  function onCard(x, y, from) {
    return x >= from.x && x < from.x + from.width && y >= from.y && y < from.y + from.height
  }
  function overDesktop(x, y, from) {
    if (onCard(x, y, from)) return false
    var side = peek.barSide
    if (side === "top") return y >= barSize
    if (side === "bottom") return y < peek.screenHeight - barSize
    if (side === "left") return x >= barSize
    return x < peek.screenWidth - barSize
  }

  // Where on the screen a window from the hover card goes when it is let go of
  // over the desktop: centered on the pointer, whatever spot it was picked up
  // by. Only a floating window has a spot of its own.
  function desktopSpot(source) {
    var item = source ? source.dragItem : null
    if (!item || !monitor) return null
    var address = workspaceApps.windowAddress(item.modelData)
    var client = source.clients[address]
    if (!client || !client.floating || !client.size) return null
    var width = client.size[0], height = client.size[1]
    var left = peekDragPos.x - width / 2
    var top = peekDragPos.y - height / 2
    return {
      address: address,
      x: Math.round(monitor.x + prefs.keepX(left, width, peek.screenWidth)),
      y: Math.round(monitor.y + prefs.keepY(top, height, peek.screenHeight)),
      width: width,
      height: height
    }
  }
  // That spot for the window being carried there now, which is outlined. One
  // carried from another workspace onto the number of the workspace being
  // shown is outlined too, where it is, which is where it would turn up.
  readonly property var peekLanding: {
    if (!peekDragItem || dragSource !== peekContent.item) return null
    if (peekOverDesktop) return desktopSpot(peekContent.item)
    if (dropTargetId !== activeId || peekId === activeId) return null
    var client = peekContent.item.clients[workspaceApps.windowAddress(peekDragItem.modelData)]
    if (!client || !client.floating || !client.size || !client.at) return null
    return { x: client.at[0], y: client.at[1], width: client.size[0], height: client.size[1] }
  }

  // Closing the last window from the card leaves it nothing to show.
  readonly property bool peekEmpty: !!peekContent.item && peekContent.item.windows.length === 0
  onPeekEmptyChanged: if (peekEmpty) hidePeek()

  // Ending a drag on the touchpad also sends a click at the drop point a moment
  // after the release, which must not count as clicking that workspace.
  property real droppedAt: 0
  function justDropped() { return Date.now() - droppedAt < 200 }

  // The workspace at this spot on the screen, gaps split between its neighbors.
  function workspaceAt(x, y) {
    var window = root.QsWindow.window
    if (!window || !window.contentItem) return -1
    for (var i = 0; i < entries.count; i++) {
      var entry = entries.itemAt(i)
      if (!entry) continue
      var at = window.contentItem.mapFromItem(entry, 0, 0)
      var pad = entryGap / 2
      var padX = vertical ? 0 : pad
      var padY = vertical ? pad : 0
      if (x >= at.x - padX && x < at.x + entry.width + padX && y >= at.y - padY && y < at.y + entry.height + padY) {
        return entry.modelData
      }
    }
    return -1
  }

  function followPointer() {
    if (peekDragItem) {
      peekTimer.stop()
    } else if (peekHover.hovered) {
      peekTimer.stop()
    } else if (pointedEntry && peekOpen) {
      peekTimer.stop()
      showPeek(pointedEntry)
    } else {
      // A short wait to open, so passing over the bar doesn't flash a card, and
      // a longer one to close, so the gap up to the card doesn't lose it.
      peekTimer.interval = pointedEntry ? 120 : 400
      peekTimer.restart()
    }
  }

  function entryHovered(entry, hovered) {
    if (hovered) pointedEntry = entry
    else if (pointedEntry === entry) pointedEntry = null
    followPointer()
  }

  Timer {
    id: peekTimer
    onTriggered: {
      if (root.peekDragItem) return
      if (root.pointedEntry) root.showPeek(root.pointedEntry)
      else if (!peekHover.hovered) root.hidePeek()
    }
  }

  // A surface of its own, not a popup of the bar's, so Hyprland blurs behind a
  // glassy background the same way it does for the panel.
  PanelWindow {
    id: peek
    readonly property real screenWidth: screen ? screen.width : 0
    readonly property real screenHeight: screen ? screen.height : 0
    readonly property string barSide: root.bar ? root.bar.position : "top"
    // Background showing beside the preview, and past it on the far end.
    readonly property int sideEdge: 3
    readonly property int endEdge: 2
    // The preview is on top on a bottom bar, and the list is everywhere else.
    readonly property bool previewOnTop: barSide === "bottom"

    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    visible: root.peekOpen || card.opacity > 0
    color: "transparent"
    // The whole screen, so a dragged window can be drawn anywhere, taking input
    // only over the card.
    anchors { top: true; left: true; right: true; bottom: true }
    mask: Region { item: card }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "dtpietrzak-workspacecontrol-peek"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    readonly property int cardWidth: Style.space(320) + sideEdge * 2
    readonly property int cardHeight: Math.min(Math.max(1, screenHeight - root.barSize),
      (peekContent.item ? peekContent.item.implicitHeight : 0) + endEdge)

    onCardHeightChanged: Qt.callLater(root.placePeek)
    onVisibleChanged: if (!visible) root.peekId = -1

    Rectangle {
      id: card
      width: peek.cardWidth
      height: peek.cardHeight
      color: workspaceApps.cardBackground(root.bar && root.bar.shell ? root.bar.shell.barConfig : null)
      // Square where it meets the bar.
      topLeftRadius: peek.barSide === "top" || peek.barSide === "left" ? 0 : Style.cornerRadius
      topRightRadius: peek.barSide === "top" || peek.barSide === "right" ? 0 : Style.cornerRadius
      bottomLeftRadius: peek.barSide === "bottom" || peek.barSide === "left" ? 0 : Style.cornerRadius
      bottomRightRadius: peek.barSide === "bottom" || peek.barSide === "right" ? 0 : Style.cornerRadius
      opacity: root.peekOpen ? 1 : 0
      Behavior on opacity {
        NumberAnimation { duration: Style.duration(root.peekOpen ? 180 : 120); easing.type: Easing.OutCubic }
      }

      HoverHandler {
        id: peekHover
        onHoveredChanged: root.followPointer()
      }

      Loader {
        id: peekContent
        anchors.fill: parent
        anchors.topMargin: peek.previewOnTop ? peek.endEdge : 0
        anchors.bottomMargin: peek.previewOnTop ? 0 : peek.endEdge
        anchors.leftMargin: peek.sideEdge
        anchors.rightMargin: peek.sideEdge
        clip: true
        active: root.peekId > 0

        sourceComponent: WorkspacePeek {
          workspaceId: root.peekId
          previewOnTop: peek.previewOnTop
          lockToScreen: prefs.lockDrops
          dragSpace: peek.contentItem
          monitor: root.monitor
          screenWidth: peek.screenWidth
          screenHeight: peek.screenHeight
          onWindowChosen: function(toplevel) {
            if (root.justDropped()) return
            root.hidePeek()
            workspaceApps.focusWindow(toplevel)
          }
          onDragMoved: function(x, y) {
            root.peekDragPos = Qt.point(x, y)
            root.dropTargetId = root.workspaceAt(x, y)
            root.peekOverDesktop = root.dropTargetId < 0 && root.overDesktop(x, y, card)
            peekContent.item.setAway(!root.peekOverDesktop && !root.onCard(x, y, card),
              root.peekId === root.activeId && !!root.peekLanding, root.peekOverDesktop)
          }
          onDragDropped: function(toplevel, fromId) {
            var target = root.dropTargetId
            var toDesktop = root.peekOverDesktop
            var spot = toDesktop ? root.desktopSpot(peekContent.item) : null
            root.dropTargetId = -1
            root.peekOverDesktop = false
            root.droppedAt = Date.now()
            if (target > 0 && target !== fromId) {
              dropMoves = true
              workspaceApps.moveWindow(toplevel, target)
              root.dripOn(target)
            } else if (toDesktop && (spot || fromId !== root.activeId)) {
              // Let go of over the desktop, it comes to the workspace being
              // shown, a floating window where it was let go, and takes focus.
              // dropMoves stays off: that keeps a window hidden until it has
              // left the screen, and this one is arriving on it.
              // In place, too, and not sliding there from where it was.
              workspaceApps.holdStill(workspaceApps.windowAddress(toplevel))
              if (fromId !== root.activeId) workspaceApps.moveWindow(toplevel, root.activeId)
              if (spot) Hyprland.dispatch('hl.dsp.window.move({ x = ' + spot.x + ', y = ' + spot.y + ', window = "address:' + spot.address + '" })')
              workspaceApps.focusWindow(toplevel)
              if (fromId !== root.activeId) root.dripOn(root.activeId)
            }
          }
          onDragCanceled: {
            root.dropTargetId = -1
            root.peekOverDesktop = false
          }
        }
      }
    }

    // Where a floating window would land on the desktop, at the size of the
    // real window.
    GhostBox {
      spot: root.peekLanding && root.monitor
        ? Qt.rect(root.peekLanding.x - root.monitor.x, root.peekLanding.y - root.monitor.y, root.peekLanding.width, root.peekLanding.height)
        : null
      toplevel: root.peekDragItem ? root.peekDragItem.modelData : null
      titleBars: prefs
    }

    // The window under the cursor while it is being dragged.
    DragGhost {
      // A row is carried as its window's thumbnail over the preview and the
      // desktop, which the card works out.
      source: peekContent.item && root.dragSource === peekContent.item ? peekContent.item.ghostItem : null
      position: root.peekDragPos
      grab: peekContent.item ? peekContent.item.ghostGrab : Qt.point(0, 0)
      itemScale: root.peekDragScale
      bounds: root.peekOverPreview ? peekContent.item.previewArea : Qt.rect(0, 0, 0, 0)
    }
  }

  PanelWindow {
    id: menu
    screen: peek.screen
    visible: root.menuOpen || menuCard.opacity > 0
    color: "transparent"
    anchors { top: true; left: true; right: true; bottom: true }
    mask: Region { item: menuCard }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "dtpietrzak-workspacecontrol-peek"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive while a new chord is being recorded. OnDemand does not take
    // the keyboard when this window is already mapped, which it is by the time
    // Settings is open.
    WlrLayershell.keyboardFocus: {
      var pane = settingsLoader.item
      if (pane && pane.capturing && !pane.capturePrimed) return WlrKeyboardFocus.Exclusive
      return root.settingsOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    }

    // Settings stay up while they're used, until a click lands anywhere else.
    HyprlandFocusGrab {
      active: root.settingsOpen
      windows: [menu]
      onCleared: root.menuOpen = false
    }

    Rectangle {
      id: menuCard
      width: (root.menuShowsSettings ? settingsLoader.width : root.menuShowsMinimized ? minimizedLoader.width : menuRows.widest) + peek.sideEdge * 2
      height: (root.menuShowsSettings ? settingsLoader.height : root.menuShowsMinimized ? minimizedLoader.height : menuRows.implicitHeight) + peek.endEdge
      color: workspaceApps.cardBackground(root.bar && root.bar.shell ? root.bar.shell.barConfig : null)
      topLeftRadius: peek.barSide === "top" || peek.barSide === "left" ? 0 : Style.cornerRadius
      topRightRadius: peek.barSide === "top" || peek.barSide === "right" ? 0 : Style.cornerRadius
      bottomLeftRadius: peek.barSide === "bottom" || peek.barSide === "left" ? 0 : Style.cornerRadius
      bottomRightRadius: peek.barSide === "bottom" || peek.barSide === "right" ? 0 : Style.cornerRadius
      opacity: root.menuOpen ? 1 : 0
      Behavior on opacity {
        NumberAnimation { duration: Style.duration(root.menuOpen ? 180 : 120); easing.type: Easing.OutCubic }
      }

      onHeightChanged: Qt.callLater(root.placeMenu)
      onWidthChanged: Qt.callLater(root.placeMenu)

      HoverHandler {
        id: menuHover
        onHoveredChanged: root.followMenu()
      }

      Loader {
        id: settingsLoader
        x: peek.sideEdge
        y: peek.barSide === "bottom" ? peek.endEdge : 0
        active: root.menuShowsSettings
        focus: true

        Keys.onEscapePressed: root.menuOpen = false

        sourceComponent: SettingsPane {
          settings: prefs
          onReloadNeeded: reloadForSetting.restart()
        }
      }

      Loader {
        id: minimizedLoader
        x: peek.sideEdge
        y: peek.barSide === "bottom" ? peek.endEdge : 0
        active: root.menuShowsMinimized

        sourceComponent: MinimizedList {
          windows: root.minimizedWindows
          dragSpace: menu.contentItem
          onRestore: function(toplevel) {
            if (!root.justDropped()) root.restoreWindow(toplevel)
          }
          onClose: function(toplevel) { workspaceApps.closeWindow(toplevel) }
          onDragMoved: function(x, y) {
            root.peekDragPos = Qt.point(x, y)
            root.dropTargetId = root.workspaceAt(x, y)
            root.peekOverDesktop = root.dropTargetId < 0 && root.overDesktop(x, y, menuCard)
          }
          onDragDropped: function(toplevel) {
            var target = root.dropTargetId
            var toDesktop = root.peekOverDesktop
            root.dropTargetId = -1
            root.peekOverDesktop = false
            root.droppedAt = Date.now()
            if (target > 0) {
              workspaceApps.moveWindow(toplevel, target)
              root.dripOn(target)
            } else if (toDesktop) {
              // Let go of over the desktop, it comes back to the workspace
              // being shown, the same as a click on its row.
              root.restoreWindow(toplevel)
              root.dripOn(root.activeId)
            }
          }
          onDragCanceled: {
            root.dropTargetId = -1
            root.peekOverDesktop = false
          }
        }
      }

      Item {
        id: menuRows
        visible: !root.menuShowsSettings && !root.menuShowsMinimized
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: peek.sideEdge
        anchors.top: parent.top
        anchors.topMargin: peek.barSide === "bottom" ? peek.endEdge : 0
        // The card takes its width from this.
        readonly property real widest: Math.max(settingsRow.implicitWidth, panelRow.implicitWidth, appsRow.implicitWidth)
        // Settings, the panel, then the app list, reversed on a bottom bar so
        // Settings still sits nearest the bar.
        readonly property bool reversed: peek.barSide === "bottom"
        implicitHeight: settingsRow.implicitHeight + panelRow.implicitHeight + appsRow.implicitHeight
        height: implicitHeight

        MenuRow {
          id: settingsRow
          y: menuRows.reversed ? appsRow.height + panelRow.height : 0
          width: parent.width
          height: implicitHeight
          label: strings.t("menu.settings")
          onClicked: {
            root.menuShowsSettings = true
            Qt.callLater(root.placeMenu)
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "\uf013"
            color: Commons.Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        MenuRow {
          id: panelRow
          y: menuRows.reversed ? appsRow.height : settingsRow.height
          width: parent.width
          height: implicitHeight
          label: strings.t("menu.openPanel")
          // Whichever ways of opening the panel are turned on.
          hint: {
            var ways = []
            if (prefs.examine) ways.push(Chord.pretty(prefs.examineKeys))
            if (prefs.swipe) ways.push(strings.t("menu.swipe"))
            return ways.join(" / ")
          }
          onClicked: {
            root.menuOpen = false
            root.togglePanel()
          }

          ThreeSquares {
            anchors.centerIn: parent
            color: Commons.Color.foreground
          }
        }

        MenuRow {
          id: appsRow
          y: menuRows.reversed ? 0 : settingsRow.height + panelRow.height
          width: parent.width
          height: implicitHeight
          label: strings.t("menu.openApps")
          hint: strings.t("search.shortcut")
          onClicked: {
            root.menuOpen = false
            root.toggleApps()
          }

          AppsMark {
            anchors.centerIn: parent
            color: Commons.Color.foreground
          }
        }

        // A line between each pair of rows. The panel row is always the middle
        // one, so they sit on its two edges.
        Repeater {
          model: 2

          Rectangle {
            required property int index
            readonly property real thin: 1 / Math.max(1, Screen.devicePixelRatio)
            x: settingsRow.edge
            y: Math.round(panelRow.y + (index === 0 ? 0 : panelRow.height) - height / 2)
            width: menuRows.width - settingsRow.edge * 2
            height: thin
            color: Qt.alpha(Commons.Color.foreground, 0.15)
          }
        }
      }
    }

    DragGhost {
      source: root.dragSource === minimizedLoader.item ? root.peekDragItem : null
      position: root.peekDragPos
      grab: minimizedLoader.item ? minimizedLoader.item.grabPoint : Qt.point(0, 0)
      itemScale: root.peekDragScale
    }
  }

  PanelWindow {
    id: appsWindow
    screen: peek.screen
    visible: root.appsOpen || appsCard.opacity > 0
    color: "transparent"
    anchors { top: true; left: true; right: true; bottom: true }
    // The whole screen takes clicks while the list is open, so a click anywhere
    // off the card closes it, the bar and its apps button included.
    mask: Region { item: root.appsOpen ? appsCatcher : appsCard }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "dtpietrzak-workspacecontrol-peek"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.appsOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    MouseArea {
      id: appsCatcher
      anchors.fill: parent
      enabled: root.appsOpen
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onPressed: root.appsOpen = false
    }

    Rectangle {
      id: appsCard
      width: appList.implicitWidth + peek.sideEdge * 2
      height: Math.min(appList.implicitHeight, Math.max(1, peek.screenHeight - root.barSize)) + peek.endEdge
      color: workspaceApps.cardBackground(root.bar && root.bar.shell ? root.bar.shell.barConfig : null)
      topLeftRadius: peek.barSide === "top" || peek.barSide === "left" ? 0 : Style.cornerRadius
      topRightRadius: peek.barSide === "top" || peek.barSide === "right" ? 0 : Style.cornerRadius
      bottomLeftRadius: peek.barSide === "bottom" || peek.barSide === "left" ? 0 : Style.cornerRadius
      bottomRightRadius: peek.barSide === "bottom" || peek.barSide === "right" ? 0 : Style.cornerRadius
      opacity: root.appsOpen ? 1 : 0
      Behavior on opacity {
        NumberAnimation { duration: Style.duration(root.appsOpen ? 180 : 120); easing.type: Easing.OutCubic }
      }

      Behavior on height { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
      onHeightChanged: Qt.callLater(root.placeApps)
      onWidthChanged: Qt.callLater(root.placeApps)

      // Its edges are part of the card, not a click away from it.
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton }

      AppListCard {
        id: appList
        flipped: peek.barSide === "bottom"
        x: peek.sideEdge
        y: peek.barSide === "bottom" ? peek.endEdge : 0
        width: implicitWidth
        height: appsCard.height - peek.endEdge
        opened: root.appsOpen
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onLaunchRequested: command => { if (root.bar) root.bar.run(command) }
        onDismissed: root.appsOpen = false
      }
    }
  }

  function focusWorkspace(id) {
    if (justDropped()) return
    hidePeek()
    if (!bar) return
    var expression = blockOf(id) === block
      ? 'o.workspaces.focus(' + slotOf(id) + ', "' + monitorName + '")'
      : 'hl.dsp.focus({ workspace = "' + id + '" })'
    bar.run("hyprctl dispatch " + Util.shellQuote(expression))
  }

  // Quickshell credits every workspace switch to the focused monitor and misses
  // some changes altogether, so ask Hyprland for the truth.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "openwindow" || name === "closewindow" || name === "movewindowv2") root.noteWindowEvent(name, String(event.data))
      var switched = name === "workspacev2" && root.monitor !== null && root.monitor.focused
      if (switched || name === "moveworkspacev2" || name === "changeworkspaceid") {
        Hyprland.refreshMonitors()
        Hyprland.refreshWorkspaces()
      }
    }
  }

  // The current workspace's line: a rounded pill, its gap from the bar's edge,
  // and the one drawing of it that moves along the row.
  readonly property real lineThickness: Math.max(3, Math.round(Style.space(4)))
  readonly property real lineEdge: Style.space(3)
  // Underline or overline, each 2px nearer its edge of the bar.
  readonly property real underlineEdge: Math.max(0, lineEdge - 2)
  readonly property real overlineEdge: Math.max(0, lineEdge - 2)
  // The grey of every workspace but the current one: a lighter grey for the
  // number of one with windows, and a darker one for its line.
  readonly property color inactiveColor: Qt.alpha(root.barForeground, 0.4)
  readonly property color occupiedColor: Qt.alpha(root.barForeground, 0.75)
  readonly property color occupiedLineColor: Qt.alpha(root.barForeground, 0.45)

  function lineOn(entry) {
    line.targetIndex = workspaceIds.indexOf(entry.modelData)
    line.target = entry.lineRect
    line.targetKey = entry.modelData
  }

  function entryById(id) {
    for (var i = 0; i < entries.count; i++) {
      var entry = entries.itemAt(i)
      if (entry && entry.modelData === id) return entry
    }
    return null
  }

  // A window dropped on a workspace drips into it: in the accent on the
  // current workspace, and in grey on any other.
  function dripOn(id) {
    var entry = entryById(id)
    if (!entry) return
    if (entry.shown) line.drip(entry.lineRect, true)
    else greyDrops.drip(entry.lineRect, false)
  }

  // Minimizing a window throws a drop of the line into the ... button.
  readonly property int minimizedCount: minimizedWindows.length
  property int minimizedSeen: -1
  onMinimizedCountChanged: {
    if (minimizedSeen >= 0 && minimizedCount > minimizedSeen && moreButton.visible)
      line.fling(Qt.rect(row.x + moreButton.x + moreLine.x, row.y + moreButton.y + moreLine.y, moreLine.width, moreLine.height))
    if (minimizedSeen >= 0) minimizedSeen = minimizedCount
  }
  // Not for the windows that were already minimized when the bar started.
  Timer {
    running: true
    interval: 1500
    onTriggered: root.minimizedSeen = root.minimizedCount
  }

  // Which workspace each window is on, kept from Hyprland's own events so a
  // move can be told where it came from.
  property var windowWorkspaces: ({})
  Component.onCompleted: {
    var known = {}
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var address = workspaceApps.windowAddress(values[i])
      if (address !== "" && values[i].workspace) known[address] = values[i].workspace.id
    }
    windowWorkspaces = known
  }

  function noteWindowEvent(name, data) {
    var fields = data.split(",")
    var address = workspaceApps.windowAddress({ address: fields[0] })
    if (address === "") return
    if (name === "closewindow") {
      delete windowWorkspaces[address]
    } else if (name === "openwindow") {
      var opened = parseInt(fields[1], 10)
      if (!isNaN(opened)) windowWorkspaces[address] = opened
    } else {
      var to = parseInt(fields[1], 10)
      var from = windowWorkspaces[address]
      if (isNaN(to)) return
      windowWorkspaces[address] = to
      if (from !== undefined && from !== to) {
        greyFrom = from
        greyTo = to
        // Held from the start, or its line shows before the moving one sets off.
        greyHeldId = to
        greyWait.restart()
      }
    }
  }

  // A window moved to another workspace sends a grey line from the one it
  // left to the one it went to, moving the way the current workspace's line
  // does, and that workspace's own grey line waits for it to land. Not when
  // the move takes the current workspace along: its line already goes there.
  property int greyFrom: -1
  property int greyTo: -1
  property int greyHeldId: -1
  Timer {
    id: greyWait
    // Long enough for a switch that comes with the move to arrive first.
    interval: 60
    onTriggered: root.sendGreyLine(root.greyFrom, root.greyTo)
  }

  function sendGreyLine(fromId, toId) {
    var from = entryById(fromId)
    var to = entryById(toId)
    if (!prefs.lineAnimation || Style.reduceMotion || toId === activeId || !from || !to) {
      greyHeldId = -1
      return
    }
    greyLine.jumpTo(from.lineRect, fromId, workspaceIds.indexOf(fromId))
    greyHeldId = toId
    greyLine.visible = true
    greyLine.targetIndex = workspaceIds.indexOf(toId)
    greyLine.target = to.lineRect
    greyLine.targetKey = toId
    greyDone.restart()
  }

  Timer {
    id: greyDone
    // The move, and its splash, then the workspace's own grey line takes over.
    interval: 750
    onTriggered: {
      greyLine.visible = false
      root.greyHeldId = -1
    }
  }

  // Drips onto workspaces other than the current one. It has no line of its own.
  WorkspaceLine {
    id: greyDrops
    z: 4
    color: root.occupiedLineColor
    animated: prefs.lineAnimation && !Style.reduceMotion
    splash: prefs.lineSplash
    vertical: root.vertical
    inward: line.inward
    thickness: root.lineThickness
    dropHeight: line.dropHeight
  }

  WorkspaceLine {
    id: greyLine
    z: 4
    visible: false
    color: root.occupiedLineColor
    animated: prefs.lineAnimation && !Style.reduceMotion
    splash: prefs.lineSplash
    vertical: root.vertical
    inward: line.inward
    thickness: root.lineThickness
    dropHeight: line.dropHeight
  }

  WorkspaceLine {
    id: line
    z: 5
    color: Commons.Color.accent
    animated: prefs.lineAnimation && !Style.reduceMotion
    splash: prefs.lineSplash
    vertical: root.vertical
    inward: root.vertical ? 1 : (prefs.overline ? 1 : -1)
    thickness: root.lineThickness
    dropHeight: root.vertical ? 0 : Math.round(root.barSize * 0.2)
  }

  // Room before the button for a divider like the ones between workspaces. Half
  // a gap, with the divider on the widget's edge: the icon slot ahead of it
  // already pads its glyph, so this keeps both sides of the divider even.
  readonly property int leadGap: Math.round(entryGap / 2)

  implicitWidth: row.implicitWidth + (vertical ? 0 : leadGap)
  implicitHeight: row.implicitHeight + (vertical ? leadGap : 0)

  // Between the apps button and the panel button, in the middle of the gap.
  Rectangle {
    visible: appsButton.visible && panelButton.visible
    readonly property real thin: 1 / Math.max(1, Screen.devicePixelRatio)
    x: root.vertical ? Math.round((root.width - width) / 2) : row.x + panelButton.x - root.entryGap / 2
    y: root.vertical ? row.y + panelButton.y - root.entryGap / 2 : Math.round((root.height - height) / 2)
    width: root.vertical ? Style.space(12) : thin
    height: root.vertical ? thin : Style.space(12)
    color: Qt.alpha(root.barForeground, 0.3)
  }

  // The divider in front of the widget, on its leading edge.
  Rectangle {
    readonly property real thin: 1 / Math.max(1, Screen.devicePixelRatio)
    x: root.vertical ? Math.round((root.width - width) / 2) : 0
    y: root.vertical ? 0 : Math.round((root.height - height) / 2)
    width: root.vertical ? Style.space(12) : thin
    height: root.vertical ? thin : Style.space(12)
    color: Qt.alpha(root.barForeground, 0.3)
  }

  GridLayout {
    id: row
    anchors.fill: parent
    anchors.leftMargin: root.vertical ? 0 : root.leadGap
    anchors.topMargin: root.vertical ? root.leadGap : 0
    columns: root.vertical ? 1 : root.workspaceIds.length + 3
    columnSpacing: root.vertical ? 0 : root.entryGap
    rowSpacing: root.vertical ? root.entryGap : 0

    // Every app, in a card like the rest of this widget's.
    BarIconButton {
      id: appsButton
      bar: root.bar
      hasVisualContent: prefs.appsButton
      onPressed: function(button) {
        if (button === Qt.RightButton) root.openMenu(appsButton)
        else root.toggleApps()
      }

      AppsMark {
        anchors.centerIn: parent
        scale: appsButton.pressScale
        color: appsButton.foreground
      }
    }

    BarIconButton {
      id: panelButton
      bar: root.bar
      hasVisualContent: prefs.panelButton
      onPressed: function(button) {
        if (button === Qt.RightButton) {
          root.openMenu(panelButton)
        } else {
          root.menuOpen = false
          root.togglePanel()
        }
      }

      HoverHandler {
        id: buttonHover
        onHoveredChanged: root.followMenu()
      }

      ThreeSquares {
        anchors.centerIn: parent
        scale: panelButton.pressScale
        color: panelButton.foreground
      }
    }

    Repeater {
      id: entries
      // Keeps each entry across changes, so hovering one isn't interrupted.
      model: ScriptModel { values: root.workspaceIds }

      Grid {
        id: entry
        required property int modelData

        property alias numberButton: number
        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool shown: modelData === root.activeId
        readonly property int slot: root.slotOf(modelData)
        readonly property var apps: prefs.barIcons ? workspaceApps.appsIn(workspace ? workspace.toplevels.values : []) : []
        // Where this workspace's line sits, in the widget's coordinates.
        readonly property rect lineRect: Qt.rect(row.x + entry.x + number.x + entryLine.x,
                                                 row.y + entry.y + number.y + entryLine.y,
                                                 entryLine.width, entryLine.height)

        onShownChanged: if (shown) root.lineOn(entry)
        onLineRectChanged: if (shown) root.lineOn(entry)
        Component.onCompleted: if (shown) root.lineOn(entry)

        columns: root.vertical ? 1 : 2
        opacity: root.reorderEntry === entry ? 0.35 : 1

        HoverHandler { onHoveredChanged: root.entryHovered(entry, hovered) }

        WidgetButton {
          id: number
          bar: root.bar
          text: entry.slot === root.slots ? "0" : String(entry.slot)
          // The accent on the current workspace, and every other number the
          // same grey as its line.
          foreground: entry.shown ? Commons.Color.accent : entry.occupied ? root.occupiedColor : root.inactiveColor
          horizontalMargin: 6
          verticalPadding: 6
          fixedWidth: root.vertical ? root.barSize : Style.space(20)
          fixedHeight: root.barSize
          onPressed: function(button) {
            if (button === Qt.RightButton) root.openMenu(number)
            else root.focusWorkspace(entry.modelData)
          }

          // Lights up the whole workspace while a window is held over it.
          Rectangle {
            visible: root.dropTargetId === entry.modelData
            z: -1
            width: root.vertical ? parent.width : parent.width + (entry.apps.length > 0 ? appIcons.width : 0)
            height: root.vertical ? parent.height + (entry.apps.length > 0 ? appIcons.height : 0) : parent.height
            radius: Style.cornerRadius
            color: Style.selectedAccentFill
          }

          // One device pixel wide, in the middle of the gap before this workspace.
          Rectangle {
            readonly property real thin: 1 / Math.max(1, Screen.devicePixelRatio)
            x: root.vertical ? (parent.width - width) / 2 : -root.entryGap / 2
            y: root.vertical ? -root.entryGap / 2 : (parent.height - height) / 2
            width: root.vertical ? Style.space(12) : thin
            height: root.vertical ? thin : Style.space(12)
            color: Qt.alpha(root.barForeground, 0.3)
          }

          // Grey on a workspace with apps, as a rounded pill that runs past this
          // button to the end of the icons beside it. It stays when the
          // workspace is current: the accent line over the whole row is drawn
          // on top of it, and it shows again the moment the line leaves.
          Rectangle {
            id: entryLine
            readonly property int numberWidth: Style.space(10)
            // Held back while a grey line is on its way here from another workspace.
            readonly property bool shows: entry.occupied && root.greyHeldId !== entry.modelData
            x: (parent.width - numberWidth) / 2
            y: prefs.overline ? root.overlineEdge : parent.height - height - root.underlineEdge
            width: !root.vertical && entry.apps.length > 0 ? parent.width + icons.implicitWidth - x : numberWidth
            height: root.lineThickness
            color: "transparent"

            // Behind the current workspace's line: the part it covers is left
            // out, so none of this shows past its edges while it stretches thin.
            // What is left is a piece before it and a piece after it.
            readonly property real start: root.vertical ? entry.lineRect.y : entry.lineRect.x
            readonly property real length: root.vertical ? height : width
            readonly property real coverFrom: line.coverFrom - start
            readonly property real coverTo: line.coverTo - start
            readonly property real beforeEnd: Math.max(0, Math.min(length, coverFrom))
            readonly property real afterStart: Math.min(length, Math.max(0, coverTo))
            readonly property bool covered: coverTo > 0 && coverFrom < length

            Repeater {
              model: 2

              Rectangle {
                required property int index
                readonly property real from: !entryLine.covered ? 0 : index === 0 ? 0 : entryLine.afterStart
                readonly property real to: !entryLine.covered ? (index === 0 ? entryLine.length : 0)
                                           : index === 0 ? entryLine.beforeEnd : entryLine.length
                visible: entryLine.shows && to - from > 0.5
                x: root.vertical ? 0 : from
                y: root.vertical ? from : 0
                width: root.vertical ? entryLine.width : to - from
                height: root.vertical ? to - from : entryLine.height
                radius: Math.min(width, height) / 2
                color: root.occupiedLineColor
              }
            }
          }
        }

        // The icons are a button of their own so the number keeps its place.
        WidgetButton {
          id: appIcons
          bar: root.bar
          hasVisualContent: entry.apps.length > 0
          fixedWidth: root.vertical ? root.barSize : icons.implicitWidth + Style.space(6)
          fixedHeight: root.vertical ? icons.implicitHeight + Style.space(6) : root.barSize
          onPressed: function(button) {
            if (button === Qt.RightButton) root.openMenu(appIcons)
            else root.focusWorkspace(entry.modelData)
          }

          Grid {
            id: icons
            // Placed by value: an anchor that gets cleared when the bar changes
            // sides would leave the icons where it last put them.
            x: root.vertical ? (parent.width - width) / 2 : 0
            y: root.vertical ? 0 : (parent.height - height) / 2
            columns: root.vertical ? 1 : Math.max(1, entry.apps.length)
            spacing: Style.space(3)
            scale: appIcons.pressScale

            Repeater {
              model: entry.apps

              AppMark {
                required property var modelData
                source: modelData.source
                letter: modelData.letter
                size: Style.bar.iconCanvas
                letterColor: appIcons.foreground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              }
            }
          }
        }
      }
    }

    // The windows that are minimized, past the last workspace.
    WidgetButton {
      id: moreButton
      bar: root.bar
      hasVisualContent: prefs.minimizedButton
      foreground: root.minimizedWindows.length > 0 ? root.barForeground : Qt.alpha(root.barForeground, 0.5)
      horizontalMargin: 6
      verticalPadding: 6
      fixedWidth: root.vertical ? root.barSize : Style.space(20)
      fixedHeight: root.barSize
      onPressed: function(button) {
        if (button === Qt.RightButton) root.openMenu(moreButton)
        else root.toggleMinimized()
      }

      HoverHandler {
        id: moreHover
        onHoveredChanged: root.followMenu()
      }

      // Where a minimized window's drop lands, in line with the workspaces'.
      Item {
        id: moreLine
        width: Style.space(10)
        height: root.lineThickness
        x: (parent.width - width) / 2
        y: prefs.overline ? root.overlineEdge : parent.height - height - root.underlineEdge
      }

      // Drawn, because text dots sit on the baseline, below the numbers' middle.
      Row {
        anchors.centerIn: parent
        scale: moreButton.pressScale
        spacing: 2

        Repeater {
          model: 3

          Rectangle {
            width: 2
            height: 2
            radius: 1
            color: moreButton.foreground
          }
        }
      }

      Rectangle {
        readonly property real thin: 1 / Math.max(1, Screen.devicePixelRatio)
        x: root.vertical ? (parent.width - width) / 2 : -root.entryGap / 2
        y: root.vertical ? -root.entryGap / 2 : (parent.height - height) / 2
        width: root.vertical ? Style.space(12) : thin
        height: root.vertical ? thin : Style.space(12)
        color: Qt.alpha(root.barForeground, 0.3)
      }
    }
  }
}
