#!/usr/bin/env python3
"""Draws Koffer's app icon (monochrome graphite, outlined suitcase) to Resources/AppIcon.png.
Run only when the design changes; the PNG is committed so builds need no drawing tools."""
import sys
from PIL import Image, ImageDraw

S = 4                      # supersampling
N = 1024 * S
img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

def rr(box, r, **kw):
    d.rounded_rectangle([c * S for c in box], radius=r * S, **kw)

# macOS icon grid: 824 pt tile centred on a 1024 canvas, corner radius ~185.
rr((100, 100, 924, 924), 185, fill=(28, 28, 30, 255))
# hairline inner edge so the tile holds its shape on dark backgrounds
rr((100, 100, 924, 924), 185, outline=(255, 255, 255, 26), width=2 * S)

W = (245, 245, 247, 255)   # off-white ink
T = 30                     # stroke weight
# handle
rr((422, 330, 602, 470), 34, outline=W, width=T * S)
# body (drawn after the handle so it covers the handle's lower half)
rr((282, 408, 742, 720), 62, fill=(28, 28, 30, 255))
rr((282, 408, 742, 720), 62, outline=W, width=T * S)
# two straps
for x in (392, 632 - T):
    d.rectangle([x * S, 408 * S, (x + T) * S, 720 * S], fill=W)

out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png"
img.resize((1024, 1024), Image.LANCZOS).save(out)
print("wrote", out)
