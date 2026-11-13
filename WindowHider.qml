import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// Takes one window off the screen while it is being carried somewhere, and
// puts it back the way it was. Hyprland has no way to unset an opacity, only
// to set a number, so the window's own opacity is read before it is hidden.
Scope {
  id: hider

  // The window hidden now, and its opacity from before, as [active, inactive].
  property string address: ""
  property var opacity: null

  // What each window's opacity was when it was last read or put back, and
  // when. A window shown and hidden again straight away, as one carried back
  // and forth over an edge is, must not be read again: Hyprland may not have
  // put it back yet, and reading 0 then would make 0 what it is put back to,
  // leaving it invisible for good.
  property var remembered: ({})
  readonly property int rememberMs: 3000

  // Hides the window at this address, showing any other one hidden before it.
  function hide(next) {
    if (next === "" || next === address) return
    show()
    address = next
    opacity = null
    var recent = remembered[next]
    if (recent && Date.now() - recent.at < rememberMs) {
      opacity = recent.values
      set(next, 0, 0)
      return
    }
    reader.address = next
    reader.command = ["sh", "-c", 'hyprctl getprop "address:$1" opacity; hyprctl getprop "address:$1" opacity_inactive', "sh", next]
    reader.running = true
  }

  // Shows the hidden window again. Not hidden yet if its opacity was still
  // being read: then there is nothing to undo.
  function show() {
    moveWait.stop()
    pastFade.stop()
    movedTo = -1
    var was = address
    var values = opacity
    address = ""
    opacity = null
    if (was !== "" && values) {
      set(was, values[0], values[1])
      remembered[was] = { values: values, at: Date.now() }
    }
  }

  // Shows the hidden window again once Hyprland has moved it off this workspace,
  // so it never flashes here first. Hyprland says it moved as the move starts,
  // and fades it out here after, so it stays hidden well past that: it is on a
  // workspace that isn't showing, so nothing is lost. Going to that workspace
  // shows it at once. In case the move never comes, soon anyway.
  function showAfterMove() {
    if (address === "") return
    moveWait.restart()
  }

  Timer {
    id: moveWait
    interval: 900
    onTriggered: hider.show()
  }

  Timer {
    id: pastFade
    interval: 1200
    onTriggered: hider.show()
  }
  // Where it was moved to.
  property int movedTo: -1

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name)
      var fields = String(event.data).split(",")
      if (name === "workspacev2" && pastFade.running && parseInt(fields[0], 10) === hider.movedTo) {
        hider.show()
        return
      }
      if (!moveWait.running || name !== "movewindowv2") return
      if (("0x" + fields[0]).toLowerCase() !== hider.address.toLowerCase()) return
      moveWait.stop()
      hider.movedTo = parseInt(fields[1], 10)
      pastFade.restart()
    }
  }

  // Gone with a window still hidden, as when its card closes mid-drag: put it back.
  Component.onDestruction: show()

  function set(target, active, inactive) {
    Hyprland.dispatch('hl.dsp.window.set_prop({ window = "address:' + target + '", prop = "opacity", value = "' + active + '" })')
    Hyprland.dispatch('hl.dsp.window.set_prop({ window = "address:' + target + '", prop = "opacity_inactive", value = "' + inactive + '" })')
  }

  Process {
    id: reader
    property string address: ""
    stdout: StdioCollector {
      onStreamFinished: {
        // Shown again, or another window hidden, while this was read.
        if (reader.address !== hider.address) return
        var values = String(text).trim().split(/\s+/).map(Number)
        var active = values.length > 0 && !isNaN(values[0]) ? values[0] : 1
        var inactive = values.length > 1 && !isNaN(values[1]) ? values[1] : 1
        // No window is meant to be invisible. One that reads as it was caught
        // while hidden, so it goes back to what it was before, or to solid.
        if (active <= 0 && inactive <= 0) {
          var before = hider.remembered[hider.address]
          active = before ? before.values[0] : 1
          inactive = before ? before.values[1] : 1
        }
        hider.opacity = [active, inactive]
        hider.remembered[hider.address] = { values: [active, inactive], at: Date.now() }
        hider.set(hider.address, 0, 0)
      }
    }
  }
}
