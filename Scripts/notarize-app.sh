#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

: "${SIMPLECUT_NOTARY_PROFILE:?Set SIMPLECUT_NOTARY_PROFILE to a notarytool keychain profile}"

application="$PWD/build/SimpleCut.app"
archive="$PWD/build/SimpleCut.zip"

if [[ ! -d "$application" ]]; then
  ./Scripts/package-app.sh
fi

codesign --verify --deep --strict --verbose=2 "$application"
ditto -c -k --keepParent "$application" "$archive"
xcrun notarytool submit "$archive" \
  --keychain-profile "$SIMPLECUT_NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$application"
xcrun stapler validate "$application"

echo "$application"
