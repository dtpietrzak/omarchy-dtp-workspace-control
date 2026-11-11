import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Chord.js" as Chord

// The bar button's settings.
Item {
  id: root

  required property var settings

  // A setting Hyprland only reads when its config loads has changed.
  signal reloadNeeded()

  // Recording a new Examine Workspaces chord. Exclusive until capturePrimed,
  // so a settings window that is already on screen still receives the keys.
  property bool capturing: false
  property bool capturePrimed: false

  function beginCapture() {
    capturePrimed = false
    capturing = true
    capturePrime.restart()
    captureFocus.arm()
  }

  function stopCapture() {
    capturing = false
    capturePrime.stop()
    captureFocus.stop()
  }

  function isModifierOnly(key) {
    return key === Qt.Key_Shift || key === Qt.Key_Control || key === Qt.Key_Alt
        || key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R
        || key === Qt.Key_AltGr || key === Qt.Key_CapsLock || key === Qt.Key_NumLock
  }

  function keyToken(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F12) return "F" + (key - Qt.Key_F1 + 1)
    var named = {}
    named[Qt.Key_Escape] = "ESCAPE"
    named[Qt.Key_Return] = "RETURN"
    named[Qt.Key_Enter] = "RETURN"
    named[Qt.Key_Space] = "SPACE"
    named[Qt.Key_Tab] = "TAB"
    named[Qt.Key_Backtab] = "TAB"
    named[Qt.Key_Backspace] = "BACKSPACE"
    named[Qt.Key_Delete] = "DELETE"
    named[Qt.Key_Left] = "LEFT"
    named[Qt.Key_Right] = "RIGHT"
    named[Qt.Key_Up] = "UP"
    named[Qt.Key_Down] = "DOWN"
    named[Qt.Key_Home] = "HOME"
    named[Qt.Key_End] = "END"
    named[Qt.Key_PageUp] = "PAGE_UP"
    named[Qt.Key_PageDown] = "PAGE_DOWN"
    named[Qt.Key_Insert] = "INSERT"
    named[Qt.Key_Comma] = "COMMA"
    named[Qt.Key_Period] = "PERIOD"
    named[Qt.Key_Slash] = "SLASH"
    named[Qt.Key_QuoteLeft] = "GRAVE"
    named[Qt.Key_Minus] = "MINUS"
    named[Qt.Key_Equal] = "EQUAL"
    named[Qt.Key_BracketLeft] = "BRACKETLEFT"
    named[Qt.Key_BracketRight] = "BRACKETRIGHT"
    named[Qt.Key_Semicolon] = "SEMICOLON"
    named[Qt.Key_Apostrophe] = "APOSTROPHE"
    named[Qt.Key_Backslash] = "BACKSLASH"
    named[Qt.Key_Print] = "PRINT"
    return named[key] || ""
  }

  function takeKey(key, modifiers, text) {
    if (!capturing) return
    if (key === Qt.Key_Escape) {
      stopCapture()
      return
    }
    if (isModifierOnly(key)) return
    var token = keyToken(key)
    if (token === "") return
    var parts = []
    if (modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (modifiers & Qt.AltModifier) parts.push("ALT")
    if (modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    parts.push(token)
    var chord = Chord.normalize(parts.join(" + "))
    if (chord === "") return
    stopCapture()
    if (chord === root.settings.examineKeys) return
    root.settings.set("examineKeys", chord)
    if (root.settings.examine) root.reloadNeeded()
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Grab the keyboard on an already-mapped settings window, then let go of
  // the pointer. Qt focus follows once that keyboard enter has landed.
  Timer {
    id: capturePrime
    interval: 75
    onTriggered: if (root.capturing) root.capturePrimed = true
  }

  Timer {
    id: captureFocus
    interval: 32
    repeat: true
    property int ticks: 0
    property int stable: 0
    function arm() {
      ticks = 0
      stable = 0
      restart()
    }
    onTriggered: {
      if (!root.capturing) {
        stop()
        return
      }
      ticks++
      if (!root.activeFocus) root.forceActiveFocus()
      if (root.capturePrimed && root.activeFocus) stable++
      else stable = 0
      if (stable >= 3 || ticks >= 24) stop()
    }
  }

  Keys.onPressed: event => {
    if (!root.capturing) return
    root.takeKey(event.key, event.modifiers, event.text)
    event.accepted = true
  }

  readonly property int edge: Style.spacing.md
  // Every row the same height, whatever control it holds.
  readonly property int rowHeight: Math.max(Style.space(38), Style.spacing.controlHeight + edge)
  readonly property color quiet: Qt.alpha(Commons.Color.foreground, 0.55)
  readonly property color hairline: Qt.alpha(Commons.Color.foreground, 0.1)

  focus: true
  implicitWidth: Style.space(320)
  implicitHeight: column.implicitHeight + edge

  // A small heading over each group of rows.
  component SectionTitle: Text {
    width: parent ? parent.width : 0
    leftPadding: root.edge
    topPadding: root.edge * 1.5
    bottomPadding: Style.spacing.sm
    textFormat: Text.PlainText
    color: root.quiet
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 0.6
  }

  // Rows that belong together, on a faint tint with a line between each.
  component Group: Rectangle {
    default property alias rows: groupColumn.data
    width: parent ? parent.width : 0
    height: groupColumn.implicitHeight
    radius: Style.cornerRadius
    color: Qt.alpha(Commons.Color.foreground, 0.05)

    Column {
      id: groupColumn
      width: parent.width
    }
  }

  component SettingRow: Item {
    id: settingRow
    property string label: ""
    // Faded when the setting has nothing to do under the others.
    property bool muted: false
    opacity: muted ? 0.45 : 1
    default property alias control: slot.data
    width: parent ? parent.width : 0
    height: root.rowHeight

    Rectangle {
      visible: settingRow.Positioner.index > 0
      x: root.edge
      width: parent.width - root.edge * 2
      height: 1 / Math.max(1, Screen.devicePixelRatio)
      color: root.hairline
    }

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.leftMargin: root.edge * 1.5
      anchors.right: slot.left
      anchors.rightMargin: root.edge
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: settingRow.label
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Item {
      id: slot
      anchors.right: parent.right
      anchors.rightMargin: root.edge
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  // One key of a shortcut, drawn as a keycap.
  component Keycap: Rectangle {
    property string key: ""
    width: Math.max(height, keyText.implicitWidth + Style.space(10))
    height: keyText.implicitHeight + Style.space(6)
    radius: Math.max(3, Style.cornerRadius / 2)
    color: Qt.alpha(Commons.Color.foreground, 0.06)
    border.width: 1
    border.color: Qt.alpha(Commons.Color.foreground, 0.22)

    Text {
      id: keyText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.key
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  // A number picked with a button either side: down on the left, up on the right.
  component Stepper: Row {
    id: stepper
    property int value: 0
    property int from: 0
    property int to: 10
    signal modified(int value)

    spacing: Style.space(2)

    function step(delta) {
      var next = Math.max(from, Math.min(to, value + delta))
      if (next !== value) modified(next)
    }

    Repeater {
      model: 3

      Item {
        id: part
        required property int index
        readonly property bool isButton: index !== 1
        readonly property int delta: index === 0 ? -1 : 1
        readonly property bool enabled: isButton && (delta < 0 ? stepper.value > stepper.from : stepper.value < stepper.to)
        readonly property int size: Style.space(24)

        width: isButton ? size : Math.max(Style.space(22), number.implicitWidth)
        height: size

        Rectangle {
          visible: part.isButton
          anchors.fill: parent
          radius: Style.cornerRadius
          color: partMouse.containsMouse && part.enabled
            ? Style.hoverFill : Qt.alpha(Commons.Color.foreground, 0.06)
          border.width: partMouse.containsMouse && part.enabled ? 1 : 0
          border.color: Commons.Color.accent
          opacity: part.enabled ? 1 : 0.35

          // Drawn bars, so the signs sit dead center.
          Rectangle {
            anchors.centerIn: parent
            width: Style.space(9)
            height: Math.max(1.5, Style.space(1.5))
            radius: height / 2
            color: Commons.Color.foreground
          }

          Rectangle {
            visible: part.delta > 0
            anchors.centerIn: parent
            width: Math.max(1.5, Style.space(1.5))
            height: Style.space(9)
            radius: width / 2
            color: Commons.Color.foreground
          }
        }

        Text {
          id: number
          visible: !part.isButton
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: Commons.I18n.formatNumber(stepper.value, 0)
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.features: { "tnum": 1 }
        }

        MouseArea {
          id: partMouse
          visible: part.isButton
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: part.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (part.enabled) stepper.step(part.delta)
        }
      }
    }
  }

  // One of a few choices, side by side, with the chosen one filled.
  component Choice: Row {
    id: choice
    property var options: []
    property string value: ""
    signal picked(string value)

    spacing: Style.space(2)

    Repeater {
      model: choice.options

      Rectangle {
        id: option
        required property var modelData
        readonly property bool chosen: modelData.value === choice.value
        width: optionText.implicitWidth + Style.space(12)
        height: Style.space(24)
        radius: Style.cornerRadius
        color: chosen ? Style.selectedAccentFill
          : optionMouse.containsMouse ? Style.hoverFill : Qt.alpha(Commons.Color.foreground, 0.06)
        border.width: chosen || optionMouse.containsMouse ? 1 : 0
        border.color: Commons.Color.accent

        Text {
          id: optionText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: option.modelData.label
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: optionMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (!option.chosen) choice.picked(option.modelData.value)
        }
      }
    }
  }

  Column {
    id: column
    x: Style.spacing.sm
    width: parent.width - Style.spacing.sm * 2

    Text {
      leftPadding: root.edge
      topPadding: root.edge
      textFormat: Text.PlainText
      text: strings.t("settings.title")
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.weight: Font.DemiBold
    }

    SectionTitle { text: strings.t("settings.section.workspaces") }

    Group {
      SettingRow {
        label: strings.t("settings.count.bar")
        Stepper {
          from: 1
          to: 10
          value: root.settings.barWorkspaces
          onModified: function(value) { root.settings.set("barWorkspaces", value) }
        }
      }

      SettingRow {
        label: strings.t("settings.count.panel")
        Stepper {
          from: 1
          to: 10
          value: root.settings.panelWorkspaces
          onModified: function(value) { root.settings.set("panelWorkspaces", value) }
        }
      }
    }

    SectionTitle { text: strings.t("settings.section.bar") }

    Group {
      SettingRow {
        label: strings.t("settings.barIcons")
        ToggleSwitch {
          checked: root.settings.barIcons
          onToggled: root.settings.set("barIcons", !root.settings.barIcons)
        }
      }

      SettingRow {
        label: strings.t("settings.hoverCards")
        ToggleSwitch {
          checked: root.settings.hoverCards
          onToggled: root.settings.set("hoverCards", !root.settings.hoverCards)
        }
      }

      SettingRow {
        label: strings.t("settings.appsButton")
        ToggleSwitch {
          checked: root.settings.appsButton
          onToggled: root.settings.set("appsButton", !root.settings.appsButton)
        }
      }

      SettingRow {
        label: strings.t("settings.panelButton")
        ToggleSwitch {
          checked: root.settings.panelButton
          onToggled: root.settings.set("panelButton", !root.settings.panelButton)
        }
      }

      SettingRow {
        label: strings.t("settings.minimizedButton")
        ToggleSwitch {
          checked: root.settings.minimizedButton
          onToggled: root.settings.set("minimizedButton", !root.settings.minimizedButton)
        }
      }
    }

    SectionTitle { text: strings.t("settings.section.line") }

    Group {
      SettingRow {
        label: strings.t("settings.linePosition")
        Choice {
          value: root.settings.overline ? "over" : "under"
          options: [
            { value: "under", label: strings.t("settings.linePosition.under") },
            { value: "over", label: strings.t("settings.linePosition.over") }
          ]
          onPicked: function(value) { root.settings.set("linePosition", value) }
        }
      }

      SettingRow {
        label: strings.t("settings.lineAnimation")
        ToggleSwitch {
          checked: root.settings.lineAnimation
          onToggled: root.settings.set("lineAnimation", !root.settings.lineAnimation)
        }
      }

      SettingRow {
        label: strings.t("settings.lineSplash")
        muted: !root.settings.lineAnimation
        ToggleSwitch {
          checked: root.settings.lineSplash
          onToggled: root.settings.set("lineSplash", !root.settings.lineSplash)
        }
      }

      SettingRow {
        label: strings.t("settings.panelAnimation")
        ToggleSwitch {
          checked: root.settings.panelAnimation
          onToggled: root.settings.set("panelAnimation", !root.settings.panelAnimation)
        }
      }

      Repeater {
        // Each needs the panel outline animated.
        model: [
          { key: "panelSpeedLines", label: "settings.panelSpeedLines" },
          { key: "panelImpacts", label: "settings.panelImpacts" },
          { key: "panelDropSplash", label: "settings.panelDropSplash" }
        ]

        SettingRow {
          required property var modelData
          label: strings.t(modelData.label)
          muted: !root.settings.panelAnimation
          ToggleSwitch {
            checked: root.settings[modelData.key]
            onToggled: root.settings.set(modelData.key, !root.settings[modelData.key])
          }
        }
      }
    }

    SectionTitle { text: strings.t("settings.section.shortcuts") }

    Group {
      SettingRow {
        label: strings.t("settings.examine")
        Row {
          spacing: root.edge

          // Click to record a new chord.
          Rectangle {
            id: shortcut
            anchors.verticalCenter: parent.verticalCenter
            readonly property bool hot: shortcutMouse.containsMouse || root.capturing
            width: (root.capturing ? pressText.implicitWidth : keys.implicitWidth) + Style.space(8)
            height: Math.max(keys.implicitHeight, pressText.implicitHeight) + Style.space(6)
            radius: Style.cornerRadius
            color: hot ? Style.hoverFill : "transparent"
            border.width: hot ? 1 : 0
            border.color: Commons.Color.accent
            opacity: root.settings.examine || root.capturing ? 1 : 0.45

            Row {
              id: keys
              visible: !root.capturing
              anchors.centerIn: parent
              spacing: Style.space(3)

              Repeater {
                model: Chord.pretty(root.settings.examineKeys).split("+")
                Keycap {
                  required property string modelData
                  key: modelData
                }
              }
            }

            Text {
              id: pressText
              visible: root.capturing
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: strings.t("settings.examine.press")
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: shortcutMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.beginCapture()
            }
          }

          ToggleSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: root.settings.examine
            onToggled: {
              root.settings.set("examine", !root.settings.examine)
              root.reloadNeeded()
            }
          }
        }
      }

      SettingRow {
        label: strings.t("settings.swipe")
        ToggleSwitch {
          checked: root.settings.swipe
          onToggled: {
            root.settings.set("swipe", !root.settings.swipe)
            root.reloadNeeded()
          }
        }
      }

      SettingRow {
        label: strings.t("settings.hotkeys")
        ToggleSwitch {
          checked: root.settings.hotkeys
          onToggled: {
            root.settings.set("hotkeys", !root.settings.hotkeys)
            root.reloadNeeded()
          }
        }
      }
    }
  }
}
