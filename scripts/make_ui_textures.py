#!/usr/bin/env python3
"""Renders the small images the Android UI draws its backdrop and glass from.

Pre-drawn images are the cheapest thing to put on screen on any GPU: one
texture each, nothing computed per pixel per frame. Writes to
android/src/assets/ui/:

  backdrop-<mood>.jpg  radial mint gradient for each mood (stretched to fit)
  sphere-<tone>.png    soft glowing ball that fades out at its edge
  sheen.png            vertical white-to-clear highlight for glass tops
  shadow.png           soft white ellipse; the app tints it for drop shadows

Usage: python3 scripts/make_ui_textures.py
"""
import os

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "android/src/assets/ui")

MOODS = {
    "idle": ("#FFFFFF", "#F1FAF3", "#DDF3E3"),
    "off": ("#FFFFFF", "#F2F6F3", "#E1ECE5"),
    "incoming": ("#FFFFFF", "#EAF7EE", "#CFEBD8"),
    "active": ("#FFFFFF", "#F2FCE6", "#D9F5C4"),
    "done": ("#FFFFFF", "#E6F7EA", "#BFE8CB"),
    "failed": ("#FFFFFF", "#FBF5F1", "#F1E4DC"),
}

SPHERES = {
    "green": ((216, 247, 180), (127, 217, 154), (46, 158, 102)),
    "cool": ((228, 243, 217), (169, 217, 182), (107, 168, 132)),
    "lime": ((232, 251, 184), (155, 230, 138), (59, 170, 112)),
    "warm": ((251, 227, 207), (232, 176, 142), (196, 120, 90)),
}

rng = np.random.default_rng(7)


def hex_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i : i + 2], 16) for i in (0, 2, 4)], np.float32)


def lerp_stops(t, stops):
    """t in [0,1] (any shape) through [(pos, rgb), ...] -> (..., 3)."""
    out = np.zeros(t.shape + (3,), np.float32)
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        m = (t >= a) & (t <= b)
        f = ((t - a) / (b - a))[..., None]
        out[m] = (ca * (1 - f) + cb * f)[m]
    out[t > stops[-1][0]] = stops[-1][1]
    return out


def save(arr, name, mode):
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), mode)
    if name.endswith(".jpg"):
        img.save(os.path.join(OUT, name), quality=92, optimize=True, subsampling=0)
    else:
        img.save(os.path.join(OUT, name), optimize=True)


def backdrop(colors, w=360, h=800):
    # CSS radial-gradient(ellipse 120% 75% at 50% 0%, a 0%, b 45%, c 100%)
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    t = np.sqrt(((x - w / 2) / (1.2 * w)) ** 2 + (y / (0.75 * h)) ** 2)
    stops = [(0.0, hex_rgb(colors[0])), (0.45, hex_rgb(colors[1])), (1.0, hex_rgb(colors[2]))]
    rgb = lerp_stops(np.clip(t, 0, 1), stops)
    rgb += rng.uniform(-0.6, 0.6, rgb.shape)  # dither so the stretch never bands
    return rgb


def sphere(tone, size=256):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / (size - 1)
    r = np.sqrt((x - 0.5) ** 2 + (y - 0.5) ** 2) / 0.5
    hl = np.sqrt((x - 0.42) ** 2 + (y - 0.38) ** 2) / 0.62
    a, b, c = (np.array(v, np.float32) for v in SPHERES[tone])
    rgb = lerp_stops(np.clip(hl, 0, 1), [(0.0, a), (0.45, b), (1.0, c)])
    alpha = np.clip(1 - r, 0, 1) ** 1.6 * 0.75 * 255
    return np.dstack([rgb, alpha])


def sheen(h=128):
    t = np.linspace(0, 1, h, dtype=np.float32)
    alpha = np.interp(t, [0, 0.3, 0.6, 1], [0.55, 0.08, 0, 0]) * 255
    col = np.dstack([np.full((h, 4), 255), np.full((h, 4), 255), np.full((h, 4), 255), np.repeat(alpha[:, None], 4, 1)])
    return col


def shadow(w=256, h=128):
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    r = np.sqrt(((x - w / 2) / (w / 2)) ** 2 + ((y - h / 2) / (h / 2)) ** 2)
    alpha = np.clip(1 - r, 0, 1) ** 1.8 * 255
    return np.dstack([np.full((h, w), 255), np.full((h, w), 255), np.full((h, w), 255), alpha])


def main():
    os.makedirs(OUT, exist_ok=True)
    for mood, colors in MOODS.items():
        save(backdrop(colors), f"backdrop-{mood}.jpg", "RGB")
    for tone in SPHERES:
        save(sphere(tone), f"sphere-{tone}.png", "RGBA")
    save(sheen(), "sheen.png", "RGBA")
    save(shadow(), "shadow.png", "RGBA")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
