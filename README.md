# omarchy-dtp-workspace-control

A four finger swipe up on Omarchy (Hyprland 0.56+) pulls a band of workspaces up from the bottom of the screen, with a live mini view of the windows on each one.

![Opening the workspace panel and dragging windows onto workspaces](screenshots/workspace-control.gif)

- The band follows your fingers. Let go after 20% of the way and it finishes the trip and stays on the bottom edge of the screen, or just above the bar if the bar is at the bottom. Let go sooner and it drops back.
- Click a workspace to jump to it. The band slides back down as you land there. Click a window's mini view to also bring that window to the front and focus it.
- Drag a window onto another workspace to move it there, either its mini view or the real window above the band. It lands on top of the windows already there, and you stay where you are.
- Each workspace's number is centered over it together with the icons of the apps with windows there, one per app.
- Hover over a workspace to set it for selection: every other workspace, border and number included, fades to 50%. Hover over a window's mini view to also get a thin rounded border in the theme's accent color and fade the other windows on that workspace to 50%, showing it can be dragged. This lasts through the drag.
- Hovering over a workspace with windows also floats a list of them above it, topmost first, each with its app icon and window title. Click one to jump to that workspace with that window focused and on top, or drag one onto another workspace to move it there. The × at the end of a row closes that window, the same as the × in its title bar.
- Drag a workspace's number and icons along the row to move it, the same as on the bar. Its windows take the new position's number and those it passed shift over by one.
- Press a number while it is open to do the same for the workspace with that number (0 is 10). A number with no workspace in the band does nothing.
- A four finger swipe down of 20% or more, a click anywhere above or below the band, or Escape closes it.
- The mouse stays where it is when you jump or close. Nothing else about the mouse changes: other workspace changes, such as Super+number, still follow your `cursor` settings.
- Super+Shift+Left and Right go to the previous or next workspace, empty or not, without wrapping. Super+Shift+Up and Down focus the next or previous window on this workspace and bring it to the front. All four replace Omarchy's defaults on those keys, which swap tiled windows.
- The bar widget has a button that opens and closes it, for anyone without a touchpad, and right-clicking the button brings up a small menu, then a number for each workspace: 1 to 7, plus any others that are open. To the right of each number are the icons of the apps with windows there, one per app. A very thin line separates the button and each workspace from the next. A workspace with apps has a grey line under its number and icons, and the current workspace has the same line in the theme's accent color. Clicking a number or its icons goes to that workspace. Drag a number along the bar to move that workspace: its windows take the new position's number and those it passed shift over by one. Hovering a workspace with windows brings up a card against the bar, lined up with the divider before that number, with a list of them, icon and title, and a preview of the workspace. On a bottom bar the preview is above the list, and on any other bar it's below. The list appears at once and the preview fades in when it's ready. Click a window in the list or its mini view in the preview to go to it, or its × to close it. Hovering a mini view gives it the panel's thin accent border and fades the others. Drag a list row or mini view onto a number on the bar to move that window there; you stay where you are. Add it with `omarchy bar` or from the bar's settings.

The band's background follows the bar's `omarchy bar background` setting: opaque, glassy with the same blur, or clear.

It lists the first seven of the focused monitor's own workspaces (see Settings below), any others that exist, and any visiting from an unplugged monitor.

The plugin id is `dtpietrzak.workspacecontrol`. It needs nothing in your Hyprland config: `WorkspaceControl.qml` loads `hypr/workspace-control.lua` into Hyprland when it starts and after every Hyprland reload. That file reports the swipe to the plugin as custom Hyprland events on the socket Quickshell already reads, because the gesture callbacks must never call `hyprctl`: Hyprland runs them itself and the call would wait on Hyprland forever. If you already have your own four finger vertical gesture, Hyprland keeps yours and the swipe won't open the panel.

Right-click the bar button and choose Settings for how many workspaces are always shown on the bar and in the panel, app icons on the bar, the hover cards, the hotkeys, and the four finger swipe up. They're saved to `~/.config/omarchy/dtpietrzak.workspacecontrol.json`.

Tuning: `SENSITIVITY` at the top of `hypr/workspace-control.lua`, and `commitAt` at the top of `WorkspaceControl.qml`.

To put it on a key as well, `omarchy-shell shell call dtpietrzak.workspacecontrol toggle ""` opens and closes it.

## Install

```bash
omarchy plugin add https://github.com/dtpietrzak/omarchy-dtp-workspace-control.git --enable
```

Plugins run unsandboxed inside the Omarchy shell, so read the code first.

To work from a local checkout, `./install.sh` copies the plugin to `~/.config/omarchy/plugins/dtpietrzak.workspacecontrol` and enables it. `omarchy-dtp-install` runs the same script. Versions before 2.0 added a line to `hyprland.lua` and a copy of the gesture to `~/.config/hypr/`, and the script removes both.

## Check

```bash
bash tests/install-test.sh
omarchy plugin validate .
```

## Remove

```bash
omarchy plugin remove dtpietrzak.workspacecontrol
```

The swipe stays registered, doing nothing, until Hyprland next reloads.
