#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

swift package resolve
transformers_checkout="$PWD/.build/checkouts/swift-transformers"
transformers_patch="$PWD/Scripts/patches/swift-transformers-app-resources.patch"
if grep -q "Bundle.module.url" \
  "$transformers_checkout/Sources/Hub/Hub.swift"; then
  git -C "$transformers_checkout" apply "$transformers_patch"
fi

swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
application_directory="$PWD/build/SimpleCut.app"

rm -rf "$application_directory"
mkdir -p "$application_directory/Contents/MacOS"
mkdir -p "$application_directory/Contents/Resources"
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
  for resource in "$resource_bundle"/*(DN); do
    cp -R "$resource" "$application_directory/Contents/Resources/"
  done
done
codesign --force --deep --sign - \
  --entitlements "Resources/SimpleCut.entitlements" \
  "$application_directory"
codesign --verify --deep --strict "$application_directory"
echo "$application_directory"
