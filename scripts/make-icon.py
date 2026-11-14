#!/usr/bin/env python3
"""Draws the PitchLane app icon (Resources/AppIcon.png, 1024x1024) in code: a glowing note lane with the sung
pitch line landing on a note at the playhead. Needs Pillow. Run: python3 scripts/make-icon.py"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4096                      # draw large, scale down for smooth edges
OUT = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, "..", "Resources", "AppIcon.png")

TEAL = (51, 217, 191)
PINK = (255, 115, 140)
VIOLET = (158, 115, 255)
GOLD = (255, 209, 77)
WHITE = (255, 255, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background():
    top, bottom = (44, 18, 104), (6, 8, 22)
    img = Image.new("RGB", (S, S))
    px = img.load()
    # Diagonal gradient.
    column = [lerp(top, bottom, min(1, max(0, (y / S) * 0.9 + 0.05))) for y in range(S)]
    for y in range(S):
        row = column[y]
        for x in range(0, S, 1):
            px[x, y] = row
    return img


def glow_layer(draw_fn, blur, strength=1.0):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(layer))
    blurred = layer.filter(ImageFilter.GaussianBlur(blur))
    if strength != 1.0:
        r, g, b, a = blurred.split()
        a = a.point(lambda v: min(255, int(v * strength)))
        blurred = Image.merge("RGBA", (r, g, b, a))
    return blurred


def capsule(draw, x0, x1, y, h, color, alpha=255):
    draw.rounded_rectangle([x0, y - h / 2, x1, y + h / 2], radius=h / 2, fill=color + (alpha,))


def pitch_curve():
    """Sung pitch: rises from the lower left and settles on the note at the playhead."""
    pts = []
    for i in range(0, 101):
        t = i / 100
        x = S * (0.07 + 0.25 * t)
        ease = t * t * (3 - 2 * t)
        y = S * (0.80 - 0.30 * ease + 0.03 * math.sin(t * math.pi * 3) * (1 - t))
        pts.append((x, y))
    return pts


def main():
    img = background().convert("RGBA")

    # Colour blooms.
    for color, cx, cy, r, s in [(TEAL, 0.15, 0.12, 0.55, 0.55), (PINK, 0.95, 0.95, 0.6, 0.5), (VIOLET, 0.8, 0.2, 0.45, 0.45)]:
        img.alpha_composite(glow_layer(lambda d, c=color, cx=cx, cy=cy, r=r: d.ellipse(
            [S * (cx - r * 0.5), S * (cy - r * 0.5), S * (cx + r * 0.5), S * (cy + r * 0.5)], fill=c + (120,)), S * 0.12, s))

    lane = ImageDraw.Draw(img)
    # Lane lines.
    for y in [0.40, 0.61]:
        lane.line([(0, S * y), (S, S * y)], fill=(200, 205, 230, 26), width=int(S * 0.008))

    playhead_x = S * 0.32
    note_h = S * 0.125
    notes = [
        (S * 0.21, S * 0.66, S * 0.50, TEAL),     # the note being sung, crossing the playhead
        (S * 0.62, S * 0.90, S * 0.27, GOLD),     # golden note ahead
        (S * 0.58, S * 0.92, S * 0.74, VIOLET),   # another ahead
    ]

    # Playhead column glow + line.
    img.alpha_composite(glow_layer(lambda d: d.rectangle([playhead_x - S * 0.05, 0, playhead_x + S * 0.05, S], fill=TEAL + (60,)), S * 0.04))
    ImageDraw.Draw(img).line([(playhead_x, S * 0.14), (playhead_x, S * 0.86)], fill=TEAL + (130,), width=int(S * 0.014))

    # Notes: glow, body, glossy top highlight.
    for x0, x1, y, color in notes:
        img.alpha_composite(glow_layer(lambda d, x0=x0, x1=x1, y=y, c=color: capsule(d, x0, x1, y, note_h * 1.6, c, 170), S * 0.03))
        d = ImageDraw.Draw(img)
        capsule(d, x0, x1, y, note_h, color)
        capsule(d, x0 + note_h * 0.35, x1 - note_h * 0.35, y - note_h * 0.2, note_h * 0.22, WHITE, 90)

    # Sung pitch: wide glow, then a tapering pink-to-white line.
    curve = pitch_curve()
    img.alpha_composite(glow_layer(lambda d: d.line(curve, fill=PINK + (230,), width=int(S * 0.09), joint="curve"), S * 0.04))
    d = ImageDraw.Draw(img)
    for i in range(len(curve) - 1):
        t = i / (len(curve) - 1)
        color = lerp(PINK, (255, 220, 228), t * t)
        width = int(S * (0.02 + 0.04 * t))
        d.line([curve[i], curve[i + 1]], fill=color + (255,), width=width)
        r = width / 2
        d.ellipse([curve[i][0] - r, curve[i][1] - r, curve[i][0] + r, curve[i][1] + r], fill=color + (255,))

    # Cursor on the note at the playhead: bright halo, pink ring, white core.
    cx, cy = curve[-1]
    img.alpha_composite(glow_layer(lambda d: d.ellipse([cx - S * 0.14, cy - S * 0.14, cx + S * 0.14, cy + S * 0.14], fill=WHITE + (210,)), S * 0.05))
    d = ImageDraw.Draw(img)
    d.ellipse([cx - S * 0.088, cy - S * 0.088, cx + S * 0.088, cy + S * 0.088], fill=PINK + (255,))
    d.ellipse([cx - S * 0.058, cy - S * 0.058, cx + S * 0.058, cy + S * 0.058], fill=WHITE + (255,))

    # Sparks flying off the hit.
    for angle, dist, size in [(-45, 0.17, 0.022), (-80, 0.20, 0.016), (-15, 0.21, 0.014), (25, 0.16, 0.014)]:
        a = math.radians(angle)
        sx, sy = cx + math.cos(a) * S * dist, cy + math.sin(a) * S * dist
        img.alpha_composite(glow_layer(lambda d, sx=sx, sy=sy, size=size: d.ellipse(
            [sx - S * size * 2, sy - S * size * 2, sx + S * size * 2, sy + S * size * 2], fill=GOLD + (200,)), S * 0.01))
        ImageDraw.Draw(img).ellipse([sx - S * size, sy - S * size, sx + S * size, sy + S * size], fill=(255, 240, 200, 255))

    # App icons must be opaque and square (iOS rounds the corners itself).
    final = img.convert("RGB").resize((OUT, OUT), Image.LANCZOS)
    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    final.save(DEST, "PNG", optimize=True)
    print(f"wrote {os.path.normpath(DEST)} ({OUT}x{OUT})")


if __name__ == "__main__":
    sys.exit(main())
