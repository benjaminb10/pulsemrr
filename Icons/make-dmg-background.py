#!/usr/bin/env python3
"""Draws the DMG window background: Icons/dmg-background.png (640x400) and @2x, merged into a .tiff by build.sh.

The app icon sits at (170, 190) and Applications at (470, 190): the arrow runs between them, drawn as a pulse line
like the one in the app icon. Needs Pillow.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

W, H = 640, 400
PURPLE = (89, 79, 224)
MINT = (106, 208, 157)
HERE = Path(__file__).parent


def font(size):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def draw(scale):
    s = lambda v: round(v * scale)
    img = Image.new("RGB", (s(W), s(H)))
    top, bottom = (251, 251, 253), (241, 240, 250)
    px = ImageDraw.Draw(img)
    for y in range(s(H)):
        t = y / (s(H) - 1)
        px.line([(0, y), (s(W), y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

    # Pulse line from the app to Applications, ending in an arrowhead
    y = 190
    pts = [(256, y), (292, y), (302, y - 14), (314, y + 12), (326, y - 22), (338, y), (380, y)]
    px.line([(s(a), s(b)) for a, b in pts], fill=PURPLE, width=s(3), joint="curve")
    px.polygon([(s(392), s(y)), (s(379), s(y - 7)), (s(379), s(y + 7))], fill=PURPLE)
    r = 4.5
    px.ellipse([s(326 - r), s(y - 22 - r), s(326 + r), s(y - 22 + r)], fill=MINT)

    text = "Drag PulseMRR to Applications"
    f = font(s(14))
    w = px.textlength(text, font=f)
    px.text(((s(W) - w) / 2, s(318)), text, font=f, fill=(128, 128, 148))
    return img


draw(1).save(HERE / "dmg-background.png")
draw(2).save(HERE / "dmg-background@2x.png")
print("Icons/dmg-background.png and @2x")
