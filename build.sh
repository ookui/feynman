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
for target in arm64 x86_64; do
  clang -isysroot "$sdk" -target "$target-apple-macos14.0" -O2 Helpers/FeynmanTTY.c -o "$work/tty-$target"
  swiftc -sdk "$sdk" -swift-version 5 -O -whole-module-optimization -target "$target-apple-macos14.0" -module-cache-path "${TMPDIR:-/tmp}/feynman-swift-modules" Sources/*.swift -o "$work/Feynman-$target"
done
lipo -create "$work/Feynman-arm64" "$work/Feynman-x86_64" -output "$app/Contents/MacOS/Feynman"
lipo -create "$work/tty-arm64" "$work/tty-x86_64" -output "$app/Contents/MacOS/FeynmanTTY"
codesign --force --sign - "$app/Contents/MacOS/FeynmanTTY"
cp Info.plist "$app/Contents/"
ditto Resources "$app/Contents/Resources"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mkdir -p build
ditto "$app" build/Feynman.app
# macOS uses the bundle's modification date when refreshing its cached Dock icon.
touch build/Feynman.app
