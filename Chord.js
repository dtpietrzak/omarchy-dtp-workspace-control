// A key chord for the Examine Workspaces hotkey. The saved form is
// "SUPER + CTRL + ALT + SHIFT + E": holders first, then one key.
// hypr/workspace-control.lua accepts only this form.

var HOLDERS = { SUPER: true, CTRL: true, ALT: true, SHIFT: true }
var HOLDER_ORDER = ["SUPER", "CTRL", "ALT", "SHIFT"]

// Key names Hyprland accepts. Letters, digits, and F1–F12 are added below.
var KEY_NAMES = [
  "ESCAPE", "RETURN", "SPACE", "TAB", "BACKSPACE", "DELETE",
  "LEFT", "RIGHT", "UP", "DOWN", "HOME", "END", "PAGE_UP", "PAGE_DOWN", "INSERT",
  "COMMA", "PERIOD", "SLASH", "GRAVE", "MINUS", "EQUAL",
  "BRACKETLEFT", "BRACKETRIGHT", "SEMICOLON", "APOSTROPHE", "BACKSLASH", "PRINT"
]

var KEYS = {}
var i
for (i = 0; i < KEY_NAMES.length; i++) KEYS[KEY_NAMES[i]] = true
for (i = 0; i < 26; i++) KEYS[String.fromCharCode(65 + i)] = true
for (i = 0; i < 10; i++) KEYS[String(i)] = true
for (i = 1; i <= 12; i++) KEYS["F" + i] = true

function normalize(text) {
  var tokens = String(text || "").toUpperCase().match(/[A-Z0-9_]+/g)
  if (!tokens) return ""
  var seen = {}
  var key = ""
  for (i = 0; i < tokens.length; i++) {
    var token = tokens[i] === "META" ? "SUPER" : tokens[i]
    if (seen[token]) continue
    seen[token] = true
    if (HOLDERS[token]) continue
    else if (KEYS[token]) {
      if (key !== "") return ""
      key = token
    } else return ""
  }
  var hasHolder = false
  var ordered = []
  for (i = 0; i < HOLDER_ORDER.length; i++) {
    if (seen[HOLDER_ORDER[i]]) {
      ordered.push(HOLDER_ORDER[i])
      if (HOLDER_ORDER[i] !== "SHIFT") hasHolder = true
    }
  }
  if (!hasHolder || key === "") return ""
  ordered.push(key)
  return ordered.join(" + ")
}

function pretty(chord) {
  var parts = String(chord || "").split(" + ")
  var out = []
  for (i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "SUPER") out.push("Super")
    else if (part === "CTRL") out.push("Ctrl")
    else if (part === "ALT") out.push("Alt")
    else if (part === "SHIFT") out.push("Shift")
    else if (part.length === 1) out.push(part)
    else if (/^F\d+$/.test(part)) out.push(part)
    else {
      var words = part.toLowerCase().split("_")
      var shown = []
      var w
      for (w = 0; w < words.length; w++) {
        if (words[w].length === 0) continue
        shown.push(words[w].charAt(0).toUpperCase() + words[w].slice(1))
      }
      out.push(shown.join(" "))
    }
  }
  return out.join("+")
}

if (typeof module !== "undefined") {
  module.exports = {
    KEY_NAMES: KEY_NAMES,
    normalize: normalize,
    pretty: pretty
  }
}
