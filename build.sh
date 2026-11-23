#!/bin/zsh
set -eu
cd "${0:A:h}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$work/Feynman.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
sdk=$(xcrun --show-sdk-path)
older_sdk="${sdk:h}/MacOSX26.5.sdk"
if [[ -d "$older_sdk" ]]; then sdk="$older_sdk"; fi
target=arm64-apple-macos14.0
clang -isysroot "$sdk" -target "$target" -O2 Helpers/FeynmanTTY.c -o "$app/Contents/MacOS/FeynmanTTY"
swiftc -sdk "$sdk" -swift-version 5 -O -whole-module-optimization -target "$target" -module-cache-path "${TMPDIR:-/tmp}/feynman-swift-modules" Sources/*.swift -o "$app/Contents/MacOS/Feynman"
codesign --force --sign - "$app/Contents/MacOS/FeynmanTTY"
cp Info.plist "$app/Contents/"
ditto Resources "$app/Contents/Resources"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p build
ditto "$app" build/Feynman.app
# macOS uses the bundle's modification date when refreshing its cached Dock icon.
touch build/Feynman.app
# Publish the archive from the same signed bundle as the local app.
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/Feynman-macOS.zip"
mv -f "$work/Feynman-macOS.zip" build/Feynman-macOS.zip
