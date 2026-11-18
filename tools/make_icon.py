"""Draws the Lumotion app icon: a six-blade aperture in glow on a deep neutral background.
Run: python tools/make_icon.py   (writes the three 1024 px PNGs into the asset catalog)."""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageChops

OUT = Path(__file__).resolve().parent.parent / "Sources/Resources/Assets.xcassets/AppIcon.appiconset"
S = 4096          # supersampled canvas
FINAL = 1024


def radial_background(inner, outer):
    img = Image.new("RGB", (S, S), outer)
    px = img.load()
    cx = cy = S / 2
    maxd = math.hypot(cx, cy)
    # draw coarse then blur: radial falloff
    d = ImageDraw.Draw(img)
    steps = 120
    for i in range(steps, 0, -1):
        t = i / steps
        r = t * maxd * 0.95
        col = tuple(int(outer[k] + (inner[k] - outer[k]) * (1 - t) ** 1.6) for k in range(3))
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
    return img.filter(ImageFilter.GaussianBlur(40))


def blade_layer(color_top, color_bottom, width, with_ring=True):
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    cx = cy = S / 2
    R = S * 0.335
    rho = R * 0.30
    beta = math.acos(rho / R)
    if with_ring:
        d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=255, width=width)
    for i in range(6):
        a = i / 6 * 2 * math.pi
        x1, y1 = cx + math.cos(a + beta) * R, cy + math.sin(a + beta) * R
        vr = rho / math.cos(math.pi / 6)
        x2, y2 = cx + math.cos(a - math.pi / 6) * vr, cy + math.sin(a - math.pi / 6) * vr
        d.line([(x1, y1), (x2, y2)], fill=255, width=width)
        for (x, y) in ((x1, y1), (x2, y2)):
            d.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=255)
    # vertical glow gradient
    grad = Image.new("RGB", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(0, S, 8):
        t = y / S
        c = tuple(int(color_top[k] + (color_bottom[k] - color_top[k]) * t) for k in range(3))
        gd.rectangle([0, y, S, y + 8], fill=c)
    return grad, mask


def compose(bg_inner, bg_outer, top, bottom, glow=True):
    img = radial_background(bg_inner, bg_outer)
    grad, mask = blade_layer(top, bottom, width=int(S * 0.0105))
    if glow:
        halo = mask.filter(ImageFilter.GaussianBlur(S * 0.012))
        halo = halo.point(lambda v: int(v * 0.55))
        glow_col = Image.new("RGB", (S, S), top)
        img = Image.composite(glow_col, img, halo)
    img.paste(grad, (0, 0), mask)
    return img.resize((FINAL, FINAL), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    glow_top, glow_bottom = (0xE6, 0xC7, 0x8C), (0xB8, 0x92, 0x52)
    compose((0x1E, 0x20, 0x25), (0x08, 0x09, 0x0B), glow_top, glow_bottom).save(OUT / "AppIcon-1024.png")
    compose((0x14, 0x15, 0x18), (0x04, 0x04, 0x05), glow_top, glow_bottom).save(OUT / "AppIcon-1024-dark.png")
    # Tinted variant: light marks on black, the system colours it.
    compose((0x10, 0x10, 0x10), (0x00, 0x00, 0x00), (0xF0, 0xF0, 0xF0), (0xC8, 0xC8, 0xC8), glow=False).convert("L").convert("RGB").save(
        OUT / "AppIcon-1024-tinted.png"
    )
    print("icons written to", OUT)


if __name__ == "__main__":
    main()
