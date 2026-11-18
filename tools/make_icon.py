"""Draws the Lumotion app icon: a still frame held inside a twisted ribbon of light that closes into a loop.

The mark: a hairline photo frame (the still) sits in the middle of a ribbon made of fine glowing strands. The ribbon
twists once around the ring (width ~ cos t, so it pinches to a thread at the top and bottom), which is the
"one photo becoming an endless loop" idea and stays readable as a luminous ring when the icon is tiny.

Run: python tools/make_icon.py
Writes AppIcon-1024.png, AppIcon-1024-dark.png and AppIcon-1024-tinted.png into the asset catalog, plus
design/icon/preview.png (a contact sheet at several sizes) and website/lumotion/assets/lumotion-mark.svg geometry
helper data is shared with website/make_site_assets.py through ribbon_svg_paths().
Needs Pillow and numpy.
"""
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/Resources/Assets.xcassets/AppIcon.appiconset"
PREVIEW = ROOT / "design/icon"

S = 4096            # supersampled canvas
FINAL = 1024

INK = (10, 12, 19)          # #0A0C13
INK_DEEP = (6, 7, 12)
NAVY_LIFT = (27, 31, 52)
GLOW = (242, 196, 141)      # #F2C48D champagne apricot
GLOW_DEEP = (201, 143, 91)
VIOLET = (126, 132, 232)    # restrained violet-blue secondary

STRANDS = 29
RING_R = 0.318              # fraction of S
RIBBON_W = 0.066            # half width of the ribbon at its widest, fraction of S
TILT = math.radians(-24)    # the pinch axis is rotated so the mark does not sit square


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def mix3(t, face=1.0):
    """Colour of the ribbon: the face turned to the viewer is champagne apricot, the turned-away face shifts to
    violet-blue, and the colour changes smoothly through the pinch, so the loop has no seam."""
    u = (1 - face) / 2            # 0 front, 1 back
    u = u * u * (3 - 2 * u)
    return lerp(GLOW, VIOLET, u * 0.9)


def background(variant):
    if variant == "dark":
        inner, outer = (17, 19, 31), INK_DEEP
    elif variant == "tinted":
        return Image.new("RGB", (S, S), (0, 0, 0))
    else:
        inner, outer = NAVY_LIFT, INK
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    # lit from upper centre, like the throw of a projector
    cx, cy = S * 0.5, S * 0.40
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (S * 0.78)
    k = np.clip(1 - d, 0, 1) ** 1.7
    arr = np.zeros((S, S, 3), np.float32)
    for c in range(3):
        arr[..., c] = outer[c] + (inner[c] - outer[c]) * k
    # faint warm bloom at the base, the light spilling out of the frame
    d2 = np.sqrt((xx - S * 0.5) ** 2 + (yy - S * 1.02) ** 2) / (S * 0.62)
    k2 = np.clip(1 - d2, 0, 1) ** 2.2 * 0.16
    for c in range(3):
        arr[..., c] += (GLOW_DEEP[c] - arr[..., c]) * k2
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


def strand_points(offset, n=900):
    """Return (xs, ys, facing, tt) for one strand. offset in [-1, 1] across the ribbon."""
    t = np.linspace(0, 2 * math.pi, n, endpoint=True)
    width = RIBBON_W * S * np.cos(t)            # signed: negative means the ribbon shows its back
    r = RING_R * S + offset * width
    # a slight breathing so the strands fan like fibres rather than a rigid band
    r = r + np.sin(t * 2 + offset * 2.1) * S * 0.0035 * (1 - abs(offset) * 0.4)
    ang = t + TILT
    xs = S / 2 + np.cos(ang) * r
    ys = S / 2 + np.sin(ang) * r
    return xs, ys, np.cos(t), t / (2 * math.pi)


def ribbon_layers(width_px, mono=False):
    """Draw the ribbon into an RGBA-ish pair of L masks: returns an RGB image and an L alpha for the strands."""
    layer = Image.new("RGB", (S, S), (0, 0, 0))
    alpha = Image.new("L", (S, S), 0)
    dc, da = ImageDraw.Draw(layer), ImageDraw.Draw(alpha)
    for back in (True, False):                      # back faces first, then the front faces on top
        for j in range(STRANDS):
            o = -1 + 2 * j / (STRANDS - 1)
            xs, ys, face, tt = strand_points(o)
            for i in range(len(xs) - 1):
                f = face[i]
                if (f < 0) != back:
                    continue
                edge = 1 - abs(o)                    # strands at the ribbon edge are brighter: it reads as a bevel
                a = 0.30 + 0.70 * abs(f) ** 0.7 if not back else 0.16 + 0.34 * abs(f) ** 0.7
                a *= 0.62 + 0.38 * (1 - edge ** 2) if not back else 1.0
                if abs(o) > 0.94:
                    a = min(1.0, a * 1.5)
                col = mix3(tt[i], f) if not mono else (255, 255, 255)
                if back:
                    col = lerp(col, (INK[0] + 40, INK[1] + 40, INK[2] + 90), 0.35) if not mono else (150, 150, 150)
                w = int(width_px * (0.85 + 0.35 * abs(f)))
                dc.line([(xs[i], ys[i]), (xs[i + 1], ys[i + 1])], fill=tuple(int(c) for c in col), width=max(w, 2))
                da.line([(xs[i], ys[i]), (xs[i + 1], ys[i + 1])], fill=int(255 * min(a, 1)), width=max(w, 2))
    return layer, alpha


def frame_layers(mono=False):
    """The still: a rounded rectangle with a hairline edge and a soft interior light."""
    fw, fh, rad = S * 0.255, S * 0.285, S * 0.060
    cx = cy = S / 2
    box = [cx - fw / 2, cy - fh / 2, cx + fw / 2, cy + fh / 2]
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, rad, fill=255)
    inner = Image.new("L", (S, S), 0)
    inset = S * 0.012
    ImageDraw.Draw(inner).rounded_rectangle([box[0] + inset, box[1] + inset, box[2] - inset, box[3] - inset], rad - inset, fill=255)
    edge = ImageChops.subtract(mask, inner)
    # interior: a vertical glow gradient, brighter low, like a photo of a horizon at golden hour
    grad = np.zeros((S, S, 3), np.float32)
    yy = np.linspace(0, 1, S, dtype=np.float32)[:, None]
    top, bottom = (24, 27, 44), (92, 62, 54)
    for c in range(3):
        grad[..., c] = top[c] + (bottom[c] - top[c]) * (yy ** 1.5)
    # a low sun
    xx = np.linspace(0, 1, S, dtype=np.float32)[None, :]
    sun = np.exp(-(((xx - 0.5) * 3.2) ** 2 + ((yy - 0.64) * 2.2) ** 2) * 9)
    for c in range(3):
        grad[..., c] += sun * (GLOW[c] - grad[..., c]) * 0.85
    img = Image.fromarray(np.clip(grad, 0, 255).astype(np.uint8), "RGB")
    d0 = ImageDraw.Draw(img)
    sx, sy, sr = cx + fw * 0.12, cy + fh * 0.02, fw * 0.105          # a low sun
    d0.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=(255, 226, 184))
    hill = [(box[0], box[3])]
    for i in range(0, 101):                                           # one soft ridge line, an unmistakable "landscape"
        x = box[0] + fw * i / 100
        y = cy + fh * (0.20 + 0.07 * math.sin(i / 100 * math.pi * 1.3 + 0.4) - 0.10 * math.exp(-((i - 22) / 18) ** 2))
        hill.append((x, y))
    hill.append((box[2], box[3]))
    d0.polygon(hill, fill=(14, 16, 26))
    if mono:
        img = img.convert("L").point(lambda v: int(v * 1.1)).convert("RGB")
    edge_col = Image.new("RGB", (S, S), (255, 255, 255) if mono else GLOW)
    return img, inner, edge, edge_col


def compose(variant):
    mono = variant == "tinted"
    base = background(variant)
    width_px = S * 0.0019

    layer, alpha = ribbon_layers(width_px, mono)
    # bloom: a blurred copy of the ribbon under the crisp one
    bloom = layer.filter(ImageFilter.GaussianBlur(S * 0.012))
    bloom_a = alpha.filter(ImageFilter.GaussianBlur(S * 0.012)).point(lambda v: min(255, int(v * 1.1)))
    bloom_strength = 0.0 if mono else (0.55 if variant == "dark" else 0.7)
    if bloom_strength:
        ba = bloom_a.point(lambda v: int(v * bloom_strength))
        base.paste(bloom, (0, 0), ba)
    wide = layer.filter(ImageFilter.GaussianBlur(S * 0.040))
    wide_a = alpha.filter(ImageFilter.GaussianBlur(S * 0.040)).point(lambda v: int(min(255, v * 1.3) * (0.38 if not mono else 0.0)))
    base.paste(wide, (0, 0), wide_a)

    # the frame sits behind the ribbon's front faces but above its back faces, so the ribbon threads around it
    img, inner, edge, edge_col = frame_layers(mono)
    # soft light spilling from the frame
    halo = Image.new("L", (S, S), 0)
    ImageDraw.Draw(halo).rounded_rectangle([S * 0.36, S * 0.35, S * 0.64, S * 0.65], S * 0.06, fill=255)
    halo = halo.filter(ImageFilter.GaussianBlur(S * 0.05)).point(lambda v: int(v * (0.22 if not mono else 0.0)))
    base.paste(Image.new("RGB", (S, S), GLOW), (0, 0), halo)
    base.paste(img, (0, 0), inner)
    base.paste(edge_col, (0, 0), edge.point(lambda v: int(v * 0.9)))

    base.paste(layer, (0, 0), alpha)
    out = base.resize((FINAL, FINAL), Image.LANCZOS)
    return out


def ribbon_svg_paths(size=100, strands=15, samples=64):
    """Polyline paths (SVG d strings with their colour and opacity) for the website mark. Shares the maths above."""
    paths = []
    k = size / S
    for back in (True, False):
        for j in range(strands):
            o = -1 + 2 * j / (strands - 1)
            xs, ys, face, tt = strand_points(o, samples * 4)
            run, runs = [], []
            for i in range(len(xs)):
                if (face[i] < 0) == back:
                    run.append(i)
                elif run:
                    runs.append(run); run = []
            if run:
                runs.append(run)
            for r in runs:
                if len(r) < 2:
                    continue
                d = "M" + " L".join(f"{xs[i] * k:.2f} {ys[i] * k:.2f}" for i in r[::4] + ([r[-1]] if (len(r) - 1) % 4 else []))
                mid = r[len(r) // 2]
                col = mix3(tt[mid], face[mid])
                a = (0.22 if back else 0.34 + 0.66 * abs(face[mid]) ** 0.7)
                paths.append((d, "#%02x%02x%02x" % tuple(int(c) for c in col), round(a, 2)))
    return paths


def preview(icons):
    PREVIEW.mkdir(parents=True, exist_ok=True)
    sizes = [180, 120, 80, 60, 40, 29]
    W = 1100
    sheet = Image.new("RGB", (W, 620), (22, 24, 30))
    x = 30
    for name, im in icons.items():
        big = im.resize((320, 320), Image.LANCZOS)
        mask = Image.new("L", (320, 320), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, 319, 319], 72, fill=255)
        sheet.paste(big, (x, 30), mask)
        sx = x
        yy = 380
        for s in sizes:
            sm = im.resize((s, s), Image.LANCZOS)
            m = Image.new("L", (s, s), 0)
            ImageDraw.Draw(m).rounded_rectangle([0, 0, s - 1, s - 1], int(s * 0.2237), fill=255)
            if sx + s > x + 330:
                break
            sheet.paste(sm, (sx, yy), m)
            sx += s + 14
        x += 360
    sheet.save(PREVIEW / "preview.png")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    icons = {}
    for variant, fname in (("light", "AppIcon-1024.png"), ("dark", "AppIcon-1024-dark.png"), ("tinted", "AppIcon-1024-tinted.png")):
        im = compose(variant)
        im.save(OUT / fname, optimize=True)
        icons[variant] = im
        print("wrote", OUT / fname)
    preview(icons)


if __name__ == "__main__":
    main()
