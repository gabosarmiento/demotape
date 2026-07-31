#!/usr/bin/env python3
"""Verify burned-in captions fit inside the frame.

The bug this catches: caption font size is derived from the video HEIGHT, so a portrait/square
reframe (1080x1350) gets a BIGGER font than the 1440x900 landscape original while having 360px
LESS width. The block is then centred with x = (frameW - blockW)/2, which simply goes negative
and clips the text off both edges.

Reading pixel brightness alone can't tell caption glyphs from bright app UI. So instead this
diffs each captioned frame against the SAME frame of the uncaptioned source: the only thing that
differs is the caption, which gives its exact bounding box.

Usage:
    check-caption-fit.py <captioned-frames-dir> <uncaptioned-frames-dir> [safe-fraction]

Both dirs must hold frames grabbed at identical timestamps (DemoTape --frame writes
<seconds>s.png, so matching filenames line up). Exits non-zero if any caption overflows.
"""
import sys
import os
import glob

from PIL import Image, ImageChops


def caption_bbox(captioned_path, plain_path, threshold=28):
    """Bounding box of what the caption added, or None if the frames are identical."""
    a = Image.open(captioned_path).convert("L")
    b = Image.open(plain_path).convert("L")
    if a.size != b.size:
        raise SystemExit(f"size mismatch: {a.size} vs {b.size} ({os.path.basename(captioned_path)})")
    diff = ImageChops.difference(a, b)
    # Drop compression noise; keep only solid caption pixels.
    mask = diff.point(lambda v: 255 if v > threshold else 0)
    return mask.getbbox(), a.size


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cap_dir, plain_dir = sys.argv[1], sys.argv[2]
    safe = float(sys.argv[3]) if len(sys.argv) > 3 else 0.94

    frames = sorted(glob.glob(os.path.join(cap_dir, "*.png")))
    if not frames:
        raise SystemExit(f"no frames in {cap_dir}")

    overflow, captioned, blank = [], 0, 0
    for cap in frames:
        plain = os.path.join(plain_dir, os.path.basename(cap))
        if not os.path.exists(plain):
            print(f"  skip {os.path.basename(cap)} (no matching uncaptioned frame)")
            continue
        bbox, (w, h) = caption_bbox(cap, plain)
        if bbox is None:
            blank += 1
            continue
        captioned += 1
        left, _, right, _ = bbox
        margin = w * (1 - safe) / 2
        bad = left < margin or right > w - margin
        status = "OVERFLOW" if bad else "ok"
        print(f"  {os.path.basename(cap):>16}  x={left:>4}..{right:<4} of {w}  "
              f"margin={margin:.0f}  {status}")
        if bad:
            overflow.append((os.path.basename(cap), left, right, w))

    print(f"\n{captioned} captioned frame(s), {blank} with no caption drawn")
    if overflow:
        print(f"FAIL: {len(overflow)} frame(s) overflow the safe width")
        for name, left, right, w in overflow:
            print(f"  {name}: spans {left}..{right} in a {w}px frame")
        return 1
    print("PASS: every caption sits inside the safe width")
    return 0


if __name__ == "__main__":
    sys.exit(main())
