#!/usr/bin/env python3
"""Renders the Mint Air DMG installer window background: mint backdrop, a white
glass card behind the two icons and Drip riding a paper plane between them.

Writes <out_dir>/dmg-background.png (660x400) and dmg-background@2x.png (1320x800).
Icon slots (in 1x points) match scripts/build-dmg.sh: app at (170, 200), Applications at (490, 200).

Usage: python3 scripts/make_dmg_background.py <out_dir>
"""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIP = os.path.join(ROOT, "design/illustrations/sending.png")
INK = (15, 29, 22, 255)
GREEN = (20, 154, 91)
W, H = 660, 400


def font(size, bold=False):
    poppins = os.path.join(ROOT, "android/android/app/src/main/assets/fonts", "Poppins-SemiBold.ttf" if bold else "Poppins-Regular.ttf")
    candidates = [
        poppins,
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def mint_backdrop(w, h):
    """Radial white-to-mint gradient from the top, like the app."""
    import math

    img = Image.new("RGB", (w, h))
    px = img.load()
    stops = [(0.0, (255, 255, 255)), (0.5, (241, 250, 243)), (1.0, (218, 241, 225))]
    cx, rx, ry = w * 0.6, w * 0.95, h * 1.1
    for y in range(h):
        for x in range(w):
            t = min(1.0, math.hypot((x - cx) / rx, y / ry))
            for (a, ca), (b, cb) in zip(stops, stops[1:]):
                if t <= b:
                    f = (t - a) / (b - a)
                    px[x, y] = tuple(int(ca[i] + (cb[i] - ca[i]) * f) for i in range(3))
                    break
    return img.convert("RGBA")


def sphere(w, h, center, radius, colors, alpha):
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    steps = 24
    for i in range(steps, 0, -1):
        r = radius * i / steps
        t = 1 - i / steps
        c = colors[0] if t > 0.6 else colors[1] if t > 0.3 else colors[2]
        d.ellipse([center[0] - r, center[1] - r, center[0] + r, center[1] + r], fill=c + (int(255 * alpha),))
    return layer.filter(ImageFilter.GaussianBlur(radius * 0.35))


def render(scale):
    w, h = W * scale, H * scale
    base = mint_backdrop(w, h)
    greens = [(216, 247, 180), (127, 217, 154), (46, 158, 102)]
    base.alpha_composite(sphere(w, h, (w + 20 * scale, h + 10 * scale), 170 * scale, greens, 0.4))
    base.alpha_composite(sphere(w, h, (int(w * 0.18), -20 * scale), 80 * scale, greens, 0.3))

    # White glass card behind the two icons.
    card = (40 * scale, 92 * scale, w - 40 * scale, 312 * scale)
    radius = 28 * scale
    mask = rounded_mask((w, h), card, radius)
    shadow = Image.new("RGBA", (w, h), (24, 84, 52, 0))
    shadow_mask = rounded_mask((w, h), (card[0], card[1] + 12 * scale, card[2], card[3] + 12 * scale), radius)
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(18 * scale)).point(lambda v: int(v * 0.14)))
    base.alpha_composite(shadow)
    glass = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    glass.putalpha(mask.point(lambda v: int(v * 0.66)))
    base.alpha_composite(glass)
    hi = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hi)
    for i in range(int(80 * scale)):
        a = int(110 * (1 - i / (80 * scale)))
        hd.line([(card[0], card[1] + i), (card[2], card[1] + i)], fill=(255, 255, 255, a))
    hi.putalpha(ImageChops.multiply(hi.getchannel("A"), mask))
    base.alpha_composite(hi)
    border = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(card, radius=radius, outline=(255, 255, 255, 245), width=max(1, scale))
    base.alpha_composite(border)

    d = ImageDraw.Draw(base)
    title = "Drag CrossDrop to Applications"
    tf = font(22 * scale, bold=True)
    tw = d.textlength(title, font=tf)
    d.text(((w - tw) / 2, 38 * scale), title, font=tf, fill=INK)
    sub = "Then open it from Applications. First launch: System Settings › Privacy & Security › Open Anyway."
    sf = font(11 * scale)
    sw2 = d.textlength(sub, font=sf)
    d.text(((w - sw2) / 2, 338 * scale), sub, font=sf, fill=(75, 91, 82, 255))

    # Dashed green arrow between the icon slots.
    y = 214 * scale
    x0, x1 = 252 * scale, 408 * scale
    dash, gap = 10 * scale, 8 * scale
    x = x0
    while x < x1 - 22 * scale:
        d.line([(x, y), (min(x + dash, x1 - 22 * scale), y)], fill=GREEN + (230,), width=3 * scale)
        x += dash + gap
    d.polygon([(x1, y), (x1 - 18 * scale, y - 11 * scale), (x1 - 18 * scale, y + 11 * scale)], fill=GREEN + (240,))

    # Drip on its paper plane, flying from the app towards Applications.
    if os.path.exists(DRIP):
        size = 120 * scale
        drip = Image.open(DRIP).convert("RGBA").resize((size, size), Image.LANCZOS)
        base.alpha_composite(drip, (w // 2 - size // 2, 100 * scale))
    return base.convert("RGB")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    render(1).save(os.path.join(out, "dmg-background.png"))
    render(2).save(os.path.join(out, "dmg-background@2x.png"))
    print("wrote", out)


if __name__ == "__main__":
    main()
