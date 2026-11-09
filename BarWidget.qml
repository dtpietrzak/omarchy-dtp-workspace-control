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
    if (settingsOpen) return
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

  function openMenu() {
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
    var iconCenter = peek.sideEdge + settingsRow.edge + settingsRow.iconSize / 2
    placeCard(menuCard, panelButton, menuCard.width, menuCard.height, vertical ? 0 : panelButton.width / 2 - iconCenter)
  }

  // Gone a moment after the pointer has left both the button and the popover.
  function followMenu() {
    if (!menuOpen) return
    if (settingsOpen || peekDragItem || buttonHover.hovered || moreHover.hovered || menuHover.hovered) menuTimer.stop()
    else menuTimer.restart()
  }

  Timer {
    id: menuTimer
    interval: 400
    onTriggered: if (!root.peekDragItem && !root.settingsOpen && !buttonHover.hovered && !moreHover.hovered && !menuHover.hovered) root.menuOpen = false
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

  MouseArea {
    id: numbersDrag
    parent: root.barSlot || root
    z: 1000
    enabled: !!root.barSlot
    // Between the button and the ..., which the bar still handles.
    x: root.vertical ? 0 : panelButton.width
    y: root.vertical ? panelButton.height : 0
    width: parent.width - x - (root.vertical ? 0 : moreButton.width + root.entryGap)
    height: parent.height - y - (root.vertical ? moreButton.height + root.entryGap : 0)
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
      peekShrink.stop()
      peekDragScale = 1
      peekShrink.to = peekDragItem.dragScale
      peekShrink.start()
    }
    followPointer()
    followMenu()
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
          }
          onDragDropped: function(toplevel, fromId) {
            var target = root.dropTargetId
            root.dropTargetId = -1
            root.droppedAt = Date.now()
            if (target > 0 && target !== fromId) workspaceApps.moveWindow(toplevel, target)
          }
          onDragCanceled: root.dropTargetId = -1
        }
      }
    }

    // The window under the cursor while it is being dragged.
    DragGhost {
      source: root.dragSource === peekContent.item ? root.peekDragItem : null
      position: root.peekDragPos
      grab: peekContent.item ? peekContent.item.grabPoint : Qt.point(0, 0)
      itemScale: root.peekDragScale
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
    WlrLayershell.keyboardFocus: root.settingsOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

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
          }
          onDragDropped: function(toplevel) {
            var target = root.dropTargetId
            root.dropTargetId = -1
            root.droppedAt = Date.now()
            if (target > 0) workspaceApps.moveWindow(toplevel, target)
          }
          onDragCanceled: root.dropTargetId = -1
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
        readonly property real widest: Math.max(settingsRow.implicitWidth, panelRow.implicitWidth)
        // Settings comes first, except on a bottom bar, where it sits nearest the bar.
        readonly property bool panelFirst: peek.barSide === "bottom"
        implicitHeight: settingsRow.implicitHeight + panelRow.implicitHeight
        height: implicitHeight

        MenuRow {
          id: settingsRow
          y: menuRows.panelFirst ? panelRow.height : 0
          width: parent.width
          height: implicitHeight
          label: "Settings"
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
          y: menuRows.panelFirst ? 0 : settingsRow.height
          width: parent.width
          height: implicitHeight
          label: "Open workspace panel"
          onClicked: {
            root.menuOpen = false
            root.togglePanel()
          }

          ThreeSquares {
            anchors.centerIn: parent
            color: Commons.Color.foreground
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
      var switched = name === "workspacev2" && root.monitor !== null && root.monitor.focused
      if (switched || name === "moveworkspacev2" || name === "changeworkspaceid") {
        Hyprland.refreshMonitors()
        Hyprland.refreshWorkspaces()
      }
    }
  }

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  GridLayout {
    id: row
    anchors.fill: parent
    columns: root.vertical ? 1 : root.workspaceIds.length + 2
    columnSpacing: root.vertical ? 0 : root.entryGap
    rowSpacing: root.vertical ? root.entryGap : 0

    BarIconButton {
      id: panelButton
      bar: root.bar
      hasVisualContent: true
      onPressed: function(button) {
        if (button === Qt.RightButton) {
          root.openMenu()
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

        columns: root.vertical ? 1 : 2
        opacity: root.reorderEntry === entry ? 0.35 : 1

        HoverHandler { onHoveredChanged: root.entryHovered(entry, hovered) }

        WidgetButton {
          id: number
          bar: root.bar
          text: entry.slot === root.slots ? "0" : String(entry.slot)
          foreground: entry.occupied || entry.shown ? root.barForeground : Qt.alpha(root.barForeground, 0.5)
          horizontalMargin: 6
          verticalPadding: 6
          fixedWidth: root.vertical ? root.barSize : Style.space(20)
          fixedHeight: root.barSize
          onPressed: function() { root.focusWorkspace(entry.modelData) }

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

          // Accent on the current workspace, grey on others with apps. It runs
          // past this button to the end of the icons beside it.
          Rectangle {
            readonly property int numberWidth: Style.space(10)
            visible: entry.shown || entry.occupied
            x: (parent.width - numberWidth) / 2
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(3)
            width: !root.vertical && entry.apps.length > 0 ? parent.width + icons.implicitWidth - x : numberWidth
            height: Math.max(1, Style.space(2))
            radius: height / 2
            color: entry.shown ? Commons.Color.accent : Qt.alpha(number.foreground, 0.4)
          }
        }

        // The icons are a button of their own so the number keeps its place.
        WidgetButton {
          id: appIcons
          bar: root.bar
          hasVisualContent: entry.apps.length > 0
          fixedWidth: root.vertical ? root.barSize : icons.implicitWidth + Style.space(6)
          fixedHeight: root.vertical ? icons.implicitHeight + Style.space(6) : root.barSize
          onPressed: function() { root.focusWorkspace(entry.modelData) }

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
      hasVisualContent: true
      foreground: root.minimizedWindows.length > 0 ? root.barForeground : Qt.alpha(root.barForeground, 0.5)
      horizontalMargin: 6
      verticalPadding: 6
      fixedWidth: root.vertical ? root.barSize : Style.space(20)
      fixedHeight: root.barSize
      onPressed: root.toggleMinimized()

      HoverHandler {
        id: moreHover
        onHoveredChanged: root.followMenu()
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
