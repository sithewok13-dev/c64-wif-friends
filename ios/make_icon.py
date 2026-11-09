"""Draws the app icon: the C64's blue screen with two joysticks.
Run: python3 ios/make_icon.py  (needs Pillow). Writes ios/icons/*.png."""
import os
from PIL import Image, ImageDraw

BLUE, LIGHT, RED, WHITE, BLACK = (0x35, 0x28, 0x79), (0x6c, 0x5e, 0xb5), (0xe0, 0x47, 0x5a), (0xe9, 0xe6, 0xff), (0x1a, 0x16, 0x30)

def draw(size=1024):
    im = Image.new("RGB", (size, size), LIGHT)
    d = ImageDraw.Draw(im)
    s = size / 1024
    d.rectangle([90 * s, 90 * s, 934 * s, 934 * s], fill=BLUE)
    for cx, tilt in ((330, -60), (694, 60)):          # two joysticks, leaning together
        base_y = 760
        d.rounded_rectangle([(cx - 150) * s, (base_y - 40) * s, (cx + 150) * s, (base_y + 90) * s], radius=30 * s, fill=BLACK)
        top = (cx + tilt, 430)
        d.line([cx * s, base_y * s, top[0] * s, top[1] * s], fill=BLACK, width=int(56 * s))
        d.ellipse([(top[0] - 78) * s, (top[1] - 78) * s, (top[0] + 78) * s, (top[1] + 78) * s], fill=RED)
        d.ellipse([(cx - 120) * s, (base_y - 70) * s, (cx - 60) * s, (base_y - 10) * s], fill=RED)
    d.rectangle([90 * s, 150 * s, 934 * s, 210 * s], fill=WHITE)  # "READY." bar
    return im

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
os.makedirs(here, exist_ok=True)
big = draw()
for name, px in (("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180),
                 ("AppIcon76x76@2x~ipad.png", 152), ("AppIcon83.5x83.5@2x~ipad.png", 167),
                 ("AppIcon-1024.png", 1024)):
    big.resize((px, px), Image.LANCZOS).save(os.path.join(here, name))
