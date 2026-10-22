"""Draws the app icon (1024×1024): a white jigsaw piece with a magnifier on a violet gradient."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out = sys.argv[1]

# Background: diagonal indigo -> violet gradient.
bg = Image.new("RGB", (S, S))
px = bg.load()
a, b = (107, 92, 250), (187, 82, 238)
for y in range(S):
    for x in range(S):
        t = (x + y) / (2 * S)
        px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# Puzzle piece mask (supersampled for smooth edges).
k = 4
M = S * k
mask = Image.new("L", (M, M), 0)
d = ImageDraw.Draw(mask)
side, cx, cy = 520 * k, 470 * k, 540 * k
x0, y0, x1, y1 = cx - side // 2, cy - side // 2, cx + side // 2, cy + side // 2
d.rounded_rectangle((x0, y0, x1, y1), radius=40 * k, fill=255)
r = 92 * k
d.ellipse((cx - r, y0 - 1.55 * r, cx + r, y0 + 0.45 * r), fill=255)          # tab on top
d.ellipse((x1 - 0.45 * r, cy - r, x1 + 1.55 * r, cy + r), fill=255)          # tab on the right
d.ellipse((cx - r, y1 - 0.45 * r, cx + r, y1 + 1.55 * r), fill=0)            # blank at the bottom
d.ellipse((x0 - 1.55 * r, cy - r, x0 + 0.45 * r, cy + r), fill=0)            # blank on the left
mask = mask.resize((S, S), Image.LANCZOS)

# Soft shadow, then the white piece.
shadow = Image.new("RGBA", (S, S), (40, 10, 90, 0))
shadow.putalpha(mask.point(lambda v: v * 0.45).filter(ImageFilter.GaussianBlur(28)))
icon = bg.convert("RGBA")
icon.alpha_composite(shadow, (14, 26))
white = Image.new("RGBA", (S, S), (255, 255, 255, 255))
white.putalpha(mask)
icon.alpha_composite(white)

# Magnifier over the lower right corner of the piece.
m = Image.new("L", (M, M), 0)
md = ImageDraw.Draw(m)
gx, gy, gr, w = 640 * k, 650 * k, 150 * k, 46 * k
md.line((gx + 0.68 * gr, gy + 0.68 * gr, gx + 1.75 * gr, gy + 1.75 * gr), fill=255, width=int(w * 1.35))
md.ellipse((gx - gr, gy - gr, gx + gr, gy + gr), outline=255, width=w)
m = m.resize((S, S), Image.LANCZOS)
lens = Image.new("L", (M, M), 0)
ImageDraw.Draw(lens).ellipse((gx - gr + w, gy - gr + w, gx + gr - w, gy + gr - w), fill=255)
lens = lens.resize((S, S), Image.LANCZOS)
tint = Image.new("RGBA", (S, S), (150, 120, 255, 255))
tint.putalpha(lens.point(lambda v: v * 0.35))
icon.alpha_composite(tint)
dark = Image.new("RGBA", (S, S), (52, 30, 140, 255))
dark.putalpha(m)
icon.alpha_composite(dark)

icon.convert("RGB").save(out)
