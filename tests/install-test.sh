#!/usr/bin/env bash
# The installer copies the plugin once, cleans up the old gesture install, and
# is quiet when run again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() {
  echo "not ok - $*" >&2
  exit 1
}

luac -p "$ROOT/hypr/workspace-control.lua"
jq -e '.id == "dtpietrzak.workspacecontrol" and .entryPoints.panel == "WorkspaceControl.qml" and .entryPoints.barWidget == "BarWidget.qml"' "$ROOT/manifest.json" >/dev/null \
  || fail "manifest does not name its entry points"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
export HOME="$tmpdir"
mkdir -p "$HOME/.config/hypr" "$tmpdir/bin"

cat >"$tmpdir/bin/hyprctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$HOME/.hyprctl-log"
exit 0
SH
cat >"$tmpdir/bin/omarchy-shell" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$tmpdir/bin/omarchy" <<'SH'
#!/bin/sh
if [ "$2" = "list" ]; then
  if [ -f "$HOME/.enabled" ]; then enabled=true; else enabled=false; fi
  if [ -f "$HOME/.stock" ]; then stock=true; else stock=false; fi
  printf '[{"id":"dtpietrzak.workspacecontrol","enabled":%s},{"id":"omarchy.workspaces","enabled":%s}]\n' "$enabled" "$stock"
elif [ "$2" = "disable" ]; then
  rm -f "$HOME/.stock"
  printf '%s\n' "$*" >>"$HOME/.omarchy-log"
elif [ "$2" = "enable" ]; then
  : >"$HOME/.enabled"
  printf '%s\n' "$*" >>"$HOME/.omarchy-log"
fi
SH
chmod +x "$tmpdir/bin/hyprctl" "$tmpdir/bin/omarchy-shell" "$tmpdir/bin/omarchy"
export PATH="$tmpdir/bin:$PATH"

HYPR="$HOME/.config/hypr/hyprland.lua"
OLD_GESTURE="$HOME/.config/hypr/workspace-control.lua"
PLUGIN="$HOME/.config/omarchy/plugins/dtpietrzak.workspacecontrol"

# A fresh install leaves the Hyprland config alone.
printf '%s\n' 'require("hypr.input")' 'require("hypr.bindings")' >"$HYPR"
before="$(cat "$HYPR")"
"$ROOT/install.sh" >/dev/null
[[ "$(cat "$HYPR")" == "$before" ]] || fail "fresh install touched hyprland.lua"
[[ ! -f $HOME/.hyprctl-log ]] || fail "fresh install reloaded Hyprland"
cmp -s "$ROOT/WorkspaceControl.qml" "$PLUGIN/WorkspaceControl.qml" || fail "plugin not copied"
cmp -s "$ROOT/hypr/workspace-control.lua" "$PLUGIN/hypr/workspace-control.lua" || fail "gesture not shipped with the plugin"
grep -q "enable dtpietrzak.workspacecontrol" "$HOME/.omarchy-log" || fail "plugin not enabled"

rm -f "$HOME/.omarchy-log"
"$ROOT/install.sh" >/dev/null
[[ ! -f $HOME/.omarchy-log ]] || fail "second run enabled the plugin again"

# The old install is cleaned up, and only its own lines go.
printf '%s\n' 'require("hypr.input")' '' '-- Four finger workspace control panel (omarchy-dtp-workspace-control).' 'require("hypr.workspace-control")' 'require("hypr.bindings")' >"$HYPR"
: >"$OLD_GESTURE"
"$ROOT/install.sh" >/dev/null
[[ "$(cat "$HYPR")" == "$(printf '%s\n' 'require("hypr.input")' '' 'require("hypr.bindings")')" ]] || fail "old lines not removed cleanly"
[[ ! -f $OLD_GESTURE ]] || fail "old gesture left behind"
grep -qx reload "$HOME/.hyprctl-log" || fail "no reload after cleanup"

# The stock numbers go once the widget is on the bar, and not before.
rm -f "$HOME/.omarchy-log"
: >"$HOME/.stock"
"$ROOT/install.sh" >/dev/null
[[ -f $HOME/.stock ]] || fail "stock numbers turned off with the widget not on the bar"
mkdir -p "$HOME/.config/omarchy"
printf '%s\n' '{"bar":{"layout":{"left":[{"id":"dtpietrzak.workspacecontrol"}]}}}' >"$HOME/.config/omarchy/shell.json"
"$ROOT/install.sh" >/dev/null
[[ ! -f $HOME/.stock ]] || fail "stock numbers left on beside the widget"
grep -q "disable omarchy.workspaces" "$HOME/.omarchy-log" || fail "stock numbers not disabled"

echo "ok"
