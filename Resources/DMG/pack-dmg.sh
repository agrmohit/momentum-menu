#!/bin/bash
# Packs an app into the styled DMG: the window layout, background and volume
# icon are the files beside this script, which Resources/AppIcon/render.sh
# writes from layout.json. Ends by checking the DMG holds exactly those, so a
# release never ships a plain one.
#
# Usage: pack-dmg.sh <MomentumMenu.app> <out.dmg>
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: pack-dmg.sh <MomentumMenu.app> <out.dmg>"; exit 2; }
APP=$1
OUT=$2
HERE="$(cd "$(dirname "$0")" && pwd)"
layout() { plutil -extract "$1" raw -o - "$HERE/layout.json"; }
# The background alias in DS_Store finds the picture by this volume name, and
# DS_Store places the app by this file name.
VOLUME=$(layout volume)
[ "$(basename "$APP")" = "$(layout app.name)" ] || { echo "the app must be named $(layout app.name)"; exit 1; }

# The mount point sits outside WORK, so cleanup never deletes into a mounted
# volume. Spotlight can hold a fresh mount busy for a moment: retry first.
# pwd -P: mount lists /var/folders under its real /private path.
WORK="$(mktemp -d)"
MOUNT="$(cd "$(mktemp -d)" && pwd -P)"
detach() {
    mount | grep -qF " on $MOUNT " || return 0
    for _ in 1 2 3 4 5; do
        hdiutil detach -quiet "$MOUNT" && return 0
        sleep 1
    done
    hdiutil detach -quiet -force "$MOUNT"
}
trap 'detach || true; rm -rf "$WORK"; rmdir "$MOUNT"' EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$HERE/background.tiff" "$STAGE/.background/background.tiff"
cp "$HERE/Volume.icns" "$STAGE/.VolumeIcon.icns"
cp "$HERE/DS_Store" "$STAGE/.DS_Store"

# The custom-icon flag belongs on the volume's own root, which hdiutil
# creates: a flag set on the source folder is lost. So build read-write, flag
# the mounted root, then compress to ULMO (LZMA; macOS 14 and later mount it).
# HFS+ is what the background alias declares.
hdiutil create -quiet -fs HFS+ -volname "$VOLUME" -srcfolder "$STAGE" -format UDRW "$WORK/rw.dmg"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$WORK/rw.dmg"
SetFile -a C "$MOUNT"
detach
hdiutil convert -quiet "$WORK/rw.dmg" -format ULMO -ov -o "$OUT"

hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$OUT"
cmp "$HERE/DS_Store" "$MOUNT/.DS_Store"
cmp "$HERE/background.tiff" "$MOUNT/.background/background.tiff"
cmp "$HERE/Volume.icns" "$MOUNT/.VolumeIcon.icns"
[[ "$(GetFileInfo -a "$MOUNT")" == *C* ]] || { echo "the volume's custom-icon flag is not set"; exit 1; }
[ "$(diskutil info "$MOUNT" | awk -F': +' '/Volume Name/ { print $2 }')" = "$VOLUME" ] ||
    { echo "the volume is not named $VOLUME"; exit 1; }
[ "$(readlink "$MOUNT/Applications")" = /Applications ] || { echo "no Applications link in the DMG"; exit 1; }
EXPECTED=$(printf '%s\n' .DS_Store .VolumeIcon.icns .background Applications "$(basename "$APP")" | sort)
FOUND=$(find "$MOUNT" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
[ "$FOUND" = "$EXPECTED" ] || { printf 'the DMG root holds:\n%s\n' "$FOUND"; exit 1; }
