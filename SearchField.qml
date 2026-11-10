import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "AppSearch.js" as AppSearch

// Slides down from the top of the screen with the workspace panel. One
// character searches apps the same way the app list does, and the background
// grows downward to fit the matches.
Rectangle {
  id: root

  property real progress: 0
  property bool opened: false
  property color panelColor: "transparent"
  property bool popupOpen: false
  // The lowest the background may reach, in this item's parent.
  property int limit: 0

  signal launched()
  signal escapePressed()
  // Enter with nothing to open.
  signal dismiss()
  // Left or right while the panel is open.
  signal workspaceStepped(int step)
  // Up or down while this field has nothing to move through.
  signal windowStepped(int step)
  // Enter while this field has nothing to open.
  signal windowActivate()
  signal launchRequested(string command)
  // The settings pane is recording a hotkey, so this field must not take it.
  property bool yieldKeys: false
  // Left or right took the keyboard, until a letter comes back.
  property bool browsing: false
  signal yielded(int key, int modifiers, string text)

  function focusField() {
    if (root.opened && !root.yieldKeys && !root.browsing) field.forceActiveFocus()
  }

  function browse() {
    browsing = true
  }

  // A letter after the arrows: the field takes the keyboard and that letter.
  function typeAgain(text) {
    browsing = false
    insertText(text)
  }

  onYieldKeysChanged: if (!yieldKeys && opened && !browsing) Qt.callLater(focusField)

  // Used when a key arrives at the overlay before the field has active focus.
  function insertText(text) {
    var extra = String(text || "")
    if (!root.opened || extra === "") return
    field.forceActiveFocus()
    var value = field.text
    var start = field.selectionStart
    var end = field.selectionEnd
    if (start > end) {
      var swap = start
      start = end
      end = swap
    }
    field.text = value.slice(0, start) + extra + value.slice(end)
    field.cursorPosition = start + extra.length
  }

  function clear() {
    root.query = ""
    if (field.text !== "") field.text = ""
    root.hits = []
    root.searchIndex = -1
    root.resultsOpen = false
    root.browsing = false
  }

  // Whole card, so matches leave with the field as the panel drops away.
  y: (progress - 1) * height
  width: Style.spacing.searchableDropdownWidth
  height: fieldBox.height + root.listHeight + (root.showResults ? root.edge / 2 : 0)
  clip: true
  color: panelColor
  border.width: 0
  radius: 0
  topLeftRadius: 0
  topRightRadius: 0
  bottomLeftRadius: Style.cornerRadius
  bottomRightRadius: Style.cornerRadius

  // Grow to fit matches once the field has settled at the top. While the panel
  // is on the way out the height stays put, so the slide doesn't change shape.
  Behavior on height {
    enabled: root.opened && root.progress >= 1
    NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
  }

  readonly property int iconSize: Math.round(Style.font.body * 1.5)
  readonly property int edge: Style.spacing.md
  readonly property int textInset: edge + edge / 2
  readonly property int rowHeight: iconSize + edge

  property string query: ""
  property var hits: []
  property int searchIndex: -1
  // Stays on through the close so the matches slide away with the field.
  property bool resultsOpen: false
  readonly property bool showResults: resultsOpen && hits.length > 0
  readonly property bool typing: field.activeFocus

  // Room above the band. Remembered at rest so a closing panel, which moves
  // the band, doesn't stretch the list on the way out.
  readonly property int liveRoom: Math.max(0, limit - fieldBox.height - edge / 2)
  property int room: 0
  onLiveRoomChanged: if (opened && progress >= 1) room = liveRoom
  readonly property int listCap: (opened && progress >= 1) ? liveRoom : room
  // Updated from the list, not bound to it, so the card can follow the matches
  // without a binding loop on the view's own height.
  property int contentH: 0
  readonly property int listHeight: {
    if (!showResults || hits.length === 0) return 0
    var content = contentH > 0 ? contentH : rowHeight
    return Math.min(content, Math.max(rowHeight, listCap))
  }

  function syncResults() {
    var want = root.query.trim().length > 0 && root.hits.length > 0
    if (root.opened && root.progress >= 1) root.resultsOpen = want
    else if (!root.opened && root.progress <= 0) root.resultsOpen = false
  }

  function rememberRoom() {
    if (root.opened && root.progress >= 1) root.room = root.liveRoom
  }

  onOpenedChanged: {
    root.rememberRoom()
    root.syncResults()
    if (root.opened) Qt.callLater(root.focusField)
  }
  onProgressChanged: {
    root.rememberRoom()
    root.syncResults()
    if (!root.opened && root.progress <= 0) root.clear()
  }
  onQueryChanged: root.syncResults()
  onHitsChanged: {
    root.syncResults()
    Qt.callLater(function() {
      if (root.contentH !== results.contentHeight) root.contentH = results.contentHeight
    })
  }

  function setQuery(text) {
    var value = String(text || "")
    if (value.length > 200) value = value.slice(0, 200)
    if (value === root.query) return
    root.query = value
    if (field.text !== value) field.text = value
    root.rebuild(true)
  }

  function move(delta) {
    if (root.hits.length === 0) return
    var start = root.searchIndex < 0 ? 0 : root.searchIndex
    root.searchIndex = Math.max(0, Math.min(root.hits.length - 1, start + delta))
    results.positionViewAtIndex(root.searchIndex, ListView.Contain)
  }

  function safeId(value) {
    var id = String(value == null ? "" : value).trim()
    if (!id || id.length > 256 || /[\0\r\n]/.test(id)) return ""
    return id
  }

  function openHit(hit) {
    var id = root.safeId(hit && hit.id)
    if (!id) return
    var words = []
    if (hit.runInTerminal) {
      var command = hit.command || []
      for (var i = 0; i < command.length; i++) {
        var word = String(command[i] || "")
        if (word && !/^%[a-zA-Z]$/.test(word)) words.push(Util.shellQuote(word))
      }
    }
    var shell = words.length > 0
      ? "omarchy-launch-tui " + words.join(" ")
      : "uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop")
    root.launchRequested(shell)
    root.launched()
  }

  function openSelected() {
    if (root.query.trim().length === 0 || root.hits.length === 0) {
      root.dismiss()
      return
    }
    var index = root.searchIndex
    if (index < 0 || index >= root.hits.length) index = 0
    root.openHit(root.hits[index])
  }

  function normalizeId(value) {
    var id = String(value || "").trim()
    if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
    return id
  }

  function parseIds(text) {
    var next = ({})
    var lines = String(text || "").split("\n")
    var count = Math.min(lines.length, 1000)
    for (var i = 0; i < count; i++) {
      var id = root.normalizeId(lines[i])
      if (id) next[id] = true
    }
    return next
  }

  property var configuredHides: ({})
  property var desktopHides: ({})

  function isHidden(entry) {
    var id = String(entry && entry.id || "")
    var normalized = root.normalizeId(id)
    return root.configuredHides[id] === true || root.configuredHides[normalized] === true
      || root.desktopHides[id] === true || root.desktopHides[normalized] === true
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (!value) value = "application-x-executable"
    if (value.charAt(0) === "/") return "file://" + value
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    var found = Quickshell.iconPath(value, true)
    if (found && String(found).length > 0) return found
    return Quickshell.iconPath("application-x-executable", true) || ""
  }

  function letterFor(name) {
    return String(name || "").replace(/^\s+/, "").slice(0, 1).toUpperCase()
  }

  function rebuild(resetSelection) {
    var q = String(root.query || "")
    if (q.trim().length < 1) {
      root.hits = []
      root.searchIndex = -1
      return
    }
    var values = DesktopEntries.applications.values || []
    var rows = AppSearch.sortedEntries(values, q, function(entry) { return root.isHidden(entry) })
    var next = []
    var count = Math.min(rows.length, 200)
    for (var i = 0; i < count; i++) {
      var entry = rows[i].entry
      var command = []
      var raw = entry.command
      var words = raw && raw.length ? raw.length : 0
      for (var c = 0; c < words && c < 32; c++) command.push(String(raw[c]))
      var name = AppSearch.entryName(entry)
      if (name.length > 300) name = name.slice(0, 300)
      var id = String(entry.id || "")
      if (id.length > 256) id = id.slice(0, 256)
      next.push({
        id: id,
        name: name,
        icon: String(entry.icon || ""),
        runInTerminal: entry.runInTerminal === true,
        command: command
      })
    }
    root.hits = next
    root.searchIndex = resetSelection || root.searchIndex < 0
      ? (next.length > 0 ? 0 : -1)
      : Math.min(root.searchIndex, next.length - 1)
    if (resetSelection) Qt.callLater(function() {
      if (results.count > 0) results.positionViewAtBeginning()
    })
  }

  readonly property string hideScript: {
    var base = Quickshell.env("OMARCHY_PATH") || ""
    return base ? base + "/shell/services/hidden-entries.sh" : ""
  }
  readonly property string desktopNames: [
    Quickshell.env("XDG_CURRENT_DESKTOP"),
    Quickshell.env("XDG_SESSION_DESKTOP"),
    Quickshell.env("DESKTOP_SESSION")
  ].filter(function(value) { return String(value || "").length > 0 }).join(":")

  function scanDesktopHides() {
    if (!root.hideScript || hiddenScan.running) return
    hiddenScan.running = true
  }

  function readConfiguredHides(text) {
    root.configuredHides = root.parseIds(text)
    if (root.query.trim().length > 0) root.rebuild(false)
  }

  function readDesktopHides(text) {
    root.desktopHides = root.parseIds(text)
    if (root.query.trim().length > 0) root.rebuild(false)
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Component.onCompleted: root.scanDesktopHides()

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root.scanDesktopHides()
      if (root.query.trim().length > 0) root.rebuild(false)
    }
  }

  FileView {
    path: (Quickshell.env("OMARCHY_PATH") || "") + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.readConfiguredHides(text())
    onFileChanged: reload()
    onLoadFailed: root.readConfiguredHides("")
  }

  Process {
    id: hiddenScan
    command: root.hideScript ? [root.hideScript, root.desktopNames] : ["true"]
    stdout: StdioCollector {
      onStreamFinished: root.readDesktopHides(text)
    }
  }

  // Keeps a click on the field from closing the panel.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: mouse => {
      mouse.accepted = true
      field.forceActiveFocus()
    }
  }

  Item {
    id: fieldBox
    width: parent.width
    height: Math.max(root.iconSize, field.implicitHeight) + root.edge

    TextInput {
      id: field
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: root.textInset
      anchors.rightMargin: root.textInset + (shortcutHint.visible ? shortcutHint.implicitWidth + root.edge : 0)
      focus: root.opened && !root.yieldKeys && !root.browsing
      clip: true
      selectByMouse: true
      color: Commons.Color.foreground
      selectionColor: Style.selectionFillFor(Commons.Color.foreground, Commons.Color.accent)
      selectedTextColor: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      onTextChanged: root.setQuery(text)
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: event => {
        if (root.yieldKeys) {
          root.yielded(event.key, event.modifiers, event.text)
          event.accepted = true
          return
        }
        var mods = event.modifiers & ~(Qt.KeypadModifier)
        if (mods === 0 && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
          root.browse()
          root.workspaceStepped(event.key === Qt.Key_Left ? -1 : 1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
          if (root.hits.length > 0) root.move(event.key === Qt.Key_Up ? -1 : 1)
          else if (mods === 0) root.windowStepped(event.key === Qt.Key_Up ? -1 : 1)
          else return
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (root.query.trim().length > 0 && root.hits.length > 0) root.openSelected()
          else root.windowActivate()
        } else if (event.key === Qt.Key_Escape) {
          if (root.popupOpen) root.escapePressed()
          else if (root.query !== "") root.clear()
          else root.escapePressed()
        } else return
        event.accepted = true
      }
    }

    Text {
      anchors.left: field.left
      anchors.right: field.right
      anchors.verticalCenter: field.verticalCenter
      visible: field.text.length === 0 && field.preeditText.length === 0
      textFormat: Text.PlainText
      text: strings.t("search.placeholder")
      color: Commons.Color.foreground
      opacity: 0.45
      font.family: field.font.family
      font.pixelSize: field.font.pixelSize
      elide: Text.ElideRight
    }

    // The shortcut that opens the app list, on the right while the field is empty.
    Text {
      id: shortcutHint
      anchors.right: parent.right
      anchors.rightMargin: root.textInset
      anchors.verticalCenter: parent.verticalCenter
      visible: field.text.length === 0 && field.preeditText.length === 0
      textFormat: Text.PlainText
      text: strings.t("search.shortcut")
      color: Commons.Color.foreground
      opacity: 0.3
      font.family: field.font.family
      font.pixelSize: field.font.pixelSize
    }
  }

  ListView {
    id: results
    visible: root.hits.length > 0
    y: fieldBox.height
    x: root.edge / 2
    width: parent.width - root.edge
    height: root.listHeight
    onContentHeightChanged: if (root.contentH !== contentHeight) root.contentH = contentHeight
    model: root.hits
    clip: true
    spacing: 0
    interactive: contentHeight > height
    boundsBehavior: Flickable.StopAtBounds
    keyNavigationEnabled: false
    cacheBuffer: root.rowHeight * 8
    maximumFlickVelocity: 8000

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: event => {
        var pixels = event.pixelDelta.y
        var angle = event.angleDelta.y
        var delta = Math.abs(angle) >= 120
          ? angle / 120 * root.rowHeight * 3
          : (pixels !== 0 ? pixels : angle)
        if (delta === 0) return
        var bottom = results.originY + Math.max(0, results.contentHeight - results.height)
        results.contentY = Math.max(results.originY, Math.min(bottom, results.contentY - delta))
        event.accepted = true
      }
    }

    delegate: Item {
      id: row
      required property int index
      required property var modelData
      readonly property bool selected: index === root.searchIndex

      width: results.width
      height: Math.max(root.iconSize, title.implicitHeight) + root.edge

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: row.selected ? Style.hoverFill : "transparent"
        border.width: row.selected ? 1 : 0
        border.color: Commons.Color.accent
      }

      AppMark {
        id: icon
        anchors.left: parent.left
        anchors.leftMargin: root.edge
        anchors.verticalCenter: parent.verticalCenter
        size: root.iconSize
        source: root.iconSource(row.modelData.icon)
        letter: root.letterFor(row.modelData.name)
        letterColor: Commons.Color.foreground
      }

      Text {
        id: title
        anchors.left: icon.right
        anchors.leftMargin: root.edge
        anchors.right: parent.right
        anchors.rightMargin: root.edge
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: row.modelData.name
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onContainsMouseChanged: if (containsMouse) root.searchIndex = row.index
        onClicked: mouse => { if (mouse.button === Qt.LeftButton) root.openHit(row.modelData) }
      }
    }
  }
}
