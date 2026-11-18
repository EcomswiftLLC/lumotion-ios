"""Builds the static Lumotion site into website/lumotion/.

  python website/build_site.py
  (optional) LUMOTION_SUPPORT_EMAIL=<public support address>   overrides the address read from docs/legal
  (optional) LUMOTION_SITE_OUT=<folder>                         write the pages somewhere else (review builds)

The support address is read from the "Contact:" line of docs/legal/privacy-policy.md unless the environment
variable is set, so it is never hard coded here. It is shown on the pages as selectable text (no mailto link,
which is unreliable in many mail setups and invites scraping).

Writes index.html, privacy/index.html, terms/index.html, support/index.html, sitemap.xml, robots.txt.
The privacy and terms pages are generated from docs/legal/*.md, so edit the Markdown and re-run this script.
The draft notice block in those files (between the DRAFT-NOTICE markers) is stripped from the web pages.
Assets (CSS, images) live in website/lumotion/assets (images come from website/make_site_assets.py).
If website/lumotion/assets/shots/*.jpg exist (real app captures) the home page shows them.
Needs tools/make_icon.py and website/make_site_assets.py for the mark geometry (Pillow, numpy).
"""
import html
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "website"))
import make_icon  # noqa: E402
import make_site_assets  # noqa: E402

SRC_SITE = ROOT / "website" / "lumotion"
OUT = Path(os.environ.get("LUMOTION_SITE_OUT") or SRC_SITE)
LEGAL = ROOT / "docs" / "legal"

BASE = "https://ecomswiftllc.github.io/lumotion/"
UPDATED = "2026-11-18"
SITE_NAME = "Photo Animator & Cinemagraph: Lumotion"


def read_support_email():
    env = os.environ.get("LUMOTION_SUPPORT_EMAIL", "").strip()
    if env:
        return env
    text = (LEGAL / "privacy-policy.md").read_text(encoding="utf-8")
    m = re.search(r"\*\*Contact:\*\*\s*(\S+@\S+)", text)
    if not m:
        sys.exit("No support address: set LUMOTION_SUPPORT_EMAIL or keep the Contact line in docs/legal/privacy-policy.md.")
    return m.group(1).strip()


SUPPORT_EMAIL = read_support_email()


# ----------------------------------------------------------------------------- hero drawing
def hero_svg():
    """The hero mark: the app icon's drawing at large size. The ribbon group turns slowly (CSS) and closes its loop."""
    paths = make_icon.ribbon_svg_paths(100, 25, 70)
    ribbon = "".join(f'<path d="{d}" stroke="{c}" stroke-opacity="{a}"/>' for d, c, a in paths)
    clip, grad, body = make_site_assets.frame_svg(100)
    return (f'<svg viewBox="8 8 84 84" aria-hidden="true" focusable="false"><defs>{clip}{grad}</defs>'
            f'<g class="ribbon" fill="none" stroke-width="0.26" stroke-linecap="round" stroke-linejoin="round">{ribbon}</g>{body}</svg>')


# ----------------------------------------------------------------------------- shell
def head(title, description, path, extra_head="", root=""):
    canonical = BASE + path
    t = html.escape(title)
    d = html.escape(description)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{t}</title>
<meta name="description" content="{d}">
<link rel="canonical" href="{canonical}">
<meta name="theme-color" content="#0A0C13">
<meta name="color-scheme" content="dark">
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="icon" href="{root}assets/favicon-32.png" type="image/png" sizes="32x32">
<link rel="apple-touch-icon" href="{root}assets/apple-touch-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{html.escape(SITE_NAME)}">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{BASE}assets/og-image.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="The Lumotion app icon, a photo frame inside a ribbon of light, next to the name Photo Animator &amp; Cinemagraph: Lumotion">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{t}">
<meta name="twitter:description" content="{d}">
<meta name="twitter:image" content="{BASE}assets/og-image.png">
<link rel="stylesheet" href="{root}assets/site.css">
{extra_head}</head>
<body>
<a class="skip" href="#main">Skip to content</a>
"""


def header(root, current=""):
    def a(href, text, key):
        cur = ' aria-current="page"' if key == current else ""
        return f'<a href="{href}"{cur}>{text}</a>'
    home = root or "./"
    return f"""<header class="site-header">
  <div class="wrap">
    <a class="brand" href="{home}"><img src="{root}assets/lumotion-mark.svg" alt="" width="34" height="34">Lumotion</a>
    <nav class="nav" aria-label="Main">
      {a(home + '#animate', 'Animate', 'a')}
      {a(home + '#export', 'Export', 'e')}
      {a(home + '#private', 'Privacy', 'p')}
      {a(home + '#free', 'Free with ads', 'f')}
      {a(home + '#faq', 'FAQ', 'q')}
      {a(root + 'support/', 'Support', 'support')}
    </nav>
  </div>
</header>
"""


def footer(root):
    home = root or "./"
    return f"""<footer class="site-footer">
  <div class="wrap">
    <div>
      <h2>Photo Animator &amp; Cinemagraph: Lumotion</h2>
      <p>A free photo animator for iPhone and iPad. Your photos and videos are processed on your device. Not on the App Store yet.</p>
    </div>
    <nav aria-label="Footer">
      <h2>Pages</h2>
      <ul>
        <li><a href="{home}">Home</a></li>
        <li><a href="{root}support/">Support</a></li>
        <li><a href="{root}privacy/">Privacy policy</a></li>
        <li><a href="{root}terms/">Terms of use</a></li>
      </ul>
    </nav>
    <div>
      <h2>Ecom Swift LLC</h2>
      <p>30 N Gould St #37906<br>Sheridan, WY 82801<br>United States</p>
      <p class="email">{html.escape(SUPPORT_EMAIL)}</p>
    </div>
    <p class="legalline">&copy; 2026 Ecom Swift LLC. Apple, iPhone, iPad and the App Store are trademarks of Apple Inc. Lumotion is not affiliated with Apple or Google. Sample photos and clips are from Pexels.</p>
  </div>
</footer>
</body>
</html>
"""


# ----------------------------------------------------------------------------- home
EMAIL_TEXT = f'<span class="email">{html.escape(SUPPORT_EMAIL)}</span>'

FAQ = [
    ("Is Lumotion really free?",
     "<p>Yes. There is no subscription, no in-app purchase, no paid version and no watermark. Ads from Google AdMob pay for the app: a banner on the Home screen, and one rewarded video that you choose to watch before you export.</p>"),
    ("Are my photos and videos uploaded anywhere?",
     "<p>No. Animating, previewing and exporting all happen on your device. We never receive your photos, videos or audio, and nothing is sent to an AI service.</p>"),
    ("Do I need an account?",
     "<p>No. There is no sign-in and no sign-up.</p>"),
    ("What is a cinemagraph?",
     "<p>A cinemagraph is a short looping clip in which only part of the picture moves, such as steam rising from a cup in an otherwise still frame. In Lumotion you pick a clip, choose the loop, choose the still frame, and paint the part that keeps moving. The ends of the loop are blended so it repeats without a jump.</p>"),
    ("Does Lumotion use AI?",
     "<p>It does not generate pictures and it does not send your photos anywhere. Motion comes from the areas, arrows and settings that you choose. For depth effects, the app can find the main subject using Apple's Vision technology on your device.</p>"),
    ("Why am I asked to watch an ad?",
     "<p>Before you export, the app offers one short video that you choose to watch. One watched ad covers your exports for 2 minutes, so you can save several versions in a row. If you choose Not now, nothing is exported and you can try again any time. If no ad is available, for example when you are offline, the export goes ahead anyway. Editing never needs an ad.</p>"),
    ("What can I export?",
     "<p>An MP4 video (H.264 or HEVC), a GIF, or a still image. You can save to Photos, share, or open in Files. There is no watermark.</p>"),
    ("Does it need photo library or camera access?",
     "<p>Not to edit. You pick photos and videos with the iOS photo picker, and Lumotion sees only the ones you choose. To save a result, the app asks for add-only permission, which lets it add items and does not let it read your library. The camera is used only if you choose to take a photo to animate.</p>"),
    ("Does it come with music?",
     "<p>No. There is no bundled music. You can add an audio file of your own from the Files app, trim it, set the volume and fade it. You are responsible for having the right to use it.</p>"),
    ("What happens if I do not allow tracking?",
     "<p>The app works the same. The ads you see will be less personalised. You can change the choice any time in iOS Settings under Privacy and Security, then Tracking. Lumotion itself runs no analytics. If you allow tracking, only Google's ad software may use your advertising identifier for ads.</p>"),
    ("Which devices does it run on?",
     "<p>iPhone and iPad with iOS 17 or iPadOS 17 or later, in portrait and landscape.</p>"),
    ("When can I download it?",
     "<p>Lumotion is not on the App Store yet, so there is no download link. This page will link to the App Store listing once the app is available.</p>"),
    ("Who makes Lumotion?",
     "<p>Ecom Swift LLC, a company registered in Wyoming, United States. You can reach us on the <a href=\"support/\">support page</a>.</p>"),
]


def jsonld_app():
    data = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": SITE_NAME,
        "alternateName": "Lumotion",
        "url": BASE,
        "applicationCategory": "MultimediaApplication",
        "operatingSystem": "iOS 17.0 or later",
        "description": "A free photo animator and cinemagraph maker for iPhone and iPad. Paint motion onto a photo, make a cinemagraph from a video, add 3D parallax, overlays and looks, and export an MP4, a GIF or a still. Everything is processed on the device. Supported by ads.",
        "image": BASE + "assets/icon-512.png",
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "publisher": {"@type": "Organization", "name": "Ecom Swift LLC", "url": "https://www.ecomswiftllc.com/",
                      "address": {"@type": "PostalAddress", "streetAddress": "30 N Gould St #37906",
                                  "addressLocality": "Sheridan", "addressRegion": "WY", "postalCode": "82801",
                                  "addressCountry": "US"}},
        "featureList": [
            "Flow brush: paint an area and draw the direction it moves",
            "Cinemagraph from a video clip",
            "3D parallax and depth zoom",
            "Camera motion: zoom, pan, drift, rotate and handheld",
            "20 overlays such as rain, snow, fireflies and sparkles",
            "Magic presets as one-tap starting points",
            "Looks, text and stickers",
            "Export MP4 video, GIF or a still image",
            "Processed on the device, no account",
        ],
    }
    return '<script type="application/ld+json">\n' + json.dumps(data, indent=2) + "\n</script>\n"


def jsonld_faq():
    plain = lambda s: html.unescape(re.sub(r"<[^>]+>", "", s))
    data = {"@context": "https://schema.org", "@type": "FAQPage",
            "mainEntity": [{"@type": "Question", "name": q,
                            "acceptedAnswer": {"@type": "Answer", "text": plain(a)}} for q, a in FAQ]}
    return '<script type="application/ld+json">\n' + json.dumps(data, indent=2) + "\n</script>\n"


REEL = [
    ("waterfall", "Forest Waterfall", "Water falls and the pool flows.", "A tall waterfall in green forest"),
    ("ocean-waves", "Ocean Waves", "Waves and foam roll against the rocks.", "Waves breaking on dark rocks"),
    ("city-rain-night", "Rainy Night", "Rain falls over a glowing street.", "A wet city street at night with red and gold lights"),
    ("portrait-hair", "Windswept Portrait", "Hair drifts while depth moves the scene.", "A woman with long brown hair against a bright sky"),
    ("sunset-lake", "Sunset Lake", "Reflections ripple under a golden sky.", "Trees reflected in a lake at sunset"),
    ("snowy-trees", "Snowy Pines", "Snow falls through a quiet forest.", "Snow-covered pine trees in a field"),
]


def reel_html():
    items = "\n".join(
        f'        <li><figure><img src="assets/photos/{n}.jpg" alt="{html.escape(alt)}" width="1000" loading="lazy" decoding="async">'
        f'<figcaption><strong>{html.escape(t)}</strong><span>{html.escape(c)}</span></figcaption></figure></li>'
        for n, t, c, alt in REEL)
    return f"""  <section class="reel-section" aria-labelledby="h-reel">
    <div class="wrap">
      <div class="reel-head">
        <h2 id="h-reel">Start from a photo you love, or one of ours</h2>
        <p>Lumotion comes with sample photos so you can try it before you pick your own. These are some of them, with the kind of motion each one invites.</p>
      </div>
      <ul class="reel">
{items}
      </ul>
      <p class="small reel-note">Sample photos are by Pexels photographers and are used under the Pexels License. They are stills here; the motion is yours to add in the app.</p>
    </div>
  </section>
"""


def shots_html():
    shots = sorted((SRC_SITE / "assets" / "shots").glob("*.jpg")) if (SRC_SITE / "assets" / "shots").exists() else []
    if not shots:
        return ""
    items = "\n".join(f'        <li><img src="assets/shots/{p.name}" alt="Lumotion on iPhone, screen {i}" width="660" loading="lazy" decoding="async"></li>'
                      for i, p in enumerate(shots, 1))
    return f"""  <section class="reel-section" aria-labelledby="h-shots">
    <div class="wrap">
      <div class="reel-head"><h2 id="h-shots">The app, as it looks today</h2></div>
      <ul class="shots">
{items}
      </ul>
    </div>
  </section>
"""


def build_index():
    title = "Photo Animator & Cinemagraph: Lumotion | Make a still photo move"
    desc = "Free photo animator for iPhone and iPad. Paint motion onto a photo, make a cinemagraph from video, add 3D parallax, overlays and looks, then export an MP4 or GIF. Made on your device, with no account."
    faq_html = "\n".join(
        f'        <details><summary>{html.escape(q)}</summary><div class="answer">{a}</div></details>' for q, a in FAQ)
    overlays = ("Rain, heavy rain, snow, blizzard, falling leaves, petals, fireflies, sparkles, bokeh, dust, embers, "
                "smoke and fog, lens flare, light leaks, twinkling stars, confetti, hearts, bubbles, shooting stars and fireworks.")

    body = head(title, desc, "", jsonld_app() + jsonld_faq(), root="") + header("", "") + f"""
<main id="main">
  <section class="hero" aria-labelledby="h1">
    <div class="wrap">
      <div>
        <h1 id="h1">Make a still photo move.</h1>
        <p class="lede">Lumotion turns one photo into a seamless loop, and one short video into a cinemagraph. Paint where the motion goes. It is free, there is no account, and everything is made on your device.</p>
        <p class="status">Not on the App Store yet</p>
        <p class="small hero-note">There is no download link yet. Questions are welcome on the <a href="support/">support page</a>.</p>
      </div>
      <div class="lens">
        {hero_svg()}
      </div>
    </div>
  </section>

{reel_html()}
{shots_html()}
  <section class="section" id="animate" aria-labelledby="h-animate">
    <div class="wrap">
      <h2 id="h-animate">Motion that you direct</h2>
      <div class="section-body">
        <dl class="defs">
          <div><dt>Flow brush</dt><dd>Paint the water, the smoke or the hair, then draw arrows to say which way it moves. Set the speed and the strength. Add as many regions as you like, each with its own settings. The loop is seamless.</dd></div>
          <div><dt>Anchor brush</dt><dd>Pin the parts that must stay still, so a river can run past a bridge that does not budge.</dd></div>
          <div><dt>Cinemagraph from video</dt><dd>Choose a clip, choose a loop of up to six seconds, choose the still frame, and paint the part that keeps moving. The loop is smoothed at the ends, or plays back and forth.</dd></div>
          <div><dt>3D parallax and depth zoom</dt><dd>Separate a subject from its background and move the camera between them. Depth can come from the subject Lumotion finds on your device, from depth saved in a portrait photo, or from a brush you paint yourself. Revealed edges are filled so there are no holes.</dd></div>
          <div><dt>Camera motion</dt><dd>Zoom in or out, pan, drift, rotate, add a handheld shake, or let the frame breathe, with easing you can choose.</dd></div>
          <div><dt>Living effects for the whole photo</dt><dd>Water ripple, waves, wind sway, heat haze, shimmer, pulse, light sweep, glitch and more, over the whole picture or just the part you choose.</dd></div>
          <div><dt>Overlays</dt><dd>{overlays} Stack several, and set the intensity, speed, size and tint of each.</dd></div>
          <div><dt>Looks, text and stickers</dt><dd>Filters, adjustment dials and animated film grain, plus text and emoji stickers with entrance and exit animations.</dd></div>
          <div><dt>Magic presets</dt><dd>One tap sets up a starting point such as Waterfall, Clouds drift, Rainy window or Parallax portrait. They are starting points, so you can change everything afterwards.</dd></div>
          <div><dt>Undo and redo, for everything</dt><dd>Compare with the original, step back through your edits, and reorder or remove layers. Your project is saved as you go.</dd></div>
        </dl>
      </div>
    </div>
  </section>

  <section class="section band" id="export" aria-labelledby="h-export">
    <div class="wrap">
      <h2 id="h-export">Ready for wherever it is going</h2>
      <div class="section-body">
        <p>Pick the shape first: the original, square, 4:5, 9:16, 16:9 or 3:4, and reframe with a gesture. Choose a loop length from 1 to 15 seconds and a frame rate, then export.</p>
        <ul class="checks">
          <li>MP4 video, in H.264 or HEVC</li>
          <li>GIF, with a size estimate before you export</li>
          <li>A still frame as an image</li>
          <li>Save to Photos, share, or open in Files</li>
          <li>No watermark</li>
        </ul>
        <p>You can add your own audio file to a video, with trim, volume and fade. Lumotion does not include music.</p>
      </div>
    </div>
  </section>

  <section class="section" id="private" aria-labelledby="h-private">
    <div class="wrap">
      <h2 id="h-private">Your photos never leave your device</h2>
      <div class="section-body">
        <p>Lumotion has no account and no server that stores your pictures. Every frame is made on your phone or iPad. We do not run analytics of our own.</p>
        <ul class="checks">
          <li>You pick photos and videos with the iOS photo picker, so Lumotion sees only what you choose</li>
          <li>Saving to your library uses add-only permission</li>
          <li>Subject finding for depth effects runs on the device</li>
          <li>Projects are saved on your device and can be deleted from the gallery</li>
          <li>No account, no sign-in, no subscription</li>
        </ul>
        <p>The only outside service is the ad network. The <a href="privacy/">privacy policy</a> explains what it collects.</p>
      </div>
    </div>
  </section>

  <section class="section band" id="free" aria-labelledby="h-free">
    <div class="wrap">
      <h2 id="h-free">Free, and paid for by ads</h2>
      <div class="section-body">
        <p>Lumotion has no subscription and no in-app purchase. Ads from Google AdMob pay for it, and they appear in two places.</p>
        <div class="split">
          <div>
            <h3>Where you will see ads</h3>
            <ul>
              <li>A banner on the Home screen. Never over the editing controls.</li>
              <li>One short rewarded video before you export. You choose whether to watch it, and one watched ad covers your exports for 2 minutes.</li>
            </ul>
          </div>
          <div>
            <h3>When no ad is available</h3>
            <ul>
              <li>The export goes ahead for free.</li>
              <li>This happens, for example, when you are offline.</li>
            </ul>
          </div>
        </div>
        <p>Where the law asks for it, the app shows a consent form from Google before personalised ads, and iOS may ask whether the app may track you. Lumotion itself runs no analytics, and the only tracking that can happen is through Google's ad software, and only if you allow it. You can say no to the iOS prompt and still use everything. Settings has an Ad privacy choices row where one is required.</p>
      </div>
    </div>
  </section>

  <section class="section faq" id="faq" aria-labelledby="h-faq">
    <div class="wrap">
      <h2 id="h-faq">Questions</h2>
      <div class="section-body">
{faq_html}
      </div>
    </div>
  </section>
</main>
""" + footer("")
    (OUT / "index.html").write_text(body, encoding="utf-8")


# ----------------------------------------------------------------------------- support
def build_support():
    title = "Support | Photo Animator & Cinemagraph: Lumotion"
    desc = "Get help with Lumotion: contact details, and answers about animating a photo, making a cinemagraph, exporting, ads and your projects."
    items = [
        ("How do I make a photo move?",
         "<ol><li>Choose a photo, or one of the sample photos, on the Home screen.</li><li>Open Flow in the tool dock and paint over the part that should move, such as water or smoke.</li><li>Draw arrows inside the painted area to show the direction. Set the speed and strength.</li><li>Use the anchor brush on anything that must stay still.</li><li>Press play to preview the loop, then export.</li></ol>"
         "<p>Magic presets give you a starting point in one tap. You can change everything they set.</p>"),
        ("How do I make a cinemagraph from a video?",
         "<ol><li>Choose a video from your library. Clips that were filmed on a steady surface or tripod work best.</li><li>Open Video, and choose the loop: where it starts and ends, up to six seconds.</li><li>Choose the still frame, then paint the part that should keep moving. The rest stays frozen.</li><li>Raise the loop smoothing if you can see a jump when the clip repeats, or use the back-and-forth loop.</li><li>Export it as an MP4 or a GIF.</li></ol>"),
        ("Why am I asked to watch an ad?",
         "<p>Lumotion is free, and ads pay for it. Before you export, the app offers one short video that you choose to watch. One watched ad covers your exports for 2 minutes. If you choose Not now, nothing is exported and you can try again any time. If no ad is available, for example when you are offline or your ad privacy choice does not allow ads, the export goes ahead without one. Editing never needs an ad.</p>"),
        ("Which file should I export for Instagram, TikTok or WhatsApp?",
         "<p>Export an MP4 and use Share, then pick the app. Choose 9:16 for stories and short videos, 4:5 or 1:1 for feed posts. GIF files are larger and lower in quality than MP4, so use a GIF only when you need one. Lumotion shows a size estimate before a GIF export.</p>"),
        ("My export is slow or stops",
         "<p>High resolutions, long loops and a high frame rate take more time and memory, especially on older devices. Try a shorter loop, 30 frames per second or a lower resolution. Keep the app open until the export finishes, and make sure your device has free storage.</p>"),
        ("Where are my projects?",
         "<p>Projects are saved on your device as you work and appear on the Home screen. You can rename, duplicate or delete them there. Lumotion keeps projects only on your device, so if you delete the app, or delete a project, they cannot be recovered by us. Files you exported to Photos or Files are not affected. A full backup of your device may still contain the app's data if you made one before deleting it.</p>"),
        ("I saw an ad that seems wrong",
         "<p>Write to us at the address above. Tell us roughly when and where in the app you saw it and what it showed. A screenshot helps. We block ad categories and advertisers through Google AdMob where we can.</p>"),
        ("I want to change my ad or tracking choice",
         "<p>Open Settings in the app and look for the Ad privacy choices row, which appears where the law requires it. You can also change tracking in iOS Settings under Privacy and Security, then Tracking, and reset your advertising identifier there.</p>"),
        ("I have an idea for an effect or a preset",
         "<p>Send it. We read every message, though we cannot promise to build every idea.</p>"),
    ]
    faq_html = "\n".join(f'          <details><summary>{html.escape(q)}</summary><div class="answer">{a}</div></details>' for q, a in items)
    body = head(title, desc, "support/", root="../") + header("../", "support") + f"""
<main id="main">
  <div class="page">
    <div class="wrap">
      <div class="doc">
        <h1>Support</h1>
        <p class="lede">Write to us and a person will read it.</p>
        <p class="contact-line">{EMAIL_TEXT}</p>
        <p class="small">Select the address to copy it into your mail app.</p>
        <p>We reply by email. A message gets answered faster when it includes:</p>
        <ul>
          <li>your iPhone or iPad model and iOS or iPadOS version</li>
          <li>what you were doing and what happened</li>
          <li>the tool you were using</li>
          <li>a screenshot, if it helps</li>
        </ul>
        <p>Lumotion is not on the App Store yet, so support right now covers questions about the app before it is available.</p>
        <h2>Common questions</h2>
        <div class="faq">
{faq_html}
        </div>
        <h2>Company</h2>
        <p>Ecom Swift LLC<br>30 N Gould St #37906<br>Sheridan, WY 82801<br>United States</p>
        <p>Read the <a href="../privacy/">privacy policy</a> and the <a href="../terms/">terms of use</a>.</p>
      </div>
    </div>
  </div>
</main>
""" + footer("../")
    (OUT / "support").mkdir(exist_ok=True)
    (OUT / "support" / "index.html").write_text(body, encoding="utf-8")


# ----------------------------------------------------------------------------- legal (markdown -> html)
URL_RE = re.compile(r"(https?://[^\s<)]+)")
MAIL_RE = re.compile(r"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})")


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)

    def url(m):
        u = m.group(1)
        trail = ""
        while u and u[-1] in ".,;":
            trail = u[-1] + trail
            u = u[:-1]
        return f'<a href="{u}" rel="noopener">{u}</a>{trail}'

    t = URL_RE.sub(url, t)
    # email addresses stay as selectable text (no mailto link)
    parts = re.split(r"(<a .*?</a>)", t)
    parts = [p if p.startswith("<a ") else MAIL_RE.sub(r'<span class="email">\1</span>', p) for p in parts]
    return "".join(parts)


def md_to_html(md):
    md = re.sub(r"<!-- DRAFT-NOTICE-START -->.*?<!-- DRAFT-NOTICE-END -->", "", md, flags=re.S)
    out, para, items = [], [], []
    title = ""
    meta_open = False
    seen_h2 = False

    def flush_para():
        nonlocal para
        if para:
            out.append("<p>" + "<br>".join(inline(p) for p in para) + "</p>")
            para = []

    def flush_list():
        nonlocal items
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items = []

    for raw in md.splitlines():
        line = raw.rstrip()
        if line.startswith("# "):
            flush_para(); flush_list()
            title = line[2:].strip()
            out.append(f"<h1>{html.escape(title)}</h1>")
        elif line.startswith("## "):
            flush_para(); flush_list()
            if meta_open:
                out.append("</div>"); meta_open = False
            seen_h2 = True
            out.append(f"<h2>{inline(line[3:].strip())}</h2>")
        elif line.startswith("- "):
            flush_para()
            items.append(line[2:].strip())
        elif not line.strip():
            flush_para(); flush_list()
        elif line.startswith("**") and title and not seen_h2:
            if not meta_open:
                out.append('<div class="meta">'); meta_open = True
            out.append("<p>" + inline(line) + "</p>")
        else:
            flush_list()
            if meta_open:
                out.append("</div>"); meta_open = False
            para.append(line.strip())
    flush_para(); flush_list()
    if meta_open:
        out.append("</div>")
    return title, "\n".join(out)


def build_legal(src, folder, current_title, desc):
    md = (LEGAL / src).read_text(encoding="utf-8")
    title, content = md_to_html(md)
    page_title = f"{current_title} | {SITE_NAME}"
    body = head(page_title, desc, folder + "/", root="../") + header("../", "") + f"""
<main id="main">
  <div class="page">
    <div class="wrap">
      <article class="doc">
{content}
      </article>
    </div>
  </div>
</main>
""" + footer("../")
    (OUT / folder).mkdir(exist_ok=True)
    (OUT / folder / "index.html").write_text(body, encoding="utf-8")


def build_misc():
    urls = ["", "support/", "privacy/", "terms/"]
    xml = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for u in urls:
        xml.append(f"  <url><loc>{BASE}{u}</loc><lastmod>{UPDATED}</lastmod></url>")
    xml.append("</urlset>")
    (OUT / "sitemap.xml").write_text("\n".join(xml) + "\n", encoding="utf-8")
    (OUT / "robots.txt").write_text(
        "# Hosted on GitHub Pages as a project path under /lumotion/.\n"
        "User-agent: *\nAllow: /\n\n"
        f"Sitemap: {BASE}sitemap.xml\n", encoding="utf-8")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if OUT != SRC_SITE:  # review build elsewhere: bring the assets along
        shutil.copytree(SRC_SITE / "assets", OUT / "assets", dirs_exist_ok=True)
    build_index()
    build_support()
    build_legal("privacy-policy.md", "privacy", "Privacy Policy",
                "How Photo Animator & Cinemagraph: Lumotion handles information: photos and videos are processed on your device and never uploaded, there is no account, and ads come from Google AdMob with your consent where required.")
    build_legal("terms-of-use.md", "terms", "Terms of Use",
                "The terms for using Photo Animator & Cinemagraph: Lumotion, a free photo animator supported by ads.")
    build_misc()
    print("site built in", OUT)


if __name__ == "__main__":
    main()
