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
# Only grep's status is ignored (it exits 1 when it filters every line). A
# failed build must stop here, or a stale binary would be installed below.
XCRUN_NO_CACHE=1 swift build -c "$CONFIG" 2>&1 | { grep -v "DVTFilePathFSEvents" || true; }

BIN=".build/$CONFIG/MomentumMenu"
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
EXE="$APP/Contents/MacOS/MomentumMenu"
cp "$BIN" "$EXE"

# SwiftPM leaves a release binary unstripped: about 1 MB of symbols and a
# debug map naming this machine's object files. As Xcode does for an app,
# link the debug info into a dSYM for crash reports, then strip. dsymutil
# runs here rather than trusting SwiftPM to, which varies by toolchain.
# Debug builds keep their symbols for the debugger.
DSYM="build/MomentumMenu.dSYM"
rm -rf "$DSYM"
if [ "$CONFIG" = "release" ]; then
    echo "==> Writing the dSYM, stripping the binary"
    # A missing object file is only a warning, and leaves a dSYM with the
    # right UUID but holes in it. A clean run prints nothing.
    dsym_log=$(dsymutil "$BIN" -o "$DSYM" 2>&1)
    if [ -n "$dsym_log" ]; then
        echo "$dsym_log"
        echo "build failed: dsymutil reported problems"
        exit 1
    fi
    strip "$EXE"

    # A dSYM symbolicates only the build whose UUID it carries.
    exe_uuid=$(dwarfdump --uuid "$EXE" | awk '{ print $2 }')
    dsym_uuid=$(dwarfdump --uuid "$DSYM" | awk '{ print $2 }')
    if [ -z "$exe_uuid" ] || [ "$exe_uuid" != "$dsym_uuid" ]; then
        echo "build failed: dSYM UUID '$dsym_uuid' does not match binary '$exe_uuid'"
        exit 1
    fi
    # Captured first: piped into `grep -q`, nm dies of SIGPIPE on a match and
    # pipefail turns that match into a pass.
    symbols=$(nm -a "$EXE")
    if grep -qE ' OSO | t ' <<<"$symbols"; then
        echo "build failed: $EXE still has local symbols or a debug map"
        exit 1
    fi
fi

# Starfield is the bundled icon. The others are for Settings > App Icon, which
# sets them at runtime. Resources/AppIcon/render.sh draws all three.
cp Resources/AppIcon/Starfield.icns "$APP/Contents/Resources/AppIcon.icns"
for alternate in Sleepy Ghost; do
    cp "Resources/AppIcon/$alternate.icns" "$APP/Contents/Resources/AppIcon-$alternate.icns"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                     <string>MomentumMenu</string>
    <key>CFBundleDisplayName</key>              <string>Momentum Menu</string>
    <key>CFBundleIdentifier</key>               <string>com.agrmohit.momentummenu</string>
    <key>CFBundleVersion</key>                  <string>2.3.0</string>
    <key>CFBundleShortVersionString</key>       <string>2.3.0</string>
    <key>CFBundleExecutable</key>               <string>MomentumMenu</string>
    <key>CFBundlePackageType</key>              <string>APPL</string>
    <key>CFBundleIconFile</key>                 <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>           <string>26.0</string>

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
    # Exact process name: -f would also kill anything with the repo path in its
    # command line, such as an editor.
    pkill -x "MomentumMenu" 2>/dev/null || true
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
