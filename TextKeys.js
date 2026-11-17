// Typing for the read-only search fields. A writable TextInput reads the
// whole clipboard every time it changes (Qt before 6.12.1), so the fields stay
// read-only and their keys go through here instead. Paste is the one place
// the clipboard is read, through a bounded wl-paste.

var PASTE_LIMIT = 128

// What a key does to the text, or "" when the field should leave it alone.
// ctrl and alt are the held modifiers, shift aside.
function opFor(name, text, ctrl, alt) {
  if (name === "backspace") return ctrl ? "deleteWordBack" : "deleteBack"
  if (name === "delete") return ctrl ? "deleteWordForward" : "deleteForward"
  if (ctrl && !alt) {
    var lower = String(text || "").toLowerCase()
    if (name === "v" || lower === "v" || lower === "\u0016") return "paste"
    if (name === "x" || lower === "x" || lower === "\u0018") return "cut"
    if (name === "u" || lower === "u" || lower === "\u0015") return "clear"
    return ""
  }
  if (alt) return ""
  return printable(text) ? "insert" : ""
}

function printable(text) {
  var value = String(text || "")
  return value.length > 0 && !/[\u0000-\u001f\u007f]/.test(value)
}

// Clipboard text as one line of at most PASTE_LIMIT characters.
function cleanPaste(raw) {
  var value = String(raw || "").replace(/[\r\n\t]+/g, " ").replace(/[\u0000-\u001f\u007f�]/g, "")
  value = value.trim()
  return Array.from(value).slice(0, PASTE_LIMIT).join("")
}

function wordStart(text, from) {
  var i = from
  while (i > 0 && /\s/.test(text[i - 1])) i--
  while (i > 0 && !/\s/.test(text[i - 1])) i--
  return i
}

function wordEnd(text, from) {
  var i = from
  while (i < text.length && /\s/.test(text[i])) i++
  while (i < text.length && !/\s/.test(text[i])) i++
  return i
}

// Applies op to text with the selection start..end. Returns { text, cursor }.
function apply(text, start, end, op, arg) {
  var value = String(text || "")
  var a = Math.max(0, Math.min(start, end, value.length))
  var b = Math.max(0, Math.min(Math.max(start, end), value.length))
  var picked = a !== b
  if (op === "insert" || op === "paste") {
    var extra = String(arg || "")
    return { text: value.slice(0, a) + extra + value.slice(b), cursor: a + extra.length }
  }
  if (op === "clear") return { text: "", cursor: 0 }
  if (op === "cut") return { text: value.slice(0, a) + value.slice(b), cursor: a }
  if (picked) return { text: value.slice(0, a) + value.slice(b), cursor: a }
  if (op === "deleteBack") {
    if (a === 0) return { text: value, cursor: 0 }
    // Keep a surrogate pair together.
    var back = a >= 2 && /[\udc00-\udfff]/.test(value[a - 1]) && /[\ud800-\udbff]/.test(value[a - 2]) ? 2 : 1
    return { text: value.slice(0, a - back) + value.slice(a), cursor: a - back }
  }
  if (op === "deleteForward") {
    var ahead = /[\ud800-\udbff]/.test(value[a]) && /[\udc00-\udfff]/.test(value[a + 1]) ? 2 : 1
    return { text: value.slice(0, a) + value.slice(a + ahead), cursor: a }
  }
  if (op === "deleteWordBack") {
    var from = wordStart(value, a)
    return { text: value.slice(0, from) + value.slice(a), cursor: from }
  }
  if (op === "deleteWordForward") {
    return { text: value.slice(0, a) + value.slice(wordEnd(value, a)), cursor: a }
  }
  return { text: value, cursor: b }
}

if (typeof module !== "undefined") {
  module.exports = {
    PASTE_LIMIT: PASTE_LIMIT,
    opFor: opFor,
    printable: printable,
    cleanPaste: cleanPaste,
    apply: apply
  }
}
