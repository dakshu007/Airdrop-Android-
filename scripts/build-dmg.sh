#!/usr/bin/env bash
# Packages a built CrossDrop.app into a compressed, unsigned DMG with an
# Applications shortcut.
#   scripts/build-dmg.sh <path/to/CrossDrop.app> <output.dmg>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <path/to/CrossDrop.app> <output.dmg>" >&2
  exit 2
fi

app="$1"
output="$2"

if [[ ! -d "$app" ]]; then
  echo "error: app bundle not found: $app" >&2
  exit 1
fi

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

rm -f "$output"
mkdir -p "$(dirname "$output")"
hdiutil create \
  -volname "CrossDrop" \
  -srcfolder "$staging" \
  -fs HFS+ \
  -ov \
  -format UDZO \
  "$output"

echo "created $output"
