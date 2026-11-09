# Workspace Control for Omarchy

A better workspace row for the Omarchy bar, and a panel of live workspaces on a four finger swipe up. See every window on every workspace, then move, focus, close and reorder them by clicking and dragging.

![Hovering workspaces on the bar for live previews, and moving windows around in the workspace panel](screenshots/workspace-control.gif)

## Requirements

- Omarchy Quattro with Hyprland 0.56 or newer.
- A touchpad for the four finger swipe. Without one, open the panel with the bar button.

Nothing else needs installing.

## Install

Plugins run unsandboxed inside the Omarchy shell, so read the code first.

```bash
omarchy plugin add https://github.com/dtpietrzak/omarchy-dtp-workspace-control.git --enable
```

It lands on the left of the bar. If you were using Omarchy's own workspace numbers, turn them off so you don't have two rows:

```bash
omarchy plugin disable omarchy.workspaces
```

## Remove

```bash
omarchy plugin remove io.github.dtpietrzak.workspace-control
rm -f ~/.config/omarchy/io.github.dtpietrzak.workspace-control.json
```

The swipe stays registered, doing nothing, until Hyprland next reloads. If you turned Omarchy's workspace numbers off, `omarchy plugin enable omarchy.workspaces` brings them back.

## On the bar

![A hover card on the bar with a live preview of the workspace and a list of its windows](screenshots/bar-hover-card.png)

- The three squares open and close the panel. Right-click them for Settings.
- A number for each workspace, 1 to 7 plus any others that are open, with the icons of the apps on it, one per app. A grey line runs under a workspace with apps, and the current one is underlined in the theme's accent color.
- Click a number or its icons to go to that workspace. Drag a number along the bar to move that workspace: its windows take the new position's number and those it passed shift over by one.
- Hover a workspace with windows for a card with a live preview and a list of its windows. Click a window in either to go to it, use its × to close it, or drag it onto a number to move it there without leaving where you are.
- The ... after the last number lists minimized windows. Click one or its ^ to bring it to the workspace you're on, use its × to close it, or drag it onto a number to send it there.

## In the panel

![The workspace panel with a live view of each workspace](preview.png)

A four finger swipe up pulls up a band of workspaces with a live mini view of each window. Let go after 20% of the way and it stays; let go sooner and it drops back.

- Click a workspace to jump to it. Click a window's mini view to also focus it and bring it to the front.
- Drag a window, by its mini view or the real window above the band, onto another workspace to move it there.
- Hover a workspace for a list of its windows, with the same click, drag and × as on the bar.
- Drag a workspace's number and icons along the row to move it.
- The gear above the first workspace opens the settings, and the ... above the last one lists minimized windows.
- Press a number to jump to that workspace (0 is 10).
- A four finger swipe down of 20% or more, a click above or below the band, or Escape closes it.

The band follows the bar's `omarchy bar background` setting: opaque, glassy with the same blur, or clear.

## Settings

Right-click the three squares and choose Settings, or use the gear in the panel:

- How many workspaces are always shown on the bar and in the panel.
- App icons on the bar.
- Workspace previews on hover.
- Super+Shift+arrow hotkeys.
- The four finger swipe up.

They're saved to `~/.config/omarchy/io.github.dtpietrzak.workspace-control.json`.

## Good to know

- **Hotkeys are off until you turn them on.** With them on, Super+Shift+Left and Right go to the previous or next workspace, and Up and Down cycle the windows on this workspace. They replace whatever is on those keys while they're on, which on a stock Omarchy is swapping tiled windows.
- **Hyprland config:** the plugin changes no files. It registers its swipe, layer rules and hotkeys with Hyprland at runtime, when it starts and after each reload. If you already have a four finger vertical gesture, yours is kept and the swipe won't open the panel.
- **Maximized windows:** Hyprland keeps drawing a window that was opened over a maximized one above it, while clicks go to whichever is first in the stack. So when a maximized window gets focus, the plugin brings it fully to the front. Focus the other window to bring it back on top.
- **Moving a workspace moves its windows.** Workspace numbers are fixed in Hyprland, so that's what reordering does.
- **Dragging numbers on the bar** relies on how Omarchy's bar lays out its widgets, which isn't a public interface. If that changes, clicking numbers keeps working and only the dragging stops.

To open the panel from your own key binding:

```bash
omarchy-shell shell call io.github.dtpietrzak.workspace-control toggle ""
```

## Development

From a checkout, `./install.sh` copies the plugin into `~/.config/omarchy/plugins` and enables it. Tuning values are `SENSITIVITY` at the top of `hypr/workspace-control.lua` and `commitAt` at the top of `WorkspaceControl.qml`.

```bash
bash tests/install-test.sh
omarchy plugin validate .
```

## License

MIT
