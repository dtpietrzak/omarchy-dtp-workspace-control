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
import "Chord.js" as Chord

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
  // When an arrow last switched the workspace. Events for a little while after
  // are its own, arriving late.
  property real ownSwitchAt: 0
  onActiveIdChanged: followActive()

  // A switch from outside the panel, as Super and a number or Super+Shift and
  // an arrow do while it is open, moves it the same as its own arrows: the
  // workspace it shows, the window list and the selection all follow.
  function followActive() {
    if (activeId <= 0) return
    if (slid) {
      // Its own arrow landing, or a late event from before it.
      if (activeId === viewedId) return
      if (slideDispatch.running || Date.now() - ownSwitchAt < 400) return
    }
    viewedId = activeId
    if (!opened) return
    if (!hoverTile && hoverCardId < 1 && !dragTile) {
      listLinger.stop()
      listId = viewedId
    }
    // Hyprland hands the keyboard to a window on the workspace it just went to.
    // Keep it the way an arrow does, so Enter and the rest still reach the panel.
    slid = true
    noteFocusSteal()
  }

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
  // The spot on the mini view it was picked up by, which stays under the pointer.
  property point dragGrab: Qt.point(0, 0)
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
  onDragTileChanged: {
    if (!dragTile) toDesktop = false
    if (!dragTile) rowThumb = null
    if (!dragTile) heldAt = null
    if (!dragTile) dragFromScreen = false
    if (!dragTile) raisedAddress = ""
    followPointer()
    // Let go or put down: a window hidden while it was carried comes back. One
    // sent to another workspace waits until it is there, so it never flashes here.
    if (!dragTile) Qt.callLater(function() {
      if (root.droppedAway) carriedHider.showAfterMove()
      else carriedHider.show()
      root.droppedAway = false
    })
    if (!dragTile) return
    lastCarried = null
    // Picked up, it shrinks to its carried size around the spot it is held by, and a
    // picture of it is kept for when it lands.
    dragShot = null
    dragThumbShot = null
    dragScale = 1
    dragShrink.to = carriedScale
    if (flightsOn) dragShrink.restart()
    var picked = dragTile
    picked.grabToImage(function(result) { if (root.dragTile === picked) root.dragShot = result })
    // A row from the list lands as its window's mini view, so keep that too.
    var thumb = picked.listRow ? tileFor(picked.modelData) : null
    if (thumb) thumb.grabToImage(function(result) { if (root.dragTile === picked) root.dragThumbShot = result })
  }
  property var dragThumbShot: null

  // The mini view showing this window, on whichever card it is.
  function tileFor(toplevel) {
    var address = workspaceApps.windowAddress(toplevel)
    if (address === "") return null
    for (var c = 0; c < cards.children.length; c++) {
      var card = cards.children[c]
      if (!card.tiles) continue
      for (var i = 0; i < card.tiles.count; i++) {
        var tile = card.tiles.itemAt(i)
        if (tile && tile.placed && workspaceApps.windowAddress(tile.modelData) === address) return tile
      }
    }
    return null
  }
  property real dragScale: 1
  // How big a carried list row is, against its full size.
  readonly property real carryScale: 0.75
  // A mini view shrinks further than a row does, which has text to keep readable.
  readonly property real tileCarryScale: 0.5
  readonly property real carriedScale: dragTile && !dragTile.listRow ? tileCarryScale : carryScale
  property var dragShot: null
  NumberAnimation { id: dragShrink; target: root; property: "dragScale"; to: root.carryScale; duration: Style.duration(180); easing.type: Easing.OutCubic }
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

  // The row of the mini view under the pointer, when the list is showing its
  // workspace. Hovering a mini view picks its row, the same as Up and Down do.
  function pickHoveredWindow() {
    if (!hoverTile || hoverTile.listRow || hoverTile.wsId !== listId) return false
    var address = workspaceApps.windowAddress(hoverTile.modelData)
    if (address === "" || listedIndex(address) < 0) return false
    windowPick = address
    return true
  }
  onHoverTileChanged: pickHoveredWindow()

  function preferFocusedWindow() {
    if (pickHoveredWindow()) return
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
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

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
    ownSwitchAt = Date.now()
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

  // The card a carried window is over. Anywhere on the band is over one: above
  // and below a card count as that card, the gap between two cards is half
  // each, and past either end of the row is the card at that end. Only above
  // the band, on the desktop, is it over none.
  function cardAt(x, y) {
    if (y < band.y) return null
    var point = cards.mapFromItem(panel.contentItem, x, y)
    var nearest = null
    var nearestBy = 0
    for (var i = 0; i < cards.children.length; i++) {
      var each = cards.children[i]
      if (each.wsId === undefined || !each.visible) continue
      var by = point.x < each.x ? each.x - point.x : Math.max(0, point.x - (each.x + each.width))
      if (!nearest || by < nearestBy) {
        nearest = each
        nearestBy = by
      }
    }
    return nearest
  }

  // The card the window being dragged is over. The same, but for a row from
  // the list over its own workspace: that counts only on the card itself. The
  // band around it, which the row crosses on its way down from the list, is
  // over nothing, so its window stays as it is until it gets there.
  function dragCardAt(tile, x, y) {
    var card = cardAt(x, y)
    if (!card || !tile || !tile.listRow || card.wsId !== tile.wsId) return card
    var point = card.mapFromItem(panel.contentItem, x, y)
    return card.contains(point) ? card : null
  }

  // The mini view of the topmost real window at this screen position. A
  // window's title bar counts as the window: it is where a window is usually
  // picked up by. Hyprland draws it above the window and outside the size it
  // reports, so a spot on no window itself is tried again as a title bar.
  function tileAt(x, y) {
    var bar = prefs.titleBarHeight
    return windowTileAt(x, y, 0) || (bar > 0 ? windowTileAt(x, y, bar) : null)
  }

  function windowTileAt(x, y, above) {
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
        if (px < at[0] || py < at[1] - above || px >= at[0] + size[0] || py >= at[1] + size[1]) continue
        if (!best || tile.z > best.z) best = tile
      }
    }
    return best
  }

  // Title bars can have been turned on or off, or resized, since it last came up.
  onShownChanged: if (shown) prefs.readTitleBars()


  // grab is the spot on the tile the drag started from, taken when it starts.
  function dragTo(tile, x, y, grab) {
    if (dragTile !== tile) dragGrab = grab || Qt.point(tile.width / 2, tile.height / 2)
    dragTile = tile
    dragPos = Qt.point(x, y)
    var card = dragCardAt(tile, x, y)
    // Over the desktop, a window is headed for the workspace being shown,
    // whose card lights up the same as one it is carried over. One already on
    // that workspace is treated the same, and moves when it is let go.
    toDesktop = !card && activeId > 0 && overDesktop(x, y)
    hoverId = card ? card.wsId : toDesktop ? activeId : -1
    // A row carried onto the workspace being shown, its card or the desktop,
    // turns into its window's mini view.
    rowThumb = tile.listRow && (card ? card.wsId === activeId : overDesktop(x, y)) ? tileFor(tile.modelData) : null
    carryWindow(tile, card)
  }

  // Set while a window is carried over the desktop, and while a minimized one is.
  property bool toDesktop: false
  property bool minimizedToDesktop: false
  // The mini view a carried row is shown as, while it is over the workspace
  // being shown.
  property Item rowThumb: null
  // Set for a drag that began on the real window, on the desktop, and not on
  // its mini view or its row.
  property bool dragFromScreen: false

  // On the desktop itself: above the band, and not on anything of the panel's
  // that floats there.
  function overDesktop(x, y) {
    if (y >= band.y) return false
    var floats = [windowList, popupCard, appSearch]
    for (var i = 0; i < floats.length; i++) {
      var item = floats[i]
      if (item.visible && item.contains(item.mapFromItem(panel.contentItem, x, y))) return false
    }
    return true
  }

  // Where on the screen a window let go of over the desktop goes: centered on
  // the pointer, whatever spot its mini view or row was picked up by. One
  // picked up by the real window stays held by that spot of it, as a window
  // dragged about the screen is. Only a floating window has a spot of its own.
  function desktopSpot(tile) {
    var toplevel = tile ? tile.modelData : null
    var ipc = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject : null
    if (!monitor || !ipc || !ipc.floating || !ipc.size || sw <= 0) return null
    var width = ipc.size[0], height = ipc.size[1]
    var ratio = root.cardW / sw
    var left = dragFromScreen ? dragPos.x - dragGrab.x / ratio : dragPos.x - width / 2
    var top = dragFromScreen ? dragPos.y - dragGrab.y / ratio : dragPos.y - height / 2
    return {
      address: workspaceApps.windowAddress(toplevel),
      x: Math.round(monitor.x + prefs.keepX(left, width, sw, dragFromScreen)),
      y: Math.round(monitor.y + prefs.keepY(top, height, sh, dragFromScreen)),
      width: width,
      height: height
    }
  }
  // That spot for the window being carried there now, which is outlined.
  // A window carried from another workspace over the card of the one being
  // shown is outlined on the screen as well, where it would turn up.
  readonly property var desktopLanding: {
    if (!dragTile) return null
    if (toDesktop) return desktopSpot(dragTile)
    if (dragTile.wsId === activeId || hoverId !== activeId) return null
    return dropSpot(dragTile, dragCardAt(dragTile, dragPos.x, dragPos.y))
  }

  // Where a floating window would land on the card it is carried over, as the
  // outline of its mini view there: a row from the list on any card, and a
  // mini view on another workspace's. Over its own card a mini view needs
  // none, being at full size where the window already is.
  readonly property var cardLanding: {
    var card = dragTile ? dragCardAt(dragTile, dragPos.x, dragPos.y) : null
    if (card && card.wsId === dragTile.wsId && !dragTile.listRow) return null
    return cardSpotRect
  }
  // The same spot whichever card that is, its own included: kept inside the
  // card, as the window is kept on the screen. A row shown as its mini view
  // sits on it.
  readonly property var cardSpotRect: {
    if (!dragTile || !monitor || sw <= 0) return null
    var card = dragCardAt(dragTile, dragPos.x, dragPos.y)
    var spot = card ? dropSpot(dragTile, card) : null
    var ipc = spot ? dragTile.modelData.lastIpcObject : null
    if (!spot || !ipc || !ipc.size) return null
    var ratio = root.cardW / sw
    var width = ipc.size[0] * ratio, height = ipc.size[1] * ratio
    var at = card.mapToItem(panel.contentItem, onCardX((spot.x - monitor.x) * ratio, width), onCardY((spot.y - monitor.y) * ratio, height))
    return Qt.rect(at.x, at.y, width, height)
  }

  // Where a mini view is drawn on its card, from where its window is or
  // would be: always wholly on the card. Only the window itself, and the
  // landing box on the screen, go past the edges a drop may go past.
  function onCardX(x, width) { return Math.max(0, Math.min(cardW - width, x)) }
  function onCardY(y, height) { return Math.max(0, Math.min(cardH - height, y)) }

  function cardFor(id) {
    for (var i = 0; i < cards.children.length; i++) {
      if (cards.children[i].wsId === id) return cards.children[i]
    }
    return null
  }

  // The real window goes where its mini view is carried: over its own card, to
  // the same spot on the screen as the mini view's spot on the card; above the
  // band, on the workspace being shown, straight under the pointer. Over
  // another card it waits where it is, for the drop to send it there. Only a
  // floating window has a spot of its own to go to.
  property var carried: null
  // Where the mini view being carried over its own card is kept, when its
  // window is: its corner, in the panel's coordinates. Null lets it follow
  // the pointer.
  property var heldAt: null
  function carryWindow(tile, card) {
    // A window of the workspace being shown leaves the screen while it is over
    // another workspace's card, where letting go would send it away, and while
    // a landing box stands in for it over the desktop. Over its own card it is
    // carried there itself, and anywhere else letting go leaves it where it
    // is, so it stays.
    var away = false
    if (tile && tile.wsId === activeId) {
      if (card) away = card.wsId !== tile.wsId
      else away = toDesktop && !!desktopSpot(tile)
    }
    setWindowHidden(tile ? tile.modelData : null, away)
    var spot = null
    var floating = !!tile && !tile.listRow && tile.placed && !!tile.ipc.floating && !!monitor && tile.ratio > 0
    if (floating && card && card.wsId === tile.wsId) {
      var inCard = card.mapFromItem(panel.contentItem, dragPos.x, dragPos.y)
      spot = Qt.point(monitor.x + (inCard.x - dragGrab.x) / tile.ratio, monitor.y + (inCard.y - dragGrab.y) / tile.ratio)
    }
    // Full size over its own card, where it stands for the real window exactly,
    // over the desktop, where letting go brings the real window back, and as
    // the mini view a row has turned into over a card.
    var scaleTo = (spot && card) || toDesktop || (rowThumb && card) ? 1 : carriedScale
    if (flightsOn && dragShrink.to !== scaleTo) {
      dragShrink.to = scaleTo
      dragShrink.restart()
    }
    // A row on the card of the workspace being shown carries its window the
    // same way its mini view would, by its middle.
    var rowSpot = tile && tile.listRow && card && card.wsId === activeId && tile.wsId === activeId ? dropSpot(tile, card) : null
    if (rowSpot) {
      raiseCarried(tile)
      carried = { address: rowSpot.address, x: rowSpot.x, y: rowSpot.y }
      if (!carryTimer.running) carryTimer.start()
    }
    if (!spot) {
      heldAt = null
      return
    }
    raiseCarried(tile)
    var width = tile.ipc.size[0], height = tile.ipc.size[1]
    carried = {
      address: workspaceApps.windowAddress(tile.modelData),
      x: Math.round(monitor.x + prefs.keepX(spot.x - monitor.x, width, sw)),
      y: Math.round(monitor.y + prefs.keepY(spot.y - monitor.y, height, sh))
    }
    // The mini view stops where its window does: held on its card at the
    // spot the window is kept to, however far past that the pointer goes.
    var held = card.mapToItem(panel.contentItem, onCardX((carried.x - monitor.x) * tile.ratio, tile.width), onCardY((carried.y - monitor.y) * tile.ratio, tile.height))
    heldAt = Qt.point(held.x, held.y)
    if (!carryTimer.running) carryTimer.start()
  }

  // A real window being carried is above every other window from the moment
  // it first moves, as it will be once it is let go. Once for each drag.
  property string raisedAddress: ""
  function raiseCarried(tile) {
    var address = workspaceApps.windowAddress(tile.modelData)
    if (address === "" || address === raisedAddress) return
    raisedAddress = address
    workspaceApps.raiseWindow(tile.modelData)
  }

  // Cartoon speed lines riding on the trailing edge of whatever is moving
  // along the row: three thin lines, at its top, middle and bottom with the
  // middle one longest, that stretch out as it sets off and pull back in as it
  // lands. amount runs 0 to 1 to 0 over the move. They are never longer than
  // traveled, the distance the trailing edge has come, so they never reach
  // back past where it started.
  component SpeedLines: Item {
    id: lines
    property real amount: 0
    property int dir: 1
    property real traveled: 0
    readonly property real longest: Math.min(root.cardW * 0.45, traveled)
    readonly property real thick: Math.max(1.5, Style.space(2))
    anchors.fill: parent
    visible: amount > 0.01 && longest > 2

    Repeater {
      model: [[0.3, 0.7], [0.5, 1], [0.7, 0.55]]

      Rectangle {
        required property var modelData
        readonly property real len: lines.longest * modelData[1] * lines.amount
        x: lines.dir > 0 ? -len : lines.width
        y: lines.height * modelData[0] - height / 2
        width: len
        height: lines.thick
        radius: height / 2
        color: Qt.alpha(Commons.Color.foreground, 0.45)
      }
    }
  }

  // Out quickly as it sets off, held, then drawn back in by the time it lands.
  function speedAmount(t) {
    if (t <= 0 || t >= 1) return 0
    var grow = Math.min(1, t / 0.15)
    var shrink = t < 0.55 ? 1 : 1 - Math.pow((t - 0.55) / 0.45, 2)
    return grow * shrink
  }

  // How thick the impact lines off a braking edge are, and how long after the
  // brake they flash.
  readonly property int impactDelay: 200
  readonly property real impactThickness: Math.max(1.5, Style.space(2))

  // Splashes are blue on the workspace being shown, and grey on any other.
  readonly property color quietSplashColor: Qt.alpha(Commons.Color.foreground, 0.55)
  function splashFor(id) { return id === activeId ? panelSplash : quietSplash }
  function clearImpacts() {
    panelSplash.clearImpacts()
    quietSplash.clearImpacts()
  }

  // Where on the screen a window dropped on this card goes: centered on the
  // spot of the card the pointer let go at, whatever spot it was picked up by.
  // Only a floating window has a spot of its own.
  function dropSpot(tile, card) {
    var toplevel = tile ? tile.modelData : null
    var ipc = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject : null
    if (!card || !monitor || !ipc || !ipc.floating || !ipc.size || sw <= 0) return null
    var ratio = root.cardW / sw
    var inCard = card.mapFromItem(panel.contentItem, dragPos.x, dragPos.y)
    var width = ipc.size[0], height = ipc.size[1]
    var left = inCard.x / ratio - width / 2
    var top = inCard.y / ratio - height / 2
    return {
      address: workspaceApps.windowAddress(toplevel),
      x: Math.round(monitor.x + prefs.keepX(left, width, sw)),
      y: Math.round(monitor.y + prefs.keepY(top, height, sh)),
      width: width,
      height: height
    }
  }

  // Windows just dropped on another workspace, and the spot each was sent to,
  // so their new mini view starts there and not where the window used to be.
  property var placedTiles: ({})

  // The window taken off the screen while it is carried away from its card.
  WindowHider {
    id: carriedHider
    // The panel is there for as long as the shell is, so it is the one to put
    // back any window the last shell left hidden.
    Component.onCompleted: recover()
  }

  function setWindowHidden(toplevel, hide) {
    var address = toplevel ? workspaceApps.windowAddress(toplevel) : ""
    if (hide && address !== "") carriedHider.hide(address)
    else carriedHider.show()
  }

  // Set by a drop that sends the carried window to another workspace.
  property bool droppedAway: false
  // That window, kept off its old card until the move gets there.
  property string leavingAddress: ""
  Timer {
    id: leavingTimer
    interval: 600
    onTriggered: root.leavingAddress = ""
  }

  // The last spot sent, so a drop can show it on the mini view right away.
  property var lastCarried: null
  function sendCarried() {
    var move = carried
    carried = null
    if (!move || move.address === "") return
    lastCarried = move
    Hyprland.dispatch('hl.dsp.window.move({ x = ' + move.x + ', y = ' + move.y + ', window = "address:' + move.address + '" })')
  }

  // Moves go out at most every 30ms, the latest spot each time.
  Timer {
    id: carryTimer
    interval: 30
    onTriggered: root.sendCarried()
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
    // Wherever the real window was being carried, it ends up there.
    carryTimer.stop()
    sendCarried()
    refresh.restart()
    var tile = dragTile
    if (tile && !tile.listRow && lastCarried && lastCarried.address === workspaceApps.windowAddress(tile.modelData))
      tile.movedTo = Qt.point(lastCarried.x, lastCarried.y)
    lastCarried = null
    var target = hoverId
    var onDesktop = !!tile && overDesktop(dragPos.x, dragPos.y)
    var asThumb = !!rowThumb
    // Worked out while the drag is still on: letting go of it forgets how the
    // window was picked up, which decides where it is held by.
    var deskSpot = tile ? desktopSpot(tile) : null
    dragTile = null
    hoverId = -1
    var ownCard = dragCardAt(tile, dragPos.x, dragPos.y)
    if (tile && target === tile.wsId && (tile.listRow || !ownCard)) {
      // Let go of on its own workspace, a floating window goes to that spot:
      // a row on its card, and a row or a mini view on the desktop itself. A
      // mini view over its own card has carried the window there already.
      var ownSpot = ownCard ? dropSpot(tile, ownCard) : deskSpot
      if (ownSpot) {
        // In place, not sliding there from where it was.
        workspaceApps.holdStill(ownSpot.address)
        Hyprland.dispatch('hl.dsp.window.move({ x = ' + ownSpot.x + ', y = ' + ownSpot.y + ', window = "address:' + ownSpot.address + '" })')
        var ownTile = tileFor(tile.modelData)
        if (ownTile) ownTile.movedTo = Qt.point(ownSpot.x, ownSpot.y)
      }
    }
    if (tile && target > 0 && target !== tile.wsId) {
      droppedAway = true
      leavingAddress = workspaceApps.windowAddress(tile.modelData)
      leavingTimer.restart()
      // It grows back to full size as it settles into the spot the window goes
      // to, kept on the screen the same way, then splashes as it lands.
      var held = tile.listRow ? Qt.point(tile.grabX, tile.height / 2) : dragGrab
      var dropCard = dragCardAt(tile, dragPos.x, dragPos.y)
      // Let go of over the desktop, it lands on the card of the workspace
      // being shown, at the spot the window goes to on the screen.
      var landCard = dropCard || cardFor(target)
      var spot = dropCard ? dropSpot(tile, dropCard) : deskSpot
      var carriedRect = Qt.rect(dragPos.x - held.x * dragScale, dragPos.y - held.y * dragScale, tile.width * dragScale, tile.height * dragScale)
      var landRect = Qt.rect(dragPos.x - held.x, dragPos.y - held.y, tile.width, tile.height)
      var ipc = tile.modelData ? tile.modelData.lastIpcObject : null
      var ratio = sw > 0 ? root.cardW / sw : 0
      if (tile.listRow && ipc && ipc.size && ratio > 0) {
        // A row from the list turns into its window's mini view as it lands:
        // that size, in the spot the window goes to, or centered on the pointer.
        var thumbW = ipc.size[0] * ratio, thumbH = ipc.size[1] * ratio
        landRect = Qt.rect(dragPos.x - thumbW / 2, dragPos.y - thumbH / 2, thumbW, thumbH)
        // Already carried as its mini view, it sets off from where that is.
        if (asThumb) carriedRect = Qt.rect(dragPos.x - thumbW * dragScale / 2, dragPos.y - thumbH * dragScale / 2, thumbW * dragScale, thumbH * dragScale)
        if (spot && monitor && landCard) {
          var rowAt = landCard.mapToItem(panel.contentItem, (spot.x - monitor.x) * ratio, (spot.y - monitor.y) * ratio)
          landRect = Qt.rect(rowAt.x, rowAt.y, thumbW, thumbH)
        }
      } else if (spot && !tile.listRow && monitor && landCard) {
        var at = landCard.mapToItem(panel.contentItem, (spot.x - monitor.x) * ratio, (spot.y - monitor.y) * ratio)
        landRect = Qt.rect(at.x, at.y, tile.width, tile.height)
      }
      if (!dropCard && !spot && landCard) {
        // A tiled window let go of over the desktop has no spot of its own, so
        // it lands in the middle of the card.
        var mid = landCard.mapToItem(panel.contentItem, (landCard.width - landRect.width) / 2, (landCard.height - landRect.height) / 2)
        landRect = Qt.rect(mid.x, mid.y, landRect.width, landRect.height)
      }
      var landsAsThumb = asThumb && !!dragThumbShot
      // Coming onto the screen, it turns up in place and doesn't slide in.
      if (target === activeId) workspaceApps.holdStill(workspaceApps.windowAddress(tile.modelData))
      if (flightsOn) landing.land(landsAsThumb ? dragThumbShot : dragShot, carriedRect, landRect, target, tile.listRow && !landsAsThumb ? dragThumbShot : null)
      moveWindow(tile.modelData, target)
      if (spot) {
        // And on the new workspace it goes where it was let go.
        Hyprland.dispatch('hl.dsp.window.move({ x = ' + spot.x + ', y = ' + spot.y + ', window = "address:' + spot.address + '" })')
        placedTiles[spot.address] = { x: spot.x, y: spot.y, at: Date.now() }
      }
    }
    // Whatever is let go of on a workspace, or on the desktop, is the top
    // window there. Last, so it holds after the moves above.
    if (tile && (target > 0 || onDesktop)) workspaceApps.raiseWindow(tile.modelData)
    dragShrink.stop()
    dragScale = 1
  }

  // Where each window's mini view was when it left its card, and new mini views
  // just made, each kept for a moment. A window whose mini view leaves one card
  // as it turns up on another, in either order, has been moved there, as
  // Super+Shift and a number does, and flies across from where it was.
  property var leftTiles: ({})
  property var newTiles: ({})
  readonly property bool flightsOn: prefs.panelAnimation && !Style.reduceMotion && shown

  function tileLeft(tile) {
    if (!flightsOn || !tile.placed) return
    var address = workspaceApps.windowAddress(tile.modelData)
    if (address === "") return
    var at = tile.mapToItem(band, 0, 0)
    var rect = Qt.rect(at.x, at.y, tile.width, tile.height)
    var arrived = newTiles[address]
    delete newTiles[address]
    if (arrived && arrived.tile && arrived.tile.wsId !== tile.wsId && Date.now() - arrived.at < 500) {
      startFlight(arrived.tile, rect)
      return
    }
    leftTiles[address] = { wsId: tile.wsId, rect: rect, at: Date.now() }
  }

  function tileArrived(tile) {
    var address = workspaceApps.windowAddress(tile.modelData)
    if (address === "") return
    if (address === leavingAddress) {
      leavingAddress = ""
      leavingTimer.stop()
    }
    var placed = placedTiles[address]
    if (placed) {
      delete placedTiles[address]
      if (Date.now() - placed.at < 1000) tile.movedTo = Qt.point(placed.x, placed.y)
    }
    if (!flightsOn) return
    var left = leftTiles[address]
    delete leftTiles[address]
    if (left && left.wsId !== tile.wsId && Date.now() - left.at < 500) {
      startFlight(tile, left.rect)
      return
    }
    newTiles[address] = { tile: tile, at: Date.now() }
  }

  // Not for a drop, which splashes where it lands, or a reorder, which
  // renumbers every window it passes.
  function startFlight(tile, from) {
    if (Date.now() - droppedAt < 800) return
    Qt.callLater(function() { flyer.fly(tile, from) })
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
          // The same spot on the mini view as on the window it was pressed on.
          var tile = pressedTile
          var grab = root.monitor && tile.placed
            ? Qt.point((pressPoint.x + root.monitor.x - tile.ipc.at[0]) * tile.ratio,
                       (pressPoint.y + root.monitor.y - tile.ipc.at[1]) * tile.ratio)
            : null
          root.dragFromScreen = true
          root.dragTo(tile, mouse.x, mouse.y, grab)
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
          if (windowList.wanted) floor = Math.min(floor, band.y - windowList.fullHeight)
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

        // The hotkey that opens this panel, centered in the room under the cards.
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Math.round((root.bandPadding - implicitHeight) / 2)
          // Whichever ways of opening the panel are turned on.
          visible: prefs.examine || prefs.swipe
          textFormat: Text.PlainText
          text: {
            var ways = []
            if (prefs.examine) ways.push(Chord.pretty(prefs.examineKeys))
            if (prefs.swipe) ways.push(strings.t("menu.swipe"))
            return ways.join(" / ")
          }
          color: Commons.Color.foreground
          opacity: 0.3
          font.family: Style.font.family
          font.pixelSize: Style.font.body
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
              // The current workspace's accent is the outline over the row, so
              // it can move from card to card.
              border.color: hovered ? Commons.Color.accent : Style.normalBorderColor

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
                  // Where a drop just sent the real window, until Hyprland says it
                  // is there. Without it the mini view shows the old spot first.
                  property var movedTo: null
                  readonly property real atX: movedTo ? movedTo.x : (placed ? ipc.at[0] : 0)
                  readonly property real atY: movedTo ? movedTo.y : (placed ? ipc.at[1] : 0)
                  onIpcChanged: if (movedTo && placed && Math.abs(ipc.at[0] - movedTo.x) < 2 && Math.abs(ipc.at[1] - movedTo.y) < 2) movedTo = null
                  Timer {
                    // In case Hyprland put it somewhere a little different.
                    running: !!tile.movedTo
                    interval: 1000
                    onTriggered: tile.movedTo = null
                  }

                  // Not shown on its old card after a drop sends it elsewhere,
                  // while the move is on its way.
                  visible: placed && root.leavingAddress !== workspaceApps.windowAddress(modelData)
                  // Drawn wholly on its card even when its window hangs off the
                  // screen, as one dropped with drops not locked to it can.
                  x: placed ? root.onCardX((atX - (root.monitor ? root.monitor.x : 0)) * ratio, width) : 0
                  y: placed ? root.onCardY((atY - (root.monitor ? root.monitor.y : 0)) * ratio, height) : 0
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
                    root.tileLeft(tile)
                  }
                  Component.onCompleted: root.tileArrived(tile)

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
                      root.dragTo(tile, point.x, point.y, pressPoint)
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

        // The accent outline on the current workspace's card. It is one outline
        // over the row, so it can move to another workspace's card: it keeps
        // its height the whole way, and its leading edge runs ahead while the
        // trailing edge follows, so it elongates on the way. Each edge only
        // ever moves toward its spot, so it never goes past the card.
        Rectangle {
          id: outline
          readonly property int index: root.workspaceIds.indexOf(root.activeId)
          readonly property real restLeft: cards.x + index * (root.cardW + root.cardGap)
          readonly property real restRight: restLeft + root.cardW
          readonly property bool animates: prefs.panelAnimation && !Style.reduceMotion && root.shown
          property int lastIndex: -1

          // The move, over travelT (0 to 1): where each edge starts and ends,
          // and which way it is going. The ends are set only in place(): read
          // live, the outline would be on the new card before the move began.
          property real fromLeft: restLeft
          property real fromRight: restRight
          property real toLeft: restLeft
          property real toRight: restRight
          property real travelT: 1
          property int travelDir: 1
          // How far this move goes, for how big its splash is, and whether it
          // has splashed yet.
          property int travelSteps: 1
          property bool braked: true

          // Speed lines ride its trailing edge while it moves, and as its
          // leading edge reaches the card, impact lines flash off it.
          onTravelTChanged: {
            if (travelT >= 1 || !animates) return
            if (!braked && travelT >= 0.6) {
              braked = true
              var edge = travelDir > 0 ? toRight : toLeft
              if (prefs.panelImpacts) panelSplash.impactLines(edge, y, y + height, travelDir, root.impactThickness, Math.min(1, 0.75 + 0.1 * (travelSteps - 1)), root.impactDelay)
            }
          }

          function clamp01(t) { return Math.max(0, Math.min(1, t)) }
          function outCubic(t) { t = clamp01(t); return 1 - Math.pow(1 - t, 3) }
          function inOutCubic(t) { t = clamp01(t); return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2 }
          // No longer than this, however far it goes.
          readonly property real longest: root.cardW * 1.3
          readonly property real leadEdge: travelDir > 0
            ? fromRight + (toRight - fromRight) * outCubic(travelT)
            : fromLeft + (toLeft - fromLeft) * outCubic(travelT)
          readonly property real trailEdge: travelDir > 0
            ? Math.max(fromLeft + (toLeft - fromLeft) * inOutCubic(travelT), leadEdge - longest)
            : Math.min(fromRight + (toRight - fromRight) * inOutCubic(travelT), leadEdge + longest)

          visible: index >= 0 && root.cardW > 0
          x: travelDir > 0 ? trailEdge : leadEdge
          width: Math.abs(leadEdge - trailEdge)
          y: cards.y
          height: root.cardH
          color: "transparent"
          radius: Style.cornerRadius
          border.width: Math.max(1, Style.space(2))
          border.color: Commons.Color.accent
          // Faded with the card under it.
          opacity: root.reorderId === root.activeId ? 0.35 : (root.selectedId > 0 && root.selectedId !== root.activeId ? 0.5 : 1)
          Behavior on opacity {
            enabled: root.reorderId <= 0
            NumberAnimation { duration: Style.duration(root.fadeMs); easing.type: Easing.OutCubic }
          }

          function place() {
            var moved = index >= 0 && lastIndex >= 0 && index !== lastIndex
            // The same card moved, or both its edges asking twice: a move under
            // way just ends in the new place.
            if (!moved && slide.running) {
              toLeft = restLeft
              toRight = restRight
              return
            }
            var steps = Math.max(1, Math.abs(index - lastIndex))
            lastIndex = index
            // From wherever it is now, so a quick second press carries on.
            var nowLeft = x
            var nowRight = x + width
            slide.stop()
            if (!moved || !animates) {
              fromLeft = restLeft
              fromRight = restRight
              toLeft = restLeft
              toRight = restRight
              travelT = 1
              return
            }
            travelDir = restLeft >= nowLeft ? 1 : -1
            travelSteps = steps
            braked = false
            // Moving again: no impact lines from the last stop.
            root.clearImpacts()
            fromLeft = nowLeft
            fromRight = nowRight
            toLeft = restLeft
            toRight = restRight
            travelT = 0
            slide.duration = 360 * (1 + 0.12 * (steps - 1))
            slide.start()
          }

          onRestLeftChanged: Qt.callLater(place)
          onRestRightChanged: Qt.callLater(place)
          onAnimatesChanged: if (!animates) place()
          Component.onCompleted: place()

          NumberAnimation { id: slide; target: outline; property: "travelT"; from: 0; to: 1 }

          SpeedLines {
            dir: outline.travelDir
            amount: outline.animates && prefs.panelSpeedLines ? root.speedAmount(outline.travelT) : 0
            traveled: outline.travelDir > 0 ? Math.max(0, outline.x - outline.fromLeft)
                                            : Math.max(0, outline.fromRight - (outline.x + outline.width))
          }
        }

        // A window moved to another workspace while the panel is open, sliding
        // from its old card to its new one and braking hard, with a splash off
        // its leading edge. Its mini view on the new card stays hidden until then.
        Item {
          id: flyer
          property Item flyTile: null
          property rect from: Qt.rect(0, 0, 0, 0)
          property rect to: Qt.rect(0, 0, 0, 0)
          property real flightT: 1
          // Fast away, then a hard stop.
          function ease(t) { return 1 - Math.pow(1 - t, 4) }

          z: 6
          visible: !!flyTile && flightT < 1
          readonly property int flyDir: to.x >= from.x ? 1 : -1
          x: from.x + (to.x - from.x) * ease(flightT)
          y: from.y + (to.y - from.y) * ease(flightT)
          width: from.width + (to.width - from.width) * flightT
          height: from.height + (to.height - from.height) * flightT

          function fly(next, start) {
            if (!next) return
            land()
            var at = next.mapToItem(band, 0, 0)
            flyTile = next
            from = start
            to = Qt.rect(at.x, at.y, next.width, next.height)
            root.clearImpacts()
            flightT = 0
            flight.restart()
          }

          function land() {
            if (!flyTile) return
            flight.stop()
            var landed = to
            var dir = to.x >= from.x ? 1 : -1
            var onto = flyTile.wsId
            flyTile = null
            flightT = 1
            if (prefs.panelImpacts) root.splashFor(onto).impactLines(dir > 0 ? landed.x + landed.width : landed.x, landed.y, landed.y + landed.height, dir, root.impactThickness, 0.85, root.impactDelay)
          }

          SpeedLines {
            dir: flyer.flyDir
            amount: prefs.panelSpeedLines ? root.speedAmount(flyer.flightT) : 0
            traveled: flyer.flyDir > 0 ? Math.max(0, flyer.x - flyer.from.x)
                                       : Math.max(0, flyer.from.x + flyer.from.width - (flyer.x + flyer.width))
          }

          ShaderEffectSource {
            anchors.fill: parent
            sourceItem: flyer.flyTile
            hideSource: true
            live: true
          }

          Rectangle {
            anchors.fill: parent
            color: "transparent"
            radius: Math.min(Style.cornerRadius, height / 2)
            border.width: 1
            // Blue going to the workspace being shown, grey to any other.
            border.color: flyer.flyTile && flyer.flyTile.wsId !== root.activeId ? root.quietSplashColor : Commons.Color.accent
          }

          NumberAnimation {
            id: flight
            target: flyer
            property: "flightT"
            from: 0
            to: 1
            duration: 380
            onFinished: flyer.land()
          }
        }

        // Splashes over the cards: where a dragged window is dropped, and where
        // a flying one lands. The same droplets as the bar's line.
        WorkspaceLine {
          id: panelSplash
          z: 7
          color: Commons.Color.accent
          animated: prefs.panelAnimation && !Style.reduceMotion && root.shown
          // Each of the panel's effects has its own setting, checked where it starts.
          splash: true
          thickness: Math.max(4, Math.round(Style.space(6)))
          pad: 40
        }

        // The same, in grey, for a window landing on a workspace that isn't
        // the one being shown.
        WorkspaceLine {
          id: quietSplash
          z: 7
          color: root.quietSplashColor
          animated: panelSplash.animated
          splash: panelSplash.splash
          thickness: panelSplash.thickness
          pad: panelSplash.pad
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
              // Over the desktop it is headed for the workspace being shown,
              // the same as over that workspace's card.
              root.minimizedToDesktop = !card && root.activeId > 0 && root.overDesktop(x, y)
              root.hoverId = card ? card.wsId : root.minimizedToDesktop ? root.activeId : -1
            }
            onDragDropped: function(toplevel) {
              root.droppedAt = Date.now()
              if (root.hoverId > 0) root.moveWindow(toplevel, root.hoverId)
              root.hoverId = -1
              root.minimizedToDesktop = false
            }
            onDragCanceled: {
              root.hoverId = -1
              root.minimizedToDesktop = false
            }
          }
        }
      }

      DragGhost {
        source: root.minimizedDrag
        position: root.minimizedDragPos
        grab: minimizedPopup.item ? minimizedPopup.item.grabPoint : Qt.point(0, 0)
        // Full size over the desktop, where letting go brings the window back.
        itemScale: root.minimizedToDesktop ? 1 : 0.5
        Behavior on itemScale {
          NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
        }
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

        readonly property bool wanted: root.opened && root.popup === "" && !root.reorderLabel && (!root.dragTile || !!root.dragTile.listRow) && root.listWindows.length > 0
        readonly property bool animates: !Style.reduceMotion

        // Where it rests: centered over its workspace's card, as wide as its rows.
        readonly property real restWidth: Math.min(root.sw * 0.4, rows.implicitWidth + edge)
        readonly property real restLeft: Math.max(edge, Math.min(root.sw - restWidth - edge, cardCenter - restWidth / 2))

        // Rising out of the band as it appears, and sinking back as it goes.
        property real shownAmount: wanted ? 1 : 0
        Behavior on shownAmount {
          NumberAnimation { duration: Style.duration(windowList.wanted ? 200 : 140); easing.type: Easing.OutCubic }
        }
        // As tall as its rows, kept while it sinks away with none left to show.
        property real fullHeight: rows.implicitHeight + edge
        Behavior on fullHeight {
          enabled: windowList.shownAmount > 0.99
          NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
        }
        Connections {
          target: rows
          function onImplicitHeightChanged() { if (root.listWindows.length > 0) windowList.fullHeight = rows.implicitHeight + windowList.edge }
        }

        // Going to another card it stretches across the way the bar's line
        // does: the leading edge runs ahead, the trailing edge follows, and
        // neither goes past where it ends up. The ends are set only in place().
        property real fromLeft: restLeft
        property real fromRight: restLeft + restWidth
        property real toLeft: restLeft
        property real toRight: restLeft + restWidth
        property real travelT: 1
        property int travelDir: 1
        // False for a change of width on the same card: both edges ease together.
        property bool leading: true
        property int lastList: -1

        function clamp01(t) { return Math.max(0, Math.min(1, t)) }
        function outCubic(t) { t = clamp01(t); return 1 - Math.pow(1 - t, 3) }
        function inOutCubic(t) { t = clamp01(t); return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2 }
        readonly property real leadEdge: travelDir > 0
          ? fromRight + (toRight - fromRight) * outCubic(travelT)
          : fromLeft + (toLeft - fromLeft) * outCubic(travelT)
        readonly property real trailEdge: travelDir > 0
          ? fromLeft + (toLeft - fromLeft) * (leading ? inOutCubic(travelT) : outCubic(travelT))
          : fromRight + (toRight - fromRight) * (leading ? inOutCubic(travelT) : outCubic(travelT))

        function place() {
          var nowLeft = x
          var nowRight = x + width
          var moved = lastList > 0 && root.listId > 0 && root.listId !== lastList
          var steps = Math.max(1, Math.abs(root.workspaceIds.indexOf(root.listId) - root.workspaceIds.indexOf(lastList)))
          if (root.listId > 0) lastList = root.listId
          var right = restLeft + restWidth
          listSlide.stop()
          // Appearing, or nothing to animate: straight to its place.
          if (!animates || shownAmount < 0.05 || (Math.abs(nowLeft - restLeft) < 0.5 && Math.abs(nowRight - right) < 0.5)) {
            fromLeft = restLeft
            fromRight = right
            toLeft = restLeft
            toRight = right
            travelT = 1
            return
          }
          leading = moved
          travelDir = restLeft + restWidth / 2 >= (nowLeft + nowRight) / 2 ? 1 : -1
          fromLeft = nowLeft
          fromRight = nowRight
          toLeft = restLeft
          toRight = right
          travelT = 0
          listSlide.duration = Style.duration(moved ? 280 * (1 + 0.1 * (steps - 1)) : 160)
          listSlide.start()
        }

        onRestLeftChanged: Qt.callLater(place)
        onRestWidthChanged: Qt.callLater(place)
        onWantedChanged: if (wanted) place()

        NumberAnimation { id: listSlide; target: windowList; property: "travelT"; from: 0; to: 1 }

        visible: shownAmount > 0.001
        x: travelDir > 0 ? trailEdge : leadEdge
        width: Math.abs(leadEdge - trailEdge)
        height: fullHeight * shownAmount
        y: band.y - height
        opacity: Math.min(1, shownAmount * 1.6)
        clip: true
        color: workspaceApps.cardBackground(root.shell ? root.shell.barConfig : null)
        topLeftRadius: Style.cornerRadius
        topRightRadius: Style.cornerRadius

        HoverHandler { id: listHover }

        // Keeps a click between two rows from closing the panel.
        MouseArea { anchors.fill: parent }

        // Pinned to the bottom at its resting width, so it is uncovered from the
        // band up as the list rises, and stays centered while the list stretches.
        ColumnLayout {
          id: rows
          anchors.bottom: parent.bottom
          anchors.bottomMargin: windowList.edge / 2
          anchors.horizontalCenter: parent.horizontalCenter
          width: windowList.restWidth - windowList.edge
          height: implicitHeight
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

              // Fades in as it joins the list.
              opacity: 0
              Component.onCompleted: rowFade.start()
              NumberAnimation { id: rowFade; target: row; property: "opacity"; to: 1; duration: Style.duration(100); easing.type: Easing.OutCubic }

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

      // Where a floating window would land on the desktop, at the size of the
      // real window.
      // Cut off at the band, which the real window would be behind.
      Item {
        width: parent.width
        height: Math.max(0, band.y)
        clip: true

        GhostBox {
          spot: root.desktopLanding && root.monitor
            ? Qt.rect(root.desktopLanding.x - root.monitor.x, root.desktopLanding.y - root.monitor.y, root.desktopLanding.width, root.desktopLanding.height)
            : null
          toplevel: root.dragTile ? root.dragTile.modelData : null
          titleBars: prefs
        }
      }

      // And where one would land on a card. A row shown as its mini view is
      // that box itself.
      GhostBox {
        spot: root.rowThumb ? null : root.cardLanding
        toplevel: root.dragTile ? root.dragTile.modelData : null
      }

      // The window under the cursor while it is being dragged.
      ShaderEffectSource {
        visible: !!root.dragTile
        sourceItem: root.dragTile
        hideSource: true
        width: root.dragTile ? root.dragTile.width : 0
        height: root.dragTile ? root.dragTile.height : 0
        // It keeps hold of the spot it was picked up by: a list row along its
        // width, a mini view wherever it was grabbed.
        x: root.heldAt ? root.heldAt.x : root.dragPos.x - held.x
        y: root.heldAt ? root.heldAt.y : root.dragPos.y - held.y
        // Still here while a row is shown as its mini view, so the row stays
        // out of the list.
        opacity: root.rowThumb ? 0 : 0.9
        readonly property point held: root.dragTile && root.dragTile.listRow ? Qt.point(root.dragTile.grabX, height / 2) : root.dragGrab
        // Smaller while it is carried, shrunk toward the spot it is held by.
        transform: Scale {
          origin.x: dragGhost.held.x
          origin.y: dragGhost.held.y
          xScale: root.dragScale
          yScale: root.dragScale
        }
        id: dragGhost
      }

      // A row carried over the workspace being shown, as its window's mini
      // view inside the same outline a landing spot has. Over a card it sits
      // on the spot a floating window would land, kept inside the card. With
      // no spot of its own, and over the desktop, it is held by its middle.
      Item {
        id: thumbGhost
        visible: !!root.rowThumb
        width: root.rowThumb ? root.rowThumb.width : 0
        height: root.rowThumb ? root.rowThumb.height : 0
        x: root.cardSpotRect ? root.cardSpotRect.x : root.dragPos.x - width / 2
        y: root.cardSpotRect ? root.cardSpotRect.y : root.dragPos.y - height / 2
        transform: Scale {
          origin.x: thumbGhost.width / 2
          origin.y: thumbGhost.height / 2
          xScale: root.dragScale
          yScale: root.dragScale
        }

        ShaderEffectSource {
          anchors.fill: parent
          sourceItem: root.rowThumb
          hideSource: true
          // As faint as the window in any other landing box. On its own
          // card, where the real window is carried along with it, as solid as
          // a mini view carried there.
          opacity: root.dragTile && root.dragTile.wsId === root.activeId && root.hoverId === root.activeId && !root.toDesktop ? 0.9 : 0.5
        }

        Rectangle {
          anchors.fill: parent
          radius: Math.min(Style.cornerRadius, height / 2)
          color: "transparent"
          border.width: 1
          border.color: Commons.Color.accent
        }
      }

      // A window dropped on another workspace's card. It grows back to full
      // size as it settles into the spot its window goes to, then splashes off
      // its outline as it lands, and fades as its mini view takes its place.
      Item {
        id: landing
        property var landedShot: null
        // From where the carried copy is, at its carried size, to where its
        // window's mini view will be, at full size.
        property rect fromRect: Qt.rect(0, 0, 0, 0)
        property rect toRect: Qt.rect(0, 0, 0, 0)
        property real settleT: 1
        property bool active: false
        // The workspace it is landing on: blue on the one being shown, grey on another.
        property int ontoId: -1
        readonly property color tint: ontoId === root.activeId ? Commons.Color.accent : root.quietSplashColor
        function ease(t) { return 1 - Math.pow(1 - t, 3) }

        visible: active
        x: fromRect.x + (toRect.x - fromRect.x) * ease(settleT)
        y: fromRect.y + (toRect.y - fromRect.y) * ease(settleT)
        width: fromRect.width + (toRect.width - fromRect.width) * ease(settleT)
        height: fromRect.height + (toRect.height - fromRect.height) * ease(settleT)

        // A row turning into a mini view cross-fades into this picture of it.
        property var thumbShot: null
        readonly property bool morphs: !!thumbShot

        function land(picture, start, end, onto, thumb) {
          landingRun.stop()
          ontoId = onto
          landedShot = picture
          thumbShot = thumb || null
          settleRun.duration = Style.duration(thumbShot ? 240 : 150)
          fromRect = start
          toRect = end
          settleT = 0
          opacity = 0.9
          active = true
          landingRun.start()
        }

        function splash() {
          if (prefs.panelDropSplash) root.splashFor(ontoId).splashRect(Qt.rect(toRect.x - band.x, toRect.y - band.y, toRect.width, toRect.height), 1)
        }

        Image {
          anchors.fill: parent
          source: landing.landedShot ? landing.landedShot.url : ""
          smooth: true
          opacity: landing.morphs ? 1 - landing.ease(Math.min(1, landing.settleT * 1.4)) : 1
        }

        Image {
          anchors.fill: parent
          visible: landing.morphs
          source: landing.thumbShot ? landing.thumbShot.url : ""
          smooth: true
          opacity: landing.ease(Math.min(1, landing.settleT * 1.4))
        }

        Rectangle {
          anchors.fill: parent
          color: "transparent"
          radius: Math.min(Style.cornerRadius, height / 2)
          border.width: 1
          border.color: landing.tint
        }

        SequentialAnimation {
          id: landingRun
          NumberAnimation { id: settleRun; target: landing; property: "settleT"; from: 0; to: 1; duration: Style.duration(150) }
          ScriptAction { script: landing.splash() }
          NumberAnimation { target: landing; property: "opacity"; to: 0; duration: Style.duration(160); easing.type: Easing.OutCubic }
          ScriptAction { script: { landing.active = false; landing.landedShot = null; landing.thumbShot = null } }
        }
      }
    }
  }
}
