#!/bin/sh
# Build KeyBar.app into ./build.
#   --install   also copy it to ~/Applications and open it
#   --release   build for Apple silicon and Intel, and package build/KeyBar.dmg
set -eu
cd "$(dirname "$0")/.."

MODE="${1:-}"
APP=build/KeyBar.app

if [ "$MODE" = "--release" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY=.build/out/Products/Release/KeyBar
else
    swift build -c release
    BINARY=.build/release/KeyBar
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BINARY" "$APP/Contents/MacOS/KeyBar"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="KeyBar Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier com.aryan.keybar "$APP"
else
    echo "note: run scripts/make-signing-cert.sh once so Input Monitoring survives rebuilds"
    codesign --force --sign - --identifier com.aryan.keybar "$APP"
fi
echo "built $APP"

if [ "$MODE" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    pkill -x KeyBar 2>/dev/null || true
    rm -rf "$HOME/Applications/KeyBar.app"
    cp -R "$APP" "$HOME/Applications/KeyBar.app"
    open "$HOME/Applications/KeyBar.app"
    echo "installed ~/Applications/KeyBar.app"
fi

if [ "$MODE" = "--release" ]; then
    STAGING=$(mktemp -d)
    trap 'rm -rf "$STAGING"' EXIT
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    rm -f build/KeyBar.dmg
    hdiutil create -volname KeyBar -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov build/KeyBar.dmg >/dev/null
    echo "packaged build/KeyBar.dmg"
fi
