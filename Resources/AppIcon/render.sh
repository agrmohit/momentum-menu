#!/bin/bash
# Renders the icons in artwork.js into G1.icns, Y1c.icns and P3.icns next to
# this script. Run it after changing artwork.js, and commit the .icns files:
# the build only copies them, so it needs neither Chrome nor oxipng.
#
# Needs Google Chrome (headless, to draw the SVG at each exact size) and
# oxipng (`brew install oxipng`, to shrink the PNGs losslessly).
set -euo pipefail

cd "$(dirname "$0")"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
command -v oxipng >/dev/null || { echo "oxipng missing: brew install oxipng"; exit 1; }
[ -x "$CHROME" ] || { echo "Google Chrome missing: $CHROME"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# id:shape. The bundled icon is full bleed; icons set at runtime are squircles.
ICONS="G1:fullbleed Y1c:squircle P3:squircle"

# iconset file name : pixels : art. Under 64 pt the hand-tuned small art is
# used, so 32 pt @2x (64 px) is still small art.
SLOTS="icon_16x16:16:small icon_16x16@2x:32:small
icon_32x32:32:small icon_32x32@2x:64:small
icon_128x128:128:large icon_128x128@2x:256:large
icon_256x256:256:large icon_256x256@2x:512:large
icon_512x512:512:large icon_512x512@2x:1024:large"

for icon in $ICONS; do
    id="${icon%%:*}"
    shape="${icon##*:}"
    set="$WORK/$id.iconset"
    mkdir "$set"
    for slot in $SLOTS; do
        IFS=: read -r name px art <<< "$slot"
        # A fixed 1024 window, cropped to the icon: see render.html for why.
        # Chrome logs harmless task-policy errors on macOS; the checks below
        # decide success.
        "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
            --default-background-color=00000000 --window-size=1024,1024 \
            --screenshot="$set/$name.png" \
            "file://$PWD/render.html?id=$id&art=$art&shape=$shape&px=$px" 2>/dev/null
        sips --cropToHeightWidth "$px" "$px" "$set/$name.png" >/dev/null
        [ "$(sips -g pixelWidth "$set/$name.png" | awk '/pixelWidth/ { print $2 }')" = "$px" ] ||
            { echo "render failed: $set/$name.png"; exit 1; }
    done
done

oxipng --opt max --strip safe --alpha --quiet "$WORK"/*.iconset/*.png

# A blank render has the right size but compresses to about 100 bytes; the
# smallest real one, 16 px, is over 400.
for png in "$WORK"/*.iconset/*.png; do
    [ "$(stat -f %z "$png")" -gt 300 ] || { echo "blank render: $png"; exit 1; }
done

for icon in $ICONS; do
    id="${icon%%:*}"
    swift pack-icns.swift "$WORK/$id.iconset" "$id.icns"
done
ls -l ./*.icns
