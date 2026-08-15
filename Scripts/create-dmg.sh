#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

application="$PWD/build/SimpleCut.app"
image="$PWD/build/SimpleCut-macOS.dmg"

if [[ ! -d "$application" ]]; then
  ./Scripts/package-app.sh
fi

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/simplecut-dmg.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT

cp -R "$application" "$staging_directory/SimpleCut.app"
ln -s /Applications "$staging_directory/Applications"
rm -f "$image"
hdiutil create \
  -volname "SimpleCut" \
  -srcfolder "$staging_directory" \
  -ov \
  -format UDZO \
  "$image"

echo "$image"
