#!/bin/bash
# Builds MomentumMenu.app.
#
# macOS will not grant Bluetooth access to a bare executable, however it is
# signed — the usage description has to come from a real bundle's Info.plist.
# So we build the binary with SwiftPM and wrap it by hand.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/MomentumMenu.app"

echo "==> Building ($CONFIG)"
XCRUN_NO_CACHE=1 swift build -c "$CONFIG" 2>&1 | grep -v "DVTFilePathFSEvents" || true

BIN=".build/$CONFIG/MomentumMenu"
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MomentumMenu"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                     <string>MomentumMenu</string>
    <key>CFBundleDisplayName</key>              <string>Momentum Menu</string>
    <key>CFBundleIdentifier</key>               <string>local.momentummenu</string>
    <!-- Must match the GitHub release tag: UpdateChecker compares the tag
         (minus its leading v) against CFBundleShortVersionString. -->
    <key>CFBundleVersion</key>                  <string>1.0.1</string>
    <key>CFBundleShortVersionString</key>       <string>1.0.1</string>
    <key>CFBundleExecutable</key>               <string>MomentumMenu</string>
    <key>CFBundlePackageType</key>              <string>APPL</string>
    <key>LSMinimumSystemVersion</key>           <string>14.0</string>

    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>                      <true/>

    <!-- Without this key macOS kills the process on first Bluetooth call. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Momentum Menu talks to your Sennheiser MOMENTUM 4 headphones to read the battery level and change noise control and equaliser settings.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo
echo "Built $APP"

# `./build.sh release install` puts it in ~/Applications so it can be launched
# by name, and survives this checkout moving around.
if [ "${2:-}" = "install" ]; then
    DEST="$HOME/Applications/MomentumMenu.app"
    echo "==> Installing to $DEST"
    pkill -f "MomentumMenu" 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"

    # Leave exactly one bundle with this id on disk. Two copies make
    # `open -a MomentumMenu` ambiguous, and Launch Services will happily
    # pick the stale one out of a build directory.
    rm -rf "$APP"
    echo
    echo "Installed. Launch it with:"
    echo "  open -a MomentumMenu"
    echo
    echo "macOS may ask for Bluetooth permission again: the app is ad-hoc"
    echo "signed, so a new location reads as a new identity to TCC."
    exit 0
fi

echo
echo "Read-only check (sends no writes). Launch via 'open' so that macOS"
echo "attributes the Bluetooth request to the app and not to your shell:"
echo "  open -W --stdout /dev/stdout $APP --args --probe --diagnose"
echo
echo "Run the menu bar app:"
echo "  open $APP"
echo
echo "Install to ~/Applications so it launches by name:"
echo "  ./build.sh release install"
