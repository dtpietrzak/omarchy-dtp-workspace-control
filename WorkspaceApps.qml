import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons as Commons

// Which apps have windows and what their icons are, for the bar and the panel.
QtObject {
  // The bar's background: opaque, glassy or none.
  function barBackground(barConfig) {
    var bar = barConfig || {}
    var look = bar.background || (bar.transparent === true ? "none" : "opaque")
    var color = Commons.Color.bar.background
    if (look === "none") return "transparent"
    if (look === "glassy") return Qt.rgba(color.r, color.g, color.b, Math.min(color.a, 0.35))
    return color
  }

  // Floating cards have text on them, so a clear bar still gets them a backing.
  function cardBackground(barConfig) {
    var color = barBackground(barConfig)
    return color.a > 0 ? color : Commons.Color.bar.background
  }

  function windowAddress(toplevel) {
    var address = String(toplevel && toplevel.address || "")
    if (address !== "" && address.indexOf("0x") !== 0) address = "0x" + address
    return /^0x[0-9a-f]+$/i.test(address) ? address : ""
  }

  // Focusing a workspace or window warps the mouse to it. Here it stays put,
  // without touching how the rest of the desktop behaves.
  function dispatchWithoutWarp(dispatcher) {
    Hyprland.dispatch('(function()'
      + ' local no_warps = hl.get_config("cursor.no_warps")'
      + ' local on_change = hl.get_config("cursor.warp_on_change_workspace")'
      + ' hl.config({ cursor = { no_warps = true, warp_on_change_workspace = 0 } })'
      + ' hl.dispatch(' + dispatcher + ')'
      + ' hl.config({ cursor = { no_warps = no_warps, warp_on_change_workspace = on_change } })'
      + ' end)')
  }

  // Focus a window, wherever it is, and bring it to the front there.
  function focusAddress(address) {
    if (address === "") return
    dispatchWithoutWarp('hl.dsp.focus({ window = "address:' + address + '" })')
    Hyprland.dispatch('hl.dsp.window.alter_zorder({ mode = "top", window = "address:' + address + '" })')
    // Hyprland keeps a window opened over a maximized one above it, whatever the
    // stack says. Maximizing again is what puts the maximized window back on top.
    Hyprland.dispatch('(function()'
      + ' local window = hl.get_active_window()'
      + ' if not window or window.address ~= "' + address + '" or (window.fullscreen or 0) == 0 then return end'
      + ' local mode = window.fullscreen == 2 and "fullscreen" or "maximized"'
      + ' hl.dispatch(hl.dsp.window.fullscreen({ mode = mode, action = "unset", window = window }))'
      + ' hl.dispatch(hl.dsp.window.fullscreen({ mode = mode, action = "set", window = window }))'
      + ' end)')
  }

  // Move a window to a workspace, on top of what's there, without following it.
  function moveWindow(toplevel, id) {
    var address = windowAddress(toplevel)
    if (address === "") return
    Hyprland.dispatch('hl.dsp.window.move({ workspace = "' + id + '", follow = false, window = "address:' + address + '" })')
    // A moved window keeps its old place in the stack, so it has to be raised.
    Hyprland.dispatch('hl.dsp.window.alter_zorder({ mode = "top", window = "address:' + address + '" })')
  }

  // Ask a window to close, the same as the × in its title bar.
  function closeWindow(toplevel) {
    var address = windowAddress(toplevel)
    if (address !== "") Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + address + '" })')
  }

  // The windows waiting on Omarchy's minimized workspace.
  readonly property var minimizedWindows: {
    var values = Hyprland.toplevels.values
    var found = []
    for (var i = 0; i < values.length; i++) {
      if (values[i].workspace && values[i].workspace.name === "special:minimized") found.push(values[i])
    }
    return found
  }

  // Back onto this workspace, focused and on top, without animating in. The same
  // as the dock does.
  function restoreWindow(toplevel, id) {
    var address = windowAddress(toplevel)
    if (address === "" || id < 1) return
    var target = 'window = "address:' + address + '"'
    Hyprland.dispatch('hl.dsp.window.set_prop({ prop = "no_anim", value = "1", ' + target + ' })')
    Hyprland.dispatch('hl.dsp.window.move({ workspace = "' + id + '", follow = false, ' + target + ' })')
    focusAddress(address)
    Quickshell.execDetached(["sh", "-c", 'sleep 0.4; exec hyprctl dispatch "$1"', "sh",
      'hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", ' + target + ' })'])
  }

  function focusWindow(toplevel) {
    focusAddress(windowAddress(toplevel))
  }

  function appIdOf(toplevel) {
    return String(toplevel.wayland && toplevel.wayland.appId || (toplevel.lastIpcObject || {})["class"] || "")
  }

  function letterFor(appId) {
    return appId.split(".").pop().slice(0, 1).toUpperCase()
  }

  function iconFor(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    var icon = String(entry && entry.icon ? entry.icon : appId)
    if (icon.charAt(0) === "/") return "file://" + icon
    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    return Quickshell.iconPath(icon, true)
  }

  // One entry per app, however many windows it has.
  function appsIn(toplevels) {
    // Desktop entries load after the shell, and a lookup alone wouldn't notice.
    var entriesLoaded = DesktopEntries.applications.values.length
    var found = []
    var seen = {}
    for (var i = 0; i < toplevels.length; i++) {
      var appId = appIdOf(toplevels[i])
      if (appId === "") continue
      var source = iconFor(appId)
      var key = source || appId
      if (seen[key]) continue
      seen[key] = true
      found.push({ source: source, letter: letterFor(appId) })
    }
    return found
  }
}
