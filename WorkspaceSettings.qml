import QtQuick
import Quickshell
import Quickshell.Io

// The plugin's saved settings. The bar and the panel each hold one of these and
// follow the file, and hypr/workspace-control.lua reads the same file.
Scope {
  id: root

  property var values: ({})

  readonly property int barWorkspaces: count("barWorkspaces", 7)
  readonly property int panelWorkspaces: count("panelWorkspaces", 7)
  readonly property bool barIcons: flag("barIcons")
  readonly property bool hoverCards: flag("hoverCards")
  // Off until asked for, because they replace what is on those keys.
  readonly property bool hotkeys: values.hotkeys === true
  readonly property bool swipe: flag("swipe")

  function count(key, fallback) {
    var value = Number(values[key])
    return value >= 1 && value <= 10 ? Math.round(value) : fallback
  }

  function flag(key) {
    return values[key] !== false
  }

  function set(key, value) {
    var next = {}
    for (var existing in values) next[existing] = values[existing]
    next[key] = value
    values = next
    file.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function read(text) {
    try {
      var parsed = JSON.parse(text)
      values = parsed && typeof parsed === "object" ? parsed : {}
    } catch (e) {
      values = {}
    }
  }

  FileView {
    id: file
    path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/io.github.dtpietrzak.workspace-control.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.read(text())
    onLoadFailed: root.values = {}
  }
}
