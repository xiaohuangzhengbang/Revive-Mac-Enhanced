#!/usr/bin/env python3
"""Draw the Revive app icon: a metallic steel-blue rounded-square tile with the
"Revive" wordmark in Great Vibes script (the brand logo). Renders a 1024px
master, downsamples to every size macOS wants, and builds Revive.icns.

The font is Great Vibes (SIL Open Font License), bundled in Support/fonts/ — so
the icon builds on any machine and carries no commercial-font licensing risk.

Run: python3 Support/make_icon.py
"""
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_PATH = os.path.join(HERE, "fonts", "GreatVibes-Regular.ttf")
FONT_INDEX = 0

ICONSET = os.path.join(HERE, "icon", "Revive.iconset")
ICNS = os.path.join(HERE, "icon", "Revive.icns")

# metallic steel-blue brand ramp
BG_TOP = (124, 168, 206)    # #7CA8CE
BG_BOT = (63, 110, 153)     # #3F6E99
RING = (255, 255, 255)
INNER = (255, 255, 255)

S = 1024
SUPER = 2  # supersample for smooth edges


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def vertical_gradient(size, top, bot):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        grad.putpixel((0, y), tuple(round(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return grad.resize((size, size))


def draw_master():
    size = S * SUPER
    # Apple icon grid: rounded rect occupies ~80% with squircle-ish radius
    tile = int(size * 0.815)
    radius = int(tile * 0.235)
    off = (size - tile) // 2

    base = vertical_gradient(tile, BG_TOP, BG_BOT)
    base.putalpha(rounded_mask(tile, radius))

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(base, (off, off))

    d = ImageDraw.Draw(canvas)

    # "Revive" wordmark in Great Vibes, scaled to fill ~76% of the tile width
    target_w = tile * 0.76
    probe = ImageFont.truetype(FONT_PATH, tile, index=FONT_INDEX)
    pb = d.textbbox((0, 0), "Revive", font=probe)
    scale = target_w / (pb[2] - pb[0])
    font = ImageFont.truetype(FONT_PATH, max(1, int(tile * scale)), index=FONT_INDEX)
    bb = d.textbbox((0, 0), "Revive", font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    x = (size - tw) / 2 - bb[0]
    y = (size - th) / 2 - bb[1]
    d.text((x, y), "Revive", font=font, fill=RING)

    return canvas.resize((S, S), Image.LANCZOS)


def main():
    os.makedirs(ICONSET, exist_ok=True)
    master = draw_master()
    master.save(os.path.join(HERE, "icon", "icon_1024.png"))

    specs = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for px, name in specs:
        master.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))

    try:
        subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)
        shutil.rmtree(ICONSET, ignore_errors=True)  # temp dir; icns is the artifact
        print("wrote", ICNS)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print("iconutil failed:", e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
