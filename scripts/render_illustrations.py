#!/usr/bin/env python3
"""Renders CrossDrop's 3D illustrations with a tiny signed-distance ray marcher.

Everything is original and procedural (NumPy + Pillow): a soft mint character
("Drip") and a few props, lit with a key light, sky fill, rim light, soft
shadows and ambient occlusion, on a transparent background with a baked
contact shadow. Output: design/illustrations/<name>.png

Usage: python3 scripts/render_illustrations.py [name ...] [--size 900] [--preview]
"""
import math
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "design/illustrations")

# ---------------------------------------------------------------- math helpers


def v(*a):
    return np.array(a, dtype=np.float32)


def norm(x):
    return x / np.maximum(np.linalg.norm(x, axis=-1, keepdims=True), 1e-8)


def length(x):
    return np.sqrt(np.maximum((x * x).sum(-1), 0))


def rot(ax=0.0, ay=0.0, az=0.0):
    """Local->world rotation (degrees, applied X then Y then Z)."""
    ax, ay, az = (math.radians(t) for t in (ax, ay, az))
    rx = np.array([[1, 0, 0], [0, math.cos(ax), -math.sin(ax)], [0, math.sin(ax), math.cos(ax)]], np.float32)
    ry = np.array([[math.cos(ay), 0, math.sin(ay)], [0, 1, 0], [-math.sin(ay), 0, math.cos(ay)]], np.float32)
    rz = np.array([[math.cos(az), -math.sin(az), 0], [math.sin(az), math.cos(az), 0], [0, 0, 1]], np.float32)
    return rz @ ry @ rx


def local(p, c, R=None):
    q = p - c
    return q if R is None else q @ R  # == R^T (p - c)


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)


# ---------------------------------------------------------------- primitives (return callables p -> d)


def sphere(c, r):
    c = v(*c)
    return lambda p: length(p - c) - r


def ellipsoid(c, r, R=None):
    c, r = v(*c), v(*r)

    def f(p):
        q = local(p, c, R)
        k0 = length(q / r)
        k1 = length(q / (r * r))
        return k0 * (k0 - 1) / np.maximum(k1, 1e-6)

    return f


def rbox(c, b, rad, R=None):
    c, b = v(*b) * 0 + v(*c), v(*b)

    def f(p):
        q = np.abs(local(p, c, R)) - b + rad
        return length(np.maximum(q, 0)) + np.minimum(np.max(q, axis=-1), 0) - rad

    return f


def capsule(a, b, r):
    a, b = v(*a), v(*b)
    ba = b - a
    bb = float(ba @ ba)

    def f(p):
        pa = p - a
        h = np.clip((pa @ ba) / bb, 0, 1)
        return length(pa - h[:, None] * ba) - r

    return f


def rcyl(c, r, h, rad, R=None):
    """Rounded cylinder along local Y, radius r, half-height h."""
    c = v(*c)

    def f(p):
        q = local(p, c, R)
        d = np.stack([length(q[:, [0, 2]]) - r + rad, np.abs(q[:, 1]) - h + rad], -1)
        return np.minimum(np.max(d, -1), 0) + length(np.maximum(d, 0)) - rad

    return f


def tri_prism(c, pts, h, rad, R=None):
    """Extruded 2D triangle (in local XZ), half-thickness h along local Y, rounded."""
    c = v(*c)
    P = [np.array(t, np.float32) for t in pts]

    def sd_tri(q):
        p0, p1, p2 = P
        e0, e1, e2 = p1 - p0, p2 - p1, p0 - p2
        v0, v1, v2 = q - p0, q - p1, q - p2

        def seg(vv, e):
            t = np.clip((vv @ e) / float(e @ e), 0, 1)
            return vv - t[:, None] * e

        pq0, pq1, pq2 = seg(v0, e0), seg(v1, e1), seg(v2, e2)
        s = np.sign(e0[0] * e2[1] - e0[1] * e2[0])
        d0 = np.stack([(pq0 * pq0).sum(-1), s * (v0[:, 0] * e0[1] - v0[:, 1] * e0[0])], -1)
        d1 = np.stack([(pq1 * pq1).sum(-1), s * (v1[:, 0] * e1[1] - v1[:, 1] * e1[0])], -1)
        d2 = np.stack([(pq2 * pq2).sum(-1), s * (v2[:, 0] * e2[1] - v2[:, 1] * e2[0])], -1)
        dmin = np.minimum(np.minimum(d0, d1), d2)
        return -np.sqrt(dmin[:, 0]) * np.sign(dmin[:, 1])

    def f(p):
        q = local(p, c, R)
        d2 = sd_tri(q[:, [0, 2]]) + rad
        w = np.stack([d2, np.abs(q[:, 1]) - h], -1)
        return np.minimum(np.max(w, -1), 0) + length(np.maximum(w, 0)) - rad

    return f


def torus_arc(c, R_major, r_minor, a0, a1, Rm=None):
    """Arc of a torus in local XY plane from angle a0 to a1 (degrees), centred at c."""
    c = v(*c)
    t0, t1 = math.radians(a0), math.radians(a1)
    mid = (t0 + t1) / 2
    half = (t1 - t0) / 2

    def f(p):
        q = local(p, c, Rm)
        ang = np.arctan2(q[:, 1], q[:, 0])
        da = np.angle(np.exp(1j * (ang - mid)))
        da = np.clip(da, -half, half) + mid
        nearest = np.stack([np.cos(da) * R_major, np.sin(da) * R_major, np.zeros_like(da)], -1)
        return length(q - nearest) - r_minor

    return f


# ---------------------------------------------------------------- materials

MAT = {
    # name: (base rgb 0..1, specular, roughness, subsurface, emissive)
    "mint": ((0.36, 0.86, 0.52), 0.55, 0.28, 0.55, 0.0),
    "lime": ((0.70, 0.95, 0.42), 0.55, 0.28, 0.55, 0.0),
    "eye": ((0.04, 0.07, 0.05), 1.0, 0.12, 0.0, 0.0),
    "white_glow": ((1.0, 1.0, 1.0), 0.0, 0.5, 0.0, 1.0),
    "cheek": ((1.0, 0.56, 0.62), 0.2, 0.5, 0.4, 0.0),
    "paper": ((0.97, 0.99, 0.97), 0.25, 0.45, 0.2, 0.0),
    "plane": ((0.95, 0.99, 0.97), 0.35, 0.35, 0.25, 0.0),
    "silver": ((0.86, 0.90, 0.88), 0.8, 0.22, 0.0, 0.0),
    "graphite": ((0.10, 0.14, 0.12), 0.7, 0.25, 0.0, 0.0),
    "screen": ((0.55, 0.95, 0.70), 0.6, 0.15, 0.0, 0.55),
    "ink": ((0.06, 0.11, 0.08), 0.7, 0.25, 0.0, 0.0),
    "box": ((0.86, 0.96, 0.89), 0.35, 0.4, 0.2, 0.0),
    "boxlid": ((0.74, 0.92, 0.80), 0.35, 0.4, 0.2, 0.0),
    "gold": ((1.0, 0.82, 0.38), 0.7, 0.25, 0.1, 0.15),
}


class Scene:
    """Objects grouped for smooth blending; each object has a material."""

    def __init__(self):
        self.objs = []  # (fn, mat, group, k)

    def add(self, fn, mat, group=None, k=0.0):
        self.objs.append((fn, mat, group, k))
        return self

    def eval(self, p, want_mat=False):
        groups = {}
        order = []
        per_obj = []
        for fn, mat, group, k in self.objs:
            d = fn(p)
            per_obj.append(d)
            key = group if group is not None else id(fn)
            if key not in groups:
                groups[key] = d
                order.append(key)
            else:
                groups[key] = smin(groups[key], d, k) if k > 0 else np.minimum(groups[key], d)
        dist = None
        for key in order:
            dist = groups[key] if dist is None else np.minimum(dist, groups[key])
        if not want_mat:
            return dist
        # Material: nearest raw object (blended surfaces take the closest part).
        stack = np.stack(per_obj, 0)
        idx = np.argmin(stack, 0)
        return dist, idx


# ---------------------------------------------------------------- the character


def drip(s, pos=(0, 0, 0), scale=1.0, yaw=0.0, mood="smile", arms="down", look=(0.0, 0.0)):
    """Drip: a soft mint drop-shaped character. Origin at its base (y=0)."""
    px, py, pz = pos
    S = scale
    R = rot(0, yaw, 0)

    def P(x, y, z):
        q = R @ v(x * S, y * S, z * S)
        return (px + q[0], py + q[1], pz + q[2])

    g = f"drip{len(s.objs)}"
    # Body: a squashed sphere with a soft tip, smoothly blended (drop silhouette).
    s.add(ellipsoid(P(0, 0.62, 0), (0.62 * S, 0.58 * S, 0.58 * S), R), "mint", g, 0.2 * S)
    s.add(sphere(P(0, 1.06, 0.02), 0.34 * S), "lime", g, 0.25 * S)
    s.add(sphere(P(0.04, 1.36, 0.0), 0.15 * S), "lime", g, 0.22 * S)
    s.add(sphere(P(0.12, 1.55, -0.02), 0.06 * S), "lime", g, 0.16 * S)
    # Arms
    if arms == "down":
        s.add(capsule(P(-0.5, 0.62, 0.12), P(-0.7, 0.36, 0.22), 0.12 * S), "mint", g, 0.12 * S)
        s.add(capsule(P(0.5, 0.62, 0.12), P(0.7, 0.36, 0.22), 0.12 * S), "mint", g, 0.12 * S)
    elif arms == "up":
        s.add(capsule(P(-0.5, 0.75, 0.1), P(-0.78, 1.15, 0.12), 0.12 * S), "mint", g, 0.12 * S)
        s.add(capsule(P(0.5, 0.75, 0.1), P(0.78, 1.15, 0.12), 0.12 * S), "mint", g, 0.12 * S)
    elif arms == "hold":
        s.add(capsule(P(-0.48, 0.5, 0.2), P(-0.3, 0.4, 0.66), 0.12 * S), "mint", g, 0.12 * S)
        s.add(capsule(P(0.48, 0.5, 0.2), P(0.3, 0.4, 0.66), 0.12 * S), "mint", g, 0.12 * S)
    elif arms == "wave":
        s.add(capsule(P(-0.5, 0.62, 0.12), P(-0.7, 0.36, 0.22), 0.12 * S), "mint", g, 0.12 * S)
        s.add(capsule(P(0.5, 0.78, 0.1), P(0.86, 1.2, 0.0), 0.12 * S), "mint", g, 0.12 * S)
    elif arms == "binoculars":
        s.add(capsule(P(-0.5, 0.62, 0.15), P(-0.4, 0.76, 0.7), 0.12 * S), "mint", g, 0.12 * S)
        s.add(capsule(P(0.5, 0.62, 0.15), P(0.4, 0.76, 0.7), 0.12 * S), "mint", g, 0.12 * S)
    elif arms == "cable":
        s.add(capsule(P(-0.5, 0.62, 0.12), P(-0.7, 0.36, 0.22), 0.12 * S), "mint", g, 0.12 * S)
        s.add(capsule(P(0.5, 0.62, 0.15), P(0.72, 0.62, 0.55), 0.12 * S), "mint", g, 0.12 * S)
    elif arms == "hug":
        s.add(capsule(P(-0.5, 0.55, 0.2), P(-0.2, 0.42, 0.6), 0.12 * S), "mint", g, 0.12 * S)
        s.add(capsule(P(0.5, 0.55, 0.2), P(0.2, 0.42, 0.6), 0.12 * S), "mint", g, 0.12 * S)
    # Feet
    s.add(ellipsoid(P(-0.24, 0.07, 0.12), (0.17 * S, 0.08 * S, 0.2 * S), R), "mint", g, 0.08 * S)
    s.add(ellipsoid(P(0.24, 0.07, 0.12), (0.17 * S, 0.08 * S, 0.2 * S), R), "mint", g, 0.08 * S)

    # Face (front is +Z)
    lx, ly = look
    ex, ey, ez = 0.2, 0.86, 0.55
    if mood == "happy":
        for sx in (-1, 1):
            s.add(torus_arc(P(sx * ex + lx, ey + ly - 0.02, ez + 0.01), 0.075 * S, 0.026 * S, 20, 160, R), "eye")
    elif mood == "blink":
        for sx in (-1, 1):
            s.add(capsule(P(sx * ex + lx - 0.055, ey + ly - 0.01, ez + 0.012), P(sx * ex + lx + 0.055, ey + ly - 0.01, ez + 0.012), 0.024 * S), "eye")
    elif mood == "sleepy":
        for sx in (-1, 1):
            s.add(torus_arc(P(sx * ex + lx, ey + ly + 0.03, ez + 0.01), 0.065 * S, 0.024 * S, 205, 335, R), "eye")
    elif mood == "hidden":
        pass
    else:
        for sx in (-1, 1):
            s.add(ellipsoid(P(sx * ex + lx, ey + ly, ez), (0.065 * S, 0.09 * S, 0.05 * S), R), "eye")
            s.add(sphere(P(sx * ex + lx + 0.022, ey + ly + 0.035, ez + 0.042), 0.022 * S), "white_glow")
    # Mouth
    if mood in ("smile", "happy", "blink"):
        s.add(torus_arc(P(lx, 0.74 + ly, 0.565), 0.1 * S, 0.024 * S, 200, 340, R), "eye")
    elif mood == "open":
        s.add(ellipsoid(P(lx, 0.68 + ly, 0.56), (0.075 * S, 0.06 * S, 0.04 * S), R), "eye")
    elif mood == "sleepy":
        s.add(ellipsoid(P(lx, 0.7 + ly, 0.56), (0.035 * S, 0.035 * S, 0.03 * S), R), "eye")
    elif mood == "worried":
        s.add(torus_arc(P(lx, 0.62 + ly, 0.555), 0.085 * S, 0.022 * S, 25, 155, R), "eye")
        for sx in (-1, 1):
            a = P(sx * (ex + 0.08) + lx, ey + ly + 0.13, ez - 0.02)
            b = P(sx * (ex - 0.06) + lx, ey + ly + 0.18, ez - 0.01)
            s.add(capsule(a, b, 0.02 * S), "eye")
    elif mood == "hidden":
        s.add(torus_arc(P(lx, 0.68 + ly, 0.565), 0.08 * S, 0.022 * S, 200, 340, R), "eye")
    # Cheeks
    for sx in (-1, 1):
        s.add(ellipsoid(P(sx * 0.33 + lx, 0.72 + ly, 0.47), (0.07 * S, 0.04 * S, 0.03 * S), R), "cheek")
    return s


# ---------------------------------------------------------------- props


def phone(s, c, R, scale=1.0):
    S = scale
    s.add(rbox(c, (0.34 * S, 0.66 * S, 0.05 * S), 0.07 * S, R), "graphite")
    off = R @ v(0, 0, 0.045 * S)
    sc = tuple(np.array(c) + off)
    s.add(rbox(sc, (0.3 * S, 0.61 * S, 0.012 * S), 0.05 * S, R), "screen")


def laptop(s, c, yaw=0.0, scale=1.0, open_deg=105):
    S = scale
    Rb = rot(0, yaw, 0)
    s.add(rbox(c, (0.85 * S, 0.035 * S, 0.58 * S), 0.03 * S, Rb), "silver")
    hinge = np.array(c) + Rb @ v(0, 0.035 * S, -0.56 * S)
    Rl = Rb @ rot(-(open_deg - 90), 0, 0)
    lid_c = hinge + Rl @ v(0, 0.56 * S, 0)
    s.add(rbox(tuple(lid_c), (0.85 * S, 0.56 * S, 0.03 * S), 0.03 * S, Rl), "silver")
    scr_c = lid_c + Rl @ v(0, 0.01 * S, 0.028 * S)
    s.add(rbox(tuple(scr_c), (0.78 * S, 0.49 * S, 0.008 * S), 0.02 * S, Rl), "screen")


def document(s, c, R, scale=1.0, mat="paper"):
    S = scale
    s.add(rbox(c, (0.36 * S, 0.46 * S, 0.025 * S), 0.04 * S, R), mat)
    for i, w in enumerate((0.22, 0.24, 0.16)):
        lc = np.array(c) + R @ v(-0.08 * S + (0.24 - w) * S * 0, (0.18 - i * 0.14) * S, 0.03 * S)
        s.add(capsule(tuple(lc + R @ v(-w * S, 0, 0)), tuple(lc + R @ v(w * S, 0, 0)), 0.022 * S), "screen")


def paper_plane(s, c, R, scale=1.0):
    S = scale
    # Two wings: triangles in local XZ, nose at +Z.
    s.add(tri_prism(c, [(0, 0.9 * S), (-0.75 * S, -0.55 * S), (0, -0.25 * S)], 0.012 * S, 0.012 * S, R @ rot(0, 0, 8)), "plane")
    s.add(tri_prism(c, [(0, 0.9 * S), (0.75 * S, -0.55 * S), (0, -0.25 * S)], 0.012 * S, 0.012 * S, R @ rot(0, 0, -8)), "plane")
    keel = np.array(c) + R @ v(0, -0.09 * S, 0)
    s.add(tri_prism(tuple(keel), [(0, 0.85 * S), (-0.1 * S, -0.5 * S), (0.1 * S, -0.5 * S)], 0.07 * S, 0.012 * S, R), "plane")


def package(s, c, R, scale=1.0):
    S = scale
    s.add(rbox(c, (0.62 * S, 0.42 * S, 0.5 * S), 0.08 * S, R), "box")
    lid = np.array(c) + R @ v(0, 0.42 * S, 0)
    s.add(rbox(tuple(lid), (0.66 * S, 0.07 * S, 0.54 * S), 0.06 * S, R), "boxlid")
    band = np.array(c) + R @ v(0, 0, 0.5 * S)
    s.add(rbox(tuple(band), (0.12 * S, 0.42 * S, 0.02 * S), 0.02 * S, R), "boxlid")


def badge_check(s, c, R, scale=1.0):
    S = scale
    s.add(rcyl(c, 0.32 * S, 0.06 * S, 0.05 * S, R @ rot(90, 0, 0)), "ink")
    front = np.array(c) + R @ v(0, 0, 0.07 * S)
    a = front + R @ v(-0.13 * S, 0.0, 0)
    b = front + R @ v(-0.03 * S, -0.1 * S, 0)
    d = front + R @ v(0.15 * S, 0.12 * S, 0)
    s.add(capsule(tuple(a), tuple(b), 0.035 * S), "white_glow")
    s.add(capsule(tuple(b), tuple(d), 0.035 * S), "white_glow")


def shield(s, c, R, scale=1.0):
    S = scale
    s.add(rcyl(c, 0.34 * S, 0.05 * S, 0.05 * S, R @ rot(90, 0, 0)), "gold")
    front = np.array(c) + R @ v(0, 0, 0.06 * S)
    s.add(rbox(tuple(front + R @ v(0, -0.06 * S, 0)), (0.12 * S, 0.1 * S, 0.02 * S), 0.03 * S, R), "ink")
    s.add(torus_arc(tuple(front + R @ v(0, 0.05 * S, 0)), 0.08 * S, 0.025 * S, 0, 180, R), "ink")


def binoculars(s, c, R, scale=1.0):
    S = scale
    cc = np.array(c, np.float32)
    for sx in (-1, 1):
        tube = cc + R @ v(sx * 0.13 * S, 0, 0)
        s.add(rcyl(tuple(tube), 0.1 * S, 0.14 * S, 0.03 * S, R @ rot(90, 0, 0)), "graphite")
        lens = tube + R @ v(0, 0, 0.14 * S)
        s.add(rcyl(tuple(lens), 0.075 * S, 0.012 * S, 0.008 * S, R @ rot(90, 0, 0)), "screen")
    s.add(rbox(tuple(cc), (0.08 * S, 0.035 * S, 0.06 * S), 0.02 * S, R), "graphite")


def plug_cable(s, start, R, scale=1.0):
    S = scale
    a = np.array(start, np.float32)
    pts = [a + R @ v(x * S, y * S, z * S) for x, y, z in ((0, 0, 0), (0.25, -0.2, 0.1), (0.45, -0.45, 0.05), (0.75, -0.55, -0.05), (1.05, -0.5, -0.1))]
    for p0, p1 in zip(pts, pts[1:]):
        s.add(capsule(tuple(p0), tuple(p1), 0.045 * S), "graphite", "cable", 0.05 * S)
    s.add(rbox(tuple(a + R @ v(-0.08 * S, 0.05 * S, 0)), (0.11 * S, 0.08 * S, 0.08 * S), 0.03 * S, R), "silver")
    for sx in (-1, 1):
        prong = a + R @ v(-0.2 * S, 0.07 * S, sx * 0.035 * S)
        s.add(capsule(tuple(prong), tuple(prong + R @ v(-0.1 * S, 0, 0)), 0.018 * S), "gold")
    spark = pts[-1] + R @ v(0.15 * S, 0.05 * S, 0)
    sparkle(s, tuple(spark), 0.08 * S)


def zzz(s, c, scale=1.0):
    cc = np.array(c, np.float32)
    for i, k in enumerate((1.0, 0.75, 0.55)):
        p = cc + v(0.16 * i * scale, 0.2 * i * scale, 0)
        s.add(sphere(tuple(p), 0.06 * k * scale), "lime")


def orb(s, c, r, mat="gold"):
    s.add(sphere(c, r), mat)


def sparkle(s, c, size, R=None):
    R = R if R is not None else np.eye(3, dtype=np.float32)
    cc = np.array(c, np.float32)
    s.add(capsule(tuple(cc + R @ v(0, -size, 0)), tuple(cc + R @ v(0, size, 0)), size * 0.18), "gold")
    s.add(capsule(tuple(cc + R @ v(-size * 0.8, 0, 0)), tuple(cc + R @ v(size * 0.8, 0, 0)), size * 0.18), "gold")


# ---------------------------------------------------------------- renderer


def render(scene, size=900, cam=(0, 1.3, 6.2), target=(0, 0.9, 0), fov=30.0, ss=2, ground=0.0, preview=False):
    W = H = size * ss
    cam, target = v(*cam), v(*target)
    fwd = norm(target - cam)
    right = norm(np.cross(fwd, v(0, 1, 0)))
    up = np.cross(right, fwd)
    t = math.tan(math.radians(fov) / 2)
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    u = (2 * (xs + 0.5) / W - 1) * t
    vv = (1 - 2 * (ys + 0.5) / H) * t
    dirs = norm(fwd[None, None, :] + u[..., None] * right + vv[..., None] * up).reshape(-1, 3)
    N = dirs.shape[0]
    ro = np.repeat(cam[None, :], N, 0)

    # March
    tdist = np.zeros(N, np.float32)
    hit = np.zeros(N, bool)
    active = np.arange(N)
    tmax = 30.0
    for _ in range(140 if not preview else 90):
        if active.size == 0:
            break
        p = ro[active] + dirs[active] * tdist[active, None]
        d = scene.eval(p)
        tdist[active] += d * 0.9
        done_hit = d < 0.0015 * (1 + tdist[active] * 0.15)
        hit[active[done_hit]] = True
        keep = (~done_hit) & (tdist[active] < tmax)
        active = active[keep]

    # Ground plane (shadow catcher) intersection
    with np.errstate(divide="ignore", invalid="ignore"):
        tg = (ground - ro[:, 1]) / dirs[:, 1]
    ground_hit = (~hit) & (dirs[:, 1] < 0) & (tg > 0)

    rgb = np.zeros((N, 3), np.float32)
    alpha = np.zeros(N, np.float32)

    key_dir = norm(v(-0.55, 0.85, 0.6))
    fill_dir = norm(v(0.7, 0.3, 0.5))
    rim_dir = norm(v(0.3, 0.5, -1.0))

    def soft_shadow(pts, ldir, k=10.0, steps=40):
        res = np.ones(len(pts), np.float32)
        tt = np.full(len(pts), 0.02, np.float32)
        idx = np.arange(len(pts))
        for _ in range(steps):
            if idx.size == 0:
                break
            d = scene.eval(pts[idx] + ldir * tt[idx, None])
            res[idx] = np.minimum(res[idx], np.clip(k * d / tt[idx], 0, 1))
            tt[idx] += np.clip(d, 0.02, 0.25)
            alive = (d > 0.001) & (tt[idx] < 8)
            res[idx[d <= 0.001]] = 0
            idx = idx[alive]
        return res * res * (3 - 2 * res)

    hi = np.where(hit)[0]
    if hi.size:
        p = ro[hi] + dirs[hi] * tdist[hi, None]
        e = 0.0015
        n = np.stack([
            scene.eval(p + v(e, 0, 0)) - scene.eval(p - v(e, 0, 0)),
            scene.eval(p + v(0, e, 0)) - scene.eval(p - v(0, e, 0)),
            scene.eval(p + v(0, 0, e)) - scene.eval(p - v(0, 0, e)),
        ], -1)
        n = norm(n)
        _, midx = scene.eval(p, want_mat=True)
        names = [scene.objs[i][1] for i in range(len(scene.objs))]
        base = np.zeros((hi.size, 3), np.float32)
        spec_s = np.zeros(hi.size, np.float32)
        rough = np.zeros(hi.size, np.float32)
        sss = np.zeros(hi.size, np.float32)
        emis = np.zeros(hi.size, np.float32)
        for i, name in enumerate(names):
            m = midx == i
            if not m.any():
                continue
            col, sp, ro_, ss_, em = MAT[name]
            base[m] = col
            spec_s[m] = sp
            rough[m] = ro_
            sss[m] = ss_
            emis[m] = em
        # Mint body: lime toward the top, deeper green toward the bottom.
        is_body = np.isin(midx, [i for i, nm in enumerate(names) if nm in ("mint", "lime")])
        if is_body.any():
            hy = np.clip((p[is_body, 1] - ground) / 1.6, 0, 1)[:, None]
            top, bot = v(0.74, 0.96, 0.32), v(0.05, 0.55, 0.30)
            base[is_body] = bot * (1 - hy) + top * hy

        # AO
        ao = np.ones(hi.size, np.float32)
        for k in range(1, 6):
            h = 0.03 * k * k
            ao -= (h - scene.eval(p + n * h)) * (0.55 / k)
        ao = np.clip(ao, 0.25, 1)

        sh = soft_shadow(p + n * 0.004, key_dir, steps=48 if not preview else 24)
        vdir = -dirs[hi]
        ndl = (n @ key_dir)
        wrap = np.clip((ndl + sss) / (1 + sss), 0, 1)
        diff = wrap * (0.35 + 0.65 * sh)
        sky = 0.5 + 0.5 * n[:, 1]
        amb = (v(0.86, 0.97, 0.9) * sky[:, None] + v(0.55, 0.75, 0.6) * (1 - sky[:, None])) * 0.32
        fill = np.clip(n @ fill_dir, 0, 1)[:, None] * v(0.75, 0.95, 0.85) * 0.25
        col = base * (v(1.0, 0.98, 0.94) * diff[:, None] * 1.18 + amb * ao[:, None] + fill)
        # Specular (Blinn) and a soft highlight
        hvec = norm(key_dir + vdir)
        shin = 2 / np.maximum(rough ** 4, 1e-4) - 2
        spec = np.power(np.clip((n * hvec).sum(-1), 0, 1), np.clip(shin, 4, 400)) * spec_s * sh
        col += spec[:, None] * 1.2
        # Rim + fresnel
        fres = np.power(1 - np.clip((n * vdir).sum(-1), 0, 1), 3)
        rim = np.clip(n @ rim_dir, 0, 1) * 0.0 + fres
        col += rim[:, None] * v(0.85, 1.0, 0.92) * 0.24 * (0.5 + 0.5 * spec_s[:, None])
        # Subsurface glow for the body
        col += (base * sss[:, None] * 0.18 * (1 - np.clip(ndl, 0, 1))[:, None])
        col = col * (1 - emis[:, None]) + base * emis[:, None] * 1.15 + col * emis[:, None] * 0.25
        rgb[hi] = col
        alpha[hi] = 1.0

    gi = np.where(ground_hit)[0]
    if gi.size:
        gp = ro[gi] + dirs[gi] * tg[gi, None]
        # Contact shadow: soft key-light shadow plus occlusion under objects.
        sh = soft_shadow(gp + v(0, 0.002, 0), norm(v(-0.25, 1.0, 0.3)), k=4.0, steps=40 if not preview else 20)
        occ = np.ones(gi.size, np.float32)
        for k in range(1, 5):
            h = 0.06 * k * k
            occ -= np.clip(h - scene.eval(gp + v(0, h, 0)), 0, None) * (0.5 / k)
        occ = np.clip(occ, 0, 1)
        dark = np.clip((1 - sh) * 0.55 + (1 - occ) * 0.6, 0, 0.75)
        rgb[gi] = v(0.08, 0.32, 0.18)
        alpha[gi] = dark

    # Tone map + gamma
    rgb = rgb / (1 + rgb * 0.18)
    rgb = np.clip(rgb, 0, 1) ** (1 / 2.2)
    img = np.concatenate([rgb * alpha[:, None], alpha[:, None]], -1).reshape(H, W, 4)
    if ss > 1:
        img = img.reshape(size, ss, size, ss, 4).mean((1, 3))
    a = img[..., 3:4]
    out = np.where(a > 1e-4, img[..., :3] / np.maximum(a, 1e-4), 0)
    out = np.concatenate([out, a], -1)
    return soften_edges(Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGBA"))


def soften_edges(img, band=0.16):
    """Fade the translucent ground shadow out before it reaches the image edge.

    The shadow catcher is an infinite plane, so a long shadow can run off the
    canvas and show as a straight cut on the app background. Opaque pixels
    (Drip and props) are left alone.
    """
    a = np.asarray(img).astype(np.float32) / 255
    h, w = a.shape[:2]
    y, x = np.mgrid[0:h, 0:w]
    edge = np.minimum(np.minimum(x, w - 1 - x) / w, np.minimum(y, h - 1 - y) / h) / band
    t = np.clip(edge, 0, 1)
    fade = t * t * (3 - 2 * t)
    shadow = a[..., 3] < 0.8
    a[..., 3] = np.where(shadow, a[..., 3] * fade, a[..., 3])
    return Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGBA")


# ---------------------------------------------------------------- compositions


def scene_welcome():
    s = Scene()
    drip(s, pos=(0, 0, 0.2), scale=1.0, mood="smile", arms="wave")
    phone(s, (-1.25, 0.95, -0.2), rot(0, 25, 12), 0.95)
    laptop(s, (1.35, 0.04, -0.35), yaw=-28, scale=0.8)
    orb(s, (-0.62, 1.95, -0.1), 0.09, "lime")
    orb(s, (0.95, 1.85, 0.2), 0.06, "lime")
    sparkle(s, (-0.25, 2.05, 0.3), 0.12)
    return s, dict(cam=(0, 1.35, 6.8), target=(0, 0.95, 0), fov=32)


def scene_nearby():
    s = Scene()
    drip(s, pos=(-0.2, 0, 0), scale=1.0, mood="smile", arms="wave")
    phone(s, (0.78, 1.32, 0.25), rot(0, -18, -14), 0.55)
    orb(s, (-1.0, 1.55, 0.0), 0.08, "lime")
    sparkle(s, (1.25, 1.95, 0.2), 0.1)
    return s, dict(cam=(0, 1.15, 5.6), target=(0, 0.85, 0), fov=30)


def scene_pairing():
    s = Scene()
    drip(s, pos=(0, 0, 0), scale=1.0, mood="open", arms="hold", look=(0.0, 0.02))
    shield(s, (0, 0.42, 0.85), rot(-8, 0, 0), 0.8)
    sparkle(s, (0.85, 1.7, 0.2), 0.11)
    sparkle(s, (-0.9, 1.45, 0.1), 0.08)
    return s, dict(cam=(0, 1.15, 5.6), target=(0, 0.85, 0), fov=30)


def scene_incoming():
    s = Scene()
    package(s, (0, 0.42, 0.25), rot(0, -18, 0), 1.05)
    drip(s, pos=(0.05, 0.9, -0.05), scale=0.82, mood="smile", arms="up")
    document(s, (-1.05, 1.15, 0.35), rot(-10, 30, 18), 0.7)
    document(s, (1.05, 1.35, 0.25), rot(-6, -28, -14), 0.6)
    return s, dict(cam=(0, 1.55, 6.6), target=(0, 1.15, 0), fov=32)


def scene_sending():
    s = Scene()
    paper_plane(s, (0, 0.62, 0), rot(-14, 58, 6), 1.35)
    drip(s, pos=(0.1, 0.66, -0.2), scale=0.6, yaw=-30, mood="happy", arms="up")
    sparkle(s, (1.25, 1.5, 0.3), 0.1)
    orb(s, (-1.3, 1.35, 0.0), 0.07, "lime")
    orb(s, (-0.9, 1.75, -0.2), 0.05, "lime")
    return s, dict(cam=(0, 3.2, 5.6), target=(0, 0.95, 0), fov=31)


def scene_done():
    s = Scene()
    drip(s, pos=(0, 0, 0), scale=1.0, mood="happy", arms="up")
    badge_check(s, (0.82, 1.48, 0.45), rot(0, -20, 0), 0.8)
    sparkle(s, (-0.95, 1.7, 0.2), 0.13)
    sparkle(s, (-0.55, 2.0, 0.0), 0.07)
    orb(s, (1.05, 0.55, 0.3), 0.07, "lime")
    return s, dict(cam=(0, 1.2, 5.8), target=(0, 0.9, 0), fov=31)


def scene_mac():
    s = Scene()
    laptop(s, (-0.35, 0.04, 0), yaw=12, scale=0.9)
    drip(s, pos=(0.95, 0, 0.45), scale=0.7, yaw=-28, mood="smile", arms="wave")
    document(s, (-1.45, 0.95, 0.45), rot(-10, 28, 14), 0.5)
    return s, dict(cam=(0, 1.7, 6.6), target=(0, 0.75, 0), fov=30)


def scene_welcome_blink():
    s, cam = scene_welcome()
    s.objs.clear()
    drip(s, pos=(0, 0, 0.2), scale=1.0, mood="blink", arms="wave")
    phone(s, (-1.25, 0.95, -0.2), rot(0, 25, 12), 0.95)
    laptop(s, (1.35, 0.04, -0.35), yaw=-28, scale=0.8)
    orb(s, (-0.62, 1.95, -0.1), 0.09, "lime")
    orb(s, (0.95, 1.85, 0.2), 0.06, "lime")
    sparkle(s, (-0.25, 2.05, 0.3), 0.12)
    return s, cam


def scene_nearby_blink():
    s = Scene()
    drip(s, pos=(-0.2, 0, 0), scale=1.0, mood="blink", arms="wave")
    phone(s, (0.78, 1.32, 0.25), rot(0, -18, -14), 0.55)
    orb(s, (-1.0, 1.55, 0.0), 0.08, "lime")
    sparkle(s, (1.25, 1.95, 0.2), 0.1)
    return s, dict(cam=(0, 1.15, 5.6), target=(0, 0.85, 0), fov=30)


def scene_sleepy():
    s = Scene()
    drip(s, pos=(0, 0, 0), scale=1.0, yaw=-8, mood="sleepy", arms="hug")
    zzz(s, (0.55, 1.6, 0.3), 1.4)
    return s, dict(cam=(0, 1.15, 5.6), target=(0, 0.85, 0), fov=30)


def scene_searching():
    s = Scene()
    drip(s, pos=(0, 0, 0), scale=1.0, mood="hidden", arms="binoculars")
    binoculars(s, (0, 0.86, 0.78), rot(-4, 0, 0), 1.55)
    sparkle(s, (0.95, 1.65, 0.2), 0.1)
    orb(s, (-1.0, 1.4, 0.0), 0.07, "lime")
    return s, dict(cam=(0, 1.15, 5.6), target=(0, 0.85, 0), fov=30)


def scene_nowifi():
    s = Scene()
    drip(s, pos=(-0.35, 0, 0), scale=1.0, mood="worried", arms="cable")
    plug_cable(s, (0.55, 0.64, 0.62), rot(0, -20, 0), 1.35)
    return s, dict(cam=(0, 1.15, 5.8), target=(0.1, 0.8, 0), fov=31)


def scene_failed():
    s = Scene()
    drip(s, pos=(0.15, 0, 0), scale=1.0, mood="worried", arms="down")
    document(s, (-0.95, 0.55, 0.35), rot(-8, 26, 28), 0.7)
    orb(s, (1.0, 1.5, 0.1), 0.06, "lime")
    return s, dict(cam=(0, 1.15, 5.8), target=(0, 0.8, 0), fov=31)


SCENES = {
    "welcome-blink": scene_welcome_blink,
    "nearby-blink": scene_nearby_blink,
    "sleepy": scene_sleepy,
    "searching": scene_searching,
    "nowifi": scene_nowifi,
    "failed": scene_failed,
    "welcome": scene_welcome,
    "nearby": scene_nearby,
    "pairing": scene_pairing,
    "incoming": scene_incoming,
    "sending": scene_sending,
    "done": scene_done,
    "mac": scene_mac,
}


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    size = 900
    preview = "--preview" in sys.argv
    if "--size" in sys.argv:
        size = int(sys.argv[sys.argv.index("--size") + 1])
        args = [a for a in args if a != str(size)]
    os.makedirs(OUT, exist_ok=True)
    if "--soften" in sys.argv:
        # Re-apply the edge fade to already rendered files: --soften a.png b.png
        for path in args:
            soften_edges(Image.open(path).convert("RGBA")).save(path, optimize=True)
            print("softened", path)
        sys.exit(0)
    for name in args or SCENES:
        scene, camargs = SCENES[name]()
        img = render(scene, size=size, ss=1 if preview else 2, preview=preview, **camargs)
        img.save(os.path.join(OUT, f"{name}.png"), optimize=True)
        print("rendered", name)
