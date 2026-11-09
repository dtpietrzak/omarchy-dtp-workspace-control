#!/usr/bin/env bash
# Install the four finger workspace control panel from a local checkout. Safe to
# run again: files that already match are left alone.
#
#   ./install.sh

set -euo pipefail

PLUGIN_ID="dtpietrzak.workspacecontrol"
ROOT="$(cd "$(dirname "$0")" && pwd)"
HYPR_DIR="$HOME/.config/hypr"
OLD_GESTURE="$HYPR_DIR/workspace-control.lua"
HYPRLAND="$HYPR_DIR/hyprland.lua"
OLD_REQUIRE='require("hypr.workspace-control")'
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

fail() {
  echo "install: $*" >&2
  exit 1
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  echo "Usage: install.sh"
  echo "Installs the four finger workspace control panel."
  exit 0
fi
[[ $# -eq 0 ]] || fail "unknown argument: $1"
command -v jq >/dev/null || fail "jq is required"
command -v rsync >/dev/null || fail "rsync is required"

updating=0
[[ -f $DEST/manifest.json ]] && updating=1
mkdir -p "$DEST"
copied="$(rsync -a --checksum --delete --exclude .git --itemize-changes "$ROOT/" "$DEST/")"
if [[ -n $copied ]]; then
  echo "Synced plugin files to $DEST"
  if [[ $updating -eq 1 ]]; then
    # An always-loaded panel survives the shell's plugin hot-reload, so only a
    # restart picks up new code.
    echo "Restarting the shell so the panel picks up the new files"
    omarchy restart shell
  else
    omarchy-shell shell rescanPlugins >/dev/null
  fi
else
  echo "Plugin files already match $DEST"
fi

known=0
for attempt in $(seq 1 40); do
  if omarchy plugin list --json | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null; then
    known=1
    break
  fi
  if [[ $attempt -eq 1 ]]; then
    omarchy-shell shell rescanPlugins >/dev/null
  fi
  sleep 0.05
done
[[ $known -eq 1 ]] || fail "plugin $PLUGIN_ID was not discovered"

# Omarchy calls a bar widget enabled only while it is on the bar, and enabling
# puts it there. Listed anywhere in shell.json, the panel already runs, and
# whether the button is on the bar is the user's choice.
if jq -e --arg id "$PLUGIN_ID" 'any(.. | objects; .id? == $id)' "$HOME/.config/omarchy/shell.json" >/dev/null 2>&1 ||
  omarchy plugin list --json | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and .enabled)' >/dev/null; then
  echo "Plugin $PLUGIN_ID is already enabled"
else
  omarchy plugin enable "$PLUGIN_ID"
fi

# The widget brings its own workspace numbers, so the stock ones would be a
# second row of the same thing.
if jq -e --arg id "$PLUGIN_ID" 'any(.bar.layout[]?[]?; .id? == $id)' "$HOME/.config/omarchy/shell.json" >/dev/null 2>&1 &&
  omarchy plugin list --json | jq -e 'any(.[]; .id == "omarchy.workspaces" and .enabled)' >/dev/null; then
  omarchy plugin disable omarchy.workspaces
  echo "Turned off the stock workspace widget"
fi

# Before 2.0 the gesture was installed into the Hyprland config. The plugin
# loads it itself now, and the old copy would hold the gesture in its place.
if [[ -f $OLD_GESTURE ]] || { [[ -f $HYPRLAND ]] && grep -qxF "$OLD_REQUIRE" "$HYPRLAND"; }; then
  rm -f "$OLD_GESTURE"
  if [[ -f $HYPRLAND ]]; then
    sed -i -e '/^-- Four finger workspace control panel (omarchy-dtp-workspace-control)\.$/d' \
      -e '/^require("hypr\.workspace-control")$/d' "$HYPRLAND"
  fi
  echo "Removed the old gesture from the Hyprland config"
  hyprctl reload >/dev/null
  errors="$(hyprctl configerrors 2>&1 || true)"
  if [[ -n ${errors//[[:space:]]/} ]]; then
    printf '%s\n' "$errors" >&2
    fail "Hyprland reported config errors"
  fi
fi
