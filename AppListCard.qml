import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "AppSearch.js" as AppSearch

// What the bar's apps button opens: every app, a search field on the top line,
// and a right-click menu to open, keep in the dock, or uninstall. The same list
// as dtpietrzak.applist, drawn like the rest of this plugin's cards.
Item {
  id: root

  property bool opened: false
  property string fontFamily: Style.font.family

  // A shell command to run, and the card is done.
  signal launchRequested(string command)
  signal dismissed()

  readonly property int edge: Style.spacing.md
  readonly property int iconSize: Math.round(Style.font.body * 1.5)
  readonly property int rowHeight: iconSize + edge
  readonly property int visibleRows: 12
  // Room on the right of the rows for the scrollbar.
  readonly property int gutter: Style.space(10)

  implicitWidth: Style.space(300)
  // The card fits what it shows, as the workspace panel's search does: one row
  // per match up to a full list, and a single line of room for the message when
  // nothing matches.
  readonly property int messageHeight: rowHeight + edge
  readonly property int listHeight: apps.length > 0 ? rowHeight * Math.min(apps.length, visibleRows) : messageHeight
  implicitHeight: fieldBox.height + listHeight + edge / 2

  property string query: ""
  property var apps: []
  property int selectedIndex: -1
  // Turned over for a bottom bar: the search field at the bottom, the list
  // growing up from it with the first row nearest the field.
  property bool flipped: false
  property var pinnedIds: ({})
  // The app the right-click menu is for, and the one being uninstalled.
  property var menuApp: null
  property int menuIndex: 0
  property point menuPoint: Qt.point(0, 0)
  property var uninstallApp: null
  property int confirmIndex: 1

  readonly property bool menuPinned: !!menuApp && pinnedIds[normalizeId(menuApp.id)] === true
  readonly property var menuItems: [
    { id: "open", label: strings.t("apps.open") },
    { id: "pin", label: menuPinned ? strings.t("apps.removeFromDock") : strings.t("apps.keepInDock") },
    { id: "uninstall", label: strings.t("apps.uninstall") }
  ]

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  onOpenedChanged: {
    if (!opened) return
    menuApp = null
    uninstallApp = null
    if (field.text !== "") field.text = ""
    query = ""
    rebuild(true)
    Qt.callLater(function() { field.forceActiveFocus() })
  }

  function safeId(value) {
    var id = String(value == null ? "" : value).trim()
    if (!id || id.length > 256 || /[\0\r\n]/.test(id)) return ""
    return id
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
      var id = normalizeId(lines[i])
      if (id) next[id] = true
    }
    return next
  }

  property var configuredHides: ({})
  property var desktopHides: ({})

  function isHidden(entry) {
    var id = String(entry && entry.id || "")
    var normalized = normalizeId(id)
    return configuredHides[id] === true || configuredHides[normalized] === true
      || desktopHides[id] === true || desktopHides[normalized] === true
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
    var values = DesktopEntries.applications.values || []
    var rows = AppSearch.sortedEntries(values, query, function(entry) { return root.isHidden(entry) })
    var next = []
    var count = Math.min(rows.length, 400)
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
    apps = next
    selectedIndex = resetSelection || selectedIndex < 0
      ? (next.length > 0 ? 0 : -1)
      : Math.min(selectedIndex, next.length - 1)
    if (resetSelection) Qt.callLater(function() { if (list.count > 0) list.positionViewAtBeginning() })
  }

  function setQuery(text) {
    var value = String(text || "")
    if (value.length > 200) value = value.slice(0, 200)
    if (value === query) return
    query = value
    if (field.text !== value) field.text = value
    rebuild(true)
  }

  function move(delta) {
    if (apps.length === 0) return
    var start = selectedIndex < 0 ? 0 : selectedIndex
    // Up is toward the top of the card, which is higher in a flipped list.
    selectedIndex = Math.max(0, Math.min(apps.length - 1, start + (flipped ? -delta : delta)))
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  // A terminal app goes through Omarchy's TUI launcher, the rest through
  // gtk-launch, the same way the shell's app library starts them.
  function launch(app) {
    var id = safeId(app && app.id)
    if (!id) return
    var words = []
    if (app.runInTerminal) {
      for (var i = 0; i < app.command.length; i++) {
        var word = String(app.command[i] || "")
        if (word && !/^%[a-zA-Z]$/.test(word)) words.push(Util.shellQuote(word))
      }
    }
    launchRequested(words.length > 0
      ? "omarchy-launch-tui " + words.join(" ")
      : "uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
    dismissed()
  }

  function openMenu(app, index, point) {
    selectedIndex = index
    menuIndex = 0
    menuApp = app
    menuPoint = point
  }

  function togglePin(app) {
    var saved = safeId(app && app.id)
    var id = normalizeId(saved)
    if (!saved || !id) return
    var pinned = pinnedIds[id] === true
    var next = ({})
    for (var key in pinnedIds) next[key] = true
    if (pinned) delete next[id]
    else next[id] = true
    pinnedIds = next
    Util.execArgv(["omarchy", "dock", pinned ? "unpin" : "pin", saved])
  }

  function triggerMenu() {
    var item = menuItems[menuIndex]
    var app = menuApp
    if (!item || !app) return
    menuApp = null
    if (item.id === "open") launch(app)
    else if (item.id === "pin") togglePin(app)
    else if (item.id === "uninstall") {
      confirmIndex = 1
      uninstallApp = app
    }
  }

  function confirmUninstall() {
    var app = uninstallApp
    uninstallApp = null
    var id = safeId(app && app.id)
    if (!id) return
    var base = Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
    launchRequested(Util.shellQuote(base + "/bin/omarchy-remove-launcher-entry") + " "
      + Util.shellQuote(id) + " " + Util.shellQuote(app.name || id))
    dismissed()
  }

  function handleKey(event) {
    if (uninstallApp) {
      if (event.key === Qt.Key_Escape) uninstallApp = null
      else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab) confirmIndex = 1 - confirmIndex
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (confirmIndex === 1) confirmUninstall()
        else uninstallApp = null
      }
      event.accepted = true
      return
    }
    if (menuApp) {
      if (event.key === Qt.Key_Escape) menuApp = null
      else if (event.key === Qt.Key_Up) menuIndex = Math.max(0, menuIndex - 1)
      else if (event.key === Qt.Key_Down) menuIndex = Math.min(menuItems.length - 1, menuIndex + 1)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) triggerMenu()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Up) move(-1)
    else if (event.key === Qt.Key_Down) move(1)
    else if (event.key === Qt.Key_PageUp) move(-visibleRows)
    else if (event.key === Qt.Key_PageDown) move(visibleRows)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (selectedIndex >= 0 && selectedIndex < apps.length) launch(apps[selectedIndex])
    } else if (event.key === Qt.Key_Escape) {
      if (query !== "") setQuery("")
      else dismissed()
    } else return
    event.accepted = true
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
    if (!hideScript || hiddenScan.running) return
    hiddenScan.running = true
  }

  function loadPins(raw) {
    var config = null
    try { config = JSON.parse(String(raw || "")) } catch (e) { return }
    var pins = config && config.dock && Array.isArray(config.dock.pinned) ? config.dock.pinned : []
    var next = ({})
    for (var i = 0; i < Math.min(pins.length, 200); i++) {
      var id = normalizeId(safeId(pins[i]))
      if (id) next[id] = true
    }
    pinnedIds = next
  }

  Component.onCompleted: scanDesktopHides()

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root.scanDesktopHides()
      if (root.opened) root.rebuild(false)
    }
  }

  FileView {
    path: (Quickshell.env("OMARCHY_PATH") || "") + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: { root.configuredHides = root.parseIds(text()); if (root.opened) root.rebuild(false) }
    onFileChanged: reload()
    onLoadFailed: root.configuredHides = ({})
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadPins(text())
    onFileChanged: reload()
  }

  Process {
    id: hiddenScan
    command: root.hideScript ? [root.hideScript, root.desktopNames] : ["true"]
    stdout: StdioCollector {
      onStreamFinished: { root.desktopHides = root.parseIds(text); if (root.opened) root.rebuild(false) }
    }
  }

  // A click on the card closes the right-click menu.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: mouse => {
      if (!root.uninstallApp) root.menuApp = null
      field.forceActiveFocus()
    }
  }

  Item {
    id: fieldBox
    y: root.flipped ? parent.height - height : 0
    width: parent.width
    // The same room as the menu's search line: a half edge of card padding, a
    // line one row tall, and a full edge before the first row.
    height: Math.max(root.iconSize, field.implicitHeight) + root.edge * 2.5

    TextInput {
      id: field
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: root.flipped ? root.edge / 4 : -root.edge / 4
      anchors.leftMargin: root.edge + root.edge / 2
      anchors.rightMargin: root.edge + root.edge / 2 + (shortcutHint.visible ? shortcutHint.implicitWidth + root.edge : 0)
      focus: root.opened
      clip: true
      selectByMouse: true
      readOnly: !!root.menuApp || !!root.uninstallApp
      color: Commons.Color.foreground
      selectionColor: Style.selectionFillFor(Commons.Color.foreground, Commons.Color.accent)
      selectedTextColor: Commons.Color.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      onTextChanged: root.setQuery(text)
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: event => root.handleKey(event)
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
      anchors.rightMargin: root.edge + root.edge / 2
      anchors.verticalCenter: field.verticalCenter
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
    id: list
    y: root.flipped ? root.edge / 2 : fieldBox.height
    x: root.edge / 2
    width: parent.width - root.edge - root.gutter
    height: parent.height - fieldBox.height - root.edge / 2
    model: root.apps
    clip: true
    verticalLayoutDirection: root.flipped ? ListView.BottomToTop : ListView.TopToBottom
    spacing: 0
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
          : (pixels !== 0 ? pixels * 2 : angle)
        if (delta === 0) return
        var bottom = list.originY + Math.max(0, list.contentHeight - list.height)
        list.contentY = Math.max(list.originY, Math.min(bottom, list.contentY - delta))
        event.accepted = true
      }
    }

    delegate: Item {
      id: row
      required property int index
      required property var modelData
      readonly property bool selected: index === root.selectedIndex

      width: list.width
      height: root.rowHeight

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: row.selected ? Style.hoverFill : "transparent"
        border.width: row.selected ? 1 : 0
        border.color: Commons.Color.accent
      }

      // A thin line between this row and the next.
      Rectangle {
        y: Math.round(parent.height - height / 2)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.edge
        anchors.rightMargin: root.edge
        height: 1 / Math.max(1, Screen.devicePixelRatio)
        visible: row.index < root.apps.length - 1 && !row.selected && row.index + 1 !== root.selectedIndex
        color: Qt.alpha(Commons.Color.foreground, 0.15)
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
        fontFamily: root.fontFamily
      }

      Text {
        anchors.left: icon.right
        anchors.leftMargin: root.edge
        anchors.right: parent.right
        anchors.rightMargin: root.edge
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: row.modelData.name
        color: Commons.Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onContainsMouseChanged: if (containsMouse && !root.menuApp && !root.uninstallApp) root.selectedIndex = row.index
        onClicked: mouse => {
          if (root.uninstallApp) return
          if (mouse.button === Qt.RightButton) {
            root.openMenu(row.modelData, row.index, row.mapToItem(root, mouse.x, mouse.y))
            return
          }
          root.menuApp = null
          root.launch(row.modelData)
        }
      }
    }
  }

  // A scrollbar of its own, in a gutter beside the rows, shown whenever the
  // list is longer than the card. Drag the thumb or click the track to move.
  Item {
    id: track
    visible: list.contentHeight > list.height
    x: list.x + list.width + (root.gutter - width) / 2
    y: list.y
    width: Math.max(3, Style.space(4))
    height: list.height

    readonly property real span: Math.max(1, list.contentHeight - list.height)
    readonly property real thumbHeight: Math.max(Style.space(24), height * list.height / Math.max(1, list.contentHeight))
    readonly property real travel: Math.max(1, height - thumbHeight)

    function scrollTo(thumbY) {
      var fraction = Math.max(0, Math.min(1, thumbY / travel))
      list.contentY = list.originY + fraction * span
    }

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Qt.alpha(Commons.Color.foreground, 0.08)
    }

    Rectangle {
      id: thumb
      width: parent.width
      height: track.thumbHeight
      y: (list.contentY - list.originY) / track.span * track.travel
      radius: width / 2
      color: Qt.alpha(Commons.Color.foreground, trackMouse.pressed || trackMouse.containsMouse ? 0.6 : 0.35)
    }

    MouseArea {
      id: trackMouse
      // Wider than the thumb so it is easy to grab.
      anchors.fill: parent
      anchors.leftMargin: -(root.gutter - parent.width) / 2
      anchors.rightMargin: -(root.gutter - parent.width) / 2
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      property real grab: 0
      onPressed: mouse => {
        var onThumb = mouse.y >= thumb.y && mouse.y <= thumb.y + thumb.height
        grab = onThumb ? mouse.y - thumb.y : thumb.height / 2
        track.scrollTo(mouse.y - grab)
      }
      onPositionChanged: mouse => { if (pressed) track.scrollTo(mouse.y - grab) }
    }
  }

  Text {
    anchors.horizontalCenter: list.horizontalCenter
    y: (root.flipped ? root.edge / 2 : fieldBox.height) + (root.messageHeight - height) / 2
    width: list.width - root.edge * 2
    horizontalAlignment: Text.AlignHCenter
    visible: root.apps.length === 0
    textFormat: Text.PlainText
    text: root.query ? strings.t("apps.noMatch").arg(root.query.slice(0, 80)) : strings.t("apps.none")
    color: Commons.Color.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  // The right-click menu, a small card of its own over the list.
  Rectangle {
    id: menuBox
    visible: !!root.menuApp
    z: 5
    readonly property int pad: Style.space(4)
    width: Math.max(Style.space(160), menuColumn.implicitWidth) + pad * 2
    height: menuColumn.implicitHeight + pad * 2
    x: Math.max(0, Math.min(root.menuPoint.x, root.width - width - root.edge / 2))
    y: Math.max(0, Math.min(root.menuPoint.y, root.height - height - root.edge / 2))
    radius: Style.cornerRadius
    color: Commons.Color.bar.background

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

    Column {
      id: menuColumn
      x: menuBox.pad
      y: menuBox.pad
      width: menuBox.width - menuBox.pad * 2

      Repeater {
        model: root.menuItems

        Item {
          id: choice
          required property int index
          required property var modelData
          readonly property bool current: index === root.menuIndex

          implicitWidth: choiceText.implicitWidth + root.edge * 2
          width: menuColumn.width
          height: choiceText.implicitHeight + root.edge

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: choice.current ? Style.hoverFill : "transparent"
            border.width: choice.current ? 1 : 0
            border.color: Commons.Color.accent
          }

          Text {
            id: choiceText
            anchors.left: parent.left
            anchors.leftMargin: root.edge
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: choice.modelData.label
            color: Commons.Color.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) root.menuIndex = choice.index
            onClicked: {
              root.menuIndex = choice.index
              root.triggerMenu()
            }
          }
        }
      }
    }
  }

  // Asking before an uninstall, over the whole card.
  Rectangle {
    visible: !!root.uninstallApp
    z: 6
    anchors.fill: parent
    color: Qt.alpha(Commons.Color.bar.background, 0.92)

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

    Column {
      anchors.centerIn: parent
      width: parent.width - root.edge * 4
      spacing: root.edge * 1.5

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: strings.t("apps.uninstallConfirm").arg(root.uninstallApp ? String(root.uninstallApp.name).slice(0, 120) : "")
        color: Commons.Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.edge

        Repeater {
          model: [strings.t("apps.cancel"), strings.t("apps.uninstall")]

          Item {
            id: answer
            required property int index
            required property string modelData
            readonly property bool current: index === root.confirmIndex

            width: Math.max(Style.space(90), answerText.implicitWidth + root.edge * 2)
            height: answerText.implicitHeight + root.edge

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: answer.current ? Style.hoverFill : "transparent"
              border.width: 1
              border.color: answer.current ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.2)
            }

            Text {
              id: answerText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: answer.modelData
              color: Commons.Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) root.confirmIndex = answer.index
              onClicked: {
                if (answer.index === 1) root.confirmUninstall()
                else root.uninstallApp = null
              }
            }
          }
        }
      }
    }
  }
}
