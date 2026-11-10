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
  // Exclusive until the open has been committed to the compositor, then OnDemand.
  // Hyprland focuses OnDemand when a surface first maps, but not when an
  // already-mapped surface (a swipe, or a reopen during the close) changes
  // from None back to OnDemand. After an arrow, slid keeps Exclusive: focusing
  // the workspace focuses a window, and that window takes the keyboard from
  // OnDemand, so the next arrow never arrives.
  property bool focusPrimed: false
  // One beat away from Exclusive. Coming back is what takes the keyboard;
  // a layer that is already Exclusive does not.
  property bool reclaiming: false
  // OnDemand for the start of a close. None while the surface is still mapped
  // refocuses the window from the workspace the panel opened on.
  property bool keyboardHold: false
  property int pendingSlot: 0

  property bool swiping: false
  property real swipeBase: 0
  property var scr: null

  readonly property bool shown: progress > 0 || opened || settle.running

  readonly property int sw: scr ? scr.width : 0
  readonly property int sh: scr ? scr.height : 0
  readonly property var monitor: scr ? Hyprland.monitorFor(scr) : null
  readonly property int activeId: monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
  // The workspace the panel is showing. Arrows move this immediately. Until
  // they do, it follows Hyprland, and a late event must not rewind an arrow.
  property int viewedId: -1
  property bool slid: false
  onActiveIdChanged: if (activeId > 0 && !slid) viewedId = activeId

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
  // The list shows this workspace while the pointer is not on a thumbnail.
  readonly property int homeListId: viewedId > 0 ? viewedId : activeId
  // Follows the pointer, but lets go late so a wandering path between a card and
  // its list doesn't lose the list. Letting go returns to homeListId.
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
  readonly property int fadeMs: 300

  // The selected workspace's windows, topmost first.
  readonly property var listWindows: {
    var order = stackOrder
    return windowsOn(listId).sort(function(a, b) {
      return (order[workspaceApps.windowAddress(b)] || 0) - (order[workspaceApps.windowAddress(a)] || 0)
    })
  }

  // Address of the row Up and Down are on. Kept across stack refreshes.
  property string windowPick: ""
  readonly property int windowIndex: {
    var windows = listWindows
    for (var i = 0; i < windows.length; i++) {
      if (workspaceApps.windowAddress(windows[i]) === windowPick) return i
    }
    return 0
  }
  // A search with matches keeps Up and Down. Otherwise they move through this list.
  readonly property bool windowKeys: opened && popup === "" && !reorderLabel && !dragTile
    && listWindows.length > 0 && (appSearch.browsing || appSearch.hits.length === 0)

  onListIdChanged: Qt.callLater(preferFocusedWindow)
  onListWindowsChanged: if (listedIndex(windowPick) < 0) preferFocusedWindow()

  function listedIndex(address) {
    var windows = listWindows
    for (var i = 0; i < windows.length; i++) {
      if (workspaceApps.windowAddress(windows[i]) === address) return i
    }
    return -1
  }

  function preferFocusedWindow() {
    var windows = listWindows
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].activated) {
        windowPick = workspaceApps.windowAddress(windows[i])
        return
      }
    }
    windowPick = windows.length > 0 ? workspaceApps.windowAddress(windows[0]) : ""
  }

  function cycleWindow(step) {
    if (!windowKeys) return false
    var windows = listWindows
    var count = windows.length
    var next = windowIndex + step
    if (next < 0) next = count - 1
    else if (next >= count) next = 0
    var address = workspaceApps.windowAddress(windows[next])
    if (address === "") return false
    windowPick = address
    return true
  }

  // Same path as clicking the row: go to its workspace and focus that window.
  function confirmListedWindow() {
    if (!windowKeys) return false
    var windows = listWindows
    var index = windowIndex
    if (index < 0 || index >= windows.length) return false
    clickWindow(listId, windows[index])
    return true
  }

  Timer {
    id: listLinger
    interval: 200
    onTriggered: root.listId = root.homeListId > 0 ? root.homeListId : -1
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

  // Start the Exclusive window once the backing surface is actually mapped.
  function beginFocusPrime() {
    if (opened && panel.backingWindowVisible) focusPrimeTimer.restart()
  }

  function open() {
    ensureScreen()
    slideDispatch.stop()
    reclaimTimer.stop()
    reclaimHold.stop()
    handoff.stop()
    keyboardHold = false
    slid = false
    reclaiming = false
    pendingSlot = 0
    if (activeId > 0) viewedId = activeId
    appSearch.clear()
    // Clear this before opened flips, so the first keyboard mode is Exclusive.
    focusPrimed = false
    opened = true
    listLinger.stop()
    listId = homeListId
    animateTo(1, 220)
    beginFocusPrime()
    focusRetry.arm()
  }

  function close() {
    // Whatever is showing now has to survive the keyboard going back.
    // Stop the slide first so a deferred workspace focus cannot land after.
    slideDispatch.stop()
    reclaimTimer.stop()
    reclaimHold.stop()
    pendingSlot = 0
    if (opened) {
      holdWorkspace(viewedId > 0 ? viewedId : activeId)
      // Exclusive refuses a window focus, so the open-from window is still
      // the focused one after an arrow. OnDemand clears that grab without
      // refocusing it. finishHandoff then focuses where the panel is leaving.
      keyboardHold = true
      handoff.restart()
    }
    opened = false
    reclaiming = false
    focusPrimeTimer.stop()
    focusRetry.stop()
    focusPrimed = false
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

  // The field gives the keyboard up after an arrow. This claims it back for
  // whichever target should have it now. Never the overlay scope: that would
  // hand focus to the field, the last child that had it.
  function keepPanelKeys() {
    if (!opened) return
    if (settingsPopup.item && settingsPopup.item.capturing) return
    if (appSearch.browsing) {
      if (!browseKeys.activeFocus) browseKeys.forceActiveFocus()
    } else {
      appSearch.focusField()
    }
  }

  // One slot over, empty or not, as Super+Shift+Left and Right do. It does
  // not wrap. The search field gives up the keyboard either way. The workspace
  // focus is synchronous IPC, so it waits until Exclusive has been committed.
  // Doing both in one turn focuses a window while this layer is still OnDemand.
  function slideWorkspace(step) {
    appSearch.browse()
    keepPanelKeys()
    var from = viewedId > 0 ? viewedId : activeId
    if (from < 1) return
    var slot = slotOf(from) + step
    if (slot < 1 || slot > slots) return
    slid = true
    viewedId = blockOf(from) * slots + slot
    pendingSlot = slot
    // A thumbnail under the pointer keeps its own windows. Otherwise the list
    // follows the workspace the arrows just moved to.
    if (!hoverTile && hoverCardId < 1) {
      listLinger.stop()
      listId = viewedId
    }
    slideDispatch.restart()
  }

  function commitSlide() {
    if (!opened || pendingSlot < 1) return
    var slot = pendingSlot
    if (monitor)
      workspaceApps.dispatchWithoutWarp('o.workspaces.focus(' + slot + ', "' + monitor.name + '")')
    else
      workspaceApps.dispatchWithoutWarp('hl.dsp.focus({ workspace = "' + viewedId + '" })')
    Qt.callLater(keepPanelKeys)
  }

  // A window focus while already Exclusive does not give the keyboard back.
  // Leave and re-enter so the return takes it, then claim the key target again.
  function noteFocusSteal() {
    if (!opened || !slid) return
    Qt.callLater(keepPanelKeys)
    // The deferred focus has not run yet. Dropping Exclusive now would give
    // the keyboard to the window that focus is about to raise.
    if (slideDispatch.running || reclaiming || reclaimHold.running) return
    reclaiming = true
    reclaimTimer.restart()
  }

  function isLetter(text) {
    if (!text || String(text).length !== 1) return false
    var value = String(text)
    return value.toLowerCase() !== value.toUpperCase()
  }

  // Hyprland does not tag a new window with the workspace it was launched
  // from, so the exec rule places it on the one the panel is showing.
  function launchOnViewed(command) {
    var id = viewedId > 0 ? viewedId : activeId
    var quoted = JSON.stringify(String(command || ""))
    if (id <= 0) {
      Util.execDetached(String(command || ""))
      return
    }
    Hyprland.dispatch('(function()'
      + ' local no_warps = hl.get_config("cursor.no_warps")'
      + ' local on_change = hl.get_config("cursor.warp_on_change_workspace")'
      + ' hl.config({ cursor = { no_warps = true, warp_on_change_workspace = 0 } })'
      + ' hl.exec_cmd(' + quoted + ', { workspace = ' + JSON.stringify(String(id)) + ' })'
      + ' hl.config({ cursor = { no_warps = no_warps, warp_on_change_workspace = on_change } })'
      + ' end)')
  }

  // Hyprland refocuses the previous window again when the surface unmaps.
  // finishHandoff has already focused the destination, so this last pass
  // stays on that workspace.
  function holdWorkspace(id) {
    heldId = id
    handBack.restart()
  }

  // The focused window on this workspace, or the topmost one.
  function windowOn(id) {
    if (id <= 0) return ""
    var order = stackOrder
    var windows = windowsOn(id)
    var top = ""
    var topRank = -1
    var activated = ""
    for (var i = 0; i < windows.length; i++) {
      var address = workspaceApps.windowAddress(windows[i])
      if (address === "") continue
      if (windows[i].activated) activated = address
      var rank = order[address] || 0
      if (top === "" || rank >= topRank) {
        top = address
        topRank = rank
      }
    }
    return activated !== "" ? activated : top
  }

  // The workspace focus from an arrow does not move the focused window: an
  // exclusive layer refuses it, and focusing the workspace again once it is
  // already current does nothing. Focus the window while OnDemand still holds,
  // so the following None does not switch back to where the panel opened.
  function finishHandoff() {
    if (!keyboardHold || opened) {
      keyboardHold = false
      return
    }
    var id = heldId
    var address = heldWindow
    if (address === "") address = windowOn(id)
    if (id > 0 && address !== "") {
      workspaceApps.dispatchWithoutWarp('hl.dsp.focus({ window = "address:' + address + '" })')
    } else if (id > 0 && id !== activeId) {
      if (blockOf(id) === blockOf(activeId) && monitor)
        workspaceApps.dispatchWithoutWarp('o.workspaces.focus(' + slotOf(id) + ', "' + monitor.name + '")')
      else
        workspaceApps.dispatchWithoutWarp('hl.dsp.focus({ workspace = "' + id + '" })')
    }
    keyboardHold = false
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

  Timer {
    id: focusPrimeTimer
    // Long enough for the Exclusive keyboard enter to commit, short enough
    // that the pointer grab does not linger.
    interval: 75
    onTriggered: if (root.opened) root.focusPrimed = true
  }

  // Qt focus can land on the overlay scope, or get reset when the keyboard
  // mode settles. Keep claiming the field, or the arrow target once the field
  // has let go, until that target holds still.
  Timer {
    id: focusRetry
    interval: 32
    repeat: true
    property int ticks: 0
    property int stable: 0
    property bool wasPrimed: false
    function arm() {
      ticks = 0
      stable = 0
      wasPrimed = false
      restart()
    }
    onTriggered: {
      if (!root.opened) {
        stop()
        return
      }
      ticks++
      var primed = root.focusPrimed
      if (primed && !wasPrimed) stable = 0
      wasPrimed = primed
      if (appSearch.browsing) {
        stable = 0
        if (!browseKeys.activeFocus) browseKeys.forceActiveFocus()
      } else if (appSearch.typing) {
        if (primed) stable++
      } else {
        stable = 0
        appSearch.focusField()
      }
      // Keep claiming the arrow target for the whole browse. A keyboard-mode
      // change can clear Qt focus after the last explicit claim.
      if (appSearch.browsing) return
      if (primed && stable >= 4) stop()
      else if (ticks >= 24) stop()
    }
  }

  // Not Style.duration: a reduced-motion zero would dispatch before Exclusive
  // is committed, which is the race this timer exists to avoid.
  Timer {
    id: slideDispatch
    interval: 48
    onTriggered: root.commitSlide()
  }

  // Same wait in reverse. OnDemand has to be committed, and the exclusive
  // grab gone, before the destination window will take focus.
  Timer {
    id: handoff
    interval: 48
    onTriggered: root.finishHandoff()
  }

  Timer {
    id: reclaimTimer
    interval: 32
    onTriggered: {
      root.reclaiming = false
      if (root.opened && root.slid) reclaimHold.restart()
      Qt.callLater(root.keepPanelKeys)
    }
  }

  // Ignore the focus events this pulse itself causes.
  Timer {
    id: reclaimHold
    interval: 80
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
      if (root.opened && root.slid && (event.name === "workspacev2" || event.name === "activewindowv2"))
        root.noteFocusSteal()
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
    // Exclusive on every open, including when this surface is already mapped,
    // then OnDemand so the pointer grab does not stay. None while a swipe has
    // not committed, so the desktop keeps the keyboard until the panel is open.
    // After an arrow, Exclusive stays: OnDemand would lose the next arrow to
    // the window just focused. reclaiming dips to OnDemand for one beat so the
    // return to Exclusive can take the keyboard back. keyboardHold is that
    // same OnDemand across the start of a close, before None.
    shownKeyboardFocus: {
      if (root.keyboardHold) return WlrKeyboardFocus.OnDemand
      if (!root.opened) return WlrKeyboardFocus.None
      if (root.reclaiming) return WlrKeyboardFocus.OnDemand
      if (root.slid || !root.focusPrimed) return WlrKeyboardFocus.Exclusive
      return WlrKeyboardFocus.OnDemand
    }
    WlrLayershell.namespace: root.layerNamespace
    onBackingWindowVisibleChanged: root.beginFocusPrime()

    FocusScope {
      anchors.fill: parent
      focus: true

      // Zero size on purpose. Forcing this scope would focus the text field,
      // which is the last child that held focus. Arrows need their own target
      // once that field has let go.
      Item {
        id: browseKeys
        width: 0
        height: 0
        focus: root.opened && appSearch.browsing
        Keys.enabled: root.opened && appSearch.browsing
        Keys.onPressed: event => {
          if (settingsPopup.item && settingsPopup.item.capturing) {
            settingsPopup.item.takeKey(event.key, event.modifiers, event.text)
            event.accepted = true
            return
          }
          var plain = (event.modifiers & ~(Qt.ShiftModifier | Qt.KeypadModifier)) === 0
          if (plain && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
            root.slideWorkspace(event.key === Qt.Key_Left ? -1 : 1)
            event.accepted = true
            return
          }
          if (plain && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
            root.cycleWindow(event.key === Qt.Key_Up ? -1 : 1)
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (!root.confirmListedWindow()) root.close()
            event.accepted = true
            return
          }
          if (plain && root.isLetter(event.text)) {
            appSearch.typeAgain(event.text)
            event.accepted = true
          }
        }
      }

      // The search field takes keys while it is focused, including Escape.
      // A key that arrives before that focus lands still goes into the field.
      Keys.onPressed: event => {
        if (settingsPopup.item && settingsPopup.item.capturing) {
          settingsPopup.item.takeKey(event.key, event.modifiers, event.text)
          event.accepted = true
          return
        }
        var plain = (event.modifiers & ~(Qt.ShiftModifier | Qt.KeypadModifier)) === 0
        if (plain && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
          root.slideWorkspace(event.key === Qt.Key_Left ? -1 : 1)
          event.accepted = true
          return
        }
        if (plain && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
          root.cycleWindow(event.key === Qt.Key_Up ? -1 : 1)
          event.accepted = true
          return
        }
        if (appSearch.typing) return
        if (appSearch.browsing) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (!root.confirmListedWindow()) root.close()
            event.accepted = true
          } else if (plain && root.isLetter(event.text)) {
            appSearch.typeAgain(event.text)
            event.accepted = true
          }
          return
        }
        if (event.key === Qt.Key_Escape) {
          if (root.popup !== "") root.popup = ""
          else root.close()
          event.accepted = true
          return
        }
        if (!plain || !event.text) return
        appSearch.focusField()
        appSearch.insertText(event.text)
        event.accepted = true
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

      // The panel is an overlay, so this stays above the bar on any edge.
      // The field is pinned to the top of the screen.
      SearchField {
        id: appSearch
        anchors.horizontalCenter: parent.horizontalCenter
        progress: root.progress
        opened: root.opened
        panelColor: root.bandColor
        popupOpen: root.popup !== ""
        yieldKeys: settingsPopup.item ? settingsPopup.item.capturing : false
        onYielded: function(key, modifiers, text) {
          if (settingsPopup.item) settingsPopup.item.takeKey(key, modifiers, text)
        }
        onWorkspaceStepped: step => root.slideWorkspace(step)
        onWindowStepped: step => root.cycleWindow(step)
        onWindowActivate: if (!root.confirmListedWindow()) root.close()
        onLaunchRequested: command => root.launchOnViewed(command)
        onDismiss: root.close()
        limit: {
          var floor = band.y
          if (windowList.visible) floor = Math.min(floor, windowList.y)
          if (popupCard.visible) floor = Math.min(floor, popupCard.y)
          return Math.max(0, floor - Style.spacing.xxl)
        }
        onLaunched: root.close()
        onEscapePressed: {
          if (root.popup !== "") root.popup = ""
          else root.close()
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
        visible: prefs.minimizedButton
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
        y: band.y - height
        color: workspaceApps.cardBackground(root.shell ? root.shell.barConfig : null)
        topLeftRadius: Style.cornerRadius
        topRightRadius: Style.cornerRadius

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
              required property int index
              readonly property bool picked: root.windowKeys && index === root.windowIndex
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
                  : row.picked || rowMouse.containsMouse || closeButton.hovered ? Style.hoverFill : "transparent"
                border.width: root.dragTile === row || row.picked || rowMouse.containsMouse || closeButton.hovered ? 1 : 0
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
                onContainsMouseChanged: {
                  if (!containsMouse) return
                  var address = workspaceApps.windowAddress(row.modelData)
                  if (address !== "") root.windowPick = address
                }
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
