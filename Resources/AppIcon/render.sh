#!/bin/bash
# Renders the icons in artwork.js into Starfield.icns, Sleepy.icns and Ghost.icns next to
# this script, and a 512 px PNG of each into docs/app-icons for the README.
# Also writes the DMG's volume icon, background and .DS_Store (as DS_Store,
# which .gitignore would hide) into Resources/DMG. Run it after changing
# artwork.js, layout.json or make_ds_store.py, and commit the output: the
# build only copies these files, so it needs none of the tools below. With the
# same Chrome and macOS, every run is byte-identical.
#
# Needs Google Chrome (headless, to draw the SVG at each exact size), oxipng
# (`brew install oxipng`, to shrink the PNGs losslessly) and uv (to run
# make_ds_store.py with its pinned libraries).
set -euo pipefail

cd "$(dirname "$0")"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
command -v oxipng >/dev/null || { echo "oxipng missing: brew install oxipng"; exit 1; }
command -v uv >/dev/null || { echo "uv missing: brew install uv"; exit 1; }
[ -x "$CHROME" ] || { echo "Google Chrome missing: $CHROME"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# id:shape. The bundled icon is full bleed; icons set at runtime are squircles.
ICONS="Starfield:fullbleed Sleepy:squircle Ghost:squircle"

# iconset file name : pixels : art. Under 64 pt the hand-tuned small art is
# used, so 32 pt @2x (64 px) is still small art.
SLOTS="icon_16x16:16:small icon_16x16@2x:32:small
icon_32x32:32:small icon_32x32@2x:64:small
icon_128x128:128:large icon_128x128@2x:256:large
icon_256x256:256:large icon_256x256@2x:512:large
icon_512x512:512:large icon_512x512@2x:1024:large"

# shoot QUERY SCALE WIDTH HEIGHT OUT screenshots render.html?QUERY into OUT,
# at SCALE pixels per point, and checks its width. Chrome logs harmless
# task-policy errors on macOS, and its exit status is ignored: the checks
# decide success, and say what failed.
shoot() {
    local query=$1 scale=$2 width=$3 height=$4 out=$5
    "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor="$scale" \
        --default-background-color=00000000 --window-size="$width,$height" \
        --screenshot="$out" "file://$PWD/render.html?$query" 2>/dev/null || true
    [ -f "$out" ] || { echo "render failed: Chrome wrote no $out"; exit 1; }
    [ "$(sips -g pixelWidth "$out" | awk '/pixelWidth/ { print $2 }')" = "$((width * scale))" ] ||
        { echo "render failed: $out"; exit 1; }
}

# render ID ART SHAPE PX OUT draws one icon at PX pixels into OUT. ID Volume
# is the DMG's volume icon, which ignores ART and SHAPE.
render() {
    local id=$1 art=$2 shape=$3 px=$4 out=$5
    # A fixed 1024 window, cropped to the icon: see render.html for why.
    shoot "id=$id&art=$art&shape=$shape&px=$px" 1 1024 1024 "$out"
    sips --cropToHeightWidth "$px" "$px" "$out" >/dev/null
}

mkdir "$WORK/docs"
for icon in $ICONS; do
    id="${icon%%:*}"
    shape="${icon##*:}"
    mkdir "$WORK/$id.iconset"
    for slot in $SLOTS; do
        IFS=: read -r name px art <<< "$slot"
        render "$id" "$art" "$shape" "$px" "$WORK/$id.iconset/$name.png"
    done
    # The README shows every icon as a squircle: unlike the Dock, GitHub does
    # not mask the full-bleed one.
    render "$id" large squircle 512 "$WORK/docs/$(echo "$id" | tr '[:upper:]' '[:lower:]').png"
done

# The DMG's volume icon has one art at every size, so each size is drawn once.
mkdir "$WORK/Volume.iconset" "$WORK/volume"
for slot in $SLOTS; do
    IFS=: read -r name px _ <<< "$slot"
    [ -f "$WORK/volume/$px.png" ] || render Volume - - "$px" "$WORK/volume/$px.png"
    cp "$WORK/volume/$px.png" "$WORK/Volume.iconset/$name.png"
done

# The DMG background at 1x and 2x, sized by layout.json. Finder picks the 2x
# image from a TIFF holding both, which it tells apart by DPI.
DMG=../DMG
layout() { plutil -extract "$1" raw -o - "$DMG/layout.json"; }
WIDTH=$(layout width)
HEIGHT=$(layout height)
BACKGROUND="id=Background&width=$WIDTH&height=$HEIGHT&appX=$(layout app.x)&applicationsX=$(layout applications.x)&iconY=$(layout app.y)"
for scale in 1 2; do
    shoot "$BACKGROUND" "$scale" "$WIDTH" "$HEIGHT" "$WORK/background@${scale}x.png"
done
sips -s dpiWidth 144 -s dpiHeight 144 "$WORK/background@2x.png" >/dev/null

oxipng --opt max --strip safe --alpha --quiet "$WORK"/*.iconset/*.png "$WORK"/docs/*.png

# A blank render has the right size but compresses to about 100 bytes; the
# smallest real one, 16 px, is over 400.
for png in "$WORK"/*.iconset/*.png "$WORK"/docs/*.png "$WORK"/background@*.png; do
    [ "$(stat -f %z "$png")" -gt 300 ] || { echo "blank render: $png"; exit 1; }
done

for icon in $ICONS; do
    id="${icon%%:*}"
    swift pack-icns.swift "$WORK/$id.iconset" "$id.icns"
done
DOCS=../../docs/app-icons
mkdir -p "$DOCS"
cp "$WORK"/docs/*.png "$DOCS"/

swift pack-icns.swift "$WORK/Volume.iconset" "$DMG/Volume.icns"
tiffutil -cathidpicheck "$WORK/background@1x.png" "$WORK/background@2x.png" -out "$DMG/background.tiff" >/dev/null
uv run --quiet --script "$DMG/make_ds_store.py" "$DMG/DS_Store"
ls -l ./*.icns "$DOCS"/*.png "$DMG"/Volume.icns "$DMG"/background.tiff "$DMG"/DS_Store
