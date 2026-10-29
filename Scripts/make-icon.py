#!/usr/bin/env python3
"""Draws Welll's app icon and writes Resources/AppIcon.icns (needs Pillow and NumPy).

Flat and abstract: three bars, the "lll" of Welll, on a deep green tile. Each bar is solid up
to the same level and translucent above it, like the battery in the menu bar, so together
they read as a charge held flat at its limit. Drawn at 2048 px and scaled down.
"""
import io
import math
import pathlib
import struct

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048                       # working size; the icon is 1024 px
ROOT = pathlib.Path(__file__).resolve().parent.parent

TILE = (16, 104, 82, 255)      # deep green
INK = (255, 255, 255, 255)
EMPTY = (255, 255, 255, 84)    # the translucent part of each bar
LEVEL = 0.8                    # the charge limit the bars level off at


def squircle_mask(size, half, center, exponent=5.0):
    """A superellipse close to Apple's continuous-corner icon shape."""
    points = []
    for i in range(2048):
        t = 2 * math.pi * i / 2048
        c, s = math.cos(t), math.sin(t)
        points.append((center[0] + half * math.copysign(abs(c) ** (2 / exponent), c),
                       center[1] + half * math.copysign(abs(s) ** (2 / exponent), s)))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def rounded_mask(size, box, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def paste(base, rgba, mask):
    layer = Image.new("RGBA", base.size, rgba)
    layer.putalpha(ImageChops.multiply(layer.getchannel("A"), mask))
    base.alpha_composite(layer)


def draw():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tile = squircle_mask(S, 824, (S // 2, S // 2))     # 824 of 2048: the 412 pt template

    # The soft shadow every macOS icon sits on, kept faint.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(tile.point(lambda v: int(v * 0.28)))
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -20)).filter(ImageFilter.GaussianBlur(34))
    icon.alpha_composite(shadow)
    paste(icon, TILE, tile)

    bar_width, gap, height = 196, 138, 1000
    left = (S - (3 * bar_width + 2 * gap)) // 2
    top = (S - height) // 2
    level_y = int(top + height * (1 - LEVEL))
    below_level = rounded_mask(S, (0, level_y, S, S), 0)
    for index in range(3):
        x = left + index * (bar_width + gap)
        bar = rounded_mask(S, (x, top, x + bar_width, top + height), bar_width // 2)
        paste(icon, EMPTY, bar)
        paste(icon, INK, ImageChops.multiply(bar, below_level))

    return icon.resize((1024, 1024), Image.LANCZOS)


def icns(master):
    def png(px):
        buffer = io.BytesIO()
        master.resize((px, px), Image.LANCZOS).save(buffer, "PNG")
        return buffer.getvalue()
    entries = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256),
               ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
    chunks = b"".join(kind.encode() + struct.pack(">I", len(data) + 8) + data
                      for kind, data in ((kind, png(px)) for kind, px in entries))
    return b"icns" + struct.pack(">I", len(chunks) + 8) + chunks


if __name__ == "__main__":
    master = draw()
    master.save(ROOT / "Resources" / "AppIcon.png")
    (ROOT / "Resources" / "AppIcon.icns").write_bytes(icns(master))
    print("Wrote Resources/AppIcon.png and Resources/AppIcon.icns")
