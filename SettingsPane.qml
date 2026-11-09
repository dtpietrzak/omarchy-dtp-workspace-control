import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bar button's settings.
Item {
  id: root

  required property var settings

  // A setting Hyprland only reads when its config loads has changed.
  signal reloadNeeded()

  readonly property int edge: Style.spacing.md

  focus: true
  implicitWidth: Style.space(300)
  implicitHeight: column.implicitHeight

  component SettingRow: Item {
    id: settingRow
    property string label: ""
    default property alias control: slot.data
    width: parent ? parent.width : 0
    height: Math.max(slot.childrenRect.height, labelText.implicitHeight) + root.edge

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.leftMargin: root.edge
      anchors.right: slot.left
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

  Column {
    id: column
    width: parent.width

    Text {
      leftPadding: root.edge
      topPadding: root.edge / 2
      bottomPadding: root.edge / 2
      textFormat: Text.PlainText
      text: "Settings"
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
    }

    SettingRow {
      label: "Workspaces on the bar"
      NumberField {
        fieldWidth: Style.space(70)
        from: 1
        to: 10
        value: root.settings.barWorkspaces
        onModified: function(value) { root.settings.set("barWorkspaces", value) }
      }
    }

    SettingRow {
      label: "Workspaces in the panel"
      NumberField {
        fieldWidth: Style.space(70)
        from: 1
        to: 10
        value: root.settings.panelWorkspaces
        onModified: function(value) { root.settings.set("panelWorkspaces", value) }
      }
    }

    SettingRow {
      label: "App icons on the bar"
      ToggleSwitch {
        checked: root.settings.barIcons
        onToggled: root.settings.set("barIcons", !root.settings.barIcons)
      }
    }

    SettingRow {
      label: "Preview workspaces on hover"
      ToggleSwitch {
        checked: root.settings.hoverCards
        onToggled: root.settings.set("hoverCards", !root.settings.hoverCards)
      }
    }

    SettingRow {
      label: "Super+Shift+arrow hotkeys"
      ToggleSwitch {
        checked: root.settings.hotkeys
        onToggled: {
          root.settings.set("hotkeys", !root.settings.hotkeys)
          root.reloadNeeded()
        }
      }
    }

    SettingRow {
      label: "4 finger swipe up"
      ToggleSwitch {
        checked: root.settings.swipe
        onToggled: {
          root.settings.set("swipe", !root.settings.swipe)
          root.reloadNeeded()
        }
      }
    }
  }
}
