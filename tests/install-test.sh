#!/usr/bin/env bash
# The installer copies the plugin and gesture once, loads the gesture once, and
# is quiet when run again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() {
  echo "not ok - $*" >&2
  exit 1
}

luac -p "$ROOT/hypr/workspace-control.lua"
jq -e '.id == "dtpietrzak.workspacecontrol" and .entryPoints.panel == "WorkspaceControl.qml"' "$ROOT/manifest.json" >/dev/null \
  || fail "manifest does not name the panel entry point"

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
  printf '[{"id":"dtpietrzak.workspacecontrol","enabled":%s}]\n' "$enabled"
elif [ "$2" = "enable" ]; then
  : >"$HOME/.enabled"
  printf '%s\n' "$*" >>"$HOME/.omarchy-log"
fi
SH
chmod +x "$tmpdir/bin/hyprctl" "$tmpdir/bin/omarchy-shell" "$tmpdir/bin/omarchy"
export PATH="$tmpdir/bin:$PATH"

HYPR="$HOME/.config/hypr/hyprland.lua"
PLUGIN="$HOME/.config/omarchy/plugins/dtpietrzak.workspacecontrol"

# After the workspace swipe when that is loaded.
printf '%s\n' 'require("hypr.input")' 'require("hypr.workspace-swipe")' 'require("hypr.bindings")' >"$HYPR"
"$ROOT/install.sh" >/dev/null
[[ "$(sed -n 3p "$HYPR")" == 'require("hypr.workspace-control")' ]] || fail "require not placed after hypr.workspace-swipe"
cmp -s "$ROOT/hypr/workspace-control.lua" "$HOME/.config/hypr/workspace-control.lua" || fail "gesture not copied"
cmp -s "$ROOT/WorkspaceControl.qml" "$PLUGIN/WorkspaceControl.qml" || fail "plugin not copied"
grep -qx reload "$HOME/.hyprctl-log" || fail "no reload"
grep -q "enable dtpietrzak.workspacecontrol" "$HOME/.omarchy-log" || fail "plugin not enabled"

rm -f "$HOME/.hyprctl-log" "$HOME/.omarchy-log"
before="$(cat "$HYPR")"
"$ROOT/install.sh" >/dev/null
[[ "$(cat "$HYPR")" == "$before" ]] || fail "second run rewrote hyprland.lua"
[[ ! -f $HOME/.hyprctl-log ]] || fail "second run reloaded Hyprland"
[[ ! -f $HOME/.omarchy-log ]] || fail "second run enabled the plugin again"

# Only hypr.input: placed after it.
printf '%s\n' 'require("hypr.input")' 'require("hypr.bindings")' >"$HYPR"
"$ROOT/install.sh" >/dev/null
[[ "$(sed -n 2p "$HYPR")" == 'require("hypr.workspace-control")' ]] || fail "require not placed after hypr.input"

# Neither: appended at the end.
printf '%s\n' '-- bare' >"$HYPR"
"$ROOT/install.sh" >/dev/null
[[ "$(grep -c 'hypr.workspace-control' "$HYPR")" == 1 ]] || fail "append failed"

echo "ok"
