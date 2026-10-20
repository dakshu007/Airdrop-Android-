#!/usr/bin/env python3
"""Renders CrossDrop's original wallpapers (no stock photos, no licences needed).

Each wallpaper is rendered once at high resolution, then exported:
  * Android: portrait JPEG + a small pre-blurred copy used for the frosted-glass
    effect (glass panels show the blurred copy aligned to the screen).
  * macOS: landscape JPEG in an asset catalog image set.

Usage: python3 scripts/make_wallpapers.py [name ...]   (from the repository root)
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANDROID = os.path.join(ROOT, "android/src/assets/wallpapers")
MAC = os.path.join(ROOT, "macos/CrossDrop/Resources/Assets.xcassets")
RNG = np.random.default_rng(7)


# ---------------------------------------------------------------- helpers

def noise(h, w, scale, octaves=5, seed=0, persistence=0.5):
    """Fractal value noise in [0, 1]."""
    rng = np.random.default_rng(seed)
    out = np.zeros((h, w), np.float32)
    amp, total = 1.0, 0.0
    for o in range(octaves):
        cells = max(2, int(scale * (2 ** o)))
        gh = max(2, int(cells * h / max(h, w)) + 2)
        gw = max(2, int(cells * w / max(h, w)) + 2)
        grid = rng.random((gh, gw)).astype(np.float32)
        img = Image.fromarray((grid * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
        out += amp * (np.asarray(img, np.float32) / 255)
        total += amp
        amp *= persistence
    return out / total


def lerp(a, b, t):
    return a + (b - a) * t


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.float32)


def gradient(h, w, stops, axis="y"):
    """Linear gradient through (position, colour) stops."""
    t = np.linspace(0, 1, h if axis == "y" else w, dtype=np.float32)
    cols = np.zeros((len(t), 3), np.float32)
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        m = (t >= p0) & (t <= p1)
        k = ((t[m] - p0) / max(p1 - p0, 1e-6))[:, None]
        k = k * k * (3 - 2 * k)
        cols[m] = lerp(hexrgb(c0), hexrgb(c1), k)
    if axis == "y":
        return np.repeat(cols[:, None, :], w, axis=1)
    return np.repeat(cols[None, :, :], h, axis=0)


def blob(h, w, cx, cy, rx, ry, color, strength=1.0):
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    d = ((x / w - cx) / rx) ** 2 + ((y / h - cy) / ry) ** 2
    a = np.exp(-d * 2.2)[..., None] * strength
    return a, hexrgb(color)


def apply_blobs(img, blobs):
    h, w, _ = img.shape
    for b in blobs:
        a, c = blob(h, w, *b)
        img = img * (1 - a) + c * a
    return img


def grain(img, amount=4.0, seed=1):
    rng = np.random.default_rng(seed)
    n = rng.normal(0, amount, img.shape[:2]).astype(np.float32)[..., None]
    return img + n


def vignette(img, strength=0.35):
    h, w, _ = img.shape
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((x / w) - 0.5) ** 2 * 1.2 + ((y / h) - 0.5) ** 2)
    return img * (1 - strength * np.clip(d - 0.25, 0, 1)[..., None] * 1.6)


def to_image(arr):
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


# ---------------------------------------------------------------- wallpapers

def dusk_ridge(h, w):
    """Layered mountain ridges at sunset with haze, a low sun and a lake."""
    sky = gradient(h, w, [(0, "#1c2a5e"), (0.28, "#5a4d9a"), (0.48, "#e0789a"), (0.6, "#ffb38a"), (0.66, "#ffd6a0"), (1, "#ffd6a0")])
    img = sky.copy()
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    # Sun glow
    sx, sy = 0.62, 0.6
    d = np.sqrt(((x / w - sx) * (w / h)) ** 2 + (y / h - sy) ** 2)
    img += (np.exp(-(d / 0.05) ** 2) * 255)[..., None] * np.array([1.0, 0.93, 0.8]) * 0.9
    img += (np.exp(-(d / 0.22) ** 2) * 120)[..., None] * np.array([1.0, 0.75, 0.55])
    # Soft clouds
    c = noise(h, w, 3, 6, seed=11)
    cl = np.clip((c - 0.55) * 3.0, 0, 1) * np.clip(1 - y / (h * 0.55), 0, 1)
    img = img * (1 - cl[..., None] * 0.35) + np.array([255, 205, 215]) * cl[..., None] * 0.35

    ridges = [
        (0.55, 0.045, "#b06a8e", 0.55, 21, 1.2),
        (0.59, 0.06, "#7d4f86", 0.7, 22, 1.4),
        (0.64, 0.07, "#4f3a72", 0.85, 23, 1.6),
        (0.70, 0.08, "#2c2551", 0.95, 24, 1.8),
        (0.77, 0.09, "#171633", 1.0, 25, 2.0),
    ]
    xs = np.arange(w, dtype=np.float32) / w
    for base, amp, col, opacity, seed, freq in ridges:
        prof = noise(1, w, freq, 5, seed=seed, persistence=0.42)[0]
        prof = (prof - prof.mean()) / (prof.std() + 1e-6)
        line = (base - amp * 0.5 * prof - 0.02 * np.sin(xs * 6.0 + seed)) * h
        mask = (y > line[None, :]).astype(np.float32)
        mask = np.asarray(Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2)), np.float32) / 255
        # Haze: ridge colour lightens toward its top edge.
        depth = np.clip((y - line[None, :]) / (h * 0.25), 0, 1)
        colr = lerp(hexrgb(col) * 1.25, hexrgb(col), depth[..., None])
        img = img * (1 - mask[..., None] * opacity) + colr * mask[..., None] * opacity
    # Mist band
    mist = np.exp(-(((y / h) - 0.66) / 0.05) ** 2) * noise(h, w, 4, 4, seed=31)
    img += mist[..., None] * np.array([255, 190, 200]) * 0.25
    # Lake with sun reflection
    lake_top = 0.8 * h
    lake = (y > lake_top).astype(np.float32)
    ripple = noise(h, w, 40, 3, seed=40)
    streak = 0.5 + 0.5 * np.sin(y / (h * 0.004) + ripple * 3)
    refl = np.exp(-((x / w - sx) * (7 + 10 * ripple)) ** 2) * (0.35 + 0.65 * streak) * np.exp(-((y - lake_top) / (h * 0.18)))
    water = lerp(hexrgb("#3d3470"), hexrgb("#0f0f26"), np.clip((y - lake_top) / (h * 0.2), 0, 1)[..., None])
    water += refl[..., None] * np.array([255, 190, 140]) * 0.45
    img = img * (1 - lake[..., None]) + water * lake[..., None]
    return grain(vignette(img, 0.3), 3.0)


def lagoon(h, w):
    """Bright sky-blue mesh with soft cloud light, like a summer afternoon."""
    img = gradient(h, w, [(0, "#1b6fd8"), (0.45, "#3aa0f0"), (1, "#8fd3ff")])
    img = apply_blobs(img, [
        (0.15, 0.2, 0.45, 0.25, "#0b4fc4", 0.8),
        (0.85, 0.35, 0.45, 0.3, "#ffd9c2", 0.55),
        (0.3, 0.75, 0.5, 0.3, "#ffffff", 0.45),
        (0.9, 0.85, 0.4, 0.25, "#4cc3ff", 0.6),
    ])
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    c = noise(h, w, 2.2, 7, seed=5, persistence=0.55)
    clouds = np.clip((c - 0.48) * 2.6, 0, 1) ** 1.4
    shade = noise(h, w, 6, 4, seed=6)
    cloud_col = lerp(np.array([255, 255, 255]), np.array([200, 220, 245]), shade[..., None])
    img = img * (1 - clouds[..., None] * 0.85) + cloud_col * clouds[..., None] * 0.85
    return grain(img, 2.5)


def canopy(h, w):
    """Macro leaf with veins and water droplets."""
    base = gradient(h, w, [(0, "#0d3b1e"), (0.5, "#1f6b33"), (1, "#0b2e17")], axis="x")
    img = apply_blobs(base, [(0.55, 0.4, 0.5, 0.5, "#3f9a4a", 0.6), (0.2, 0.9, 0.4, 0.3, "#0a2a14", 0.6)])
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    tex = noise(h, w, 30, 4, seed=8)
    img *= (0.88 + 0.24 * tex)[..., None]
    # Veins: a midrib and angled side veins.
    axis_x = 0.42 + 0.05 * np.sin(y / h * 2.4)
    dx = np.abs(x / w - axis_x)
    mid = np.exp(-((x / w - axis_x) / 0.007) ** 2)
    veins = mid.copy()
    wob = noise(h, w, 8, 3, seed=12) * 0.02
    for k in range(-8, 16):
        y0 = k * 0.075
        t = (y / h) - y0 - (dx * 0.5 + dx ** 2 * 0.9) - wob
        fade = np.exp(-dx * 1.4)
        veins += np.exp(-(t / 0.0028) ** 2) * 0.55 * fade
    veins = np.clip(veins, 0, 1)
    veins = np.asarray(Image.fromarray((veins * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(w / 900)), np.float32) / 255
    img = img * (1 - veins[..., None] * 0.28) + np.array([140, 205, 110]) * veins[..., None] * 0.28
    # Droplets
    rng = np.random.default_rng(3)
    out = to_image(img).convert("RGBA")
    layer = Image.new("RGBA", out.size, (0, 0, 0, 0))
    n = int(w * h / 6000)
    for _ in range(n):
        r = rng.choice([rng.uniform(4, 10), rng.uniform(10, 26), rng.uniform(26, 48)], p=[0.55, 0.33, 0.12]) * (w / 1170)
        cx, cy = rng.uniform(0, w), rng.uniform(0, h)
        draw_droplet(layer, cx, cy, r, rng.uniform(0.75, 1.25))
    out.alpha_composite(layer)
    sharp = out.convert("RGB")
    # Shallow depth of field: sharp band through the middle, soft top and bottom.
    soft = sharp.filter(ImageFilter.GaussianBlur(w / 160))
    t = np.clip((np.abs(np.linspace(0, 1, h) - 0.48) - 0.12) / 0.3, 0, 1)[:, None, None]
    mixed = np.asarray(sharp, np.float32) * (1 - t) + np.asarray(soft, np.float32) * t
    return grain(mixed, 2.0)


def draw_droplet(layer, cx, cy, r, squash):
    """A lit water bead: dark rim, bright caustic at the bottom, specular dot at the top."""
    s = int(r * 2 + 6)
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32)
    dx, dy = (xx - s / 2) / r, (yy - s / 2) / (r * squash)
    d = np.sqrt(dx ** 2 + dy ** 2)
    inside = np.clip((1 - d) * r, 0, 1)
    rim = np.clip(1 - np.abs(d - 0.92) * 8, 0, 1)
    caustic = np.exp(-((dx) ** 2 + (dy - 0.45) ** 2) / 0.08)
    spec = np.exp(-((dx + 0.32) ** 2 + (dy + 0.38) ** 2) / 0.012)
    rgb = np.zeros((s, s, 3), np.float32)
    a = np.zeros((s, s), np.float32)
    rgb += np.array([180, 235, 170]) * caustic[..., None]
    a += caustic * 0.55 * inside
    rgb = rgb + np.array([10, 40, 15]) * rim[..., None]
    a = np.maximum(a, rim * 0.55 * inside)
    a = np.maximum(a, inside * 0.12)
    rgb = rgb * (1 - spec[..., None]) + 255 * spec[..., None]
    a = np.maximum(a, spec * inside)
    # Contact shadow below the bead.
    shadow = np.exp(-((dx - 0.1) ** 2 + (dy - 0.25) ** 2) / 0.6) * (1 - inside) * 0.35
    a = np.maximum(a, shadow)
    rgb = np.where((shadow > a - 1e-6)[..., None] & (inside[..., None] < 0.5), np.array([5, 20, 8], np.float32), rgb)
    patch = Image.fromarray(np.dstack([np.clip(rgb, 0, 255), np.clip(a * 255, 0, 255)]).astype(np.uint8), "RGBA")
    layer.alpha_composite(patch, (int(cx - s / 2), int(cy - s / 2)))


def midnight(h, w):
    """Deep indigo nebula with stars."""
    img = gradient(h, w, [(0, "#05060f"), (0.5, "#0b0b24"), (1, "#060612")])
    n1 = noise(h, w, 2.5, 7, seed=21, persistence=0.58)
    n2 = noise(h, w, 3.5, 7, seed=22, persistence=0.58)
    neb1 = np.clip((n1 - 0.45) * 2.4, 0, 1) ** 1.5
    neb2 = np.clip((n2 - 0.5) * 2.6, 0, 1) ** 1.6
    img += neb1[..., None] * np.array([120, 70, 230]) * 0.9
    img += neb2[..., None] * np.array([40, 150, 255]) * 0.6
    img = apply_blobs(img, [(0.7, 0.3, 0.35, 0.2, "#ff5fa8", 0.25), (0.25, 0.7, 0.4, 0.25, "#3b2bd0", 0.35)])
    rng = np.random.default_rng(9)
    stars = np.zeros((h, w), np.float32)
    for _ in range(int(w * h / 1800)):
        yy, xx = rng.integers(0, h), rng.integers(0, w)
        stars[yy, xx] = rng.uniform(0.3, 1.0) ** 3
    stars_img = Image.fromarray((stars * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.7))
    s = np.asarray(stars_img, np.float32) / 255 * 3.5
    img += np.clip(s, 0, 1)[..., None] * 255
    return grain(vignette(img, 0.4), 2.5)


WALLPAPERS = {
    "dusk": dusk_ridge,
    "lagoon": lagoon,
    "canopy": canopy,
    "midnight": midnight,
}


def render(name):
    fn = WALLPAPERS[name]
    portrait = to_image(fn(2532, 1170))
    landscape = to_image(fn(1800, 2880))

    os.makedirs(ANDROID, exist_ok=True)
    portrait.save(os.path.join(ANDROID, f"{name}.jpg"), quality=86, optimize=True, progressive=True)
    # Pre-blurred copy for glass: blurring at low resolution, then shown scaled up, matches a
    # strong backdrop blur and keeps the file tiny.
    small = portrait.resize((292, 633), Image.LANCZOS).filter(ImageFilter.GaussianBlur(9))
    small.save(os.path.join(ANDROID, f"{name}-blur.jpg"), quality=90, optimize=True)

    iset = os.path.join(MAC, f"Wallpaper-{name}.imageset")
    os.makedirs(iset, exist_ok=True)
    landscape.save(os.path.join(iset, f"{name}.jpg"), quality=86, optimize=True, progressive=True)
    with open(os.path.join(iset, "Contents.json"), "w") as f:
        json.dump({"images": [{"idiom": "universal", "filename": f"{name}.jpg"}], "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    print("rendered", name)


if __name__ == "__main__":
    for n in (sys.argv[1:] or WALLPAPERS):
        render(n)
