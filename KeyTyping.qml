import QtQuick
import Quickshell.Io
import "TextKeys.js" as TextKeys

// Typing, deleting, cut and paste for a read-only TextInput, plus its cursor.
// A writable TextInput reads the whole clipboard whenever it changes, so the
// search fields stay read-only and call handle() from their key handlers.
//
// TEMPORARY: a workaround for a Qt bug, to be undone later.
// Why: QQuickTextInput's canPaste check called QMimeData::text() on every
// clipboard change, so a hostile clipboard owner could stall or flood the
// shell (marketplace review of v2.1.1, eb3f167). Qt fixed it in qtdeclarative
// bcbfae6 (QTBUG-149610), first shipped in 6.12.1; 6.12.0 still has it.
// When to undo: once Arch's qt6-declarative is at 6.12.1 or later, and the
// plugin can require that.
// How to undo: drop readOnly: true and the KeyTyping block from
// SearchField.qml and AppListCard.qml, put back AppListCard's
// readOnly: !!root.menuApp || !!root.uninstallApp, remove the typing.handle()
// fallbacks in their key handlers, and delete KeyTyping.qml, TextKeys.js and
// tests/textkeys.test.js. Doing that brings back the input method and compose.
Item {
  id: typing

  property var field: null
  property color cursorColor: "white"

  function nameFor(key) {
    if (key === Qt.Key_Backspace) return "backspace"
    if (key === Qt.Key_Delete) return "delete"
    if (key === Qt.Key_V) return "v"
    if (key === Qt.Key_X) return "x"
    if (key === Qt.Key_U) return "u"
    return ""
  }

  // True when the key changed the text or started a paste.
  function handle(event) {
    if (!field) return false
    var mods = event.modifiers & ~(Qt.KeypadModifier)
    var ctrl = (mods & Qt.ControlModifier) !== 0
    var alt = (mods & (Qt.AltModifier | Qt.MetaModifier)) !== 0
    var op = event.key === Qt.Key_Insert && (mods & Qt.ShiftModifier) && !ctrl && !alt
      ? "paste"
      : TextKeys.opFor(nameFor(event.key), event.text, ctrl, alt)
    if (!op) return false
    if (op === "paste") paste()
    else if (op === "cut") {
      if (field.selectedText.length === 0) return true
      field.copy()
      run(op, "")
    } else run(op, event.text)
    return true
  }

  function run(op, arg) {
    var next = TextKeys.apply(field.text, field.selectionStart, field.selectionEnd, op, arg)
    if (next.text !== field.text) field.text = next.text
    field.cursorPosition = Math.min(next.cursor, field.text.length)
    blink.restart()
    caret.visible = true
  }

  function paste() {
    if (reader.running) return
    reader.running = true
  }

  // wl-paste runs apart from the shell with a time and size limit, so a slow
  // or endless clipboard owner can't hold up the panel.
  Process {
    id: reader
    command: ["timeout", "2", "sh", "-c", "wl-paste -n -t text 2>/dev/null | head -c 1024"]
    stdout: StdioCollector {
      onStreamFinished: {
        var value = TextKeys.cleanPaste(text)
        if (value && typing.field && typing.field.activeFocus) typing.run("paste", value)
      }
    }
  }

  // Read-only TextInput draws no cursor, so this one stands in for it.
  Rectangle {
    id: caret
    parent: typing.field
    visible: false
    x: typing.field ? typing.field.cursorRectangle.x : 0
    y: typing.field ? typing.field.cursorRectangle.y : 0
    width: 1
    height: typing.field ? typing.field.cursorRectangle.height : 0
    color: typing.cursorColor
  }

  Timer {
    id: blink
    interval: Math.max(250, Qt.styleHints.cursorFlashTime / 2)
    repeat: true
    running: !!typing.field && typing.field.activeFocus && typing.field.selectedText.length === 0
    onRunningChanged: caret.visible = running
    onTriggered: caret.visible = !caret.visible
  }
}
