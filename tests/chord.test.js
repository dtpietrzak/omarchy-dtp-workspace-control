const assert = require("assert")
const fs = require("fs")
const path = require("path")
const chord = require("../Chord.js")

assert.strictEqual(chord.normalize("super + e"), "SUPER + E")
assert.strictEqual(chord.normalize("E + SUPER"), "SUPER + E")
assert.strictEqual(chord.normalize("META + shift + e"), "SUPER + SHIFT + E")
assert.strictEqual(chord.normalize("SHIFT + CTRL + SUPER + ALT + F5"), "SUPER + CTRL + ALT + SHIFT + F5")
assert.strictEqual(chord.normalize("SUPER + SUPER + E"), "SUPER + E")
assert.strictEqual(chord.normalize("SHIFT + E"), "")
assert.strictEqual(chord.normalize("SUPER"), "")
assert.strictEqual(chord.normalize("SUPER + E + F"), "")
assert.strictEqual(chord.normalize("SUPER + NOT_A_KEY"), "")
assert.strictEqual(chord.normalize("comma + super"), "SUPER + COMMA")
assert.strictEqual(chord.pretty("SUPER + E"), "Super+E")
assert.strictEqual(chord.pretty("SUPER + CTRL + PAGE_UP"), "Super+Ctrl+Page Up")
assert.strictEqual(chord.pretty("SUPER + F12"), "Super+F12")

const lua = fs.readFileSync(path.join(__dirname, "../hypr/workspace-control.lua"), "utf8")
const listed = lua.slice(lua.indexOf("local EXAMINE_KEYS"), lua.indexOf("for byte"))
for (const name of chord.KEY_NAMES) {
  assert.ok(listed.indexOf(name + " = true") !== -1, name + " missing from the lua allowlist")
}
assert.ok(/enabled\("examine", true\)/.test(lua))
assert.ok(/Examine Workspaces/.test(lua))
assert.ok(/examine_binding\(\)/.test(lua))

const strings = JSON.parse(fs.readFileSync(path.join(__dirname, "../i18n/en.json"), "utf8"))
assert.strictEqual(strings["settings.examine"], "Examine Workspaces")
assert.strictEqual(strings["settings.examine.press"], "Press keys…")

const pane = fs.readFileSync(path.join(__dirname, "../SettingsPane.qml"), "utf8")
assert.ok(/settings\.examine/.test(pane))
assert.ok(/function beginCapture/.test(pane))
assert.ok(/function takeKey/.test(pane))

console.log("chord tests ok")
