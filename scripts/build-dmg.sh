#!/usr/bin/env bash
# Packages a built CrossDrop.app into a compressed, unsigned DMG.
#
#   scripts/build-dmg.sh <path/to/CrossDrop.app> <output.dmg>
#
# With create-dmg installed (brew install create-dmg) and Pillow available, the
# DMG opens as a styled installer window: wallpaper background, the app on the
# left and an Applications drop link on the right. create-dmg drives Finder via
# AppleScript, which can fail on headless CI; in that case this falls back to a
# plain DMG (app + Applications shortcut) so the build never breaks.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <path/to/CrossDrop.app> <output.dmg>" >&2
  exit 2
fi

app="$1"
output="$2"
here="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d "$app" ]]; then
  echo "error: app bundle not found: $app" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rm -f "$output"
mkdir -p "$(dirname "$output")"

plain_dmg() {
  local staging="$work/plain"
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "CrossDrop" -srcfolder "$staging" -fs HFS+ -ov -format UDZO "$output"
}

styled_dmg() {
  command -v create-dmg >/dev/null 2>&1 || { echo "create-dmg not installed"; return 1; }
  python3 "$here/make_dmg_background.py" "$work/bg" || return 1
  local background="$work/bg/dmg-background.png"
  # Combine 1x and 2x into one HiDPI-aware TIFF when the tool is available.
  if command -v tiffutil >/dev/null 2>&1; then
    tiffutil -cathidpicheck "$work/bg/dmg-background.png" "$work/bg/dmg-background@2x.png" \
      -out "$work/bg/dmg-background.tiff" >/dev/null 2>&1 && background="$work/bg/dmg-background.tiff"
  fi
  local staging="$work/styled"
  mkdir -p "$staging"
  cp -R "$app" "$staging/"
  timeout_cmd=""
  command -v gtimeout >/dev/null 2>&1 && timeout_cmd="gtimeout 300"
  $timeout_cmd create-dmg \
    --volname "CrossDrop" \
    --background "$background" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 112 \
    --text-size 13 \
    --icon "CrossDrop.app" 170 200 \
    --hide-extension "CrossDrop.app" \
    --app-drop-link 490 200 \
    "$output" "$staging"
}

if styled_dmg; then
  echo "created styled $output"
else
  echo "styled DMG unavailable; building a plain DMG instead" >&2
  rm -f "$output"
  plain_dmg
  echo "created $output"
fi
