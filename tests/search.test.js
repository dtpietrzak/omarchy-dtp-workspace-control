const assert = require("assert")
const fs = require("fs")
const path = require("path")
const search = require("../AppSearch.js")
const upstream = require("../../omarchy/shell/services/AppSearch.js")

const entries = [
  {
    name: "Google Contacts",
    genericName: "Address Book",
    comment: "Manage contacts",
    keywords: ["contacts", "address book", "people"],
    id: "google-contacts"
  },
  {
    name: "Calculator",
    genericName: "Calculator",
    comment: "Perform arithmetic, scientific or financial calculations",
    keywords: ["calculation", "arithmetic", "scientific", "financial"],
    id: "org.gnome.Calculator"
  },
  {
    name: "OBS Studio",
    genericName: "Streaming/Recording Software",
    comment: "Free and Open Source Streaming/Recording Software",
    keywords: ["streaming", "recording", "capture"],
    id: "com.obsproject.Studio"
  },
  {
    name: "Aether",
    genericName: "",
    comment: "Minimal internet radio player",
    keywords: ["audio", "music", "radio"],
    id: "io.github.taqi.aether"
  },
  {
    name: "1Password",
    genericName: "",
    comment: "Password manager",
    keywords: ["password", "vault"],
    id: "1password",
    noDisplay: true
  }
]

function names(mod, query, hidden) {
  return mod.sortedEntries(entries, query, hidden).map(function(row) { return row.entry.name })
}

for (const query of ["", "contact", "gc", "obs", "calc", "password", "no-such-app"]) {
  assert.deepStrictEqual(names(search, query), names(upstream, query), query)
}

assert.deepStrictEqual(names(search, "contact"), ["Google Contacts"])
assert.ok(search.fuzzyScore(entries[1], "contact") < 0)
assert.strictEqual(names(search, "gc")[0], "Google Contacts")
assert.strictEqual(names(search, "obs")[0], "OBS Studio")
assert.deepStrictEqual(names(search, "password"), [])
assert.deepStrictEqual(
  names(search, "", function(entry) { return entry.id === "org.gnome.Calculator" }),
  ["Aether", "Google Contacts", "OBS Studio"]
)

const qml = fs.readFileSync(path.join(__dirname, "../SearchField.qml"), "utf8")
const textBlocks = qml.split(/Text\s*\{/).slice(1)
assert.ok(textBlocks.length >= 2, "expected Text elements")
for (let i = 0; i < textBlocks.length; i++) {
  const body = textBlocks[i].split("}")[0]
  assert.ok(/textFormat:\s*Text\.PlainText/.test(body), "Text element " + i + " is missing PlainText")
}
assert.ok(/border\.width:\s*0/.test(qml))
assert.ok(/topLeftRadius:\s*0/.test(qml))
assert.ok(/bottomLeftRadius:\s*Style\.cornerRadius/.test(qml))
assert.ok(/bottomRightRadius:\s*Style\.cornerRadius/.test(qml))

const strings = JSON.parse(fs.readFileSync(path.join(__dirname, "../i18n/en.json"), "utf8"))
assert.strictEqual(strings["search.placeholder"], "Search apps…")

const panel = fs.readFileSync(path.join(__dirname, "../WorkspaceControl.qml"), "utf8")
assert.ok(/if \(!root\.opened\) return WlrKeyboardFocus\.None/.test(panel), "closed releases the keyboard")
assert.ok(/if \(root\.keyboardHold\) return WlrKeyboardFocus\.OnDemand[\s\S]*if \(!root\.opened\) return WlrKeyboardFocus\.None/.test(panel), "close holds OnDemand until the destination window is focused")
assert.ok(/if \(root\.slid \|\| !root\.focusPrimed\) return WlrKeyboardFocus\.Exclusive/.test(panel), "arrows keep Exclusive")
assert.ok(/id: handoff/.test(panel), "destination focus waits until OnDemand is committed")
assert.ok(/function finishHandoff/.test(panel))
assert.ok(/function windowOn/.test(panel))
assert.ok(/hl\.dsp\.focus\(\{ window = "address:' \+ address \+ '" \}\)[\s\S]*keyboardHold = false/.test(panel), "the window is focused before the keyboard drops")
assert.ok(/id: browseKeys/.test(panel), "arrows need a focus target once the field lets go")
assert.ok(/id: slideDispatch/.test(panel), "workspace focus waits until Exclusive is committed")
assert.ok(/function keepPanelKeys/.test(panel))
assert.ok(/slideDispatch\.stop\(\)/.test(panel))
assert.ok(/interval: 75/.test(panel))
assert.ok(/backingWindowVisible/.test(panel))
assert.ok(/function insertText\(/.test(qml))
assert.ok(!/pressNumber/.test(panel), "digits must not jump workspaces while the panel is open")
assert.ok(/function slideWorkspace/.test(panel))
assert.ok(/function launchOnViewed/.test(panel))
assert.ok(/homeListId/.test(panel), "the open panel lists the workspace you're on")
assert.ok(/function cycleWindow/.test(panel))
assert.ok(/function confirmListedWindow/.test(panel))
assert.ok(/signal windowStepped/.test(qml))
assert.ok(/signal windowActivate/.test(qml))
assert.ok(/property bool browsing/.test(qml))
assert.ok(/query\.trim\(\)\.length === 0 \|\| root\.hits\.length === 0/.test(qml))

console.log("search tests ok")
