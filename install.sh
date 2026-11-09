#!/usr/bin/env bash
# Install the four finger workspace control panel: the shell plugin and the
# Hyprland gesture that drives it. Safe to run again: files that already match
# are left alone.
#
#   ./install.sh

set -euo pipefail

PLUGIN_ID="dtpietrzak.workspacecontrol"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/hypr/workspace-control.lua"
HYPR_DIR="$HOME/.config/hypr"
TARGET="$HYPR_DIR/workspace-control.lua"
HYPRLAND="$HYPR_DIR/hyprland.lua"
REQUIRE='require("hypr.workspace-control")'
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
[[ -f $SOURCE ]] || fail "missing $SOURCE"
[[ -f $HYPRLAND ]] || fail "$HYPRLAND must already exist"
command -v jq >/dev/null || fail "jq is required"
command -v rsync >/dev/null || fail "rsync is required"
command -v python3 >/dev/null || fail "python3 is required"

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

if omarchy plugin list --json | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and .enabled)' >/dev/null; then
  echo "Plugin $PLUGIN_ID is already enabled"
else
  omarchy plugin enable "$PLUGIN_ID"
fi

changed=0

if [[ -f $TARGET ]] && cmp -s "$SOURCE" "$TARGET"; then
  echo "workspace-control.lua is already installed"
else
  cp "$SOURCE" "$TARGET"
  echo "Installed $TARGET"
  changed=1
fi

if grep -qxF "$REQUIRE" "$HYPRLAND"; then
  echo "hyprland.lua already loads workspace-control"
else
  python3 - "$HYPRLAND" "$REQUIRE" <<'PY'
import sys
from pathlib import Path

path, require = Path(sys.argv[1]), sys.argv[2]
lines = path.read_text().splitlines(keepends=True)
for anchor in ('require("hypr.workspace-swipe")', 'require("hypr.input")'):
    hit = next((i for i, line in enumerate(lines) if line.strip() == anchor), None)
    if hit is not None:
        lines.insert(hit + 1, require + "\n")
        break
else:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append("\n-- Four finger workspace control panel (omarchy-dtp-workspace-control).\n")
    lines.append(require + "\n")
path.write_text("".join(lines))
PY
  echo "Updated hyprland.lua"
  changed=1
fi

if [[ $changed -eq 1 ]]; then
  hyprctl reload >/dev/null
  errors="$(hyprctl configerrors 2>&1 || true)"
  if [[ -n ${errors//[[:space:]]/} ]]; then
    printf '%s\n' "$errors" >&2
    fail "Hyprland reported config errors"
  fi
  echo "Hyprland config reloaded with no errors"
fi
