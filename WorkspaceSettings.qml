import QtQuick
import Quickshell
import Quickshell.Io
import "Chord.js" as Chord

// The plugin's saved settings. The bar and the panel each hold one of these and
// follow the file, and hypr/workspace-control.lua reads the same file.
Scope {
  id: root

  property var values: ({})

  readonly property int barWorkspaces: count("barWorkspaces", 7)
  readonly property int panelWorkspaces: count("panelWorkspaces", 7)
  // A window dropped somewhere is kept wholly on the screen. Off, it may hang
  // off the left, right and bottom edges, with some of it left showing.
  readonly property bool lockDrops: flag("lockDrops")
  // Where a window's left and top may be on a screen this big, for a drop
  // there. Its top is never above the top edge either way, nor closer to it
  // than its title bar is tall, so the title bar is always in reach.
  readonly property int keepShowing: 50
  // free is for a window dragged about the screen by the real window, which
  // is never held wholly on it, whatever the setting: that is how a window
  // dragged about the screen always goes.
  function keepX(left, width, screenWidth, free) {
    var whole = lockDrops && !free
    var least = whole ? 0 : keepShowing - width
    var most = whole ? screenWidth - width : screenWidth - keepShowing
    return Math.max(least, Math.min(most, left))
  }
  function keepY(top, height, screenHeight, free) {
    return Math.max(titleBarHeight, Math.min(lockDrops && !free ? screenHeight - height : screenHeight - keepShowing, top))
  }

  // Not settings of the plugin's, but ones it has to go by: the title bars
  // the hyprbars plugin puts on windows. They sit above a window, outside the
  // size Hyprland reports for it. The height is 0 without them. Read when
  // asked, since they can be turned on or off or restyled.
  property int titleBarHeight: 0
  property color titleBarColor: "transparent"
  function readTitleBars() { titleBarReader.running = true }

  // Hyprland gives a color as one number, alpha first.
  function colorOf(value) {
    return Qt.rgba(((value >>> 16) & 255) / 255, ((value >>> 8) & 255) / 255, (value & 255) / 255, ((value >>> 24) & 255) / 255)
  }

  Process {
    id: titleBarReader
    command: ["sh", "-c", 'for o in enabled bar_height bar_color; do hyprctl getoption "plugin:hyprbars:$o" -j | tr -d "\n"; echo; done']
    stdout: StdioCollector {
      onStreamFinished: {
        // One line for each option, and not JSON for one that isn't there.
        var found = {}
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
          try {
            var entry = JSON.parse(lines[i])
            var name = String(entry.option).replace("plugin:hyprbars:", "")
            found[name] = entry["int"] !== undefined ? entry["int"] : entry["bool"]
          } catch (e) {}
        }
        root.titleBarHeight = found.enabled !== false && found.bar_height > 0 ? found.bar_height : 0
        if (found.bar_color !== undefined) root.titleBarColor = root.colorOf(found.bar_color)
      }
    }
  }

  readonly property bool barIcons: flag("barIcons")
  readonly property bool hoverCards: flag("hoverCards")
  readonly property bool appsButton: flag("appsButton")
  readonly property bool panelButton: flag("panelButton")
  readonly property bool minimizedButton: flag("minimizedButton")
  // Off until asked for, because they replace what is on those keys.
  readonly property bool hotkeys: values.hotkeys === true
  readonly property bool swipe: flag("swipe")
  // On by default: Super+E is not used by Omarchy.
  readonly property bool examine: flag("examine")
  readonly property string examineKeys: chord("examineKeys")

  // The current workspace's line: under the numbers or over them, whether it
  // moves to the next workspace or jumps, and whether it splashes on landing.
  readonly property bool overline: values.linePosition === "over"
  readonly property bool lineAnimation: flag("lineAnimation")
  readonly property bool lineSplash: flag("lineSplash")
  // The outline on the current workspace in the panel, stretching to the next.
  readonly property bool panelAnimation: flag("panelAnimation")
  // The panel's effects, each on its own: speed lines behind whatever slides
  // along the row, impact lines as it stops, and a splash off a dropped window.
  readonly property bool panelSpeedLines: flag("panelSpeedLines")
  readonly property bool panelImpacts: flag("panelImpacts")
  readonly property bool panelDropSplash: flag("panelDropSplash")

  function chord(key) {
    var value = values[key] === undefined || values[key] === null ? "" : String(values[key])
    var normal = Chord.normalize(value)
    return normal !== "" ? normal : "SUPER + E"
  }

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
