#!/usr/bin/env python3
"""Draw the app icon: two rounded screens with a switch arrow between them."""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

BG_TOP = (86, 118, 240)
BG_BOTTOM = (46, 66, 170)
INK = (255, 255, 255)


def rounded(size):
    S = size * 4
    image = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    gradient = Image.new("RGB", (1, S))
    for y in range(S):
        t = y / (S - 1)
        gradient.putpixel((0, y), tuple(
            round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)))
    gradient = gradient.resize((S, S))

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=255)
    image.paste(gradient, (0, 0), mask)

    # Two laptop screens, the left one lit, the right one waiting.
    w, h = int(S * 0.30), int(S * 0.21)
    y = int(S * 0.24)
    for x, fill in ((int(S * 0.13), INK), (int(S * 0.57), None)):
        draw.rounded_rectangle([x, y, x + w, y + h], radius=int(S * 0.02),
                               outline=INK, width=int(S * 0.022), fill=fill)
        base_y = y + h + int(S * 0.035)
        draw.rounded_rectangle([x - int(S * 0.03), y + h + int(S * 0.012), x + w + int(S * 0.03), base_y],
                               radius=int(S * 0.012), fill=INK)

    # The arrow that carries keyboard and mouse across.
    cy = int(S * 0.70)
    x0, x1 = int(S * 0.20), int(S * 0.80)
    draw.line([x0, cy, x1, cy], fill=INK, width=int(S * 0.045))
    head = int(S * 0.07)
    draw.polygon([(x1 + head // 2, cy), (x1 - head, cy - head), (x1 - head, cy + head)], fill=INK)
    draw.polygon([(x0 - head // 2, cy), (x0 + head, cy - head), (x0 + head, cy + head)], fill=INK)

    return image.resize((size, size), Image.LANCZOS)


def main(destination):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "icon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 64, 128, 256, 512, 1024):
            rounded(size).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
            if size > 16:
                rounded(size).save(os.path.join(iconset, f"icon_{size // 2}x{size // 2}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", destination], check=True)


if __name__ == "__main__":
    main(sys.argv[1])
