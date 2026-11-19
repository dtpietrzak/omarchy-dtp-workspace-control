// Pure helpers for the shared favorites file. The same copy ships in
// omarchy-dtp-favorites, omarchy-dtp-app-list and omarchy-dtp-menu, which all
// read and write ~/.config/omarchy/favorites.json:
//
//   { "version": 1, "apps": ["org.gnome.Nautilus", "chromium", ...] }
//
// Ids are kept exactly as Quickshell's DesktopEntries reports them (the file
// name without its ".desktop"), so org.telegram.desktop stays whole. The list
// order is the order the bar shows them in.

var LIMIT = 48
var DEFAULT_APPS = ["org.gnome.Nautilus", "chromium"]

function appId(value) {
  var id = String(value == null ? "" : value).trim()
  if (!id || id.length > 256) return ""
  if (/[\0\r\n\/]/.test(id)) return ""
  return id
}

// A desktop file name as xdg-terminal-exec prints it ("foot.desktop", or
// "foot.desktop:new-window" with an action) becomes the entry id.
function idFromDesktopFile(value) {
  var name = String(value == null ? "" : value).trim().split(/\r?\n/)[0] || ""
  var colon = name.indexOf(":")
  if (colon >= 0) name = name.slice(0, colon)
  if (name.slice(-8) === ".desktop") name = name.slice(0, -8)
  return appId(name)
}

function clean(list) {
  var next = []
  var seen = ({})
  var values = Array.isArray(list) ? list : []
  for (var i = 0; i < values.length && next.length < LIMIT; i++) {
    var id = appId(values[i])
    if (!id || seen[id]) continue
    seen[id] = true
    next.push(id)
  }
  return next
}

// The saved list, or null when the text is not a favorites file, so a file
// caught half-written or edited by hand into bad JSON never empties the bar.
function parse(text) {
  var data = null
  try { data = JSON.parse(String(text == null ? "" : text)) } catch (e) { return null }
  if (Array.isArray(data)) return clean(data)
  if (data && typeof data === "object" && Array.isArray(data.apps)) return clean(data.apps)
  return null
}

function serialize(list) {
  return JSON.stringify({ version: 1, apps: clean(list) }, null, 2) + "\n"
}

function defaults(terminalId) {
  return clean(DEFAULT_APPS.concat([appId(terminalId)]))
}

function toMap(list) {
  var map = ({})
  var values = clean(list)
  for (var i = 0; i < values.length; i++) map[values[i]] = true
  return map
}

// Adds the app at the end, or takes it out. Null for an id that can't be saved.
function toggle(list, value) {
  var id = appId(value)
  if (!id) return null
  var current = clean(list)
  var index = current.indexOf(id)
  if (index >= 0) current.splice(index, 1)
  else current.push(id)
  return clean(current)
}

// The favorites moved to the front of a list, for launchers that put their
// first row beside the search field. Both groups keep the order they had.
// idOf maps a list item to its app id; null keeps an item with the rest.
function favoritesFirst(list, idOf, map) {
  var first = []
  var rest = []
  var values = Array.isArray(list) ? list : []
  var favorites = map || ({})
  for (var i = 0; i < values.length; i++) {
    var id = idOf(values[i])
    if (id && favorites[id] === true) first.push(values[i])
    else rest.push(values[i])
  }
  return first.concat(rest)
}

// The saved list after the bar drags one of its icons. shown is the ids the
// bar shows, in order (favorites that are not installed are left out); the
// one at from moves to before insert (shown.length means the end). Apps the
// bar does not show keep their places in the file. Null when nothing moves.
function reorder(list, shown, from, insert) {
  var all = clean(list)
  var inFile = toMap(all)
  var order = clean(shown)
  if (from < 0 || from >= order.length) return null
  if (insert < 0 || insert > order.length) return null
  if (insert === from || insert === from + 1) return null
  if (inFile[order[from]] !== true) return null
  var id = order.splice(from, 1)[0]
  order.splice(insert > from ? insert - 1 : insert, 0, id)
  // An icon whose favorite was taken off meanwhile is not written back.
  var moved = order.filter(function(value) { return inFile[value] === true })
  var isShown = toMap(moved)
  var k = 0
  return all.map(function(value) { return isShown[value] === true ? moved[k++] : value })
}

if (typeof module !== "undefined") {
  module.exports = {
    LIMIT: LIMIT,
    appId: appId,
    idFromDesktopFile: idFromDesktopFile,
    clean: clean,
    parse: parse,
    serialize: serialize,
    defaults: defaults,
    toMap: toMap,
    toggle: toggle,
    favoritesFirst: favoritesFirst,
    reorder: reorder
  }
}
