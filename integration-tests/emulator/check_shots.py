#!/usr/bin/env python3
"""Pixel checks on the emulator screenshots (CI only).

Flags straight seams in the background: a column (or row) where the colour
jumps sharply for most of the screen's height (width), which is what a
backdrop or panel that stops short looks like. Content edges (cards, text)
are short, so they don't trip it.

  check_shots.py <shots-dir>   prints one line per finding, then a summary
"""
import os
import sys

import numpy as np
from PIL import Image

JUMP = 9          # colour difference (sum over RGB) between neighbouring pixels
COVERAGE = 0.55   # fraction of the band that must jump at the same column/row


def seams(img):
    a = np.asarray(img.convert("RGB"), np.int32)
    h, w, _ = a.shape
    top, bottom = int(h * 0.08), int(h * 0.88)  # skip status bar and gesture bar
    band = a[top:bottom]
    found = []
    dx = np.abs(np.diff(band, axis=1)).sum(axis=2) > JUMP  # (rows, w-1)
    cols = dx.mean(axis=0)
    for x in np.where(cols > COVERAGE)[0]:
        # Cards sit 24 dp from the screen edge; their long sides are not seams.
        if 72 < x < w - 72:
            found.append(f"vertical seam at x={x} ({cols[x]:.0%} of height)")
    dy = np.abs(np.diff(a[:, 4:-4], axis=0)).sum(axis=2) > JUMP
    rows = dy.mean(axis=1)
    for y in np.where(rows > 0.97)[0]:
        if top < y < bottom:
            found.append(f"horizontal seam at y={y} ({rows[y]:.0%} of width)")
    return found


def main():
    shots = sys.argv[1]
    total = 0
    for name in sorted(os.listdir(shots)):
        if not name.endswith(".png") or os.path.getsize(os.path.join(shots, name)) == 0:
            continue
        for finding in seams(Image.open(os.path.join(shots, name))):
            print(f"SEAM {name}: {finding}")
            total += 1
    print(f"seams found: {total}")


if __name__ == "__main__":
    main()
