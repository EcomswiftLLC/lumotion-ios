"""Builds the Lumotion website image assets into website/lumotion/assets/.

The mark geometry comes from tools/make_icon.py (a still frame inside a twisted ribbon of light), so the site, the
app icon and the favicon are one drawing.

Writes: favicon.svg, lumotion-mark.svg, favicon-32.png, apple-touch-icon.png, icon-512.png, og-image.png and
photos/<name>.jpg (small copies of the bundled sample photos for the landing page).
Usage: python website/make_site_assets.py     (needs Pillow and numpy; run tools/make_icon.py first)
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import make_icon  # noqa: E402

OUT = ROOT / "website" / "lumotion" / "assets"
ICON = ROOT / "Sources" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
SAMPLES = ROOT / "Sources" / "Resources" / "Samples"
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "photos").mkdir(exist_ok=True)

SITE_PHOTOS = ["waterfall", "ocean-waves", "city-rain-night", "portrait-hair", "sunset-lake", "snowy-trees"]


def frame_svg(size=100):
    """The still: rounded frame, low sun and ridge, in SVG, sized for a 100 unit mark."""
    cx = cy = size / 2
    fw, fh, rad = size * 0.255, size * 0.285, size * 0.060
    x0, y0 = cx - fw / 2, cy - fh / 2
    sun = (cx + fw * 0.12, cy + fh * 0.02, fw * 0.105)
    ridge = f"M{x0:.2f} {cy + fh * 0.5:.2f}"
    import math
    for i in range(0, 101, 4):
        x = x0 + fw * i / 100
        y = cy + fh * (0.20 + 0.07 * math.sin(i / 100 * math.pi * 1.3 + 0.4) - 0.10 * math.exp(-((i - 22) / 18) ** 2))
        ridge += f" L{x:.2f} {y:.2f}"
    ridge += f" L{x0 + fw:.2f} {cy + fh * 0.5:.2f} Z"
    clip = f'<clipPath id="lmFrame"><rect x="{x0:.2f}" y="{y0:.2f}" width="{fw:.2f}" height="{fh:.2f}" rx="{rad:.2f}"/></clipPath>'
    grad = (f'<linearGradient id="lmSky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#181B2C"/>'
            f'<stop offset="1" stop-color="#5C3E36"/></linearGradient>'
            f'<radialGradient id="lmSun" cx="{(sun[0] - x0) / fw:.3f}" cy="{(sun[1] - y0) / fh:.3f}" r=".55">'
            f'<stop offset="0" stop-color="#F2C48D" stop-opacity=".9"/><stop offset="1" stop-color="#F2C48D" stop-opacity="0"/></radialGradient>')
    body = (f'<g clip-path="url(#lmFrame)"><rect x="{x0:.2f}" y="{y0:.2f}" width="{fw:.2f}" height="{fh:.2f}" fill="url(#lmSky)"/>'
            f'<rect x="{x0:.2f}" y="{y0:.2f}" width="{fw:.2f}" height="{fh:.2f}" fill="url(#lmSun)"/>'
            f'<circle cx="{sun[0]:.2f}" cy="{sun[1]:.2f}" r="{sun[2]:.2f}" fill="#FFE2B8"/>'
            f'<path d="{ridge}" fill="#0E101A"/></g>'
            f'<rect x="{x0 + 0.3:.2f}" y="{y0 + 0.3:.2f}" width="{fw - 0.6:.2f}" height="{fh - 0.6:.2f}" rx="{rad:.2f}" fill="none" stroke="#F2C48D" stroke-width="{size * 0.0062:.2f}"/>')
    return clip, grad, body


def mark_svg(bg, size=100, strands=15, label="Lumotion", uid=""):
    paths = make_icon.ribbon_svg_paths(size, strands)
    stroke = size * 0.0042
    ribbon = "".join(f'<path d="{d}" stroke="{c}" stroke-opacity="{a}"/>' for d, c, a in paths)
    clip, grad, body = frame_svg(size)
    bgrect = (f'<rect width="{size}" height="{size}" rx="{size * 0.224:.1f}" fill="#0A0C13"/>') if bg else ""
    title = f'role="img" aria-label="{label}"><title>{label}</title>' if label else 'aria-hidden="true">'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" {title}'
            f'<defs>{clip}{grad}</defs>{bgrect}'
            f'<g fill="none" stroke-width="{stroke:.2f}" stroke-linecap="round" stroke-linejoin="round">{ribbon}</g>{body}</svg>\n')


def fonts(size, serif=True, bold=False):
    names = (["georgiab.ttf"] if bold else ["georgia.ttf"]) if serif else ["segoeui.ttf"]
    for n in names:
        p = Path("C:/Windows/Fonts") / n
        if p.exists():
            return ImageFont.truetype(str(p), size)
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf" if serif else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if Path(p).exists():
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def rounded_icon(px):
    icon = Image.open(ICON).convert("RGB").resize((px, px), Image.LANCZOS)
    mask = Image.new("L", (px * 4, px * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, px * 4 - 1, px * 4 - 1], radius=int(px * 4 * 0.2237), fill=255)
    mask = mask.resize((px, px), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.paste(icon, (0, 0), mask)
    return out


def og_image():
    W, H = 1200, 630
    img = Image.new("RGB", (W, H), (10, 12, 19))
    # projector glow from the upper right, behind the icon
    glow = Image.new("RGB", (W, H), (242, 196, 141))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse([W * 0.45, -H * 0.35, W * 1.15, H * 0.95], fill=58)
    mask = mask.filter(ImageFilter.GaussianBlur(120))
    img = Image.composite(glow, img, mask)
    d = ImageDraw.Draw(img)
    d.rectangle([80, 96, 80 + 64, 99], fill=(242, 196, 141))
    d.text((80, 128), "Photo Animator", font=fonts(64), fill=(237, 234, 227))
    d.text((80, 204), "& Cinemagraph", font=fonts(64), fill=(237, 234, 227))
    d.text((80, 300), "Lumotion", font=fonts(84), fill=(242, 196, 141))
    d.text((80, 430), "Turn one photo into a seamless loop.", font=fonts(34, False), fill=(163, 165, 171))
    d.text((80, 478), "Free for iPhone and iPad. Made on your device.", font=fonts(34, False), fill=(163, 165, 171))
    ic = rounded_icon(360)
    img.paste(ic, (W - 360 - 96, (H - 360) // 2), ic)
    d.rectangle([0, H - 10, W, H], fill=(242, 196, 141))
    img.save(OUT / "og-image.png", optimize=True)


def main():
    (OUT / "favicon.svg").write_text(mark_svg(True, strands=9, label="Lumotion"), encoding="utf-8")
    (OUT / "lumotion-mark.svg").write_text(mark_svg(False, strands=13, label=""), encoding="utf-8")
    icon = Image.open(ICON).convert("RGB")
    icon.resize((180, 180), Image.LANCZOS).save(OUT / "apple-touch-icon.png", optimize=True)
    rounded_icon(512).save(OUT / "icon-512.png", optimize=True)
    rounded_icon(32).save(OUT / "favicon-32.png", optimize=True)
    og_image()
    for n in SITE_PHOTOS:
        im = Image.open(SAMPLES / f"{n}.jpg").convert("RGB")
        im.thumbnail((1000, 1000), Image.LANCZOS)
        im.save(OUT / "photos" / f"{n}.jpg", quality=80, optimize=True, progressive=True)
    print("assets written to", OUT)


if __name__ == "__main__":
    main()
