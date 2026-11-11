const assert = require("assert")
const fs = require("fs")
const path = require("path")

const read = name => fs.readFileSync(path.join(__dirname, "..", name), "utf8")
const strings = JSON.parse(read("i18n/en.json"))
const pane = read("SettingsPane.qml")
const settings = read("WorkspaceSettings.qml")

// Every string the settings pane asks for is in the English file.
for (const match of pane.matchAll(/strings\.t\("([^"]+)"\)/g)) {
  assert.ok(match[1] in strings, match[1] + " missing from i18n/en.json")
}
for (const match of pane.matchAll(/label: "(settings\.[^"]+)"/g)) {
  assert.ok(match[1] in strings, match[1] + " missing from i18n/en.json")
}

// The line's three settings, and nothing else of its in the pane.
for (const key of ["lineAnimation", "lineSplash"]) {
  assert.ok(new RegExp("readonly property bool " + key + ":").test(settings), key + " missing from WorkspaceSettings.qml")
  assert.ok(pane.indexOf('settings.set("' + key + '"') !== -1, key + " missing from SettingsPane.qml")
}
assert.ok(/linePosition === "over"/.test(settings))
assert.ok(pane.indexOf('settings.set("linePosition"') !== -1)
assert.strictEqual((pane.match(/settings\.set\("line/g) || []).length, 3)
assert.ok(/readonly property bool panelAnimation:/.test(settings))
assert.ok(pane.indexOf('settings.set("panelAnimation"') !== -1)

// The panel's three effects, each a setting of its own with a switch.
for (const key of ["panelSpeedLines", "panelImpacts", "panelDropSplash"]) {
  assert.ok(new RegExp("readonly property bool " + key + ":").test(settings), key + " missing from WorkspaceSettings.qml")
  assert.ok(pane.indexOf('key: "' + key + '"') !== -1, key + " missing from SettingsPane.qml")
}

// The line only imports Qt, so it can be rendered on its own.
const line = read("WorkspaceLine.qml")
for (const match of line.matchAll(/^import (\S+)/gm)) {
  assert.ok(/^Qt/.test(match[1]), "WorkspaceLine.qml imports " + match[1])
}

console.log("line tests ok")
