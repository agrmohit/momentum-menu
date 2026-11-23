# /// script
# requires-python = ">=3.12"
# dependencies = ["ds_store==1.3.3", "mac_alias==2.2.3"]
# ///
"""Writes the DMG window's .DS_Store from layout.json, byte-identical on every run.

render.sh runs it with `uv run --script`. The background alias names the
volume and path only, with no file IDs or dates, so it does not depend on the
disk it was made on. Finder on macOS 27 resolves it.
"""

import datetime
import json
import pathlib
import sys

from ds_store import DSStore
from mac_alias import ALIAS_FIXED_DISK, ALIAS_KIND_FILE, Alias, TargetInfo, VolumeInfo

LAYOUT = json.loads((pathlib.Path(__file__).parent / "layout.json").read_text())
# pack-dmg.sh puts the background here.
BACKGROUND_FOLDER, BACKGROUND_FILE = ".background", "background.tiff"
# Finder's stored frame includes the title bar, about 32 pt.
TITLE_BAR = 32
# Any fixed date: Finder does not match the alias on it.
EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.UTC)


def background_alias(volume: str) -> bytes:
    """An alias to the background on the volume named `volume`."""
    alias = Alias()
    alias.volume = VolumeInfo(volume.encode(), EPOCH, b"H+", ALIAS_FIXED_DISK, 0, b"\0\0")
    alias.volume.posix_path = f"/Volumes/{volume}".encode()
    alias.target = TargetInfo(ALIAS_KIND_FILE, BACKGROUND_FILE.encode(), 0, 0, EPOCH, b"\0\0\0\0", b"\0\0\0\0")
    alias.target.folder_name = BACKGROUND_FOLDER.encode()
    alias.target.posix_path = f"/{BACKGROUND_FOLDER}/{BACKGROUND_FILE}".encode()
    alias.target.carbon_path = f"{volume}:{BACKGROUND_FOLDER}:{BACKGROUND_FILE}".encode()
    return alias.to_bytes()


def write(path: str) -> None:
    """Writes the .DS_Store to `path`, replacing any file there."""
    with DSStore.open(path, "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = {
            "WindowBounds": f"{{{{200, 120}}, {{{LAYOUT['width']}, {LAYOUT['height'] + TITLE_BAR}}}}}",
            "ShowStatusBar": False,
            "ShowTabView": False,
            "ShowToolbar": False,
            "ShowPathbar": False,
            "ShowSidebar": False,
            "ContainerShowSidebar": False,
            "PreviewPaneVisibility": False,
            "SidebarWidth": 180,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "arrangeBy": "none",
            "iconSize": 128.0,
            "textSize": 13.0,
            "labelOnBottom": True,
            "showIconPreview": True,
            "showItemInfo": False,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
            "backgroundType": 2,
            "backgroundImageAlias": background_alias(LAYOUT["volume"]),
            # Finder ignores the view options without a colour, even under a picture.
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
        }
        # Icon view, whatever the user's Finder default: vstl is the documented
        # view-style record; icvl is what dmgbuild writes, kept as well.
        store["."]["vstl"] = ("type", b"icnv")
        store["."]["icvl"] = ("type", b"icnv")
        store[LAYOUT["app"]["name"]]["Iloc"] = (LAYOUT["app"]["x"], LAYOUT["app"]["y"])
        store["Applications"]["Iloc"] = (LAYOUT["applications"]["x"], LAYOUT["applications"]["y"])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: make_ds_store.py <out>")
    write(sys.argv[1])
