#!/usr/bin/env python3
"""Renders the CrossDrop app icon for Android and macOS (Pillow + NumPy).

Design: a deep blue-to-violet field with a soft light bloom, and a frosted
glass droplet carrying an up/down exchange arrow. Everything is drawn at 4x and
downsampled for clean edges.

Usage: python3 scripts/make_icons.py   (run from the repository root)
"""
import json
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android/android/app/src/main/res")
MAC = os.path.join(ROOT, "macos/CrossDrop/Resources/Assets.xcassets/AppIcon.appiconset")

TOP_LEFT = np.array([92, 140, 255], dtype=np.float32)
BOTTOM_RIGHT = np.array([104, 52, 230], dtype=np.float32)


def background(size: int) -> Image.Image:
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / max(size - 1, 1)
    t = np.clip((x + y) / 2, 0, 1)[..., None]
    rgb = TOP_LEFT * (1 - t) + BOTTOM_RIGHT * t
    # Soft bloom from the upper left, and a cooler glow lower right.
    d1 = np.sqrt((x - 0.22) ** 2 + (y - 0.12) ** 2)
    d2 = np.sqrt((x - 0.9) ** 2 + (y - 0.95) ** 2)
    rgb += (np.exp(-(d1 / 0.38) ** 2) * 70)[..., None] * np.array([1.0, 1.0, 1.0])
    rgb += (np.exp(-(d2 / 0.35) ** 2) * 40)[..., None] * np.array([0.2, 0.9, 1.0])
    img = np.dstack([np.clip(rgb, 0, 255), np.full((size, size), 255, np.float32)]).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def droplet_mask(size: int, scale: float = 1.0) -> Image.Image:
    """Teardrop pointing up, centred, height = 0.62*size*scale."""
    s = size * 4
    m = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(m)
    h = 0.62 * s * scale
    r = h * 0.36
    cx, cy = s / 2, s / 2 + h * 0.14
    tip = (cx, cy - h * 0.62)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    # Tangent lines from the tip to the circle form the drop's shoulders.
    import math

    dist = cy - tip[1]
    ang = math.asin(r / dist)
    left = (cx - r * math.cos(ang), cy - r * math.sin(ang))
    right = (cx + r * math.cos(ang), cy - r * math.sin(ang))
    d.polygon([tip, left, right], fill=255)
    return m.resize((size, size), Image.LANCZOS)


def arrows_mask(size: int, scale: float = 1.0) -> Image.Image:
    """Two opposed arrows (exchange) inside the drop body, drawn as rounded strokes."""
    s = size * 4
    m = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(m)
    h = 0.62 * s * scale
    cx, cy = s / 2, s / 2 + h * 0.16
    w = max(h * 0.075, 1)  # stroke width
    span = h * 0.2
    gap = h * 0.095
    head = h * 0.1

    def stroke(points):
        d.line(points, fill=255, width=int(w), joint="curve")
        for x, y in (points[0], points[-1]):
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)

    up_x, down_x = cx - gap, cx + gap
    stroke([(up_x, cy + span), (up_x, cy - span)])
    stroke([(up_x - head, cy - span + head), (up_x, cy - span), (up_x + head, cy - span + head)])
    stroke([(down_x, cy - span), (down_x, cy + span)])
    stroke([(down_x - head, cy + span - head), (down_x, cy + span), (down_x + head, cy + span - head)])
    return m.resize((size, size), Image.LANCZOS)


def glass_drop(size: int, scale: float = 1.0) -> Image.Image:
    """Frosted white droplet with a rim highlight and the arrows cut in tinted glass."""
    drop = droplet_mask(size, scale)
    arrows = arrows_mask(size, scale)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Shadow under the drop for depth.
    shadow = drop.filter(ImageFilter.GaussianBlur(size * 0.03))
    shadow_img = Image.new("RGBA", (size, size), (20, 10, 70, 0))
    shadow_img.putalpha(shadow.point(lambda v: int(v * 0.45)))
    layer.alpha_composite(shadow_img, (0, int(size * 0.02)))

    # Glass body: vertical white gradient, more opaque at the top.
    y = np.linspace(0, 1, size, dtype=np.float32)[:, None].repeat(size, 1)
    alpha = (0.92 - 0.30 * y) * (np.array(drop, dtype=np.float32) / 255)
    body = np.dstack([np.full((size, size), 255), np.full((size, size), 255), np.full((size, size), 255), alpha * 255]).astype(np.uint8)
    layer.alpha_composite(Image.fromarray(body, "RGBA"))

    # Rim: a thin bright edge.
    inner = drop.filter(ImageFilter.GaussianBlur(max(size * 0.006, 0.6)))
    rim = ImageChops.subtract(drop, inner.point(lambda v: 255 if v > 200 else 0))
    rim_img = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    rim_img.putalpha(rim)
    layer.alpha_composite(rim_img)

    # Arrows in the brand blue, slightly deeper at the bottom.
    t = y[..., None]
    arrow_rgb = np.array([62, 98, 255], np.float32) * (1 - t) + np.array([108, 58, 235], np.float32) * t
    arrow = np.dstack([arrow_rgb, np.array(arrows, dtype=np.float32)[..., None]]).astype(np.uint8)
    layer.alpha_composite(Image.fromarray(arrow, "RGBA"))
    return layer


def rounded_mask(size: int, radius_ratio: float) -> Image.Image:
    s = size * 4
    m = Image.new("L", (s, s), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * radius_ratio), fill=255)
    return m.resize((size, size), Image.LANCZOS)


def full_icon(size: int, shape: str) -> Image.Image:
    img = background(size)
    img.alpha_composite(glass_drop(size, 0.95))
    mask = rounded_mask(size, 0.22) if shape == "square" else circle_mask(size)
    img.putalpha(ImageChops.multiply(img.getchannel("A"), mask))
    return img


def circle_mask(size: int) -> Image.Image:
    s = size * 4
    m = Image.new("L", (s, s), 0)
    ImageDraw.Draw(m).ellipse([0, 0, s - 1, s - 1], fill=255)
    return m.resize((size, size), Image.LANCZOS)


def save(img: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)


def android() -> None:
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, k in densities.items():
        legacy = int(48 * k)
        save(full_icon(legacy, "square"), f"{RES}/mipmap-{name}/ic_launcher.png")
        save(full_icon(legacy, "circle"), f"{RES}/mipmap-{name}/ic_launcher_round.png")
        adaptive = int(108 * k)
        save(background(adaptive), f"{RES}/mipmap-{name}/ic_launcher_background.png")
        # Adaptive foregrounds must keep content inside the central 66dp.
        save(glass_drop(adaptive, 0.78), f"{RES}/mipmap-{name}/ic_launcher_foreground.png")
        # Android 12+ splash: 240dp canvas, content within the central 160dp circle.
        splash_px = int(240 * k)
        canvas = Image.new("RGBA", (splash_px, splash_px), (0, 0, 0, 0))
        disc = int(150 * k)
        canvas.alpha_composite(full_icon(disc, "circle"), ((splash_px - disc) // 2, (splash_px - disc) // 2))
        save(canvas, f"{RES}/drawable-{name}/splash_icon.png")
    adaptive_xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
"""
    os.makedirs(f"{RES}/mipmap-anydpi-v26", exist_ok=True)
    for n in ("ic_launcher", "ic_launcher_round"):
        with open(f"{RES}/mipmap-anydpi-v26/{n}.xml", "w") as f:
            f.write(adaptive_xml)


def macos() -> None:
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            fname = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            # macOS icon grid: 824/1024 body with a soft shadow on a transparent canvas.
            canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
            body = max(int(px * 824 / 1024), 1)
            off = (px - body) // 2
            if px >= 64:
                sh = Image.new("RGBA", (px, px), (0, 0, 0, 0))
                sh_mask = Image.new("L", (px, px), 0)
                sh_mask.paste(rounded_mask(body, 0.225), (off, off + max(px // 64, 1)))
                sh.putalpha(sh_mask.filter(ImageFilter.GaussianBlur(px / 64)).point(lambda v: int(v * 0.35)))
                canvas.alpha_composite(sh)
            icon = background(body)
            icon.alpha_composite(glass_drop(body, 0.95))
            icon.putalpha(rounded_mask(body, 0.225))
            canvas.alpha_composite(icon, (off, off))
            save(canvas, f"{MAC}/{fname}")
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": fname})
    with open(f"{MAC}/Contents.json", "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    android()
    macos()
    print("icons written")
