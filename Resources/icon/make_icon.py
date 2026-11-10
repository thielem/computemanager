# /// script
# dependencies = ["pillow"]
# ///
"""Render AppIcon.iconset (flat graphite square, three-blade fan, amber bolt hub).
Usage: uv run Resources/icon/make_icon.py && iconutil -c icns Resources/icon/AppIcon.iconset -o Resources/AppIcon.icns"""
import math
import pathlib
from PIL import Image, ImageDraw

OUT = pathlib.Path(__file__).parent / "AppIcon.iconset"
OUT.mkdir(exist_ok=True)

def render(n: int) -> Image.Image:
    s = 4  # supersample
    N = n * s
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = N * 0.1
    d.rounded_rectangle([pad, pad, N - pad, N - pad], radius=N * 0.18, fill=(30, 32, 36, 255))
    c = N / 2
    r = N * 0.3
    for k in range(3):
        a0 = math.radians(k * 120 - 90)
        pts = [(c, c)]
        for t in range(0, 61, 4):
            a = a0 + math.radians(t)
            rr = r * (0.35 + 0.65 * math.sin(math.radians(t * 3)) ** 0.5) if t else r * 0.35
            pts.append((c + rr * math.cos(a), c + rr * math.sin(a)))
        d.polygon(pts, fill=(235, 236, 238, 255))
    h = N * 0.075
    d.ellipse([c - h, c - h, c + h, c + h], fill=(255, 176, 32, 255))
    return img.resize((n, n), Image.LANCZOS)

for base in (16, 32, 128, 256, 512):
    render(base).save(OUT / f"icon_{base}x{base}.png")
    render(base * 2).save(OUT / f"icon_{base}x{base}@2x.png")
