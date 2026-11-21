#!/bin/sh
# Build KeyBar.app into ./build and (with --install) copy it to ~/Applications.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
APP=build/KeyBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f .build/release/KeyBar "$APP/Contents/MacOS/KeyBar"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
IDENTITY="KeyBar Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier com.aryan.keybar "$APP"
else
    echo "note: run scripts/make-signing-cert.sh once so Input Monitoring survives rebuilds"
    codesign --force --sign - --identifier com.aryan.keybar "$APP"
fi
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    pkill -x KeyBar 2>/dev/null || true
    rm -rf "$HOME/Applications/KeyBar.app"
    cp -R "$APP" "$HOME/Applications/KeyBar.app"
    open "$HOME/Applications/KeyBar.app"
    echo "installed ~/Applications/KeyBar.app"
fi
