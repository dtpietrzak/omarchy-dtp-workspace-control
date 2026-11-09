# omarchy-dtp-workspace-control

A four finger swipe up on Omarchy (Hyprland 0.56+) pulls a band of workspaces up from the bottom of the screen, with a live mini view of the windows on each one.

![Opening the workspace panel and dragging windows onto workspaces](screenshots/workspace-control.gif)

- The band follows your fingers. Let go after 20% of the way and it finishes the trip and stays on the bottom edge of the screen, or just above the bar if the bar is at the bottom. Let go sooner and it drops back.
- Click a workspace to jump to it. The band slides back down as you land there. Click a window's mini view to also bring that window to the front and focus it.
- Drag a window onto another workspace to move it there, either its mini view or the real window above the band. It lands on top of the windows already there, and you stay where you are.
- Hover over a workspace to set it for selection: every other workspace, border and number included, fades to 50%. Hover over a window's mini view to also get a thin rounded border in the theme's accent color and fade the other windows on that workspace to 50%, showing it can be dragged. This lasts through the drag.
- Press a number while it is open to do the same for the workspace with that number (0 is 10). A number with no workspace in the band does nothing.
- A four finger swipe down of 20% or more, a click anywhere above or below the band, or Escape closes it.
- The mouse stays where it is when you jump or close. This turns off `cursor.warp_on_change_workspace`, so it also stays put on every other workspace change, such as Super+number.

The band's background follows the bar's `omarchy bar background` setting: opaque, glassy with the same blur, or clear.

It lists the same workspaces as the bar: the first five of the focused monitor's own, any others that exist, and any visiting from an unplugged monitor.

The shell plugin id is `dtpietrzak.workspacecontrol`. The gesture lives in `hypr/workspace-control.lua` and reports the swipe to the plugin as custom Hyprland events on the socket Quickshell already reads, because the gesture callbacks must never call `hyprctl`: Hyprland runs them itself and the call would wait on Hyprland forever.

Tuning: `SENSITIVITY` at the top of `hypr/workspace-control.lua`, and `commitAt` at the top of `WorkspaceControl.qml`.

To put it on a key as well, `omarchy-shell shell call dtpietrzak.workspacecontrol toggle ""` opens and closes it.

## Install

`omarchy-dtp-install` runs this script with the other features. From a local checkout:

```bash
./install.sh
```

It copies the plugin to `~/.config/omarchy/plugins/dtpietrzak.workspacecontrol` and enables it, copies `hypr/workspace-control.lua` to `~/.config/hypr/`, and adds `require("hypr.workspace-control")` to `hyprland.lua`. Running it again leaves matching files alone.

## Check

```bash
bash tests/install-test.sh
omarchy plugin validate .
```

## Undo

```bash
omarchy plugin remove dtpietrzak.workspacecontrol
```

Then delete the `require("hypr.workspace-control")` line from `~/.config/hypr/hyprland.lua` and remove `~/.config/hypr/workspace-control.lua`.
