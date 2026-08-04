#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
application_directory="$PWD/build/SimpleCut.app"

mkdir -p "$application_directory/Contents/MacOS"
mkdir -p "$application_directory/Contents/Resources"
for stale_root_bundle in "$application_directory"/*.bundle(N); do
  rm -rf "$stale_root_bundle"
done
cp "$binary_directory/SimpleCut" "$application_directory/Contents/MacOS/SimpleCut"
cp "Resources/Info.plist" "$application_directory/Contents/Info.plist"
for resource_bundle in "$binary_directory"/*.bundle(N); do
  bundle_name="${resource_bundle:t}"
  rm -rf "$application_directory/Contents/Resources/$bundle_name"
  cp -R "$resource_bundle" "$application_directory/Contents/Resources/$bundle_name"
done
codesign --force --deep --sign - \
  --entitlements "Resources/SimpleCut.entitlements" \
  "$application_directory"
codesign --verify --deep --strict "$application_directory"

echo "$application_directory"
