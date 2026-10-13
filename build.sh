#!/bin/bash
# Builds "Light-mulator.app" into build/. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Light-mulator.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ! -f Resources/AppIcon.icns ]; then
    ICONSET=build/AppIcon.iconset
    mkdir -p "$ICONSET"
    xcrun swift Resources/make_icon.swift build/icon.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
    Sources/*.swift -o "$APP/Contents/MacOS/Light-mulator"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

if [ "${1:-}" = "--install" ]; then
    rm -rf "$HOME/Applications/Light-mulator.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/Light-mulator.app"
fi
echo "Built $APP"
