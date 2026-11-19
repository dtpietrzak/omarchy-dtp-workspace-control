import QtQuick
import Quickshell
import Quickshell.Io
import "Favorites.js" as Favorites

// The favorited apps, shared through ~/.config/omarchy/favorites.json. Every
// copy watches the file, so a star clicked in the app list or the menu shows
// on the bar at once. The same file ships in omarchy-dtp-favorites,
// omarchy-dtp-app-list and omarchy-dtp-menu.
//
// With no file yet, the first copy to load writes the defaults: Files,
// Chromium and the default terminal.
Item {
  id: store

  property var apps: []
  readonly property var map: Favorites.toMap(store.apps)
  property bool missing: false
  readonly property string path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
    + "/omarchy/favorites.json"

  function isFavorite(id) {
    return store.map[String(id == null ? "" : id)] === true
  }

  function save(list) {
    store.apps = Favorites.clean(list)
    store.missing = false
    file.setText(Favorites.serialize(store.apps))
  }

  function toggle(id) {
    var next = Favorites.toggle(store.apps, id)
    if (next !== null) store.save(next)
  }

  FileView {
    id: file
    path: store.path
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onFileChanged: reload()
    onLoaded: {
      store.missing = false
      var parsed = Favorites.parse(text())
      if (parsed !== null) store.apps = parsed
    }
    onLoadFailed: function(error) {
      store.missing = true
      store.apps = Favorites.defaults("")
      if (!terminalProbe.running) terminalProbe.running = true
    }
  }

  // The default terminal, as Omarchy's own `omarchy default terminal` reads it.
  Process {
    id: terminalProbe
    command: ["xdg-terminal-exec", "--print-id"]
    stdout: StdioCollector { id: terminalOut }
    onExited: function(exitCode) {
      if (!store.missing) return
      var terminal = exitCode === 0 ? Favorites.idFromDesktopFile(terminalOut.text) : ""
      store.save(Favorites.defaults(terminal))
    }
  }
}
