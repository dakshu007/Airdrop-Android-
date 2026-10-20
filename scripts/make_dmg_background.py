#!/usr/bin/env python3
"""Renders the DMG installer window background from the Dusk wallpaper.

Writes <out_dir>/dmg-background.png (660x400) and dmg-background@2x.png (1320x800).
Icon slots (in 1x points) match scripts/build-dmg.sh: app at (170, 200), Applications at (490, 200).

Usage: python3 scripts/make_dmg_background.py <out_dir>
"""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WALLPAPER = os.path.join(ROOT, "macos/CrossDrop/Resources/Assets.xcassets/Wallpaper-dusk.imageset/dusk.jpg")
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


def render(scale):
    w, h = W * scale, H * scale
    src = Image.open(WALLPAPER).convert("RGB")
    # Centre-crop the wallpaper to the window aspect, favouring the sunset band.
    sw, sh = src.size
    crop_h = int(sw * h / w)
    top = max(0, min(sh - crop_h, int(sh * 0.42) - crop_h // 2))
    bg = src.crop((0, top, sw, top + crop_h)).resize((w, h), Image.LANCZOS)
    base = bg.filter(ImageFilter.GaussianBlur(2 * scale)).convert("RGBA")
    base.alpha_composite(Image.new("RGBA", (w, h), (10, 8, 30, 40)))

    # Frosted glass card behind the two icons.
    card = (40 * scale, 92 * scale, w - 40 * scale, 312 * scale)
    radius = 28 * scale
    frosted = bg.filter(ImageFilter.GaussianBlur(18 * scale)).convert("RGBA")
    frosted.alpha_composite(Image.new("RGBA", (w, h), (255, 255, 255, 46)))
    mask = rounded_mask((w, h), card, radius)
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shadow_mask = rounded_mask((w, h), (card[0], card[1] + 10 * scale, card[2], card[3] + 10 * scale), radius)
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(16 * scale)).point(lambda v: int(v * 0.35)))
    base.alpha_composite(shadow)
    base.paste(frosted, (0, 0), mask)

    # Top highlight and hairline border.
    hi = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hi)
    for i in range(int(70 * scale)):
        a = int(46 * (1 - i / (70 * scale)))
        hd.line([(card[0], card[1] + i), (card[2], card[1] + i)], fill=(255, 255, 255, a))
    hi.putalpha(ImageChops.multiply(hi.getchannel("A"), mask))
    base.alpha_composite(hi)
    border = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(card, radius=radius, outline=(255, 255, 255, 120), width=max(1, scale))
    base.alpha_composite(border)

    d = ImageDraw.Draw(base)
    # Title and hint.
    title = "Drag CrossDrop to Applications"
    tf = font(22 * scale, bold=True)
    tw = d.textlength(title, font=tf)
    d.text(((w - tw) / 2, 38 * scale), title, font=tf, fill=(255, 255, 255, 255))
    sub = "Then open it from Applications. First launch: System Settings › Privacy & Security › Open Anyway."
    sf = font(11 * scale)
    sw2 = d.textlength(sub, font=sf)
    d.text(((w - sw2) / 2, 338 * scale), sub, font=sf, fill=(255, 255, 255, 200))

    # Soft arrow between the icon slots.
    y = 200 * scale
    x0, x1 = 250 * scale, 410 * scale
    arrow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    dash, gap = 10 * scale, 8 * scale
    x = x0
    while x < x1 - 22 * scale:
        ad.line([(x, y), (min(x + dash, x1 - 22 * scale), y)], fill=(255, 255, 255, 230), width=3 * scale)
        x += dash + gap
    ad.polygon([(x1, y), (x1 - 18 * scale, y - 11 * scale), (x1 - 18 * scale, y + 11 * scale)], fill=(255, 255, 255, 235))
    glow = arrow.filter(ImageFilter.GaussianBlur(6 * scale))
    base.alpha_composite(glow)
    base.alpha_composite(arrow)
    return base.convert("RGB")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    render(1).save(os.path.join(out, "dmg-background.png"))
    render(2).save(os.path.join(out, "dmg-background@2x.png"))
    print("wrote", out)


if __name__ == "__main__":
    main()
