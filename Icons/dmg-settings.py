# Layout of the PulseMRR disk image, written straight into the image by dmgbuild (no Finder involved),
# so the window opens laid out from the first frame. Used by make-dmg.sh.
import os.path

app = defines.get("app", "build/PulseMRR.app")  # noqa: F821 (defines comes from dmgbuild)
here = os.path.abspath("Icons")  # dmgbuild runs from the repo root (make-dmg.sh)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(here, "PulseMRR.icns")
badge_icon = None

# dmgbuild picks up dmg-background@2x.png next to it for Retina screens
background = os.path.join(here, "dmg-background.png")
# From the bottom left of the screen, as Finder counts
window_rect = ((200, 520), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    "PulseMRR.app": (170, 190),
    "Applications": (470, 190),
}
