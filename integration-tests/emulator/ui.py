#!/usr/bin/env python3
"""Tiny adb + uiautomator driver for the emulator UI run (CI only).

  ui.py find  <text>            print "x y" of the centre of the first node whose
                                text or content-desc equals <text>, ignoring case
                                (exit 1 if none)
  ui.py tap   <text> [timeout]  wait for <text>, then tap it
  ui.py wait  <text> [timeout]  wait until <text> is on screen
  ui.py texts                   print every visible text / content-desc (debugging)

uiautomator can only dump an idle window, and CrossDrop animates all the time
(Drip bobs and blinks). When a dump fails, the helper briefly switches the
system animation scales to 0 — React Native reports that as Reduce Motion, so
the app goes still — dumps, and restores them.
"""
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

SCALES = ("animator_duration_scale", "transition_animation_scale", "window_animation_scale")


def adb(*args, check=True):
    return subprocess.run(["adb", *args], capture_output=True, text=True, check=check).stdout


def set_scales(value):
    for key in SCALES:
        adb("shell", "settings", "put", "global", key, value)


def dump():
    for attempt in range(2):
        if attempt == 1:
            set_scales("0")
            time.sleep(1.2)
        try:
            out = adb("shell", "uiautomator", "dump", "/sdcard/cd-ui.xml", check=False)
            if "dumped" in out.lower():
                return ET.fromstring(adb("exec-out", "cat", "/sdcard/cd-ui.xml"))
        finally:
            if attempt == 1:
                set_scales("1")
    return None


def nodes(root):
    for node in root.iter("node"):
        text = node.get("text") or ""
        desc = node.get("content-desc") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        yield text, desc, ((x1 + x2) // 2, (y1 + y2) // 2)


def find(label):
    root = dump()
    if root is None:
        return None
    want = label.casefold()
    for text, desc, centre in nodes(root):
        if want in (text.casefold(), desc.casefold()):
            return centre
    return None


def wait(label, timeout=30.0):
    end = time.time() + timeout
    while time.time() < end:
        centre = find(label)
        if centre:
            return centre
        time.sleep(1)
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "texts":
        root = dump()
        for text, desc, centre in nodes(root) if root is not None else []:
            if text or desc:
                print(f"{centre[0]},{centre[1]}\t{text or ''}\t{desc or ''}")
        return
    label = sys.argv[2]
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
    if cmd == "find":
        centre = find(label)
    else:
        centre = wait(label, timeout)
    if not centre:
        print(f"not found: {label}", file=sys.stderr)
        sys.exit(1)
    if cmd == "tap":
        adb("shell", "input", "tap", str(centre[0]), str(centre[1]))
    print(f"{centre[0]} {centre[1]}")


if __name__ == "__main__":
    main()
