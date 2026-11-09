#!/usr/bin/env bash
# The installer copies the plugin once and is quiet when run again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() {
  echo "not ok - $*" >&2
  exit 1
}

luac -p "$ROOT/hypr/workspace-control.lua"
jq -e '.id == "io.github.dtpietrzak.workspace-control" and .entryPoints.panel == "WorkspaceControl.qml" and .entryPoints.barWidget == "BarWidget.qml"' "$ROOT/manifest.json" >/dev/null \
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
  printf '[{"id":"io.github.dtpietrzak.workspace-control","enabled":%s}]
' "$enabled"
elif [ "$2" = "enable" ]; then
  : >"$HOME/.enabled"
  printf '%s\n' "$*" >>"$HOME/.omarchy-log"
fi
SH
chmod +x "$tmpdir/bin/hyprctl" "$tmpdir/bin/omarchy-shell" "$tmpdir/bin/omarchy"
export PATH="$tmpdir/bin:$PATH"

HYPR="$HOME/.config/hypr/hyprland.lua"
PLUGIN="$HOME/.config/omarchy/plugins/io.github.dtpietrzak.workspace-control"

# It leaves the Hyprland config alone, and only enables the plugin once.
printf '%s\n' 'require("hypr.input")' 'require("hypr.bindings")' >"$HYPR"
before="$(cat "$HYPR")"
"$ROOT/install.sh" >/dev/null
[[ "$(cat "$HYPR")" == "$before" ]] || fail "install touched hyprland.lua"
[[ ! -f $HOME/.hyprctl-log ]] || fail "install reloaded Hyprland"
cmp -s "$ROOT/WorkspaceControl.qml" "$PLUGIN/WorkspaceControl.qml" || fail "plugin not copied"
cmp -s "$ROOT/hypr/workspace-control.lua" "$PLUGIN/hypr/workspace-control.lua" || fail "gesture not shipped with the plugin"
grep -q "enable io.github.dtpietrzak.workspace-control" "$HOME/.omarchy-log" || fail "plugin not enabled"

rm -f "$HOME/.omarchy-log"
"$ROOT/install.sh" >/dev/null
[[ ! -f $HOME/.omarchy-log ]] || fail "second run enabled the plugin again"

echo "ok"
