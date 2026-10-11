"""Generates the textures used by the gil and inventory widgets (images/ui/).
Run from the addon root: python tools/make_ui_assets.py
"""
from PIL import Image, ImageDraw, ImageFilter
import os

OUT = os.path.join('images', 'ui')
os.makedirs(OUT, exist_ok=True)
SS = 4  # supersampling for anti-aliasing


def circle(size, fill=True, width=2):
    big = Image.new('RGBA', (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    pad = SS
    box = (pad, pad, size * SS - pad - 1, size * SS - pad - 1)
    if fill:
        d.ellipse(box, fill=(255, 255, 255, 255))
    else:
        d.ellipse(box, outline=(255, 255, 255, 255), width=width * SS)
    return big.resize((size, size), Image.LANCZOS)


# Slot dot (tinted per state) and ring (outline drawn over empty slots).
circle(32, True).save(os.path.join(OUT, 'dot.png'))
circle(32, False, 3).save(os.path.join(OUT, 'ring.png'))

# Panel master: FFXI-like dark navy window with soft border and the classic highlight line.
W = H = 64
R = 7
C = 12  # corner slice size
big = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
mask = Image.new('L', (W * SS, H * SS), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, W * SS - 1, H * SS - 1), radius=R * SS, fill=255)
grad = Image.new('RGBA', (W * SS, H * SS))
gd = ImageDraw.Draw(grad)
top, bottom = (30, 36, 70), (12, 14, 32)
for y in range(H * SS):
    t = y / (H * SS - 1)
    col = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (225,)
    gd.line((0, y, W * SS, y), fill=col)
big.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(big)
d.rounded_rectangle((0, 0, W * SS - 1, H * SS - 1), radius=R * SS, outline=(120, 135, 185, 200), width=SS)
# highlight lines just inside the top and bottom border
d.line((R * SS, 2 * SS, (W - R) * SS, 2 * SS), fill=(205, 214, 235, 170), width=SS)
d.line((R * SS, (H - 3) * SS, (W - R) * SS, (H - 3) * SS), fill=(150, 160, 190, 90), width=SS)
master = big.resize((W, H), Image.LANCZOS)
master.save(os.path.join(OUT, 'panel_master.png'))


def crop(box, name):
    master.crop(box).save(os.path.join(OUT, 'panel_' + name + '.png'))


crop((0, 0, C, C), 'tl')
crop((W - C, 0, W, C), 'tr')
crop((0, H - C, C, H), 'bl')
crop((W - C, H - C, W, H), 'br')
crop((C, 0, C + 4, C), 't')             # stretched horizontally
crop((C, H - C, C + 4, H), 'b')
crop((0, C, C, H - C), 'l')             # stretched vertically (keeps the gradient)
crop((W - C, C, W, H - C), 'r')
crop((C, C, C + 4, H - C), 'c')         # stretched both ways (vertical gradient)
print('ok', sorted(os.listdir(OUT)))


# ---- config menu icons -------------------------------------------------------
import math


def gear(size=32, teeth=8):
    big = Image.new('RGBA', (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    cx = cy = size * SS / 2
    r_out, r_in, r_hole = size * SS * 0.46, size * SS * 0.34, size * SS * 0.14
    pts = []
    for i in range(teeth * 2):
        a0 = math.pi * 2 * i / (teeth * 2)
        r = r_out if i % 2 == 0 else r_in
        for da in (-0.17, 0.17):
            a = a0 + da
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    d.polygon(pts, fill=(255, 255, 255, 255))
    d.ellipse((cx - r_in, cy - r_in, cx + r_in, cy + r_in), fill=(255, 255, 255, 255))
    d.ellipse((cx - r_hole, cy - r_hole, cx + r_hole, cy + r_hole), fill=(0, 0, 0, 0))
    return big.resize((size, size), Image.LANCZOS)


def check(size=32):
    big = Image.new('RGBA', (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    s = size * SS
    d.line([(s * 0.18, s * 0.52), (s * 0.42, s * 0.76), (s * 0.84, s * 0.26)], fill=(255, 255, 255, 255),
           width=int(s * 0.14), joint='curve')
    return big.resize((size, size), Image.LANCZOS)


def cross(size=32):
    big = Image.new('RGBA', (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    s = size * SS
    w = int(s * 0.12)
    d.line([(s * 0.24, s * 0.24), (s * 0.76, s * 0.76)], fill=(255, 255, 255, 255), width=w)
    d.line([(s * 0.76, s * 0.24), (s * 0.24, s * 0.76)], fill=(255, 255, 255, 255), width=w)
    return big.resize((size, size), Image.LANCZOS)


gear().save(os.path.join(OUT, 'gear.png'))
check().save(os.path.join(OUT, 'check.png'))
cross().save(os.path.join(OUT, 'close.png'))
print('icons ok')
