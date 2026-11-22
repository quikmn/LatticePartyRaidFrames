"""A choice sheet of six blue-fire styles for the 5-second rule ring's burning state (nothing here goes in the addon).

    python -P tools/fivesecond_fire_options.py

Writes Media/fivesecond-fire-options.png: each style at 150 px and again at the real 64 px. Deterministic.
The ring, its fill, core line and halo are the addon's own textures from fivesecond_art.py.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fivesecond_art as art  # noqa: E402

OUT = os.path.join(art.ROOT, "Media", "fivesecond-fire-options.png")

S = 150                       # ring box at preview size
PW, PH = 360, 400             # one big panel
CX, CY = PW / 2, 236          # ring centre in the panel
RC = art.RC / 256 * S         # ring centre line radius (display px)
RW = art.W / 256 * S          # half thickness
RO, RI = RC + RW, RC - RW
GAP_HALF = art.GAP / 2

BLUE = np.array([0x4f, 0xb4, 0xff]) / 255
HOT = np.array([0.86, 0.95, 1.0])
DEEP = np.array([0.16, 0.42, 1.0])


def rng(seed):
    art.RNG = np.random.default_rng(seed)


def panel_grid():
    return art.grid(PW, PH)


def polar():
    x, y = panel_grid()
    dx, dy = x - CX, y - CY
    return x, y, np.hypot(dx, dy), art.theta_of(dx, dy)


def soft(a, sigma):
    return art.blur(a, sigma)


def background():
    img = np.zeros((PH, PW, 3))
    yy = np.linspace(0, 1, PH)[:, None, None]
    img[...] = (np.array([27, 33, 44]) / 255) * (1 - yy) + (np.array([10, 12, 17]) / 255) * yy
    return img


def add(img, alpha, color, strength=1.0):
    img += np.clip(alpha, 0, 1)[..., None] * np.array(color)[None, None, :] * strength
    np.clip(img, 0, 1, out=img)


def ring(img, tex, halo=1.0, fill=1.0, coreline=1.0, tint=BLUE):
    if halo:
        art.place(img, art.resized(tex["glow"], 2 * S, 2 * S), CX, CY, tint, 0.95 * halo, "add")
    art.place(img, art.resized(tex["track"], S, S), CX, CY)
    art.place(img, art.resized(tex["fill"], S, S), CX, CY, tint, fill)
    if coreline:
        core = art.resized(tex["core"], S, S)
        art.place(img, core, CX, CY, (1, 1, 1), 0.75 * coreline, "add")
        art.place(img, core, CX, CY, tint, 0.5 * coreline, "add")


def tongues(list_, warp, noise_scale=6):
    """Flame tongues on the panel grid (warped by noise). Returns (body, core)."""
    x, y = panel_grid()
    if warp:
        x = x + art.noise((PH, PW), noise_scale) * warp
        y = y + art.noise((PH, PW), noise_scale) * warp
    body = np.zeros((PH, PW))
    core = np.zeros((PH, PW))
    for t in list_:
        b, c = art.tongue(x, y, **t)
        body = 1 - (1 - body) * (1 - b * 0.85)
        core = np.maximum(core, c)
    return body, core


def on_ring(a_deg, r):
    a = math.radians(a_deg)
    return CX + r * math.sin(a), CY - r * math.cos(a)


# ----------------------------------------------------------------------------------------------------------------
# the six styles: each draws the whole burning look into img
# ----------------------------------------------------------------------------------------------------------------
def style_spirit(img, tex):
    """A: soft translucent wisps rising gently off the top half, no hard edges."""
    rng(101)
    ring(img, tex, halo=0.8)
    ts = []
    for a in np.linspace(-95, 95, 9):
        if abs(a) < 8:
            continue
        bx, by = on_ring(a + art.RNG.uniform(-6, 6), RC)
        ts.append(dict(base=(bx, by), direction=(art.RNG.uniform(-0.15, 0.15) + math.sin(math.radians(a)) * 0.25, -1),
                       length=art.RNG.uniform(55, 105), width=art.RNG.uniform(11, 17),
                       wobble=art.RNG.uniform(-22, 22), bend=art.RNG.uniform(-0.3, 0.3)))
    ts.append(dict(base=(CX, CY - RC + 6), direction=(0, -1), length=120, width=15, wobble=14, bend=0.1))
    body, core = tongues(ts, 9, 10)
    body = soft(body, 3.0)
    add(img, soft(body, 10) * 0.35, BLUE)
    add(img, body * 0.55, BLUE)
    add(img, soft(core, 2.5) * 0.25, HOT)


def style_burning_ring(img, tex):
    """B: many small candle tongues all along the ring, all leaning up."""
    rng(202)
    ring(img, tex, halo=0.7)
    ts = []
    n = 26
    for i in range(n):
        a = GAP_HALF + 10 + (360 - art.GAP - 20) * i / (n - 1)
        r = RC + RW * 0.35
        bx, by = on_ring(a, r)
        ts.append(dict(base=(bx, by), direction=(math.sin(math.radians(a)) * 0.25, -1),
                       length=art.RNG.uniform(15, 24), width=art.RNG.uniform(4.2, 5.6),
                       wobble=art.RNG.uniform(-2.5, 2.5), bend=art.RNG.uniform(-0.15, 0.15)))
    body, core = tongues(ts, 1.5, 4)
    add(img, soft(body, 5) * 0.45, BLUE)
    add(img, body * 0.85, BLUE)
    add(img, core * 0.85, HOT)


def style_inner(img, tex):
    """C: a calm flame burning inside the ring, contained; the ring glows."""
    rng(303)
    ring(img, tex, halo=1.0)
    x, y, r, _ = polar()
    ts = [dict(base=(CX, CY + RI * 0.55), direction=(0, -1), length=RI * 1.35, width=RI * 0.38, wobble=4, bend=0.04),
          dict(base=(CX - RI * 0.22, CY + RI * 0.5), direction=(-0.15, -1), length=RI * 0.8, width=RI * 0.2, wobble=-3, bend=-0.1),
          dict(base=(CX + RI * 0.22, CY + RI * 0.5), direction=(0.15, -1), length=RI * 0.85, width=RI * 0.2, wobble=3, bend=0.1)]
    body, core = tongues(ts, 2.0, 7)
    inside = np.clip((RI - 3 - r) / 6, 0, 1)
    body, core = soft(body, 1.2) * inside, core * inside
    add(img, soft(body, 6) * 0.35 * inside, BLUE)
    add(img, body * 0.9, BLUE)
    add(img, core * 0.9, HOT)


def style_comet(img, tex):
    """D: a bright flame head running clockwise round the ring, a fading fire trail behind it."""
    rng(404)
    ring(img, tex, halo=0.6)
    x, y, r, th = polar()
    head = 135.0
    behind = (head - th) % 360                      # degrees behind the head (clockwise motion)
    ahead = (th - head) % 360
    # trail behind the head; just ahead of it a quick soft taper (no hard edge where the trail starts)
    fade = np.maximum(np.exp(-behind / 70) * np.clip((260 - behind) / 40, 0, 1), np.exp(-ahead / 3) * (ahead < 40))
    n1 = art.noise((PH, PW), 4)
    band = np.exp(-((r - RC - 2 - fade * 6 * (1 + n1)) / (RW * (0.9 + 1.4 * fade))) ** 2)
    trail = band * fade
    # flicks off the trail, blown outwards and back
    ts = []
    for k in range(9):
        a = head - 8 - k * 20 - art.RNG.uniform(0, 8)
        s = math.exp(-(head - a) / 70)
        bx, by = on_ring(a, RC + RW * 0.4)
        rad = np.array([math.sin(math.radians(a)), -math.cos(math.radians(a))])
        tang = np.array([-math.cos(math.radians(a)), -math.sin(math.radians(a))])  # backwards along the ring
        d = rad * 0.8 + tang * 0.9
        ts.append(dict(base=(bx, by), direction=d, length=8 + 26 * s, width=3 + 6 * s, wobble=art.RNG.uniform(-3, 3), bend=0.1))
    body, core = tongues(ts, 2.0, 4)
    hx, hy = on_ring(head, RC)
    headglow = np.exp(-(((x - hx) ** 2 + (y - hy) ** 2) / (2 * 9 ** 2)))
    headcore = np.exp(-(((x - hx) ** 2 + (y - hy) ** 2) / (2 * 4 ** 2)))
    add(img, soft(trail + headglow, 8) * 0.5, BLUE)
    add(img, trail * 0.8 + body * 0.75, BLUE)
    add(img, headglow * 0.9, BLUE)
    add(img, np.clip(headcore + core * 0.7 + trail * 0.25 * fade, 0, 1), HOT)


def style_hearth(img, tex):
    """E: one full, rounded flame filling the middle and rising out through the gap, soft heat glow round it."""
    rng(505)
    ring(img, tex, halo=0.9)
    x, y, r, _ = polar()
    base_y = CY + RI * 0.62
    # a smooth teardrop: round belly in the ring, tip well above the gap
    tip = CY - RO - 46
    h = base_y - tip
    t = np.clip((base_y - y) / h, 0, 1)
    sway = 3 * np.sin(t * 3.0)
    width = RI * 0.78 * np.sqrt(np.clip(t * 4.0, 0, 1)) * (1 - t) ** 0.9 * (1 + 0.6 * (1 - t))
    inside = (y <= base_y + 6)
    bottom = np.exp(-np.clip(y - base_y, 0, None) ** 2 / (2 * 5 ** 2))
    body = np.exp(-((x - CX - sway) / np.maximum(width, 0.5)) ** 2 * 1.4) * bottom * inside * (1 - t ** 4)
    body = soft(body, 2.0)
    ct = np.clip((base_y - 4 - y) / (h * 0.55), 0, 1)
    cw = RI * 0.38 * np.sqrt(np.clip(ct * 4, 0, 1)) * (1 - ct) ** 0.9
    core = np.exp(-((x - CX - sway) / np.maximum(cw, 0.5)) ** 2 * 1.6) * (y <= base_y) * (1 - ct ** 3)
    core = soft(core, 1.5)
    add(img, soft(body, 16) * 0.55, BLUE)
    add(img, body * 0.85, BLUE)
    add(img, core * 0.95, HOT)


def style_aura(img, tex):
    """F: no flames: a breathing deep-blue heat haze round the ring, faint embers drifting up."""
    rng(606)
    x, y, r, th = polar()
    n = art.noise((PH, PW), 9)
    haze = np.exp(-((r - RC) / (RW * 2.2 + 6 * n)) ** 2)
    haze = soft(haze, 4)
    up = np.clip((CY + RO - y) / (2 * RO), 0, 1) ** 0.5      # a little more above, heat rises
    add(img, soft(haze, 18) * (0.6 + 0.3 * up), DEEP)
    add(img, haze * 0.55, DEEP)
    ring(img, tex, halo=0.6, tint=np.array([0.3, 0.62, 1.0]))
    embers = np.zeros((PH, PW))
    for _ in range(14):
        ex = CX + art.RNG.uniform(-RO * 0.9, RO * 0.9)
        ey = CY - art.RNG.uniform(RO * 0.2, RO + 70)
        s = art.RNG.uniform(1.0, 1.9)
        a = art.RNG.uniform(0.4, 1.0) * np.clip((ey - (CY - RO - 80)) / 60, 0.2, 1)
        embers = np.maximum(embers, a * np.exp(-(((x - ex) ** 2 + (y - ey) ** 2) / (2 * s ** 2))))
    add(img, soft(embers, 3) * 0.8, BLUE)
    add(img, embers, HOT)


STYLES = [
    ("A", "Spirit fire", style_spirit),
    ("B", "Burning ring", style_burning_ring),
    ("C", "Inner flame", style_inner),
    ("D", "Comet chase", style_comet),
    ("E", "Blue hearth", style_hearth),
    ("F", "Aura: glow and embers", style_aura),
]


def main():
    tex = {"track": art.make_track(), "fill": art.make_fill(), "core": art.make_core(), "glow": art.make_glow()}
    small_w = int(PW * 64 / S)
    small_h = int(PH * 64 / S)
    CW, CH = PW + small_w + 30, PH + 50
    cols, rows = 3, 2
    sheet = Image.new("RGB", (CW * cols + 20, CH * rows + 70), (12, 14, 19))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/segoeuib.ttf", 22)
        small = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 15)
    except OSError:
        font = small = ImageFont.load_default()
    d.text((20, 18), "5-second rule ring: burning state, six blue-fire styles. Each at 150 px, and at the real 64 px on the right.",
           fill=(160, 172, 190), font=small)
    for i, (letter, name, fn) in enumerate(STYLES):
        img = background()
        fn(img, tex)
        big = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
        smallimg = big.resize((small_w, small_h), Image.LANCZOS)
        cx, cy = 10 + (i % cols) * CW, 60 + (i // cols) * CH
        sheet.paste(big, (cx, cy))
        bg = Image.fromarray((background() * 255 + 0.5).astype(np.uint8), "RGB").crop((0, 0, small_w + 20, PH))
        sheet.paste(bg, (cx + PW, cy))
        sheet.paste(smallimg, (cx + PW + 10, cy + int(CY - CY * 64 / S)))
        d.text((cx + 14, cy + PH + 8), f"{letter}  {name}", fill=(225, 232, 244), font=font)
        d.text((cx + PW + 14, cy + PH - 24), "64 px", fill=(120, 130, 148), font=small)
    sheet.save(OUT)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
