#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
application_directory="$PWD/build/SimpleCut.app"

rm -rf "$application_directory"
mkdir -p "$application_directory/Contents/MacOS"
mkdir -p "$application_directory/Contents/Resources"
codesign --force --sign - \
  --entitlements "Resources/SimpleCut.entitlements" \
  "$binary_directory/SimpleCut"
codesign --verify --strict "$binary_directory/SimpleCut"
cp "$binary_directory/SimpleCut" "$application_directory/Contents/MacOS/SimpleCut"
cp "Resources/Info.plist" "$application_directory/Contents/Info.plist"
xcrun actool \
  --compile "$application_directory/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$application_directory/Contents/asset-info.plist" \
  "Resources/Assets.xcassets"
rm "$application_directory/Contents/asset-info.plist"
for resource_bundle in "$binary_directory"/*.bundle(N); do
  bundle_name="${resource_bundle:t}"
  cp -R "$resource_bundle" "$application_directory/$bundle_name"
done
echo "$application_directory"
